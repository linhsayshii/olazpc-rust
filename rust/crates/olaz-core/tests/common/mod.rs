//! Case format v1 replay engine shared by `tests/cases.rs` and `tests/session_scenarios.rs`.
//!
//! Runs the real `olaz_core::CoreHandle` + `SessionEffectRunner<ScriptedTransport>` over the real
//! `olaz_net::SessionClient` request builders and `olaz_crypto` AES/ParamCipher crypto.

#![expect(
    dead_code,
    reason = "shared test helper used selectively by each test binary"
)]

use std::collections::BTreeMap;
use std::future::Future;
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use async_trait::async_trait;
use olaz_core::actor::CoreHandle;
use olaz_core::input::{Command, LegacyCookie};
use olaz_core::runner::{Host, SessionEffectRunner};
use olaz_core::state::{CoreFailKind, CoreState, LoginStep, Phase, SessionSnapshot};
use olaz_crypto::{decode_aes, encode_aes, md5_hex, parse_any, parse_secret_key};
use olaz_net::http::{DEFAULT_REQUEST_TIMEOUT, RawResponse, RequestSpec, Transport};
use olaz_net::{
    LoginAccount, NetError, NetworkErrorKind, SessionClient, ZaloDomains, ZaloSessionError,
};
use serde::Deserialize;
use serde_json::{Map, Value, json};
use tokio::runtime::Handle;

/// Keys replaced with `"<volatile>"` before canonical request comparison (Case format v1).
pub const VOLATILE_KEYS: &[&str] = &[
    "imei",
    "client_time",
    "ts",
    "signkey",
    "zcid",
    "zcid_ext",
    "params",
    "cookie",
    "zpw_sek",
    "computer_name",
];

/// Test-only canonicalization for `FailReason::Core` so `tests/cases.rs` can compare against
/// recordings captured on an English macOS locale without hard-coding Foundation text in
/// production Rust code (see Q1 in approved design).
///
/// Reproduces `RustCore.mapError(...).localizedDescription` on an `en` macOS locale
/// (including Foundation's `NSError` description without `userInfo`, e.g.
/// `URLError(.cannotConnectToHost).localizedDescription`).
pub fn render_core_fail_en(kind: &CoreFailKind) -> String {
    match kind {
        CoreFailKind::Network(NetworkErrorKind::Timeout) => {
            "The operation couldn\u{2019}t be completed. (NSURLErrorDomain error -1001.)".to_owned()
        }
        CoreFailKind::Network(NetworkErrorKind::ConnectionLost) => {
            "The operation couldn\u{2019}t be completed. (NSURLErrorDomain error -1005.)".to_owned()
        }
        CoreFailKind::Network(NetworkErrorKind::Other) => {
            "The operation couldn\u{2019}t be completed. (NSURLErrorDomain error -1004.)".to_owned()
        }
        CoreFailKind::Session { code, message, url } => ZaloSessionError {
            code: *code,
            message: message.clone(),
            url: url.clone(),
        }
        .to_string(),
        CoreFailKind::Http { status } => format!("Lỗi máy chủ HTTP {status}."),
        CoreFailKind::InvalidJson => "Phản hồi máy chủ không đúng định dạng.".to_owned(),
        CoreFailKind::NotAuthenticated => "Chưa đăng nhập Zalo.".to_owned(),
        CoreFailKind::Crypto(msg) => format!("SQLite step failed: {msg}"),
    }
}

