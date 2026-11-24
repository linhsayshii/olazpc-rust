//! Case format v1 replay engine shared by `tests/cases.rs`, `tests/session_scenarios.rs`, and
//! `tests/transport_scenarios.rs`.
//!
//! Runs the real `olaz_core::CoreHandle` + `SessionEffectRunner<ScriptedTransport>` over the real
//! `olaz_net::SessionClient`, `olaz_api::ZaloApi`, `olaz_ws::WsCore`, and `olaz_crypto`.

#![expect(
    dead_code,
    reason = "shared test helper used selectively by each test binary"
)]

use std::collections::{BTreeMap, VecDeque};
use std::future::Future;
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use async_trait::async_trait;
use olaz_api::PollState;
use olaz_core::actor::{ActorSink, CoreHandle};
use olaz_core::input::{Command, Input, LegacyCookie};
use olaz_core::reduce::classify::MobileSyncEvent;
use olaz_core::runner::{Host, SessionEffectRunner, WsDriver, WsStartParams};
use olaz_core::state::{
    CoreFailKind, CoreState, LoginStep, PersistedTransportState, Phase, SessionSnapshot,
};
use olaz_core::typed_chat::{
    PlainChatParse, TypedChatEnvelope, new_shared_parse, try_parse_plain_chat,
};
use olaz_crypto::{decode_aes, encode_aes, md5_hex, parse_any, parse_secret_key};
use olaz_net::http::{DEFAULT_REQUEST_TIMEOUT, RawResponse, RequestSpec, Transport};
use olaz_net::{
    LoginAccount, NetError, NetworkErrorKind, SessionClient, ZaloDomains, ZaloSessionError,
};
use olaz_wire::{WireParseOptions, extract_batch_events};
use olaz_ws::consts::{CMD_AUTHEN, CMD_PING, CMD_PING_ACTIVE, DEFAULT_WS_ENDPOINTS, FRAME_VERSION};
use olaz_ws::frame::encode_frame_json;
use olaz_ws::{
    CloseRequest, CryptoDecryptor, CursorMap, ReconnectPolicy, WsCore, build_socket_url,
    decode_frame,
};
use serde::Deserialize;
use serde_json::{Map, Value, json};
use tokio::runtime::Handle;
use tokio::sync::{Notify, mpsc};
use tokio::task::AbortHandle;