#[derive(Debug, Clone, Deserialize)]
pub struct Case {
    pub format: u32,
    pub domain: String,
    pub name: String,
    #[serde(default)]
    pub slow: bool,
    #[serde(default)]
    pub seed: Seed,
    #[serde(default)]
    pub server: Vec<ServerEntry>,
    #[serde(default)]
    pub steps: Vec<Step>,
    pub expect: Expect,
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct Seed {
    #[serde(default)]
    pub saved_session: Option<Value>,
    #[serde(default)]
    pub domains: Option<Value>,
    #[serde(default)]
    pub legacy_cookie: Option<Value>,
    #[serde(default)]
    pub prefs: BTreeMap<String, String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct ServerEntry {
    pub kind: String,
    pub path: String,
    #[serde(default)]
    pub method: Option<String>,
    #[serde(default)]
    pub repeat: bool,
    #[serde(default)]
    pub response: Option<HttpResponseSpec>,
    #[serde(default)]
    pub accept: Option<bool>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct HttpResponseSpec {
    #[serde(default = "default_status")]
    pub status: u16,
    #[serde(default)]
    pub json: Option<Value>,
    #[serde(default)]
    pub raw: Option<String>,
    #[serde(default)]
    pub error: Option<String>,
    #[serde(default)]
    pub headers: BTreeMap<String, String>,
}

fn default_status() -> u16 {
    200
}

#[derive(Debug, Clone, Deserialize)]
#[serde(untagged)]
pub enum Step {
    Cmd {
        cmd: String,
        #[serde(default)]
        args: Value,
    },
    Await {
        #[serde(rename = "await")]
        predicate: AwaitPredicate,
        #[serde(default)]
        timeout_ms: Option<u64>,
    },
    Snapshot {
        snapshot: String,
    },
}

#[derive(Debug, Clone, Deserialize)]
pub struct AwaitPredicate {
    pub phase: String,
    #[serde(default)]
    pub step: Option<String>,
}

impl AwaitPredicate {
    pub fn matches(&self, snap: &SessionSnapshot) -> bool {
        if snap.phase.kind_name() != self.phase {
            return false;
        }
        match (&self.step, &snap.phase) {
            (None, _) => true,
            (Some(expected_step), Phase::Login(login)) => login.step.kind_name() == expected_step,
            (Some(_), _) => false,
        }
    }
}

#[derive(Debug, Clone, Deserialize)]
pub struct Expect {
    #[serde(default)]
    pub snapshots: BTreeMap<String, Value>,
    #[serde(rename = "final")]
    pub final_state: Value,
    #[serde(default)]
    pub requests: Vec<Value>,
    #[serde(default)]
    pub host: Vec<Value>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct KnownDiff {
    pub domain: String,
    pub name: String,
    pub path: String,
    pub actual: Value,
    #[serde(default)]
    pub reason: String,
}

#[derive(Debug, Clone)]
pub struct CaseRunResult {
    pub snapshots: BTreeMap<String, Value>,
    pub final_state: Value,
    pub requests: Vec<Value>,
    pub host: Vec<Value>,
}

struct ScriptedEntryState {
    spec: ServerEntry,
    consumed: bool,
}

struct ScriptState {
    entries: Vec<ScriptedEntryState>,
    /// True once every remaining unconsumed HTTP entry is a non-repeat `"error": "refused"`.
    /// Matches U1a's fake server stopping its listener: subsequent requests fail with ECONNREFUSED
    /// and are never recorded in `expect.requests`.
    server_down: bool,
}

fn should_stop_server(entries: &[ScriptedEntryState]) -> bool {
    let mut has_remaining = false;
    for entry in entries {
        if entry.spec.kind != "http" || entry.consumed {
            continue;
        }
        has_remaining = true;
        let is_non_repeat_refused = !entry.spec.repeat
            && entry
                .spec
                .response
                .as_ref()
                .and_then(|r| r.error.as_deref())
                == Some("refused");
        if !is_non_repeat_refused {
            return false;
        }
    }
    has_remaining
}

enum ScriptDispatch {
    Refused,
    Matched(Box<ServerEntry>),
    Unscripted,
}

/// Scripted [`Transport`] that plugs directly into `olaz_net::SessionClient`, decrypts incoming
/// `ParamCipher` or session-AES `params`, records canonical Case format v1 requests, and encrypts
/// scripted JSON responses the way Zalo does.
pub struct ScriptedTransport {
    state: Mutex<ScriptState>,
    recorded: Mutex<Vec<Value>>,
    /// Session AES secret key (kept in sync from seed + `getLoginInfo` responses).
    secret_key: Mutex<Option<Vec<u8>>>,
}

impl ScriptedTransport {
    pub fn new(entries: Vec<ServerEntry>, initial_secret_key: Option<Vec<u8>>) -> Self {
        let states: Vec<ScriptedEntryState> = entries
            .into_iter()
            .map(|spec| ScriptedEntryState {
                spec,
                consumed: false,
            })
            .collect();
        let server_down = should_stop_server(&states);
        Self {
            state: Mutex::new(ScriptState {
                entries: states,
                server_down,
            }),
            recorded: Mutex::new(Vec::new()),
            secret_key: Mutex::new(initial_secret_key),
        }
    }

    pub fn has_repeat_entries(&self) -> bool {
        let state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        state
            .entries
            .iter()
            .any(|e| e.spec.kind == "http" && e.spec.repeat)
    }

    pub fn recorded_count(&self) -> usize {
        self.recorded
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .len()
    }

    pub fn recorded_requests_sorted(&self) -> Vec<Value> {
        let mut reqs = self
            .recorded
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone();
        reqs.sort_by(|a, b| {
            let ka = a.get("kind").and_then(Value::as_str).unwrap_or("");
            let kb = b.get("kind").and_then(Value::as_str).unwrap_or("");
            let pa = a.get("path").and_then(Value::as_str).unwrap_or("");
            let pb = b.get("path").and_then(Value::as_str).unwrap_or("");
            let ja = canonical_json_string(a);
            let jb = canonical_json_string(b);
            (ka, pa, ja).cmp(&(kb, pb, jb))
        });
        reqs
    }

    fn update_secret_key_from_response(&self, json_val: &Value) {
        let enk = json_val
            .get("data")
            .and_then(Value::as_object)
            .and_then(|d| d.get("zpw_enk"))
            .and_then(Value::as_str);
        if let Some(enk) = enk {
            let parsed = parse_secret_key(enk);
            if parsed.len() == 16 || parsed.len() == 32 {
                *self
                    .secret_key
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner) = Some(parsed);
            }
        }
    }

    fn dispatch_entry(&self, path: &str, method: &str) -> ScriptDispatch {
        let mut state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        if state.server_down {
            return ScriptDispatch::Refused;
        }
        let mut matched = None;
        for entry in state.entries.iter_mut() {
            if entry.consumed || entry.spec.kind != "http" || entry.spec.path != path {
                continue;
            }
            if let Some(expected_method) = &entry.spec.method
                && !expected_method.eq_ignore_ascii_case(method)
            {
                continue;
            }
            if !entry.spec.repeat {
                entry.consumed = true;
            }
            matched = Some(entry.spec.clone());
            break;
        }
        if should_stop_server(&state.entries) {
            state.server_down = true;
        }
        match matched {
            Some(spec)
                if spec.response.as_ref().and_then(|r| r.error.as_deref()) == Some("refused") =>
            {
                ScriptDispatch::Refused
            }
            Some(spec) => ScriptDispatch::Matched(Box::new(spec)),
            None => ScriptDispatch::Unscripted,
        }
    }
}

fn derive_param_cipher_key(zcid: &str, zcid_ext: &str) -> Vec<u8> {
    let md5_upper = md5_hex(zcid_ext).to_uppercase();
    let n_even: Vec<char> = md5_upper.chars().step_by(2).collect();
    let a_even: Vec<char> = zcid.chars().step_by(2).collect();
    let a_odd: Vec<char> = zcid.chars().skip(1).step_by(2).collect();
    let key: String = n_even
        .iter()
        .take(8)
        .chain(a_even.iter().take(12))
        .chain(a_odd.iter().rev().take(12))
        .collect();
    key.into_bytes()
}

fn is_volatile_key(key: &str) -> bool {
    VOLATILE_KEYS.contains(&key)
}

fn scrub_volatile_value(val: Value) -> Value {
    match val {
        Value::Object(map) => {
            let mut out = Map::new();
            for (k, v) in map {
                if is_volatile_key(&k) {
                    out.insert(k, Value::String("<volatile>".to_owned()));
                } else {
                    out.insert(k, scrub_volatile_value(v));
                }
            }
            Value::Object(out)
        }
        Value::Array(arr) => Value::Array(arr.into_iter().map(scrub_volatile_value).collect()),
        other => other,
    }
}

fn decrypt_request_params(
    req: &RequestSpec,
    session_key: Option<&[u8]>,
) -> (Value, Option<Vec<u8>>) {
    let param_cipher_key = match (req.query_value("zcid"), req.query_value("zcid_ext")) {
        (Some(zcid), Some(zcid_ext)) => Some(derive_param_cipher_key(zcid, zcid_ext)),
        _ => None,
    };

    let raw_params = req.query_value("params").map(str::to_owned).or_else(|| {
        let body = req.body.as_deref()?;
        let body_str = std::str::from_utf8(body).ok()?;
        url::form_urlencoded::parse(body_str.as_bytes())
            .find(|(k, _)| k == "params")
            .map(|(_, v)| v.into_owned())
    });

    let Some(enc_params) = raw_params else {
        return (Value::Null, param_cipher_key);
    };

    let decrypt_key = param_cipher_key.as_deref().or(session_key);
    let decrypted = decrypt_key
        .and_then(|k| decode_aes(k, &enc_params).ok())
        .and_then(|plain| parse_any(plain.as_bytes()))
        .map(scrub_volatile_value)
        .unwrap_or_else(|| Value::String("<volatile>".to_owned()));

    (decrypted, param_cipher_key)
}

fn canonical_http_request(
    req: &RequestSpec,
    session_key: Option<&[u8]>,
    unscripted: bool,
) -> (Value, Option<Vec<u8>>) {
    let (params, param_cipher_key) = decrypt_request_params(req, session_key);

    let mut query_map = BTreeMap::new();
    for (k, v) in &req.query {
        let scrubbed = if is_volatile_key(k) {
            "<volatile>".to_owned()
        } else {
            v.clone()
        };
        query_map.insert(k.clone(), Value::String(scrubbed));
    }
    let query_obj: Map<String, Value> = query_map.into_iter().collect();

    let mut obj = Map::new();
    obj.insert("kind".to_owned(), Value::String("http".to_owned()));
    obj.insert("path".to_owned(), Value::String(req.path()));
    obj.insert(
        "method".to_owned(),
        Value::String(req.method.as_str().to_owned()),
    );
    obj.insert("params".to_owned(), params);
    obj.insert("query".to_owned(), Value::Object(query_obj));
    if unscripted {
        obj.insert("unscripted".to_owned(), Value::Bool(true));
    }
    (Value::Object(obj), param_cipher_key)
}

fn encrypt_response_if_needed(plain: &Value, encrypt_key: Option<&[u8]>) -> Vec<u8> {
    let Some(key) = encrypt_key.filter(|k| k.len() == 16 || k.len() == 32) else {
        return serde_json::to_vec(plain).unwrap_or_default();
    };
    let Some(obj) = plain.as_object() else {
        return serde_json::to_vec(plain).unwrap_or_default();
    };
    // Match Zalo wire format: if `data` is a JSON object/array, AES-encrypt it under the request
    // key (`ParamCipher` key for `reqqr`/`getLoginInfo`, session `zpw_enk` for authenticated calls).
    if let Some(data_val) = obj.get("data")
        && (data_val.is_object() || data_val.is_array())
        && let Ok(data_json) = serde_json::to_string(data_val)
        && let Ok(enc) = encode_aes(key, &data_json)
    {
        let mut wrapped = obj.clone();
        wrapped.insert("data".to_owned(), Value::String(enc));
        return serde_json::to_vec(&Value::Object(wrapped)).unwrap_or_default();
    }
    serde_json::to_vec(plain).unwrap_or_default()
}

impl Transport for ScriptedTransport {
    fn send(
        &self,
        request: RequestSpec,
    ) -> impl Future<Output = Result<RawResponse, NetError>> + Send {
        let session_key = self
            .secret_key
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone();
        let dispatch = self.dispatch_entry(&request.path(), request.method.as_str());

        // Under `tokio::time::pause()`, a small virtual RTT (10ms) guarantees the actor + any
        // `await`/`snapshot` observer finishes draining synchronously before the next HTTP reply
        // arrives, while advancing instantaneously in real time. A scripted `"timeout"` sleeps the
        // request's real idle timeout so `wait_for_qr_scan` hits its 60s deadline floor in one call.
        let mut virtual_rtt = Duration::from_millis(10);
        let result = match dispatch {
            ScriptDispatch::Refused => {
                // Refused requests never reach the server listener, so they are not recorded.
                Err(NetError::network(
                    NetworkErrorKind::Other,
                    "scripted refused",
                ))
            }
            ScriptDispatch::Unscripted => {
                let (canonical, _) = canonical_http_request(&request, session_key.as_deref(), true);
                self.recorded
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner)
                    .push(canonical);
                Ok(RawResponse::new(
                    200,
                    br#"{"error_code":0,"data":{}}"#.to_vec(),
                ))
            }
            ScriptDispatch::Matched(entry) => {
                let (canonical, param_cipher_key) =
                    canonical_http_request(&request, session_key.as_deref(), false);
                let has_params = !canonical.get("params").is_none_or(Value::is_null);
                self.recorded
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner)
                    .push(canonical);
                match entry.response {
                    None => Ok(RawResponse::new(
                        200,
                        br#"{"error_code":0,"data":{}}"#.to_vec(),
                    )),
                    Some(resp) => {
                        if let Some(err) = resp.error.as_deref() {
                            match err {
                                "timeout" => {
                                    virtual_rtt =
                                        request.timeout.unwrap_or(DEFAULT_REQUEST_TIMEOUT);
                                    Err(NetError::network(
                                        NetworkErrorKind::Timeout,
                                        "scripted timeout",
                                    ))
                                }
                                "reset" => Err(NetError::network(
                                    NetworkErrorKind::ConnectionLost,
                                    "scripted reset",
                                )),
                                _ => Err(NetError::network(
                                    NetworkErrorKind::Other,
                                    "scripted error",
                                )),
                            }
                        } else {
                            let body = if let Some(raw) = resp.raw {
                                raw.into_bytes()
                            } else if let Some(json_val) = resp.json {
                                self.update_secret_key_from_response(&json_val);
                                // Encrypt response `data` using ParamCipher key (for reqqr/getLoginInfo)
                                // or session key (for authenticated API calls with `params`).
                                let resp_key = if param_cipher_key.is_some() {
                                    param_cipher_key.as_deref()
                                } else if has_params {
                                    session_key.as_deref()
                                } else {
                                    None
                                };
                                encrypt_response_if_needed(&json_val, resp_key)
                            } else {
                                Vec::new()
                            };
                            let mut raw_resp = RawResponse::new(resp.status, body);
                            for (k, v) in resp.headers {
                                raw_resp = raw_resp.with_header(&k, &v);
                            }
                            Ok(raw_resp)
                        }
                    }
                }
            }
        };

        async move {
            tokio::time::sleep(virtual_rtt).await;
            result
        }
    }
}

/// Fake [`Host`] that answers `load_saved_session` / `load_legacy_cookie` from the case `seed`
/// and records every traced domain activity in Case format v1 `host` order.
pub struct RecordingHost {
    saved_session: Option<String>,
    legacy_cookie: Option<LegacyCookie>,
    calls: Mutex<Vec<Value>>,
}

impl RecordingHost {
    pub fn from_seed(seed: &Seed) -> Self {
        let saved_session = seed
            .saved_session
            .as_ref()
            .and_then(|v| serde_json::to_string(v).ok());
        let legacy_cookie = parse_legacy_cookie_seed(seed.legacy_cookie.as_ref());
        Self {
            saved_session,
            legacy_cookie,
            calls: Mutex::new(Vec::new()),
        }
    }

    pub fn calls(&self) -> Vec<Value> {
        self.calls
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone()
    }

    fn record(&self, call: &str, args: Value) {
        self.calls
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .push(json!({ "call": call, "args": args }));
    }
}

fn parse_legacy_cookie_seed(val: Option<&Value>) -> Option<LegacyCookie> {
    let val = val?;
    match val {
        Value::Null => None,
        Value::String(sek) if !sek.is_empty() => Some(LegacyCookie {
            zpw_sek: sek.clone(),
            imei: None,
        }),
        Value::Object(map) => {
            let sek = map
                .get("zpw_sek")
                .or_else(|| map.get("zpwSek"))
                .and_then(Value::as_str)?
                .to_owned();
            if sek.is_empty() {
                return None;
            }
            let imei = map
                .get("imei")
                .and_then(Value::as_str)
                .filter(|s| !s.is_empty())
                .map(str::to_owned);
            Some(LegacyCookie { zpw_sek: sek, imei })
        }
        _ => None,
    }
}

#[async_trait]
impl Host for RecordingHost {
    async fn load_saved_session(&self) -> Option<String> {
        self.saved_session.clone()
    }

    async fn load_legacy_cookie(&self) -> Option<LegacyCookie> {
        self.legacy_cookie.clone()
    }

    async fn set_pref(&self, _key: String, _value: String) {
        // Storage primitive: reflected in `state.prefs`, not in `host` trace.
    }