/// Keys replaced with `"<volatile>"` before canonical request comparison (Case format v1).
pub const VOLATILE_KEYS: &[&str] = &[
    "imei",
    "client_time",
    "ts",
    "t",
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
    #[serde(default)]
    pub poll_state: Option<Value>,
    #[serde(default)]
    pub ws_cursors: Option<Value>,
    #[serde(default)]
    pub suppress: Vec<String>,
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct ServerEntry {
    pub kind: String,
    #[serde(default)]
    pub path: String,
    #[serde(default)]
    pub method: Option<String>,
    #[serde(default)]
    pub repeat: bool,
    #[serde(default)]
    pub response: Option<HttpResponseSpec>,
    #[serde(default)]
    pub accept: Option<bool>,
    #[serde(default)]
    pub cmd: Option<u16>,
    #[serde(default)]
    pub sub_cmd: Option<u8>,
    #[serde(default)]
    pub version: Option<u8>,
    #[serde(default)]
    pub encrypt: Option<u8>,
    #[serde(default)]
    pub payload: Option<Value>,
    #[serde(default)]
    pub key: Option<String>,
    #[serde(default)]
    pub code: Option<u16>,
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
    AwaitHost {
        await_host: String,
        #[serde(default)]
        timeout_ms: Option<u64>,
    },
    WsPush {
        ws_push: usize,
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
    recorded: Arc<Mutex<Vec<Value>>>,
    /// Session AES secret key (kept in sync from seed + `getLoginInfo` responses).
    secret_key: Mutex<Option<Vec<u8>>>,
}

impl ScriptedTransport {
    pub fn new(entries: Vec<ServerEntry>, initial_secret_key: Option<Vec<u8>>) -> Self {
        Self::with_recorded(
            entries,
            initial_secret_key,
            Arc::new(Mutex::new(Vec::new())),
        )
    }

    pub fn with_recorded(
        entries: Vec<ServerEntry>,
        initial_secret_key: Option<Vec<u8>>,
        recorded: Arc<Mutex<Vec<Value>>>,
    ) -> Self {
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
            recorded,
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

    fn update_secret_key_from_response(&self, json: &Value) {
        if let Some(enk) = json
            .get("data")
            .and_then(|d| d.get("zpw_enk"))
            .and_then(Value::as_str)
            && !enk.is_empty()
        {
            let key = parse_secret_key(enk);
            if key.len() == 16 || key.len() == 32 {
                *self
                    .secret_key
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner) = Some(key);
            }
        }
    }

    fn dispatch_entry(&self, path: &str, method: &str) -> ScriptDispatch {
        let mut state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        if state.server_down {
            return ScriptDispatch::Refused;
        }
        let mut matched_spec: Option<ServerEntry> = None;
        for entry in &mut state.entries {
            if entry.spec.kind != "http" || entry.consumed {
                continue;
            }
            if entry.spec.path != path {
                continue;
            }
            if let Some(expected_method) = entry.spec.method.as_deref()
                && !expected_method.eq_ignore_ascii_case(method)
            {
                continue;
            }
            if !entry.spec.repeat {
                entry.consumed = true;
            }
            matched_spec = Some(entry.spec.clone());
            break;
        }
        if should_stop_server(&state.entries) {
            state.server_down = true;
        }
        match matched_spec {
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

        let mut virtual_rtt = Duration::from_millis(10);
        let result = match dispatch {
            ScriptDispatch::Refused => Err(NetError::network(
                NetworkErrorKind::Other,
                "scripted refused",
            )),
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

/// Scripted [`WsDriver`] built directly on `olaz_ws::WsCore`.
///
/// Supports:
/// - `suppress`: if true, `start` is a no-op (no `ws_connect`, no auth, no `e2ee_connected`);
/// - auto-delivery of `cmd == 1` auth reply on connect;
/// - gated delivery of subsequent `ws_frame` / `ws_close` entries via [`Self::push`];
/// - recording of `ws_connect` and outgoing `ws_send` frames (excluding pings cmd 2/4);
/// - strict event-before-cursors ordering per frame.
pub struct ScriptedWsDriver {
    suppress: bool,
    recorded: Arc<Mutex<Vec<Value>>>,
    ws_connects: Arc<Mutex<VecDeque<ServerEntry>>>,
    ws_events: Arc<Mutex<VecDeque<ServerEntry>>>,
    state: Arc<Mutex<ScriptedWsState>>,
}

struct ScriptedWsState {
    push_tx: Option<mpsc::UnboundedSender<usize>>,
    task_abort: Option<AbortHandle>,
    core: Arc<Mutex<WsCore>>,
    fixed_now_secs: i64,
}

impl ScriptedWsDriver {
    pub fn new(entries: &[ServerEntry], recorded: Arc<Mutex<Vec<Value>>>, suppress: bool) -> Self {
        let mut ws_connects = VecDeque::new();
        let mut ws_events = VecDeque::new();
        for e in entries {
            match e.kind.as_str() {
                "ws" => ws_connects.push_back(e.clone()),
                "ws_frame" | "ws_close" => ws_events.push_back(e.clone()),
                _ => {}
            }
        }
        Self {
            suppress,
            recorded,
            ws_connects: Arc::new(Mutex::new(ws_connects)),
            ws_events: Arc::new(Mutex::new(ws_events)),
            state: Arc::new(Mutex::new(ScriptedWsState {
                push_tx: None,
                task_abort: None,
                core: Arc::new(Mutex::new(WsCore::new())),
                fixed_now_secs: 1_700_000_000,
            })),
        }
    }

    /// Releases the next `count` scripted `ws_frame` / `ws_close` entries to the active session.
    pub fn push(&self, count: usize) {
        let st = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        if let Some(tx) = &st.push_tx {
            let _ = tx.send(count);
        }
    }

    /// Injects an ad-hoc `ws_frame` / `ws_close` directly into the queue and pushes it.
    pub fn enqueue_and_push(&self, entry: ServerEntry) {
        self.ws_events
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .push_back(entry);
        self.push(1);
    }
}

fn encode_scripted_ws_frame(entry: &ServerEntry) -> Vec<u8> {
    let cmd = entry.cmd.unwrap_or(0);
    let sub_cmd = entry.sub_cmd.unwrap_or(1);
    let version = entry.version.unwrap_or(FRAME_VERSION);
    let encrypt = entry.encrypt.unwrap_or(0);
    let payload_val = entry.payload.clone().unwrap_or_else(|| json!({}));

    if encrypt > 0 {
        let mut map = payload_val.as_object().cloned().unwrap_or_default();
        map.entry("encrypt".to_owned())
            .or_insert_with(|| Value::from(encrypt));
        if let Some(key) = &entry.key {
            map.insert("key".to_owned(), Value::String(key.clone()));
        }
        return encode_frame_json(cmd, sub_cmd, version, Some(&map));
    }

    // Wrap plain payload in `{"encrypt": 0, "data": "<json>"}` so `WsCore::handle_binary_frame`
    // and `WsCore::handle_auth` both recover the exact payload map losslessly.
    let mut envelope = Map::new();
    envelope.insert("encrypt".to_owned(), Value::from(0u8));
    if let Some(key) = &entry.key {
        envelope.insert("key".to_owned(), Value::String(key.clone()));
    }
    let data_str = serde_json::to_string(&payload_val).unwrap_or_else(|_| "{}".to_owned());
    envelope.insert("data".to_owned(), Value::String(data_str));
    encode_frame_json(cmd, sub_cmd, version, Some(&envelope))
}

fn record_ws_connect(recorded: &Arc<Mutex<Vec<Value>>>, endpoint: &str) {
    let full = build_socket_url(endpoint, 0);
    let parsed = url::Url::parse(&full).ok();
    let path = parsed
        .as_ref()
        .map_or_else(|| "/".to_owned(), |u| u.path().to_owned());
    let mut query_map = BTreeMap::new();
    if let Some(u) = &parsed {
        for (k, v) in u.query_pairs() {
            let scrubbed = if is_volatile_key(&k) {
                "<volatile>".to_owned()
            } else {
                v.into_owned()
            };
            query_map.insert(k.into_owned(), Value::String(scrubbed));
        }
    }
    let query_obj: Map<String, Value> = query_map.into_iter().collect();
    recorded
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .push(json!({
            "kind": "ws_connect",
            "path": path,
            "query": Value::Object(query_obj),
        }));
}

fn record_ws_send_bytes(recorded: &Arc<Mutex<Vec<Value>>>, raw: &[u8]) {
    let Ok(frame) = decode_frame(raw) else {
        return;
    };
    if frame.cmd == CMD_PING || frame.cmd == CMD_PING_ACTIVE {
        return;
    }
    let payload = scrub_volatile_value(Value::Object(frame.envelope));
    recorded
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .push(json!({
            "kind": "ws_send",
            "cmd": frame.cmd,
            "sub_cmd": frame.sub_cmd,
            "payload": payload,
        }));
}

fn deliver_frame_to_core(
    core: &Arc<Mutex<WsCore>>,
    recorded: &Arc<Mutex<Vec<Value>>>,
    parse_state: &olaz_core::typed_chat::SharedParse,
    sink: &ActorSink,
    ws_gen: u64,
    now_unix_secs: i64,
    entry: &ServerEntry,
) -> Option<CloseRequest> {
    let bytes = encode_scripted_ws_frame(entry);
    let (prev_authed, now_authed, out) = {
        let mut guard = core.lock().unwrap_or_else(PoisonError::into_inner);
        let prev = guard.is_authed();
        let outcome = guard.handle_binary_frame(&bytes, &CryptoDecryptor);
        let now = guard.is_authed();
        (prev, now, outcome)
    };
    for send in &out.sends {
        record_ws_send_bytes(recorded, send);
    }
    if prev_authed != now_authed {
        sink.send(Input::WsAuthChanged {
            ws_gen,
            authed: now_authed,
        });
    }
    // Deliver event strictly before cursors_changed (Claude's U2 ordering rule).
    if let Some(ev) = out.event {
        match try_parse_plain_chat(ev.cmd, &ev.payload, parse_state) {
            PlainChatParse::Empty => {}
            PlainChatParse::Typed(envelope) => {
                sink.send(Input::WsTypedChat {
                    ws_gen,
                    cmd: ev.cmd,
                    envelope,
                });
            }
            PlainChatParse::NotPlain => {
                sink.send(Input::WsEvent {
                    ws_gen,
                    cmd: ev.cmd,
                    payload: ev.payload,
                    now_unix_secs,
                });
            }
        }
    }
    if let Some(cursors) = out.cursors_changed {
        sink.send(Input::WsCursorsChanged { ws_gen, cursors });
    }
    out.close
}

#[async_trait]
impl WsDriver for ScriptedWsDriver {
    fn start(&self, params: WsStartParams, sink: ActorSink, runtime: &Handle) {
        if self.suppress {
            return;
        }
        let mut st = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        if let Some(old) = st.task_abort.take() {
            old.abort();
        }
        let core = Arc::new(Mutex::new(WsCore::new()));
        core.lock()
            .unwrap_or_else(PoisonError::into_inner)
            .cursors
            .seed(&params.seed_cursors);
        st.core = Arc::clone(&core);

        let (push_tx, mut push_rx) = mpsc::unbounded_channel::<usize>();
        st.push_tx = Some(push_tx);
        let now_unix_secs = st.fixed_now_secs;

        let endpoints: Vec<String> = if params.endpoints.is_empty() {
            DEFAULT_WS_ENDPOINTS
                .iter()
                .map(|s| (*s).to_owned())
                .collect()
        } else {
            params.endpoints
        };
        let ws_gen = params.ws_gen;
        let recorded = Arc::clone(&self.recorded);
        let ws_connects = Arc::clone(&self.ws_connects);
        let ws_events = Arc::clone(&self.ws_events);
        let parse_state = new_shared_parse(params.my_uid, params.self_conv_id);

        let handle = runtime
            .spawn(async move {
                let mut policy = ReconnectPolicy::new(endpoints.len());
                while let Some(idx) = policy.current_endpoint() {
                    let endpoint = &endpoints[idx];
                    let accept = {
                        let mut connects =
                            ws_connects.lock().unwrap_or_else(PoisonError::into_inner);
                        if let Some(front) = connects.front() {
                            let acc = front.accept.unwrap_or(true);
                            if !front.repeat {
                                connects.pop_front();
                            }
                            acc
                        } else {
                            true
                        }
                    };
                    record_ws_connect(&recorded, endpoint);
                    if !accept {
                        let delay = policy.on_session_ended(Duration::from_secs(0));
                        tokio::time::sleep(delay).await;
                        continue;
                    }

                    core.lock()
                        .unwrap_or_else(PoisonError::into_inner)
                        .on_connect();

                    // Auto-deliver an immediate `cmd == 1` auth reply on connect if scripted next.
                    let auth_entry = {
                        let mut evs = ws_events.lock().unwrap_or_else(PoisonError::into_inner);
                        if evs
                            .front()
                            .is_some_and(|e| e.kind == "ws_frame" && e.cmd == Some(CMD_AUTHEN))
                        {
                            evs.pop_front()
                        } else {
                            None
                        }
                    };
                    if let Some(entry) = auth_entry
                        && deliver_frame_to_core(
                            &core,
                            &recorded,
                            &parse_state,
                            &sink,
                            ws_gen,
                            now_unix_secs,
                            &entry,
                        )
                        .is_some()
                    {
                        let was_authed = {
                            let mut c = core.lock().unwrap_or_else(PoisonError::into_inner);
                            let was = c.is_authed();
                            let _ = c.on_disconnect();
                            was
                        };
                        if was_authed {
                            sink.send(Input::WsAuthChanged {
                                ws_gen,
                                authed: false,
                            });
                        }
                        let delay = policy.on_session_ended(Duration::from_secs(0));
                        tokio::time::sleep(delay).await;
                        continue;
                    }

                    // Wait for explicit `ws_push` steps for all subsequent frames/closes.
                    let mut reconnect = false;
                    while let Some(count) = push_rx.recv().await {
                        for _ in 0..count {
                            let next = ws_events
                                .lock()
                                .unwrap_or_else(PoisonError::into_inner)
                                .pop_front();
                            let Some(entry) = next else {
                                break;
                            };
                            if entry.kind == "ws_close" {
                                let was_authed = {
                                    let mut c = core.lock().unwrap_or_else(PoisonError::into_inner);
                                    let was = c.is_authed();
                                    let _ = c.on_disconnect();
                                    was
                                };
                                if was_authed {
                                    sink.send(Input::WsAuthChanged {
                                        ws_gen,
                                        authed: false,
                                    });
                                }
                                reconnect = true;
                                break;
                            }
                            if deliver_frame_to_core(
                                &core,
                                &recorded,
                                &parse_state,
                                &sink,
                                ws_gen,
                                now_unix_secs,
                                &entry,
                            )
                            .is_some()
                            {
                                let was_authed = {
                                    let mut c = core.lock().unwrap_or_else(PoisonError::into_inner);
                                    let was = c.is_authed();
                                    let _ = c.on_disconnect();
                                    was
                                };
                                if was_authed {
                                    sink.send(Input::WsAuthChanged {
                                        ws_gen,
                                        authed: false,
                                    });
                                }
                                reconnect = true;
                                break;
                            }
                        }
                        if reconnect {
                            break;
                        }
                    }

                    if !reconnect {
                        break;
                    }
                    let delay = policy.on_session_ended(Duration::from_secs(0));
                    tokio::time::sleep(delay).await;
                }
            })
            .abort_handle();

        st.task_abort = Some(handle);
    }

    fn stop(&self, reset_cursors: bool) {
        let mut st = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        if let Some(old) = st.task_abort.take() {
            old.abort();
        }
        st.push_tx = None;
        let _ = st
            .core
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .stop(reset_cursors);
    }

    fn record_file_done(&self, file_id: String, url: String) {
        let st = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        let _ = st
            .core
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .files
            .record(&file_id, &url);
    }

    async fn send_frame(&self, cmd: u16, sub_cmd: u8, payload_json: Option<Vec<u8>>) -> bool {
        self.send_frame_versioned(cmd, sub_cmd, FRAME_VERSION, payload_json)
            .await
    }

    async fn send_frame_versioned(
        &self,
        cmd: u16,
        sub_cmd: u8,
        version: u8,
        payload_json: Option<Vec<u8>>,
    ) -> bool {
        let st = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        let core = st.core.lock().unwrap_or_else(PoisonError::into_inner);
        if !core.is_authed() {
            return false;
        }
        let raw = olaz_ws::encode_frame(cmd, sub_cmd, version, payload_json.as_deref());
        record_ws_send_bytes(&self.recorded, &raw);
        true
    }

    async fn send_request(
        &self,
        cmd: u16,
        sub_cmd: u8,
        version: u8,
        req_id: Option<String>,
        inner_data: Map<String, Value>,
        _timeout: Duration,
    ) -> Option<Map<String, Value>> {
        let st = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        let mut core = st.core.lock().unwrap_or_else(PoisonError::into_inner);
        let prep = core.prepare_request(cmd, sub_cmd, version, req_id.as_deref(), &inner_data)?;
        record_ws_send_bytes(&self.recorded, &prep.frame);
        None
    }

    async fn wait_for_file_done(&self, file_id: String, _timeout: Duration) -> Option<String> {
        let st = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        let mut core = st.core.lock().unwrap_or_else(PoisonError::into_inner);
        match core.wait_for_file_done(&file_id) {
            olaz_ws::FileWait::Ready(url) => Some(url),
            olaz_ws::FileWait::Pending(_) | olaz_ws::FileWait::Invalid => None,
        }
    }

    async fn is_authed(&self) -> bool {
        let st = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        let core = Arc::clone(&st.core);
        drop(st);
        let guard = core.lock().unwrap_or_else(PoisonError::into_inner);
        guard.is_authed()
    }

    async fn current_cursors(&self) -> CursorMap {
        let st = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        let core = Arc::clone(&st.core);
        drop(st);
        let guard = core.lock().unwrap_or_else(PoisonError::into_inner);
        guard.cursors.current()
    }

    async fn seed_cursors(&self, cursors: CursorMap) {
        let st = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        st.core
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .cursors
            .seed(&cursors);
    }
}

/// Fake [`Host`] that answers `load_saved_session` / `load_legacy_cookie` / `load_transport_state`
/// from the case `seed` and records every traced domain activity in Case format v1 `host` order.
pub struct RecordingHost {
    saved_session: Option<String>,
    legacy_cookie: Option<LegacyCookie>,
    transport_state: PersistedTransportState,
    calls: Mutex<Vec<Value>>,
    notify: Notify,
}

impl RecordingHost {
    pub fn from_seed(seed: &Seed) -> Self {
        let saved_session = seed
            .saved_session
            .as_ref()
            .and_then(|v| serde_json::to_string(v).ok());
        let legacy_cookie = parse_legacy_cookie_seed(seed.legacy_cookie.as_ref());
        let poll_state = seed
            .poll_state
            .as_ref()
            .and_then(|v| serde_json::from_value::<PollState>(v.clone()).ok())
            .unwrap_or_default();
        let ws_cursors = seed
            .ws_cursors
            .as_ref()
            .and_then(|v| serde_json::from_value::<CursorMap>(v.clone()).ok())
            .unwrap_or_default();
        Self {
            saved_session,
            legacy_cookie,
            transport_state: PersistedTransportState {
                poll_state,
                ws_cursors,
            },
            calls: Mutex::new(Vec::new()),
            notify: Notify::new(),
        }
    }

    pub fn calls(&self) -> Vec<Value> {
        self.calls
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone()
    }

    /// Waits until a host call named `call_name` appears at index `>= *cursor`, then advances
    /// `*cursor` past that entry.
    pub async fn await_call(&self, call_name: &str, cursor: &mut usize) {
        loop {
            let notified = self.notify.notified();
            tokio::pin!(notified);
            notified.as_mut().enable();
            {
                let calls = self.calls.lock().unwrap_or_else(PoisonError::into_inner);
                if let Some(rel) = calls[*cursor..]
                    .iter()
                    .position(|c| c.get("call").and_then(Value::as_str) == Some(call_name))
                {
                    *cursor += rel + 1;
                    return;
                }
            }
            notified.await;
        }
    }

    fn record(&self, call: &str, args: Value) {
        self.calls
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .push(json!({ "call": call, "args": args }));
        self.notify.notify_waiters();
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

    async fn load_transport_state(&self) -> PersistedTransportState {
        self.transport_state.clone()
    }

    async fn set_pref(&self, _key: String, _value: String) {}

    async fn prepare_store(&self, user_id: String, _account: LoginAccount) {
        self.record("prepare_store", json!({ "user_id": user_id }));
    }

    async fn on_ws_started(&self, endpoints: Vec<String>) -> bool {
        self.record("start_ws", json!({ "endpoints": endpoints }));
        true
    }

    async fn on_long_poll_started(&self) -> bool {
        self.record("start_long_poll", json!({}));
        true
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

    async fn persist_poll_state(&self, state: PollState) {
        self.record("persist_poll_state", json!({ "state": state }));
    }

    async fn persist_ws_cursors(&self, cursors: CursorMap) {
        self.record("persist_ws_cursors", json!({ "cursors": cursors }));
    }

    async fn apply_batch(
        &self,
        cmd: Option<u16>,
        increment_unread: bool,
        notify_incoming: bool,
        payload: Map<String, Value>,
    ) -> u32 {
        let root = Value::Object(payload.clone());
        let opts = WireParseOptions {
            cmd: cmd.unwrap_or(0),
            fallback_conv_id: None,
            is_group_hint: None,
            self_conv_id: None,
            name_lookup: None,
        };
        let events = extract_batch_events(&root, "", &opts);
        let count = u32::try_from(events.len()).unwrap_or(u32::MAX);
        self.record(
            "apply_batch",
            json!({
                "cmd": cmd,
                "increment_unread": increment_unread,
                "notify_incoming": notify_incoming,
                "payload": Value::Object(payload),
            }),
        );
        count
    }

    async fn apply_parsed_events(
        &self,
        cmd: u16,
        increment_unread: bool,
        notify_incoming: bool,
        envelope: TypedChatEnvelope,
    ) {
        self.record(
            "apply_parsed_events",
            json!({
                "cmd": cmd,
                "increment_unread": increment_unread,
                "notify_incoming": notify_incoming,
                "count": envelope.events.len(),
                "uids": envelope.uids,
            }),
        );
    }

    async fn mobile_sync(&self, events: Vec<MobileSyncEvent>) {
        self.record("mobile_sync", json!({ "count": events.len() }));
    }

    async fn e2ee_signal(&self, cmd: u16, payload: Map<String, Value>) {
        self.record(
            "e2ee_signal",
            json!({ "cmd": cmd, "payload": Value::Object(payload) }),
        );
    }

    async fn e2ee_deliver_reports(&self, cmd: u16, payload: Map<String, Value>) {
        self.record(
            "e2ee_deliver_reports",
            json!({ "cmd": cmd, "payload": Value::Object(payload) }),
        );
    }

    async fn e2ee_connected(&self, uid: String) {
        self.record("e2ee_connected", json!({ "uid": uid }));
    }

    async fn e2ee_disconnected(&self) {
        self.record("e2ee_disconnected", json!({}));
    }

    async fn voip_control(&self, act: String, raw_data: Value, data: Map<String, Value>) {
        self.record(
            "voip_control",
            json!({ "act": act, "raw_data": raw_data, "data": Value::Object(data) }),
        );
    }

    async fn show_typing(&self, conv_id: String, uid: String, on_pc: bool) {
        self.record(
            "show_typing",
            json!({ "conv_id": conv_id, "uid": uid, "on_pc": on_pc }),
        );
    }

    async fn pin_topic(&self, conv_id: String) {
        self.record("pin_topic", json!({ "conv_id": conv_id }));
    }

    async fn group_notice(&self, act: String, data: Map<String, Value>, ts: i64) {
        self.record(
            "group_notice",
            json!({ "act": act, "data": Value::Object(data), "ts": ts }),
        );
    }

    async fn mute(&self, conv_id: String, set: bool, start: i64, duration: i64) {
        self.record(
            "mute",
            json!({ "conv_id": conv_id, "set": set, "start": start, "duration": duration }),
        );
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
        "drain_chat_polling" => {
            let max_batches = args
                .get("max_batches")
                .and_then(Value::as_u64)
                .and_then(|n| u32::try_from(n).ok())
                .unwrap_or(3);
            let notify_incoming = args
                .get("notify_incoming")
                .and_then(Value::as_bool)
                .unwrap_or(false);
            Ok(Command::DrainChatPolling {
                max_batches,
                notify_incoming,
            })
        }
        other => Err(format!("unknown step cmd: {other}")),
    }
}

/// Runs a single Case format v1 [`Case`] under paused tokio time and returns the observed
/// snapshots, final state, sorted canonical requests, and ordered host calls.
pub async fn run_case(case: &Case) -> Result<CaseRunResult, String> {
    let seed_domains = extract_seed_domains(&case.seed);
    let initial_key = extract_seed_secret_key(&case.seed);
    let recorded = Arc::new(Mutex::new(Vec::new()));
    let transport = Arc::new(ScriptedTransport::with_recorded(
        case.server.clone(),
        initial_key,
        Arc::clone(&recorded),
    ));

    // Session-domain cases recorded under U1a trace `start_ws` / `start_long_poll` without running
    // the real loops; suppress both loops automatically for `domain == "session"`.
    let suppress_ws = case.domain == "session" || case.seed.suppress.iter().any(|s| s == "ws");
    let suppress_lp =
        case.domain == "session" || case.seed.suppress.iter().any(|s| s == "long_poll");

    let ws_driver = Arc::new(ScriptedWsDriver::new(
        &case.server,
        Arc::clone(&recorded),
        suppress_ws,
    ));

    let client = Arc::new(SessionClient::new(
        ArcTransport(Arc::clone(&transport)),
        "00000000-0000-4000-8000-000000000000-00000000000000000000000000000000".to_owned(),
        "TestMac".to_owned(),
    ));
    if let Some(d) = &seed_domains {
        client.with_session(|s| s.domains = d.clone());
    }

    let host = Arc::new(RecordingHost::from_seed(&case.seed));
    let runner = Arc::new(SessionEffectRunner::with_options(
        Arc::clone(&client),
        Arc::clone(&host) as Arc<dyn Host>,
        Arc::clone(&ws_driver) as Arc<dyn WsDriver>,
        Handle::current(),
        seed_domains,
        suppress_lp,
    ));

    let mut initial_state = CoreState::default();
    initial_state.session.prefs = case.seed.prefs.clone();
    let core = CoreHandle::start_with_state(initial_state, runner, Handle::current());

    let mut snapshots = BTreeMap::new();
    let mut host_cursor = 0usize;

    for step in &case.steps {
        match step {
            Step::Cmd { cmd, args } => {
                let parsed = parse_command(cmd, args)?;
                match parsed {
                    Command::LogOut | Command::SessionExpired { .. } => {
                        let _ =
                            tokio::time::timeout(Duration::from_secs(5), core.wait_idle()).await;
                        core.send(parsed);
                    }
                    Command::RefreshQr => {
                        let _ = tokio::time::timeout(Duration::from_millis(500), core.wait_idle())
                            .await;
                        core.send(parsed);
                    }
                    Command::ApplyAccountProfile(_) => {
                        let _ = core.send_and_ack(parsed).await;
                    }
                    Command::DrainChatPolling {
                        max_batches,
                        notify_incoming,
                    } => {
                        let _ = core.drain_chat_polling(max_batches, notify_incoming).await;
                    }
                    Command::Start => {
                        core.send(parsed);
                    }
                }
            }
            Step::Await { predicate, .. } => {
                let wait_fut = core.wait_until(|snap| predicate.matches(snap));
                let _ = tokio::time::timeout(Duration::from_secs(3600), wait_fut).await;
            }
            Step::AwaitHost {
                await_host,
                timeout_ms,
            } => {
                let dur = Duration::from_millis(timeout_ms.unwrap_or(15_000));
                tokio::time::timeout(dur, host.await_call(await_host, &mut host_cursor))
                    .await
                    .map_err(|_| format!("timed out awaiting host call `{await_host}`"))?;
            }
            Step::WsPush { ws_push } => {
                ws_driver.push(*ws_push);
            }
            Step::Snapshot { snapshot } => {
                if let Some(snap) = core.snapshot().await {
                    snapshots.insert(snapshot.clone(), snap.to_case_json(&render_core_fail_en));
                }
            }
        }
    }

    if !transport.has_repeat_entries() {
        let _ = tokio::time::timeout(Duration::from_secs(5), core.wait_idle()).await;
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