    async fn prepare_store(&self, user_id: String, _account: LoginAccount) {
        self.record("prepare_store", json!({ "user_id": user_id }));
    }

    async fn start_ws(&self, endpoints: Vec<String>, _zpw_sek: String) {
        self.record("start_ws", json!({ "endpoints": endpoints }));
    }

    async fn start_long_poll(&self) {
        self.record("start_long_poll", json!({}));
    }

    async fn start_bootstrap(&self) {
        self.record("start_bootstrap", json!({}));
    }

    async fn offer_first_login_transfer(&self, force: bool) {
        self.record("offer_first_login_transfer", json!({ "force": force }));
    }

    async fn reset_domains(&self) {
        self.record("reset_domains", json!({}));
    }

    async fn persist_session(&self, _snapshot_json: String) {
        self.record("persist_session", json!({}));
    }

    async fn clear_session(&self) {
        self.record("clear_session", json!({}));
    }

    async fn mark_expired(&self, _snapshot_json: String) {
        self.record("mark_expired", json!({}));
    }
}

fn extract_seed_domains(seed: &Seed) -> Option<ZaloDomains> {
    if let Some(d) = seed.domains.as_ref()
        && d.as_object().is_some_and(|m| !m.is_empty())
        && let Ok(parsed) = serde_json::from_value::<ZaloDomains>(d.clone())
    {
        return Some(parsed);
    }
    if let Some(saved) = seed.saved_session.as_ref()
        && let Some(d) = saved.get("domains")
        && let Ok(parsed) = serde_json::from_value::<ZaloDomains>(d.clone())
    {
        return Some(parsed);
    }
    None
}

fn extract_seed_secret_key(seed: &Seed) -> Option<Vec<u8>> {
    let saved = seed.saved_session.as_ref()?;
    let enk = saved
        .get("plainAccount")
        .and_then(|a| a.get("zpwEnk"))
        .and_then(Value::as_str)?;
    let key = parse_secret_key(enk);
    (key.len() == 16 || key.len() == 32).then_some(key)
}

fn parse_command(cmd: &str, args: &Value) -> Result<Command, String> {
    match cmd {
        "start" => Ok(Command::Start),
        "refresh_qr" => Ok(Command::RefreshQr),
        "log_out" => Ok(Command::LogOut),
        "session_expired" => {
            let reason = args
                .get("reason")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_owned();
            Ok(Command::SessionExpired { reason })
        }
        "apply_account_profile" => {
            let account: LoginAccount = serde_json::from_value(args.clone())
                .map_err(|e| format!("invalid apply_account_profile args: {e}"))?;
            Ok(Command::ApplyAccountProfile(account))
        }
        other => Err(format!("unknown step cmd: {other}")),
    }
}

/// Runs a single Case format v1 [`Case`] under paused tokio time and returns the observed
/// snapshots, final state, sorted canonical requests, and ordered host calls.
pub async fn run_case(case: &Case) -> Result<CaseRunResult, String> {
    let seed_domains = extract_seed_domains(&case.seed);
    let initial_key = extract_seed_secret_key(&case.seed);
    let transport = Arc::new(ScriptedTransport::new(case.server.clone(), initial_key));

    let client = Arc::new(SessionClient::new(
        ArcTransport(Arc::clone(&transport)),
        "00000000-0000-4000-8000-000000000000-00000000000000000000000000000000".to_owned(),
        "TestMac".to_owned(),
    ));
    if let Some(d) = &seed_domains {
        client.with_session(|s| s.domains = d.clone());
    }

    let host = Arc::new(RecordingHost::from_seed(&case.seed));
    let runner = Arc::new(SessionEffectRunner::with_default_domains(
        Arc::clone(&client),
        Arc::clone(&host) as Arc<dyn Host>,
        Handle::current(),
        seed_domains,
    ));

    let mut initial_state = CoreState::default();
    initial_state.session.prefs = case.seed.prefs.clone();
    let core = CoreHandle::start_with_state(initial_state, runner, Handle::current());

    let mut snapshots = BTreeMap::new();

    for step in &case.steps {
        match step {
            Step::Cmd { cmd, args } => {
                let parsed = parse_command(cmd, args)?;
                if matches!(parsed, Command::ApplyAccountProfile(_)) {
                    let _ = core.send_and_ack(parsed).await;
                } else {
                    core.send(parsed);
                }
            }
            Step::Await { predicate, .. } => {
                let wait_fut = core.wait_until(|snap| predicate.matches(snap));
                let _ = tokio::time::timeout(Duration::from_secs(3600), wait_fut).await;
            }
            Step::Snapshot { snapshot } => {
                if let Some(snap) = core.snapshot().await {
                    snapshots.insert(snapshot.clone(), snap.to_case_json(&render_core_fail_en));
                }
            }
        }
    }

    // Drain remaining finite work cleanly without letting a `repeat: true` long-poll sleep
    // advance virtual time into a 60s QR timeout.
    if !transport.has_repeat_entries() {
        let _ = tokio::time::timeout(Duration::from_secs(3600), core.wait_idle()).await;
    } else {
        let mut prev_reqs = transport.recorded_count();
        for _ in 0..200 {
            if tokio::time::timeout(Duration::from_millis(50), core.wait_idle())
                .await
                .is_ok()
            {
                break;
            }
            let now_reqs = transport.recorded_count();
            if now_reqs == prev_reqs {
                break;
            }
            prev_reqs = now_reqs;
        }
    }

    let final_snap = core
        .snapshot()
        .await
        .ok_or_else(|| "actor stopped before final snapshot".to_owned())?;
    core.stop();

    Ok(CaseRunResult {
        snapshots,
        final_state: final_snap.to_case_json(&render_core_fail_en),
        requests: transport.recorded_requests_sorted(),
        host: host.calls(),
    })
}

/// Thin wrapper allowing `Arc<ScriptedTransport>` to implement `olaz_net::http::Transport`.
struct ArcTransport(Arc<ScriptedTransport>);

impl Transport for ArcTransport {
    fn send(
        &self,
        request: RequestSpec,
    ) -> impl Future<Output = Result<RawResponse, NetError>> + Send {
        let inner = Arc::clone(&self.0);
        async move { inner.send(request).await }
    }
}

/// Canonicalizes JSON values by recursively sorting all object keys.
pub fn canonicalize_json(val: &Value) -> Value {
    match val {
        Value::Object(map) => {
            let sorted: BTreeMap<String, Value> = map
                .iter()
                .map(|(k, v)| (k.clone(), canonicalize_json(v)))
                .collect();
            Value::Object(sorted.into_iter().collect())
        }
        Value::Array(arr) => Value::Array(arr.iter().map(canonicalize_json).collect()),
        other => other.clone(),
    }
}

pub fn canonical_json_string(val: &Value) -> String {
    serde_json::to_string(&canonicalize_json(val)).unwrap_or_default()
}

#[derive(Debug, Clone)]
pub struct Mismatch {
    pub path: String,
    pub expected: Value,
    pub actual: Value,
}

/// Exact canonical JSON comparison (keys sorted, exact integers, no float tolerance).
pub fn diff_json(path: &str, expected: &Value, actual: &Value, out: &mut Vec<Mismatch>) {
    match (expected, actual) {
        (Value::Object(exp), Value::Object(act)) => {
            let mut keys: Vec<&String> = exp.keys().chain(act.keys()).collect();
            keys.sort();
            keys.dedup();
            for key in keys {
                let child_path = if path.is_empty() {
                    key.clone()
                } else {
                    format!("{path}.{key}")
                };
                match (exp.get(key), act.get(key)) {
                    (Some(e), Some(a)) => diff_json(&child_path, e, a, out),
                    (Some(e), None) => out.push(Mismatch {
                        path: child_path,
                        expected: canonicalize_json(e),
                        actual: Value::String("<missing>".to_owned()),
                    }),
                    (None, Some(a)) => out.push(Mismatch {
                        path: child_path,
                        expected: Value::String("<missing>".to_owned()),
                        actual: canonicalize_json(a),
                    }),
                    (None, None) => {}
                }
            }
        }
        (Value::Array(exp), Value::Array(act)) => {
            let len = exp.len().max(act.len());
            for i in 0..len {
                let child_path = format!("{path}[{i}]");
                match (exp.get(i), act.get(i)) {
                    (Some(e), Some(a)) => diff_json(&child_path, e, a, out),
                    (Some(e), None) => out.push(Mismatch {
                        path: child_path,
                        expected: canonicalize_json(e),
                        actual: Value::String("<missing>".to_owned()),
                    }),
                    (None, Some(a)) => out.push(Mismatch {
                        path: child_path,
                        expected: Value::String("<missing>".to_owned()),
                        actual: canonicalize_json(a),
                    }),
                    (None, None) => {}
                }
            }
        }
        (Value::Number(e), Value::Number(a)) => {
            // Exact comparison (preserving 64-bit ints vs floats via arbitrary_precision representation).
            if e.to_string() != a.to_string() {
                out.push(Mismatch {
                    path: path.to_owned(),
                    expected: Value::Number(e.clone()),
                    actual: Value::Number(a.clone()),
                });
            }
        }
        (e, a) => {
            if e != a {
                out.push(Mismatch {
                    path: path.to_owned(),
                    expected: canonicalize_json(e),
                    actual: canonicalize_json(a),
                });
            }
        }
    }
}

/// Compares actual run output against `case.expect`, filtering out matching `known_diffs`
/// (marking used entries in `used_known_diffs`).
pub fn compare_case(
    case: &Case,
    actual: &CaseRunResult,
    known_diffs: &[KnownDiff],
    used_known_diffs: &mut [bool],
) -> Vec<Mismatch> {
    let mut expected_reqs = case.expect.requests.clone();
    expected_reqs.sort_by(|a, b| {
        let ka = a.get("kind").and_then(Value::as_str).unwrap_or("");
        let kb = b.get("kind").and_then(Value::as_str).unwrap_or("");
        let pa = a.get("path").and_then(Value::as_str).unwrap_or("");
        let pb = b.get("path").and_then(Value::as_str).unwrap_or("");
        (ka, pa, canonical_json_string(a)).cmp(&(kb, pb, canonical_json_string(b)))
    });

    let expected_root = json!({
        "snapshots": case.expect.snapshots,
        "final": case.expect.final_state,
        "requests": expected_reqs,
        "host": case.expect.host,
    });
    let actual_root = json!({
        "snapshots": actual.snapshots,
        "final": actual.final_state,
        "requests": actual.requests,
        "host": actual.host,
    });

    let mut raw_mismatches = Vec::new();
    diff_json("", &expected_root, &actual_root, &mut raw_mismatches);

    let mut remaining = Vec::new();
    for m in raw_mismatches {
        let matched_known = known_diffs.iter().enumerate().find(|(_, kd)| {
            kd.domain == case.domain
                && kd.name == case.name
                && kd.path == m.path
                && canonical_json_string(&kd.actual) == canonical_json_string(&m.actual)
        });
        if let Some((idx, _)) = matched_known {
            used_known_diffs[idx] = true;
        } else {
            remaining.push(m);
        }
    }
    remaining
}

/// Helper to build a synthetic `LoginStep` check for unit tests.
pub fn is_login_step(snap: &SessionSnapshot, expected: &str) -> bool {
    matches!(&snap.phase, Phase::Login(l) if l.step.kind_name() == expected)
}

/// Helper to inspect `LoginStep::Failed` message rendered in English.
pub fn failed_message_en(snap: &SessionSnapshot) -> Option<String> {
    match &snap.phase {
        Phase::Login(l) => match &l.step {
            LoginStep::Failed(olaz_core::state::FailReason::Text(s)) => Some(s.clone()),
            LoginStep::Failed(olaz_core::state::FailReason::Core(c)) => {
                Some(render_core_fail_en(c))
            }
            _ => None,
        },
        _ => None,
    }
}
