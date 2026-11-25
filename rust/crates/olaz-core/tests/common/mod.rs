//! Case format v1 replay engine shared by `tests/cases.rs`, `tests/session_scenarios.rs`, and
//! `tests/transport_scenarios.rs`.
//!
//! Runs the real `olaz_core::CoreHandle` + `SessionEffectRunner<ScriptedTransport>` over the real
//! `olaz_net::SessionClient`, `olaz_api::ZaloApi`, `olaz_ws::WsCore`, and `olaz_crypto`.

#![expect(
    dead_code,
    reason = "shared test helper used selectively by each test binary"
)]

use olaz_core::runner::{BatchHookOutcome, ParsedEventsHookOutcome};
use std::collections::{BTreeMap, HashMap, VecDeque};
use std::future::Future;
use std::path::PathBuf;
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use async_trait::async_trait;
use olaz_api::{PollState, SendMessageResult, ZaloApi};
use olaz_core::actor::{ActorSink, CoreHandle};
use olaz_core::conversations::{
    BatchApplyDelta, CachedGroup, CachedProfile, ConvMessageDelta, ConvPreviewOverride,
    ConversationPreview, FriendIdentity, GroupIdentity, IdentityTable, MessagePreviewInput,
    message_preview_label, to_wire_stored,
};
use olaz_core::effect::Effect;
use olaz_core::forward::{
    ComposerSendOutcome, FileResolutionOutcome, ForwardOutcome, MediaResolutionOutcome,
};
use olaz_core::input::{Command, E2eeQuoteArg, Input, LegacyCookie, SeenTarget};
use olaz_core::messages::{HistoryFreshness, MuteEntry};
use olaz_core::reduce::classify::MobileSyncEvent;
use olaz_core::runner::{
    EffectRunner, Host, SessionEffectRunner, SharedStoreSlot, WsDriver, WsStartParams,
};
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
use olaz_store::{Store, StoredConversation, StoredMessage};
use olaz_wire::{
    Availability, ChatMessage, DeleteMode, Kind, Mention, NameLookup, ParsedWireEvent, StarMode,
    Status, TextStyle, WireParseOptions, decode_stored_message, extract_batch_events,
};
use olaz_ws::consts::{CMD_AUTHEN, CMD_PING, CMD_PING_ACTIVE, DEFAULT_WS_ENDPOINTS, FRAME_VERSION};
use olaz_ws::frame::encode_frame_json;
use olaz_ws::{
    CloseRequest, CryptoDecryptor, CursorMap, ReconnectPolicy, WsCore, build_socket_url,
    decode_frame,
};
use serde::Deserialize;
use serde_json::{Map, Value, json};
use tokio::runtime::Handle;
use tokio::sync::{Notify, mpsc, oneshot};
use tokio::task::AbortHandle;

/// Sentinel wall-clock timestamp used by `ScriptedWsDriver` so `RecordingHost::mute` can mark
/// fallback timestamps (`startTime` and `systemTime` both absent) as `"<volatile>"`.
const FIXED_TEST_NOW_SECS: i64 = 1_700_000_000;

/// Keys replaced with `"<volatile>"` inside outgoing `ws_send` payloads (Case format v1).
const WS_SEND_VOLATILE_KEYS: &[&str] = &["ts", "client_time", "timestamp"];

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
    #[serde(default)]
    pub ws_auth: Option<String>,
    #[serde(default)]
    pub contacts: Option<Value>,
    #[serde(default)]
    pub pinned_ids: Option<Vec<String>>,
    #[serde(default)]
    pub archived_ids: Option<Vec<String>>,
    #[serde(default)]
    pub unread_marks: Option<Vec<String>>,
    #[serde(default)]
    pub hidden_ids: Option<Vec<String>>,
    #[serde(default)]
    pub hidden_pin_md5: Option<String>,
    #[serde(default)]
    pub hidden_pin_hash: Option<String>,
    #[serde(default)]
    pub labels_pref: Option<Value>,
    #[serde(default)]
    pub activity_ranks: Option<Value>,
    #[serde(default)]
    pub local_conversations: Option<Vec<Value>>,
    #[serde(default)]
    pub local_messages: Option<Vec<Value>>,
    #[serde(default)]
    pub open_conversation_id: Option<String>,
    // U4-bootstrap
    #[serde(default)]
    pub history_full_refresh_at: Option<String>,
    #[serde(default)]
    pub history_freshness: BTreeMap<String, String>,
    // U5
    #[serde(default)]
    pub next_client_id: Option<i64>,
    #[serde(default)]
    pub e2ee_threads: Vec<String>,
    #[serde(default)]
    pub auto_delete: BTreeMap<String, i64>,
    #[serde(default)]
    pub host_results: Option<Value>,
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
    pub hold: bool,
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
        #[serde(default)]
        now_ms: Option<i64>,
        #[serde(default)]
        rand4: Option<String>,
        #[serde(default)]
        timeout_ms: Option<u64>,
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
    HttpRelease {
        http_release: usize,
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
struct HoldGate {
    waiters: VecDeque<oneshot::Sender<()>>,
    credits: usize,
    arrived: usize,
}

pub struct ScriptedTransport {
    state: Mutex<ScriptState>,
    recorded: Arc<Mutex<Vec<Value>>>,
    /// Session AES secret key (kept in sync from seed + `getLoginInfo` responses).
    secret_key: Mutex<Option<Vec<u8>>>,
    hold_gate: Arc<Mutex<HoldGate>>,
    hold_notify: Arc<Notify>,
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
            hold_gate: Arc::new(Mutex::new(HoldGate {
                waiters: VecDeque::new(),
                credits: 0,
                arrived: 0,
            })),
            hold_notify: Arc::new(Notify::new()),
        }
    }

    pub fn release_http(&self, count: usize) {
        let mut gate = self
            .hold_gate
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        for _ in 0..count {
            if let Some(tx) = gate.waiters.pop_front() {
                let _ = tx.send(());
            } else {
                gate.credits += 1;
            }
        }
    }

    pub fn held_arrived_count(&self) -> usize {
        self.hold_gate
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .arrived
    }

    pub async fn wait_for_held_arrival(&self, target: usize) {
        loop {
            let notified = self.hold_notify.notified();
            if self.held_arrived_count() >= target {
                return;
            }
            notified.await;
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

fn scrub_ws_send_value(val: Value) -> Value {
    match val {
        Value::Object(map) => {
            let mut out = Map::new();
            for (k, v) in map {
                if WS_SEND_VOLATILE_KEYS.contains(&k.as_str()) {
                    out.insert(k, Value::String("<volatile>".to_owned()));
                } else {
                    out.insert(k, scrub_ws_send_value(v));
                }
            }
            Value::Object(out)
        }
        Value::Array(arr) => Value::Array(arr.into_iter().map(scrub_ws_send_value).collect()),
        other => other,
    }
}

fn canonical_http_request(
    req: &RequestSpec,
    session_key: Option<&[u8]>,
    unscripted: bool,
) -> (Value, Option<Vec<u8>>) {
    let is_long_poll_query = req.path() == "/"
        && (req.query_value("zcid").is_none() || req.query_value("zcid_ext").is_none())
        && req.query_value("params").is_some();
    let (params, param_cipher_key) = if is_long_poll_query {
        (Value::Null, None)
    } else {
        decrypt_request_params(req, session_key)
    };

    let mut query_map = BTreeMap::new();
    for (k, v) in &req.query {
        let scrubbed = if k == "params" && is_long_poll_query {
            v.clone()
        } else if is_volatile_key(k) {
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
        let mut hold_rx: Option<oneshot::Receiver<()>> = None;
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
                if entry.hold {
                    let mut gate = self
                        .hold_gate
                        .lock()
                        .unwrap_or_else(PoisonError::into_inner);
                    gate.arrived += 1;
                    if gate.credits > 0 {
                        gate.credits -= 1;
                    } else {
                        let (tx, rx) = oneshot::channel();
                        gate.waiters.push_back(tx);
                        hold_rx = Some(rx);
                    }
                    drop(gate);
                    self.hold_notify.notify_waiters();
                }
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
            if let Some(rx) = hold_rx {
                let _ = rx.await;
            }
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
    ws_auth_manual: bool,
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
        Self::with_auth_mode(entries, recorded, suppress, false)
    }

    pub fn with_auth_mode(
        entries: &[ServerEntry],
        recorded: Arc<Mutex<Vec<Value>>>,
        suppress: bool,
        ws_auth_manual: bool,
    ) -> Self {
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
            ws_auth_manual,
            recorded,
            ws_connects: Arc::new(Mutex::new(ws_connects)),
            ws_events: Arc::new(Mutex::new(ws_events)),
            state: Arc::new(Mutex::new(ScriptedWsState {
                push_tx: None,
                task_abort: None,
                core: Arc::new(Mutex::new(WsCore::new())),
                fixed_now_secs: FIXED_TEST_NOW_SECS,
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
    let payload = scrub_ws_send_value(Value::Object(frame.envelope));
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
        let ws_auth_manual = self.ws_auth_manual;
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

                    // Auto-deliver an immediate `cmd == 1` auth reply on connect unless ws_auth is manual.
                    let auth_entry = if ws_auth_manual {
                        None
                    } else {
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
#[derive(Debug, Clone, Default)]
struct HostSelfProfile {
    user_id: String,
    display_name: String,
    avatar: String,
    self_conv_id: Option<String>,
}

pub struct RecordingHost {
    saved_session: Option<String>,
    legacy_cookie: Option<LegacyCookie>,
    transport_state: PersistedTransportState,
    self_profile: Mutex<Option<HostSelfProfile>>,
    calls: Mutex<Vec<Value>>,
    notify: Notify,
    is_u3: bool,
    is_u4: bool,
    data_dir: Option<PathBuf>,
    shared_store_slot: Mutex<Option<SharedStoreSlot>>,
    store: Mutex<Option<Arc<Mutex<Store>>>>,
    e2ee_send_results: Mutex<VecDeque<Result<SendMessageResult, String>>>,
    resolve_media_results: Mutex<VecDeque<MediaResolutionOutcome>>,
    resolve_file_results: Mutex<VecDeque<FileResolutionOutcome>>,
    fetch_media_data_results: Mutex<VecDeque<bool>>,
    send_media_results: Mutex<VecDeque<ComposerSendOutcome>>,
    send_files_results: Mutex<VecDeque<ComposerSendOutcome>>,
    fwd_photo_counter: Mutex<usize>,
    messages: Mutex<HashMap<String, Vec<ChatMessage>>>,
    open_conversation_id: Mutex<Option<String>>,
    identities: Mutex<IdentityTable>,
}

impl RecordingHost {
    pub fn from_seed(seed: &Seed) -> Self {
        Self::from_seed_with_u3(seed, false, None)
    }

    pub fn from_seed_with_u3(seed: &Seed, is_u3: bool, data_dir: Option<PathBuf>) -> Self {
        Self::from_seed_with_modes(seed, is_u3, false, data_dir)
    }

    pub fn from_seed_with_modes(
        seed: &Seed,
        is_u3: bool,
        is_u4: bool,
        data_dir: Option<PathBuf>,
    ) -> Self {
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
        let self_profile = seed.saved_session.as_ref().and_then(|saved| {
            let acc = saved.get("plainAccount")?;
            let user_id = acc.get("userId").and_then(Value::as_str)?.to_owned();
            if user_id.is_empty() {
                return None;
            }
            let display_name = acc
                .get("displayName")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_owned();
            let avatar = acc
                .get("avatar")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_owned();
            let send2me = acc
                .get("send2MeId")
                .and_then(Value::as_str)
                .filter(|id| !id.is_empty())
                .map(str::to_owned)
                .or_else(|| Some(user_id.clone()));
            Some(HostSelfProfile {
                user_id,
                display_name,
                avatar,
                self_conv_id: send2me,
            })
        });
        let mut identities = IdentityTable::default();
        if let Some(contacts) = &seed.contacts {
            apply_contacts_json(contacts, &mut identities);
        }
        let open_conv = seed
            .open_conversation_id
            .clone()
            .filter(|id| !id.is_empty());
        let mut e2ee_send_results = VecDeque::new();
        if let Some(arr) = seed
            .host_results
            .as_ref()
            .and_then(|hr| hr.get("send_e2ee_text"))
            .and_then(Value::as_array)
        {
            for item in arr {
                if let Some(err_obj) = item.get("error").and_then(Value::as_object) {
                    let code = err_obj.get("code").and_then(Value::as_i64).unwrap_or(500);
                    let msg = err_obj
                        .get("message")
                        .and_then(Value::as_str)
                        .unwrap_or("E2EE error");
                    let url = err_obj.get("url").and_then(Value::as_str).unwrap_or("");
                    let formatted = if url.is_empty() {
                        format!("Zalo error {code}: {msg}")
                    } else {
                        format!("Zalo error {code}: {msg} ({url})")
                    };
                    e2ee_send_results.push_back(Err(formatted));
                } else {
                    let msg_id = item
                        .get("msg_id")
                        .and_then(Value::as_str)
                        .unwrap_or_default()
                        .to_owned();
                    let cli_msg_id = item
                        .get("cli_msg_id")
                        .and_then(Value::as_str)
                        .unwrap_or_default()
                        .to_owned();
                    let ts_ms = item.get("ts_ms").and_then(Value::as_i64).unwrap_or(0);
                    e2ee_send_results.push_back(Ok(SendMessageResult {
                        msg_id,
                        cli_msg_id,
                        ts_ms,
                    }));
                }
            }
        }
        let mut resolve_media_results = VecDeque::new();
        if let Some(arr) = seed
            .host_results
            .as_ref()
            .and_then(|hr| hr.get("resolve_media"))
            .and_then(Value::as_array)
        {
            for item in arr {
                let outcome = match item
                    .get("state")
                    .and_then(Value::as_str)
                    .unwrap_or("unavailable")
                {
                    "file" | "ok" => match item.get("path").and_then(Value::as_str) {
                        Some(path) if path.starts_with('/') => {
                            MediaResolutionOutcome::File(path.to_owned())
                        }
                        _ => MediaResolutionOutcome::Unavailable,
                    },
                    "expired" => MediaResolutionOutcome::Expired,
                    "unsupported" => MediaResolutionOutcome::Unsupported,
                    _ => MediaResolutionOutcome::Unavailable,
                };
                resolve_media_results.push_back(outcome);
            }
        }
        let mut resolve_file_results = VecDeque::new();
        if let Some(arr) = seed
            .host_results
            .as_ref()
            .and_then(|hr| hr.get("resolve_file"))
            .and_then(Value::as_array)
        {
            for item in arr {
                let outcome = match item
                    .get("state")
                    .and_then(Value::as_str)
                    .unwrap_or("failed")
                {
                    "ready" => match item.get("path").and_then(Value::as_str) {
                        Some(path) if !path.is_empty() => {
                            FileResolutionOutcome::Ready(path.to_owned())
                        }
                        _ => FileResolutionOutcome::Failed("Missing staged path".to_owned()),
                    },
                    "expired" => FileResolutionOutcome::Expired,
                    _ => FileResolutionOutcome::Failed(
                        item.get("message")
                            .and_then(Value::as_str)
                            .unwrap_or("Không tải được tệp.")
                            .to_owned(),
                    ),
                };
                resolve_file_results.push_back(outcome);
            }
        }
        let mut fetch_media_data_results = VecDeque::new();
        if let Some(arr) = seed
            .host_results
            .as_ref()
            .and_then(|hr| hr.get("fetch_media_data"))
            .and_then(Value::as_array)
        {
            for item in arr {
                let has_data = item.get("data_utf8").and_then(Value::as_str).is_some()
                    || item.get("ok").and_then(Value::as_bool) == Some(true);
                fetch_media_data_results.push_back(has_data);
            }
        }
        let parse_composer = |item: &Value| -> ComposerSendOutcome {
            match item
                .get("outcome")
                .and_then(Value::as_str)
                .unwrap_or("failed")
            {
                "done" => ComposerSendOutcome::Done,
                "cancelled" => ComposerSendOutcome::Cancelled,
                "pending" => ComposerSendOutcome::Pending(
                    item.get("text")
                        .and_then(Value::as_str)
                        .unwrap_or("Đang chờ...")
                        .to_owned(),
                ),
                _ => ComposerSendOutcome::Failed(
                    item.get("text")
                        .and_then(Value::as_str)
                        .unwrap_or("Có lỗi khi gửi tệp")
                        .to_owned(),
                ),
            }
        };
        let mut send_media_results = VecDeque::new();
        if let Some(arr) = seed
            .host_results
            .as_ref()
            .and_then(|hr| hr.get("send_media"))
            .and_then(Value::as_array)
        {
            for item in arr {
                send_media_results.push_back(parse_composer(item));
            }
        }
        let mut send_files_results = VecDeque::new();
        if let Some(arr) = seed
            .host_results
            .as_ref()
            .and_then(|hr| hr.get("send_files"))
            .and_then(Value::as_array)
        {
            for item in arr {
                send_files_results.push_back(parse_composer(item));
            }
        }
        Self {
            saved_session,
            legacy_cookie,
            transport_state: PersistedTransportState {
                poll_state,
                ws_cursors,
            },
            self_profile: Mutex::new(self_profile),
            calls: Mutex::new(Vec::new()),
            notify: Notify::new(),
            is_u3,
            is_u4,
            data_dir,
            shared_store_slot: Mutex::new(None),
            store: Mutex::new(None),
            e2ee_send_results: Mutex::new(e2ee_send_results),
            resolve_media_results: Mutex::new(resolve_media_results),
            resolve_file_results: Mutex::new(resolve_file_results),
            fetch_media_data_results: Mutex::new(fetch_media_data_results),
            send_media_results: Mutex::new(send_media_results),
            send_files_results: Mutex::new(send_files_results),
            fwd_photo_counter: Mutex::new(0),
            messages: Mutex::new(HashMap::new()),
            open_conversation_id: Mutex::new(open_conv),
            identities: Mutex::new(identities),
        }
    }

    pub fn bind_store_slot(&self, slot: SharedStoreSlot) {
        *self
            .shared_store_slot
            .lock()
            .unwrap_or_else(PoisonError::into_inner) = Some(slot);
    }

    pub fn attached_store(&self) -> Option<Arc<Mutex<Store>>> {
        self.store
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone()
    }

    pub fn set_open_conversation(&self, id: Option<String>) {
        *self
            .open_conversation_id
            .lock()
            .unwrap_or_else(PoisonError::into_inner) = id;
    }

    pub fn update_contacts(&self, contacts: &Value) -> IdentityTable {
        let mut guard = self
            .identities
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        apply_contacts_json(contacts, &mut guard);
        guard.clone()
    }

    pub fn current_identities(&self) -> IdentityTable {
        self.identities
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone()
    }

    pub fn remove_messages(&self, conv_id: &str) {
        self.messages
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .remove(conv_id);
    }

    pub fn last_message_id(&self, conv_id: &str) -> String {
        self.messages
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get(conv_id)
            .and_then(|list| list.last())
            .map(|m| m.id.clone())
            .unwrap_or_default()
    }

    pub fn seen_target_for(&self, conv_id: &str) -> Option<SeenTarget> {
        let msgs = self.messages.lock().unwrap_or_else(PoisonError::into_inner);
        let list = msgs.get(conv_id)?;
        let last = list.iter().rev().find(|m| !m.is_mine)?;
        Some(SeenTarget {
            conv_id: conv_id.to_owned(),
            msg_id: last.id.clone(),
            cli_msg_id: last.client_id.clone(),
            sender_id: last.sender_id.clone(),
        })
    }

    fn lookup_person(&self, uid: &str) -> Option<NameLookup> {
        let ids = self
            .identities
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        if let Some(f) = ids.friends.iter().find(|f| f.id == uid) {
            return Some(NameLookup {
                name: f.name.clone(),
                avatar: f.avatar.clone().unwrap_or_default(),
            });
        }
        if let Some(alias) = ids.aliases.get(uid)
            && !alias.is_empty()
        {
            let avt = ids
                .cached_profiles
                .get(uid)
                .map(|p| p.avatar.clone())
                .unwrap_or_default();
            return Some(NameLookup {
                name: alias.clone(),
                avatar: avt,
            });
        }
        if let Some(prof) = ids.cached_profiles.get(uid)
            && (!prof.name.is_empty() || !prof.avatar.is_empty())
        {
            return Some(NameLookup {
                name: prof.name.clone(),
                avatar: prof.avatar.clone(),
            });
        }
        drop(ids);
        let profile = self
            .self_profile
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        if let Some(p) = profile.as_ref()
            && p.user_id == uid
        {
            return Some(NameLookup {
                name: "Bạn".to_owned(),
                avatar: p.avatar.clone(),
            });
        }
        drop(profile);
        if let Some(store_arc) = self.attached_store() {
            let store = store_arc.lock().unwrap_or_else(PoisonError::into_inner);
            if let Ok(convs) = store.load_conversations()
                && let Some(conv) = convs.into_iter().find(|c| c.id == uid)
            {
                let trimmed = conv.name.trim();
                let valid_name = if !trimmed.is_empty()
                    && trimmed != conv.id
                    && trimmed != olaz_wire::UNKNOWN_NAME
                {
                    trimmed.to_owned()
                } else {
                    String::new()
                };
                if !valid_name.is_empty() || !conv.avatar.is_empty() {
                    return Some(NameLookup {
                        name: valid_name,
                        avatar: conv.avatar,
                    });
                }
            }
        }
        None
    }

    fn merge_message_into_memory(
        messages: &mut HashMap<String, Vec<ChatMessage>>,
        msg: ChatMessage,
        replacing_client_id: &str,
    ) {
        let list = messages.entry(msg.conversation_id.clone()).or_default();
        if let Some(pos) = list.iter().position(|m| {
            m.id == msg.id
                || (!replacing_client_id.is_empty()
                    && (m.id == replacing_client_id || m.client_id == replacing_client_id))
        }) {
            list[pos] = msg;
        } else {
            list.push(msg);
        }
        list.sort_by_key(|m| m.date_ms);
    }

    pub fn apply_events_pass1(
        &self,
        events: &[ParsedWireEvent],
        increment_unread: bool,
        persist_conversations: bool,
    ) -> BatchApplyDelta {
        if events.is_empty() {
            return BatchApplyDelta::default();
        }
        let open_conv = self
            .open_conversation_id
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone();
        let mut messages = self.messages.lock().unwrap_or_else(PoisonError::into_inner);
        let mut stored_batch: Vec<StoredMessage> = Vec::new();
        let mut latest_by_conv: BTreeMap<String, ChatMessage> = BTreeMap::new();
        let mut unread_delta_by_conv: HashMap<String, i64> = HashMap::new();

        for ev in events {
            if let ParsedWireEvent::Message(msg, stored) = ev {
                let already_known = messages
                    .get(&msg.conversation_id)
                    .is_some_and(|list| list.iter().any(|m| m.id == msg.id));
                stored_batch.push(StoredMessage {
                    id: stored.id.clone(),
                    conv_id: stored.conv_id.clone(),
                    client_id: stored.client_id.clone(),
                    sender_id: stored.sender_id.clone(),
                    sender_name: stored.sender_name.clone(),
                    sender_avatar: stored.sender_avatar.clone(),
                    is_mine: stored.is_mine,
                    text: stored.text.clone(),
                    kind_tag: stored.kind_tag.clone(),
                    ts_ms: stored.ts_ms,
                    status: stored.status.clone(),
                    raw_json_data: stored.raw_json_data.clone(),
                });
                Self::merge_message_into_memory(&mut messages, (**msg).clone(), &stored.client_id);
                let replace = latest_by_conv
                    .get(&msg.conversation_id)
                    .is_none_or(|cur| msg.date_ms >= cur.date_ms);
                if replace {
                    latest_by_conv.insert(msg.conversation_id.clone(), (**msg).clone());
                }
                if increment_unread
                    && !already_known
                    && !msg.is_mine
                    && open_conv.as_deref() != Some(msg.conversation_id.as_str())
                {
                    *unread_delta_by_conv
                        .entry(msg.conversation_id.clone())
                        .or_insert(0) += 1;
                }
            }
        }
        drop(messages);

        if !stored_batch.is_empty()
            && let Some(store_arc) = self.attached_store()
        {
            let mut store = store_arc.lock().unwrap_or_else(PoisonError::into_inner);
            let _ = store.save_messages(&stored_batch);
        }

        let mut preview_overrides: Vec<ConvPreviewOverride> = Vec::new();
        for ev in events {
            match ev {
                ParsedWireEvent::Undo {
                    conv_id,
                    msg_id,
                    cli_msg_id,
                } => {
                    let target_id = if !msg_id.is_empty() {
                        msg_id.as_str()
                    } else {
                        cli_msg_id.as_str()
                    };
                    if conv_id.is_empty() || target_id.is_empty() {
                        continue;
                    }
                    let mut found_in_memory = false;
                    let mut recalled_last: Option<(i64, bool)> = None;
                    {
                        let mut messages =
                            self.messages.lock().unwrap_or_else(PoisonError::into_inner);
                        if let Some(list) = messages.get_mut(conv_id)
                            && let Some(idx) = list.iter().position(|m| {
                                m.id == target_id
                                    || m.client_id == target_id
                                    || (!cli_msg_id.is_empty()
                                        && (m.id == *cli_msg_id || m.client_id == *cli_msg_id))
                            })
                        {
                            found_in_memory = true;
                            let was_last = idx + 1 == list.len();
                            let msg = &mut list[idx];
                            msg.kind = Kind::Recalled;
                            msg.text.clear();
                            msg.reactions.clear();
                            msg.quote = None;
                            msg.card_buttons.clear();
                            if was_last {
                                recalled_last = Some((msg.date_ms, msg.is_mine));
                            }
                        }
                    }
                    if let Some(store_arc) = self.attached_store() {
                        let mut store = store_arc.lock().unwrap_or_else(PoisonError::into_inner);
                        let _ = store.mark_recalled(conv_id, target_id, cli_msg_id);
                        if !found_in_memory
                            && let Ok(rows) = store.messages(conv_id, None, 1)
                            && let Some(latest) = rows.last()
                            && latest.kind_tag == "recalled"
                            && (latest.id == target_id
                                || latest.client_id == target_id
                                || (!cli_msg_id.is_empty()
                                    && (latest.id == *cli_msg_id
                                        || latest.client_id == *cli_msg_id)))
                        {
                            recalled_last = Some((latest.ts_ms, latest.is_mine));
                        }
                    }
                    if let Some((target_date_ms, from_me)) = recalled_last {
                        preview_overrides.push(ConvPreviewOverride {
                            conv_id: conv_id.clone(),
                            target_date_ms,
                            preview: Some(ConversationPreview {
                                text: "Tin nhắn đã được thu hồi".to_owned(),
                                date_ms: Some(target_date_ms),
                                from_me,
                            }),
                        });
                    }
                }
                ParsedWireEvent::Delete {
                    conv_id,
                    msg_id,
                    cli_msg_id,
                } => {
                    let target_id = if !msg_id.is_empty() {
                        msg_id.as_str()
                    } else {
                        cli_msg_id.as_str()
                    };
                    if conv_id.is_empty() || target_id.is_empty() {
                        continue;
                    }
                    let mut deleted_ts_ms: Option<i64> = None;
                    let mem_latest: Option<ConversationPreview> = {
                        let mut messages =
                            self.messages.lock().unwrap_or_else(PoisonError::into_inner);
                        if let Some(list) = messages.get_mut(conv_id) {
                            for m in list.iter() {
                                if m.id == target_id
                                    || m.client_id == target_id
                                    || (!cli_msg_id.is_empty()
                                        && (m.id == *cli_msg_id || m.client_id == *cli_msg_id))
                                {
                                    deleted_ts_ms = Some(
                                        deleted_ts_ms.map_or(m.date_ms, |prev| prev.max(m.date_ms)),
                                    );
                                }
                            }
                            list.retain(|m| {
                                !(m.id == target_id
                                    || m.client_id == target_id
                                    || (!cli_msg_id.is_empty()
                                        && (m.id == *cli_msg_id || m.client_id == *cli_msg_id)))
                            });
                            list.last().map(|m| ConversationPreview {
                                text: message_preview_label(m),
                                date_ms: Some(m.date_ms),
                                from_me: m.is_mine,
                            })
                        } else {
                            None
                        }
                    };
                    let mut store_latest: Option<ConversationPreview> = None;
                    if let Some(store_arc) = self.attached_store() {
                        let mut store = store_arc.lock().unwrap_or_else(PoisonError::into_inner);
                        if deleted_ts_ms.is_none() {
                            if let Ok(Some(row)) = store.message(conv_id, target_id) {
                                deleted_ts_ms = Some(row.ts_ms);
                            } else if !cli_msg_id.is_empty()
                                && let Ok(Some(row)) = store.message(conv_id, cli_msg_id)
                            {
                                deleted_ts_ms = Some(row.ts_ms);
                            }
                        }
                        let _ = store.delete_message(conv_id, target_id);
                        if !cli_msg_id.is_empty() && cli_msg_id != target_id {
                            let _ = store.delete_message(conv_id, cli_msg_id);
                        }
                        if let Ok(rows) = store.messages(conv_id, None, 1)
                            && let Some(row) = rows.last()
                        {
                            store_latest = Some(Self::preview_from_stored_message(row));
                        }
                    }
                    if let Some(target_date_ms) = deleted_ts_ms {
                        let best_remaining = match (mem_latest, store_latest) {
                            (Some(a), Some(b)) => {
                                if a.date_ms.unwrap_or(0) >= b.date_ms.unwrap_or(0) {
                                    Some(a)
                                } else {
                                    Some(b)
                                }
                            }
                            (Some(a), None) => Some(a),
                            (None, Some(b)) => Some(b),
                            (None, None) => None,
                        };
                        let still_newer = best_remaining
                            .as_ref()
                            .and_then(|p| p.date_ms)
                            .is_some_and(|d| d > target_date_ms);
                        if !still_newer {
                            preview_overrides.push(ConvPreviewOverride {
                                conv_id: conv_id.clone(),
                                target_date_ms,
                                preview: best_remaining,
                            });
                        }
                    }
                }
                _ => {}
            }
        }

        let updates: Vec<ConvMessageDelta> = latest_by_conv
            .into_iter()
            .map(|(conv_id, latest)| {
                let delta = unread_delta_by_conv.get(&conv_id).copied().unwrap_or(0);
                ConvMessageDelta {
                    conv_id,
                    preview_text: message_preview_label(&latest),
                    preview_date_ms: latest.date_ms,
                    preview_from_me: latest.is_mine,
                    is_mine: latest.is_mine,
                    sender_name: latest.sender_name,
                    sender_avatar: latest.sender_avatar.filter(|s| !s.is_empty()),
                    unread_delta: delta,
                }
            })
            .collect();

        BatchApplyDelta {
            applied_count: u32::try_from(events.len()).unwrap_or(u32::MAX),
            updates,
            preview_overrides,
            persist_conversations,
        }
    }

    fn preview_from_stored_message(row: &StoredMessage) -> ConversationPreview {
        if let Some(decoded) = decode_stored_message(&to_wire_stored(row)) {
            ConversationPreview {
                text: message_preview_label(&decoded),
                date_ms: Some(decoded.date_ms),
                from_me: decoded.is_mine,
            }
        } else {
            let text = if row.kind_tag == "recalled" {
                "Tin nhắn đã được thu hồi".to_owned()
            } else {
                row.text.clone()
            };
            ConversationPreview {
                text,
                date_ms: Some(row.ts_ms),
                from_me: row.is_mine,
            }
        }
    }

    pub fn process_direct_batch(
        &self,
        payload: &Value,
        default_cmd: u16,
        fallback_conv_id: Option<&str>,
        is_group_hint: Option<bool>,
        increment_unread: bool,
        persist_conversations: bool,
    ) -> BatchApplyDelta {
        let profile = self
            .self_profile
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone();
        let my_uid = profile
            .as_ref()
            .map(|p| p.user_id.as_str())
            .unwrap_or_default();
        let self_conv = profile.as_ref().and_then(|p| p.self_conv_id.as_deref());
        let lookup = |uid: &str| self.lookup_person(uid);
        let opts = WireParseOptions {
            cmd: default_cmd,
            fallback_conv_id,
            is_group_hint,
            self_conv_id: self_conv,
            name_lookup: Some(&lookup),
        };
        let events = extract_batch_events(payload, my_uid, &opts);
        self.apply_events_pass1(&events, increment_unread, persist_conversations)
    }

    pub fn load_local_messages_for_open(&self, conv_id: &str) -> Option<ChatMessage> {
        if let Some(store_arc) = self.attached_store() {
            let store = store_arc.lock().unwrap_or_else(PoisonError::into_inner);
            if let Ok(rows) = store.messages(conv_id, None, 50) {
                let mut messages = self.messages.lock().unwrap_or_else(PoisonError::into_inner);
                for row in &rows {
                    if let Some(msg) = decode_stored_message(&to_wire_stored(row)) {
                        Self::merge_message_into_memory(&mut messages, msg, "");
                    }
                }
            }
        }
        self.messages
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get(conv_id)
            .and_then(|list| list.last().cloned())
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

    async fn prepare_store(&self, user_id: String, account: LoginAccount) {
        let self_conv_id = if account.send2me_id.is_empty() {
            (!user_id.is_empty()).then(|| user_id.clone())
        } else {
            Some(account.send2me_id.clone())
        };
        *self
            .self_profile
            .lock()
            .unwrap_or_else(PoisonError::into_inner) = Some(HostSelfProfile {
            user_id: user_id.clone(),
            display_name: account.display_name,
            avatar: account.avatar,
            self_conv_id,
        });
        if self.is_u3
            && let Some(dir) = &self.data_dir
            && !user_id.is_empty()
        {
            let acc_dir = dir.join("accounts").join(&user_id);
            let _ = std::fs::create_dir_all(&acc_dir);
            let db_path = acc_dir.join("history.sqlite3");
            if let Ok(store) = Store::open(&db_path) {
                let shared = Arc::new(Mutex::new(store));
                *self.store.lock().unwrap_or_else(PoisonError::into_inner) =
                    Some(Arc::clone(&shared));
                if let Some(slot) = self
                    .shared_store_slot
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner)
                    .as_ref()
                {
                    *slot.lock().unwrap_or_else(PoisonError::into_inner) = Some(shared);
                }
            }
        }
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

    async fn on_bootstrap_started(&self) -> bool {
        self.start_bootstrap().await;
        false
    }

    async fn apply_mutes(&self, mutes: Vec<MuteEntry>) {
        let items: Vec<Value> = mutes
            .iter()
            .map(|m| {
                json!({
                    "conv_id": m.conv_id,
                    "start": m.start,
                    "duration": m.duration,
                })
            })
            .collect();
        self.record("apply_mutes", json!({ "mutes": items }));
    }

    async fn refresh_cloud(&self) {
        self.record("refresh_cloud", json!({}));
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
        *self.store.lock().unwrap_or_else(PoisonError::into_inner) = None;
        self.record("clear_session", json!({}));
    }

    async fn mark_expired(&self, _snapshot_json: String) {
        *self.store.lock().unwrap_or_else(PoisonError::into_inner) = None;
        self.record("mark_expired", json!({}));
    }

    async fn persist_poll_state(&self, state: PollState) {
        self.record("persist_poll_state", json!({ "state": state }));
    }

    async fn persist_ws_cursors(&self, cursors: CursorMap) {
        self.record("persist_ws_cursors", json!({ "cursors": cursors }));
    }

    async fn on_batch_received(
        &self,
        cmd: Option<u16>,
        increment_unread: bool,
        notify_incoming: bool,
        payload: Map<String, Value>,
    ) -> BatchHookOutcome {
        if self.is_u4 {
            self.record(
                "apply_batch",
                json!({
                    "cmd": cmd,
                    "increment_unread": increment_unread,
                    "notify_incoming": notify_incoming,
                    "payload": Value::Object(payload.clone()),
                }),
            );
            BatchHookOutcome::IngestInCore(payload)
        } else {
            BatchHookOutcome::DelegateToLegacy
        }
    }

    async fn on_parsed_events_received(
        &self,
        cmd: u16,
        increment_unread: bool,
        notify_incoming: bool,
        envelope: &TypedChatEnvelope,
    ) -> ParsedEventsHookOutcome {
        if self.is_u4 {
            let profile = self
                .self_profile
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .clone();
            let events = if let Some(p) = profile {
                let mut names = Vec::new();
                for uid in &envelope.uids {
                    if let Some(info) = self.lookup_person(uid) {
                        names.push((uid.clone(), info));
                    }
                }
                envelope
                    .payload
                    .resolve(&p.user_id, p.self_conv_id.as_deref(), &names)
                    .unwrap_or_else(|| envelope.events.clone())
            } else {
                envelope.events.clone()
            };
            let serialized: Vec<Value> = events
                .iter()
                .filter(|ev| !matches!(ev, ParsedWireEvent::Ignore))
                .map(serialize_parsed_wire_event)
                .collect();
            self.record(
                "apply_parsed_events",
                json!({
                    "cmd": cmd,
                    "increment_unread": increment_unread,
                    "notify_incoming": notify_incoming,
                    "events": serialized,
                }),
            );
            ParsedEventsHookOutcome::IngestInCore
        } else {
            ParsedEventsHookOutcome::DelegateToLegacy
        }
    }

    async fn refresh_board_pins(&self, conv_id: String) {
        if self.is_u4 {
            self.record("refresh_board_pins", json!({ "conv_id": conv_id }));
        }
    }

    async fn mark_read_boundary(&self, conv_id: String, _seen_target: Option<SeenTarget>) {
        if self.is_u4 {
            self.record("mark_read", json!({ "conv_id": conv_id }));
        }
    }

    async fn send_e2ee_text(
        &self,
        conv_id: String,
        text: String,
        client_id: String,
        quote: Option<E2eeQuoteArg>,
    ) -> Result<SendMessageResult, String> {
        let quote_val = match quote {
            Some(q) => json!({
                "msg_id": q.msg_id,
                "cli_msg_id": q.cli_msg_id,
                "sender_id": q.sender_id,
                "sender_name": q.sender_name,
                "text": q.text,
                "ts_ms": q.ts_ms,
            }),
            None => Value::Null,
        };
        self.record(
            "send_e2ee_text",
            json!({
                "conv_id": conv_id,
                "text": text,
                "client_id": client_id,
                "quote": quote_val,
            }),
        );
        self.e2ee_send_results
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .pop_front()
            .unwrap_or_else(|| {
                Err(
                    "Zalo error 500: No scripted send_e2ee_text result (/api/e2ee/pc/message/sms)"
                        .to_owned(),
                )
            })
    }

    async fn show_card(&self, conv_id: Option<String>, text: String) {
        self.record(
            "show_card",
            json!({
                "conv_id": conv_id,
                "text": text,
            }),
        );
    }

    async fn resolve_media(
        &self,
        conv_id: String,
        msg_id: String,
        kind: String,
    ) -> MediaResolutionOutcome {
        self.record(
            "resolve_media",
            json!({
                "conv_id": conv_id,
                "msg_id": msg_id,
                "kind": kind,
            }),
        );
        self.resolve_media_results
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .pop_front()
            .unwrap_or(MediaResolutionOutcome::Unavailable)
    }

    async fn resolve_file(
        &self,
        conv_id: String,
        msg_id: String,
        name: String,
        url: Option<String>,
    ) -> FileResolutionOutcome {
        self.record(
            "resolve_file",
            json!({
                "conv_id": conv_id,
                "msg_id": msg_id,
                "name": name,
                "url": url,
            }),
        );
        self.resolve_file_results
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .pop_front()
            .unwrap_or_else(|| {
                FileResolutionOutcome::Failed("No scripted resolve_file result".to_owned())
            })
    }

    async fn fetch_media_data(&self, url: String) -> Option<String> {
        self.record("fetch_media_data", json!({ "url": url }));
        let ok = self
            .fetch_media_data_results
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .pop_front()
            .unwrap_or(false);
        if !ok {
            return None;
        }
        let mut counter = self
            .fwd_photo_counter
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        *counter += 1;
        Some(format!("<tmp>/fwd-{}.jpg", *counter))
    }

    async fn send_media(
        &self,
        conv_id: String,
        paths: Vec<String>,
        _cleanup_after: bool,
    ) -> ComposerSendOutcome {
        self.record(
            "send_media",
            json!({
                "conv_id": conv_id,
                "paths": paths,
            }),
        );
        self.send_media_results
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .pop_front()
            .unwrap_or_else(|| ComposerSendOutcome::Failed("Có lỗi khi gửi tệp".to_owned()))
    }

    async fn send_files(&self, conv_id: String, paths: Vec<String>) -> ComposerSendOutcome {
        self.record(
            "send_files",
            json!({
                "conv_id": conv_id,
                "paths": paths,
            }),
        );
        self.send_files_results
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .pop_front()
            .unwrap_or_else(|| ComposerSendOutcome::Failed("Có lỗi khi gửi tệp".to_owned()))
    }

    async fn apply_remote_reaction(
        &self,
        conv_id: String,
        msg_id: String,
        cli_msg_id: String,
        sender_id: String,
        r_type: String,
        r_icon: String,
        event_id: String,
        react_client_id: String,
        sender_name: String,
    ) {
        if self.is_u4 {
            self.record(
                "apply_remote_reaction",
                json!({
                    "conv_id": conv_id,
                    "msg_id": msg_id,
                    "cli_msg_id": cli_msg_id,
                    "sender_id": sender_id,
                    "r_type": r_type,
                    "r_icon": r_icon,
                    "event_id": event_id,
                    "react_client_id": react_client_id,
                    "sender_name": sender_name,
                }),
            );
        }
    }

    async fn apply_remote_recall(
        &self,
        conv_id: String,
        msg_id: String,
        cli_msg_id: String,
        _update_conversation_preview: bool,
        _persist_conversations: bool,
    ) {
        if self.is_u4 {
            self.record(
                "apply_remote_recall",
                json!({
                    "conv_id": conv_id,
                    "msg_id": msg_id,
                    "cli_msg_id": cli_msg_id,
                }),
            );
        }
    }

    async fn apply_remote_delete(
        &self,
        conv_id: String,
        msg_id: String,
        cli_msg_id: String,
        _update_conversation_preview: bool,
        _persist_conversations: bool,
    ) {
        if self.is_u4 {
            self.record(
                "apply_remote_delete",
                json!({
                    "conv_id": conv_id,
                    "msg_id": msg_id,
                    "cli_msg_id": cli_msg_id,
                }),
            );
        }
    }

    async fn apply_batch(
        &self,
        cmd: Option<u16>,
        increment_unread: bool,
        notify_incoming: bool,
        payload: Map<String, Value>,
    ) -> BatchApplyDelta {
        let root = Value::Object(payload.clone());
        let delta = if self.is_u3 {
            self.process_direct_batch(&root, cmd.unwrap_or(0), None, None, increment_unread, true)
        } else {
            let opts = WireParseOptions {
                cmd: cmd.unwrap_or(0),
                fallback_conv_id: None,
                is_group_hint: None,
                self_conv_id: None,
                name_lookup: None,
            };
            let events = extract_batch_events(&root, "", &opts);
            let count = u32::try_from(events.len()).unwrap_or(u32::MAX);
            BatchApplyDelta {
                applied_count: count,
                updates: Vec::new(),
                preview_overrides: Vec::new(),
                persist_conversations: false,
            }
        };
        self.record(
            "apply_batch",
            json!({
                "cmd": cmd,
                "increment_unread": increment_unread,
                "notify_incoming": notify_incoming,
                "payload": Value::Object(payload),
            }),
        );
        delta
    }

    async fn apply_parsed_events(
        &self,
        cmd: u16,
        increment_unread: bool,
        notify_incoming: bool,
        envelope: TypedChatEnvelope,
    ) -> BatchApplyDelta {
        let profile = self
            .self_profile
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone();
        let events = if let Some(p) = profile {
            let mut names = Vec::new();
            for uid in &envelope.uids {
                if self.is_u3 {
                    if let Some(info) = self.lookup_person(uid) {
                        names.push((uid.clone(), info));
                    }
                } else if uid == &p.user_id {
                    names.push((
                        uid.clone(),
                        NameLookup {
                            name: p.display_name.clone(),
                            avatar: p.avatar.clone(),
                        },
                    ));
                }
            }
            envelope
                .payload
                .resolve(&p.user_id, p.self_conv_id.as_deref(), &names)
                .unwrap_or(envelope.events)
        } else {
            envelope.events
        };
        let serialized: Vec<Value> = events
            .iter()
            .filter(|ev| !matches!(ev, ParsedWireEvent::Ignore))
            .map(serialize_parsed_wire_event)
            .collect();
        let delta = if self.is_u3 {
            self.apply_events_pass1(&events, increment_unread, true)
        } else {
            BatchApplyDelta::default()
        };
        self.record(
            "apply_parsed_events",
            json!({
                "cmd": cmd,
                "increment_unread": increment_unread,
                "notify_incoming": notify_incoming,
                "events": serialized,
            }),
        );
        delta
    }

    async fn mobile_sync(&self, events: Vec<MobileSyncEvent>) {
        let serialized: Vec<Value> = events.iter().map(serialize_mobile_sync_event).collect();
        self.record("mobile_sync", json!({ "events": serialized }));
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

    async fn mute(
        &self,
        conv_id: String,
        set: bool,
        start: i64,
        start_explicit: bool,
        duration: i64,
    ) {
        let start_val = if start_explicit {
            Value::from(start)
        } else {
            Value::String("<volatile>".to_owned())
        };
        self.record(
            "mute",
            json!({ "conv_id": conv_id, "set": set, "start": start_val, "duration": duration }),
        );
    }
}

fn serialize_mobile_sync_event(ev: &MobileSyncEvent) -> Value {
    match ev {
        MobileSyncEvent::TransferAfterLogin { temp_key } => {
            json!({ "kind": "transfer_after_login", "temp_key": temp_key })
        }
        MobileSyncEvent::WaitingConfirmOnPhone { sync_id } => {
            json!({ "kind": "waiting_confirm_on_phone", "sync_id": sync_id })
        }
        MobileSyncEvent::UserConfirmed => json!({ "kind": "user_confirmed" }),
        MobileSyncEvent::UserRejected => json!({ "kind": "user_rejected" }),
        MobileSyncEvent::MobileBusy => json!({ "kind": "mobile_busy" }),
        MobileSyncEvent::UploadBatch {
            sync_id,
            url,
            batch_type,
            idx,
            is_last,
        } => json!({
            "kind": "upload_batch",
            "sync_id": sync_id,
            "url": url,
            "batch_type": batch_type,
            "idx": idx,
            "is_last": is_last,
        }),
    }
}

fn serialize_parsed_wire_event(ev: &ParsedWireEvent) -> Value {
    match ev {
        ParsedWireEvent::Message(msg, stored) => json!({
            "kind": "message",
            "conv_id": msg.conversation_id,
            "msg_id": msg.id,
            "client_id": stored.client_id,
            "sender_id": msg.sender_id,
            "sender_name": msg.sender_name,
            "sender_avatar": msg.sender_avatar,
            "is_mine": msg.is_mine,
            "kind_tag": stored.kind_tag,
            "text": msg.text,
            "ts_ms": stored.ts_ms,
            "status": stored.status,
            "is_e2ee": msg.is_e2ee,
        }),
        ParsedWireEvent::Reaction {
            conv_id,
            msg_id,
            cli_msg_id,
            sender_id,
            r_type,
            r_icon,
            event_id,
            react_client_id,
            ts_ms,
            seq_id,
            sender_name,
        } => json!({
            "kind": "reaction",
            "conv_id": conv_id,
            "msg_id": msg_id,
            "cli_msg_id": cli_msg_id,
            "sender_id": sender_id,
            "sender_name": sender_name,
            "r_type": r_type,
            "r_icon": r_icon,
            "event_id": event_id,
            "react_client_id": react_client_id,
            "ts_ms": ts_ms,
            "seq_id": seq_id,
        }),
        ParsedWireEvent::Undo {
            conv_id,
            msg_id,
            cli_msg_id,
        } => json!({
            "kind": "undo",
            "conv_id": conv_id,
            "msg_id": msg_id,
            "cli_msg_id": cli_msg_id,
        }),
        ParsedWireEvent::Delete {
            conv_id,
            msg_id,
            cli_msg_id,
        } => json!({
            "kind": "delete",
            "conv_id": conv_id,
            "msg_id": msg_id,
            "cli_msg_id": cli_msg_id,
        }),
        ParsedWireEvent::Typing {
            conv_id,
            sender_id,
            is_group,
        } => json!({
            "kind": "typing",
            "conv_id": conv_id,
            "sender_id": sender_id,
            "is_group": is_group,
        }),
        ParsedWireEvent::Ignore => json!({ "kind": "ignore" }),
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

fn apply_contacts_json(contacts: &Value, table: &mut IdentityTable) {
    if let Some(b) = contacts.get("friends_loaded").and_then(Value::as_bool) {
        table.friends_loaded = b;
    }
    if let Some(b) = contacts.get("groups_loaded").and_then(Value::as_bool) {
        table.groups_loaded = b;
    }
    if let Some(arr) = contacts.get("friends").and_then(Value::as_array) {
        table.friends.clear();
        for row in arr {
            let Some(id) = row.get("id").and_then(Value::as_str) else {
                continue;
            };
            let name = row
                .get("name")
                .and_then(Value::as_str)
                .unwrap_or(id)
                .to_owned();
            let avatar = row
                .get("avatar")
                .and_then(Value::as_str)
                .filter(|s| !s.is_empty())
                .map(str::to_owned);
            table.friends.push(FriendIdentity {
                id: id.to_owned(),
                name,
                avatar,
            });
        }
    }
    if let Some(arr) = contacts.get("groups").and_then(Value::as_array) {
        table.groups.clear();
        for row in arr {
            let Some(id) = row.get("id").and_then(Value::as_str) else {
                continue;
            };
            let name = row
                .get("name")
                .and_then(Value::as_str)
                .unwrap_or(id)
                .to_owned();
            let avatar = row
                .get("avatar")
                .and_then(Value::as_str)
                .filter(|s| !s.is_empty())
                .map(str::to_owned);
            let members = row.get("members").and_then(Value::as_i64).unwrap_or(0);
            table.groups.push(GroupIdentity {
                id: id.to_owned(),
                name,
                avatar,
                members,
            });
        }
    }
    if let Some(obj) = contacts.get("aliases").and_then(Value::as_object) {
        table.aliases.clear();
        for (k, v) in obj {
            if let Some(val) = v.as_str() {
                table.aliases.insert(k.clone(), val.to_owned());
            }
        }
    }
    if let Some(obj) = contacts.get("cached_profiles").and_then(Value::as_object) {
        table.cached_profiles.clear();
        for (k, v) in obj {
            let name = v
                .get("name")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_owned();
            let avatar = v
                .get("avatar")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_owned();
            table
                .cached_profiles
                .insert(k.clone(), CachedProfile { name, avatar });
        }
    }
    if let Some(obj) = contacts.get("cached_groups").and_then(Value::as_object) {
        table.cached_groups.clear();
        for (k, v) in obj {
            let name = v
                .get("name")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_owned();
            let avatar = v
                .get("avatar")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_owned();
            let members = v.get("members").and_then(Value::as_i64).unwrap_or(0);
            table.cached_groups.insert(
                k.clone(),
                CachedGroup {
                    name,
                    avatar,
                    members,
                },
            );
        }
    }
    if let Some(obj) = contacts.get("friend_global_ids").and_then(Value::as_object) {
        for (gid, v) in obj {
            if let Some(uid) = v.as_str()
                && !gid.is_empty()
                && !uid.is_empty()
            {
                table.friend_global_ids.insert(uid.to_owned(), gid.clone());
            }
        }
    }
}

fn seed_sqlite_store(user_id: &str, data_dir: &std::path::Path, seed: &Seed) -> Result<(), String> {
    let acc_dir = data_dir.join("accounts").join(user_id);
    std::fs::create_dir_all(&acc_dir).map_err(|e| format!("create accounts dir: {e}"))?;
    let db_path = acc_dir.join("history.sqlite3");
    let mut store = Store::open(&db_path).map_err(|e| format!("open sqlite store: {e}"))?;

    if let Some(ids) = &seed.pinned_ids {
        store
            .set_preference_strings("pinnedIds", ids)
            .map_err(|e| format!("seed pinnedIds: {e}"))?;
    }
    if let Some(ids) = &seed.archived_ids {
        store
            .set_preference_strings("archivedIds", ids)
            .map_err(|e| format!("seed archivedIds: {e}"))?;
    }
    if let Some(ids) = &seed.unread_marks {
        store
            .set_preference_strings("unreadMarks", ids)
            .map_err(|e| format!("seed unreadMarks: {e}"))?;
    }
    if let Some(ids) = &seed.hidden_ids {
        store
            .set_preference_strings("hiddenIds", ids)
            .map_err(|e| format!("seed hiddenIds: {e}"))?;
    }
    if let Some(md5) = &seed.hidden_pin_md5
        && !md5.is_empty()
    {
        store
            .set_preference_string("hiddenPinMD5", md5)
            .map_err(|e| format!("seed hiddenPinMD5: {e}"))?;
    }
    if let Some(sha) = &seed.hidden_pin_hash
        && !sha.is_empty()
    {
        store
            .set_preference_string("hiddenPinHash", sha)
            .map_err(|e| format!("seed hiddenPinHash: {e}"))?;
    }
    if let Some(labels) = &seed.labels_pref
        && !labels.is_null()
    {
        let bytes = canonical_json_string(labels).into_bytes();
        store
            .set_preference_data("labels", &bytes)
            .map_err(|e| format!("seed labels: {e}"))?;
    }
    if let Some(ranks) = &seed.activity_ranks
        && !ranks.is_null()
    {
        let bytes = canonical_json_string(ranks).into_bytes();
        store
            .set_preference_data("activityRanks", &bytes)
            .map_err(|e| format!("seed activityRanks: {e}"))?;
    }
    // U4-bootstrap
    if let Some(ts) = &seed.history_full_refresh_at
        && !ts.is_empty()
    {
        store
            .set_preference_string("historyFullRefreshAt", ts)
            .map_err(|e| format!("seed historyFullRefreshAt: {e}"))?;
    }
    if let Some(contacts) = &seed.contacts {
        if let Some(v) = contacts.get("aliases")
            && !v.is_null()
        {
            let _ = store.set_preference_data("aliases", canonical_json_string(v).as_bytes());
        }
        if let Some(v) = contacts.get("cached_profiles")
            && !v.is_null()
        {
            let _ =
                store.set_preference_data("cachedProfiles", canonical_json_string(v).as_bytes());
        }
        if let Some(v) = contacts.get("cached_groups")
            && !v.is_null()
        {
            let _ = store.set_preference_data("cachedGroups", canonical_json_string(v).as_bytes());
        }
        if let Some(v) = contacts.get("friend_global_ids")
            && !v.is_null()
        {
            let _ = store.set_preference_data("gidToUidMap", canonical_json_string(v).as_bytes());
        }
    }
    if let Some(conv_rows) = &seed.local_conversations
        && !conv_rows.is_empty()
    {
        let stored: Vec<StoredConversation> = conv_rows
            .iter()
            .filter_map(|row| {
                let id = row.get("id").and_then(Value::as_str)?.to_owned();
                Some(StoredConversation {
                    id,
                    is_group: row
                        .get("is_group")
                        .and_then(Value::as_bool)
                        .unwrap_or(false),
                    name: row
                        .get("name")
                        .and_then(Value::as_str)
                        .unwrap_or_default()
                        .to_owned(),
                    avatar: row
                        .get("avatar")
                        .and_then(Value::as_str)
                        .unwrap_or_default()
                        .to_owned(),
                    pinned: row.get("pinned").and_then(Value::as_bool).unwrap_or(false),
                    members: row.get("members").and_then(Value::as_i64).unwrap_or(0),
                    unread: row.get("unread").and_then(Value::as_i64).unwrap_or(0),
                    preview_text: row
                        .get("preview_text")
                        .and_then(Value::as_str)
                        .unwrap_or_default()
                        .to_owned(),
                    preview_ts_ms: row
                        .get("preview_ts_ms")
                        .and_then(Value::as_i64)
                        .unwrap_or(0),
                    preview_from_me: row
                        .get("preview_from_me")
                        .and_then(Value::as_bool)
                        .unwrap_or(false),
                    updated_at_ms: row
                        .get("updated_at_ms")
                        .and_then(Value::as_i64)
                        .unwrap_or(1_700_000_000_000),
                })
            })
            .collect();
        store
            .save_conversations(&stored)
            .map_err(|e| format!("seed local_conversations: {e}"))?;
    }
    if let Some(msg_rows) = &seed.local_messages
        && !msg_rows.is_empty()
    {
        let stored: Vec<StoredMessage> = msg_rows
            .iter()
            .filter_map(|row| {
                let id = row.get("id").and_then(Value::as_str)?.to_owned();
                let conv_id = row.get("conv_id").and_then(Value::as_str)?.to_owned();
                let client_id = row
                    .get("client_id")
                    .and_then(Value::as_str)
                    .unwrap_or(&id)
                    .to_owned();
                let sender_id = row
                    .get("sender_id")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_owned();
                let sender_name = row
                    .get("sender_name")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_owned();
                let sender_avatar = row
                    .get("sender_avatar")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_owned();
                let is_mine = row.get("is_mine").and_then(Value::as_bool).unwrap_or(false);
                let text = row
                    .get("text")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_owned();
                let kind_tag = row
                    .get("kind_tag")
                    .and_then(Value::as_str)
                    .unwrap_or("text")
                    .to_owned();
                let ts_ms = row.get("ts_ms").and_then(Value::as_i64).unwrap_or(0);
                let status = row
                    .get("status")
                    .and_then(Value::as_str)
                    .unwrap_or("sent")
                    .to_owned();
                let raw_json_data = if let Some(raw_obj) = row.get("raw_json")
                    && !raw_obj.is_null()
                {
                    canonical_json_string(raw_obj).into_bytes()
                } else {
                    let is_e2ee = row.get("is_e2ee").and_then(Value::as_bool).unwrap_or(false);
                    let mut fallback = json!({
                        "id": id,
                        "conversationId": conv_id,
                        "clientId": client_id,
                        "senderId": sender_id,
                        "senderName": sender_name,
                        "senderAvatar": sender_avatar,
                        "isMine": is_mine,
                        "text": text,
                        "date": ts_ms,
                        "status": status,
                        "isE2EE": is_e2ee,
                        "kind": { "type": kind_tag },
                    });
                    if let Some(reactions) = row.get("reactions")
                        && !reactions.is_null()
                        && let Some(obj) = fallback.as_object_mut()
                    {
                        obj.insert("reactions".to_owned(), reactions.clone());
                    }
                    canonical_json_string(&fallback).into_bytes()
                };
                Some(StoredMessage {
                    id,
                    conv_id,
                    client_id,
                    sender_id,
                    sender_name,
                    sender_avatar,
                    is_mine,
                    text,
                    kind_tag,
                    ts_ms,
                    status,
                    raw_json_data,
                })
            })
            .collect();
        store
            .save_messages(&stored)
            .map_err(|e| format!("seed local_messages: {e}"))?;
    }
    Ok(())
}

struct LogCapturingRunner<R> {
    inner: Arc<R>,
    send_logs: Arc<Mutex<Vec<String>>>,
}

impl<R: EffectRunner> EffectRunner for LogCapturingRunner<R> {
    fn dispatch(&self, effects: Vec<Effect>, sink: ActorSink) {
        {
            let mut logs = self
                .send_logs
                .lock()
                .unwrap_or_else(PoisonError::into_inner);
            for eff in &effects {
                if let Effect::EngineLog(line) = eff
                    && line.starts_with("sendText ")
                {
                    logs.push(line.clone());
                }
            }
        }
        self.inner.dispatch(effects, sink);
    }

    fn shutdown(&self) {
        self.inner.shutdown();
    }
}

fn enrich_send_message_json(m: &ChatMessage, base: &mut Map<String, Value>) {
    base.insert(
        "status".to_owned(),
        Value::String(m.status.raw_value().to_owned()),
    );
    let quote_val = match &m.quote {
        Some(q) => json!({
            "sender_name": q.sender_name,
            "text": q.text,
            "msg_id": q.msg_id,
            "cli_msg_id": q.cli_msg_id,
        }),
        None => Value::Null,
    };
    base.insert("quote".to_owned(), quote_val);
    let mentions: Vec<Value> = m
        .mentions
        .iter()
        .map(|mn| {
            json!({
                "uid": mn.uid,
                "pos": mn.pos,
                "len": mn.len,
                "is_all": mn.is_all,
            })
        })
        .collect();
    base.insert("mentions".to_owned(), Value::Array(mentions));
    let styles: Vec<Value> = m
        .text_styles
        .iter()
        .map(|st| {
            json!({
                "start": st.start,
                "len": st.len,
                "st": st.st,
            })
        })
        .collect();
    base.insert("text_styles".to_owned(), Value::Array(styles));
    base.insert("ttl_ms".to_owned(), json!(m.ttl_ms));
    base.insert("urgency".to_owned(), json!(m.urgency));
    let forward = match m.menu.forward {
        Availability::Hidden => "hidden",
        Availability::Available => "available",
        Availability::Blocked => "blocked",
    };
    let delete_val = match m.menu.delete {
        None => Value::Null,
        Some(DeleteMode::Plain) => Value::String("plain".to_owned()),
        Some(DeleteMode::ForMe) => Value::String("for_me".to_owned()),
    };
    let star_val = match m.menu.star {
        None => Value::Null,
        Some(StarMode::Star) => Value::String("star".to_owned()),
        Some(StarMode::Unstar) => Value::String("unstar".to_owned()),
        Some(StarMode::Blocked) => Value::String("blocked".to_owned()),
    };
    base.insert(
        "menu".to_owned(),
        json!({
            "forward": forward,
            "recall": m.menu.recall,
            "delete": delete_val,
            "pin": m.menu.pin,
            "star": star_val,
            "starred": m.menu.starred,
            "pinned": m.menu.pinned,
            "protected": m.menu.is_protected,
        }),
    );
}

#[derive(Clone, Default)]
struct TestSelection {
    conv_id: String,
    ids: Vec<String>,
    anchor: Option<String>,
}

fn is_selectable_msg(m: &ChatMessage) -> bool {
    !matches!(
        m.kind,
        Kind::System | Kind::Notice { .. } | Kind::Ecard(_) | Kind::Poll(_)
    ) && m.status != Status::Sending
}

fn encode_forward_outcome_json(outcome: &ForwardOutcome) -> Value {
    match outcome {
        ForwardOutcome::Done(text) => json!({
            "status": "done",
            "text": text,
        }),
        ForwardOutcome::Pending(text) => json!({
            "status": "pending",
            "text": text,
        }),
        ForwardOutcome::Failed(text) => json!({
            "status": "failed",
            "text": text,
        }),
    }
}

struct ForwardSnapCtx<'a> {
    is_u8: bool,
    auto_delete_seeded: bool,
    last_send_result: Option<bool>,
    selection: Option<&'a TestSelection>,
    results: &'a Map<String, Value>,
}

async fn capture_case_snapshot(
    core: &CoreHandle,
    host: &RecordingHost,
    is_u3: bool,
    is_u4: bool,
    is_u5: bool,
    send_logs: &Mutex<Vec<String>>,
    fwd_ctx: &ForwardSnapCtx<'_>,
) -> Option<Value> {
    let last_send_result = fwd_ctx.last_send_result;
    if !is_u3 {
        return core
            .snapshot()
            .await
            .map(|s| s.to_case_json(&render_core_fail_en));
    }
    let full = core.full_snapshot().await?;
    let mut obj = match full.session.to_case_json(&render_core_fail_en) {
        Value::Object(m) => m,
        _ => Map::new(),
    };
    let (conv_fields, msg_fields) = if let Some(store_arc) = host.attached_store() {
        let store = store_arc.lock().unwrap_or_else(PoisonError::into_inner);
        let cf = full.conversations.to_case_json_fields(Some(&store));
        let mf = if is_u4 {
            Some(full.messages.to_case_json_fields(Some(&store)))
        } else {
            None
        };
        (cf, mf)
    } else {
        let cf = full.conversations.to_case_json_fields(None);
        let mf = if is_u4 {
            Some(full.messages.to_case_json_fields(None))
        } else {
            None
        };
        (cf, mf)
    };
    for (k, v) in conv_fields {
        obj.insert(k, v);
    }
    if let Some(mut mf) = msg_fields {
        obj.insert(
            "open_conversation_id".to_owned(),
            full.conversations
                .open_conversation_id
                .clone()
                .map_or(Value::Null, Value::String),
        );
        let store_msgs = mf.remove("__store_messages");
        let store_u4_prefs = mf.remove("__store_u4_prefs");
        for (k, v) in mf {
            obj.insert(k, v);
        }
        if let Some(Value::Object(store_obj)) = obj.get_mut("store") {
            if let Some(msgs_val) = store_msgs {
                store_obj.insert("messages".to_owned(), msgs_val);
            }
            if let Some(Value::Object(u4_prefs)) = store_u4_prefs
                && let Some(Value::Object(prefs_obj)) = store_obj.get_mut("prefs")
            {
                for (pk, pv) in u4_prefs {
                    prefs_obj.insert(pk, pv);
                }
            }
        }
    }
    if is_u5 {
        if let Some(Value::Object(msgs_obj)) = obj.get_mut("messages") {
            for (conv_id, list) in &full.messages.windows {
                if let Some(Value::Array(arr)) = msgs_obj.get_mut(conv_id)
                    && arr.len() == list.len()
                {
                    for (m, item) in list.iter().zip(arr.iter_mut()) {
                        if let Value::Object(map) = item {
                            enrich_send_message_json(m, map);
                        }
                    }
                }
            }
        }
        let mut typing_obj = Map::new();
        for (conv_id, t) in &full.typing {
            typing_obj.insert(
                conv_id.clone(),
                json!({
                    "name": t.name,
                    "on_pc": t.on_pc,
                }),
            );
        }
        obj.insert("typing".to_owned(), Value::Object(typing_obj));
        obj.insert(
            "last_send_result".to_owned(),
            last_send_result.map_or(Value::Null, Value::Bool),
        );
        let logs: Vec<Value> = send_logs
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .iter()
            .cloned()
            .map(Value::String)
            .collect();
        obj.insert("send_logs".to_owned(), Value::Array(logs));
    }
    if fwd_ctx.is_u8 {
        if let Some(Value::Object(msgs_obj)) = obj.get_mut("messages") {
            for (conv_id, list) in &full.messages.windows {
                if let Some(Value::Array(arr)) = msgs_obj.get_mut(conv_id)
                    && arr.len() == list.len()
                {
                    for (m, item) in list.iter().zip(arr.iter_mut()) {
                        if let Value::Object(map) = item {
                            let btns: Vec<Value> = m
                                .card_buttons
                                .iter()
                                .map(|b| {
                                    json!({
                                        "ref": b.r#ref,
                                        "label": b.label,
                                        "enabled": b.enabled,
                                        "help": b.help,
                                    })
                                })
                                .collect();
                            map.insert("buttons".to_owned(), Value::Array(btns));
                        }
                    }
                }
            }
        }
        obj.insert("delete_undo".to_owned(), Value::Null);
        obj.insert("message_confirm".to_owned(), Value::Null);
        let auto_del_val = if fwd_ctx.auto_delete_seeded {
            let mut m = Map::new();
            for (k, v) in &full.send_auto_delete {
                m.insert(k.clone(), json!(*v));
            }
            Value::Object(m)
        } else {
            Value::Null
        };
        obj.insert("auto_delete".to_owned(), auto_del_val);
        obj.insert("starred_ids".to_owned(), Value::Array(Vec::new()));
        obj.insert("prune_next_expiry_ms".to_owned(), Value::Null);
        let mut cp_obj = Map::new();
        for (uid, cp) in &full.conversations.identities.cached_profiles {
            cp_obj.insert(
                uid.clone(),
                json!({
                    "name": cp.name,
                    "avatar": cp.avatar,
                }),
            );
        }
        obj.insert("cached_profiles".to_owned(), Value::Object(cp_obj));
        obj.insert("action_logs".to_owned(), Value::Array(Vec::new()));

        if let Some(store_arc) = host.attached_store()
            && let Some(Value::Object(store_obj)) = obj.get_mut("store")
        {
            let store = store_arc.lock().unwrap_or_else(PoisonError::into_inner);
            let mut stored_msgs = store.load_all_messages().unwrap_or_default();
            stored_msgs.sort_by(|a, b| {
                a.conv_id
                    .as_bytes()
                    .cmp(b.conv_id.as_bytes())
                    .then_with(|| a.ts_ms.cmp(&b.ts_ms))
                    .then_with(|| a.id.as_bytes().cmp(b.id.as_bytes()))
            });
            if let Some(Value::Array(arr)) = store_obj.get_mut("messages")
                && arr.len() == stored_msgs.len()
            {
                for (row, item) in stored_msgs.iter().zip(arr.iter_mut()) {
                    if let Value::Object(map) = item {
                        let decoded = olaz_core::decode_db_stored(row);
                        let reactions: Vec<Value> = decoded
                            .as_ref()
                            .map(|d| {
                                d.reactions
                                    .iter()
                                    .map(|r| {
                                        let icon = if !r.icon.emoji.is_empty() {
                                            r.icon.emoji.as_str()
                                        } else if !r.icon.key.is_empty() {
                                            r.icon.key.as_str()
                                        } else {
                                            r.icon.r#type.as_str()
                                        };
                                        json!({
                                            "icon": icon,
                                            "count": r.count,
                                            "includes_me": r.includes_me,
                                        })
                                    })
                                    .collect()
                            })
                            .unwrap_or_default();
                        let starred = decoded.as_ref().is_some_and(|d| d.menu.starred);
                        map.insert("reactions".to_owned(), Value::Array(reactions));
                        map.insert("starred".to_owned(), Value::Bool(starred));
                    }
                }
            }
            if let Some(Value::Object(prefs_obj)) = store_obj.get_mut("prefs") {
                let mut starred_ids = store
                    .get_preference_strings("starredIds")
                    .unwrap_or_default();
                starred_ids.sort_by(|a, b| a.as_bytes().cmp(b.as_bytes()));
                prefs_obj.insert(
                    "starred_ids".to_owned(),
                    Value::Array(starred_ids.into_iter().map(Value::String).collect()),
                );
                let seen_ids = store
                    .get_preference_strings("seenReactionEventIds")
                    .unwrap_or_default();
                prefs_obj.insert(
                    "seen_reaction_event_ids".to_owned(),
                    Value::Array(seen_ids.into_iter().map(Value::String).collect()),
                );
            }
        }

        obj.insert(
            "forward_request".to_owned(),
            match &full.forward_request {
                Some(req) => json!({
                    "conv_id": req.conversation_id,
                    "msg_id": req.message.id,
                    "more": req.more.iter().map(|m| m.id.clone()).collect::<Vec<_>>(),
                }),
                None => Value::Null,
            },
        );
        obj.insert(
            "selection".to_owned(),
            match fwd_ctx.selection {
                Some(sel) => json!({
                    "conv_id": sel.conv_id,
                    "ids": sel.ids,
                    "anchor": sel.anchor,
                }),
                None => Value::Null,
            },
        );
        obj.insert("results".to_owned(), Value::Object(fwd_ctx.results.clone()));
    }
    Some(Value::Object(obj))
}

fn str_arg(args: &Value, key: &str) -> String {
    args.get(key)
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_owned()
}

fn str_vec_arg(args: &Value, key: &str) -> Vec<String> {
    args.get(key)
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(Value::as_str)
                .map(str::to_owned)
                .collect()
        })
        .unwrap_or_default()
}

/// Runs a single Case format v1 [`Case`] under paused tokio time and returns the observed
/// snapshots, final state, sorted canonical requests, and ordered host calls.
pub async fn run_case(case: &Case) -> Result<CaseRunResult, String> {
    let is_u8 = case.domain == "forward";
    let is_u5 = case.domain == "send" || is_u8;
    let is_u4 = case.domain == "bootstrap" || case.domain == "messages" || is_u5;
    let is_u3 = case.domain == "conversations" || case.domain == "conversation_actions" || is_u4;
    let temp_dir = if is_u3 {
        Some(tempfile::tempdir().map_err(|e| format!("tempdir: {e}"))?)
    } else {
        None
    };

    if is_u3
        && let Some(dir) = temp_dir.as_ref()
        && let Some(uid) = case
            .seed
            .saved_session
            .as_ref()
            .and_then(|s| s.get("plainAccount"))
            .and_then(|a| a.get("userId"))
            .and_then(Value::as_str)
        && !uid.is_empty()
    {
        seed_sqlite_store(uid, dir.path(), &case.seed)?;
    }

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
    let ws_auth_manual = case.seed.ws_auth.as_deref() == Some("manual");

    let ws_driver = Arc::new(ScriptedWsDriver::with_auth_mode(
        &case.server,
        Arc::clone(&recorded),
        suppress_ws,
        ws_auth_manual,
    ));

    let client = Arc::new(SessionClient::new(
        ArcTransport(Arc::clone(&transport)),
        "00000000-0000-4000-8000-000000000000-00000000000000000000000000000000".to_owned(),
        "TestMac".to_owned(),
    ));
    if let Some(d) = &seed_domains {
        client.with_session(|s| s.domains = d.clone());
    }
    if let Some(next_cid) = case.seed.next_client_id {
        client.seed_next_client_id(next_cid);
    }

    let host = Arc::new(RecordingHost::from_seed_with_modes(
        &case.seed,
        is_u3,
        is_u4,
        temp_dir.as_ref().map(|d| d.path().to_path_buf()),
    ));
    let inner_runner = Arc::new(SessionEffectRunner::with_options(
        Arc::clone(&client),
        Arc::clone(&host) as Arc<dyn Host>,
        Arc::clone(&ws_driver) as Arc<dyn WsDriver>,
        Handle::current(),
        seed_domains,
        suppress_lp,
    ));
    host.bind_store_slot(inner_runner.shared_store_slot());
    let send_logs = Arc::new(Mutex::new(Vec::<String>::new()));
    let runner: Arc<dyn EffectRunner> = Arc::new(LogCapturingRunner {
        inner: Arc::clone(&inner_runner),
        send_logs: Arc::clone(&send_logs),
    });

    let mut initial_state = CoreState::default();
    initial_state.session.prefs = case.seed.prefs.clone();
    if is_u3 {
        initial_state.conversations.identities = host.current_identities();
        initial_state.conversations.open_conversation_id = case
            .seed
            .open_conversation_id
            .clone()
            .filter(|id| !id.is_empty());
    }
    if is_u4 && !case.seed.history_freshness.is_empty() {
        for (cid, raw_f) in &case.seed.history_freshness {
            let f = match raw_f.as_str() {
                "up_to_date" => HistoryFreshness::UpToDate,
                _ => HistoryFreshness::Stale,
            };
            initial_state
                .messages
                .history_freshness
                .insert(cid.clone(), f);
        }
    }
    for tid in &case.seed.e2ee_threads {
        initial_state.send.e2ee_threads.insert(tid.clone());
    }
    for (conv_id, ttl) in &case.seed.auto_delete {
        if *ttl > 0 {
            initial_state
                .send
                .auto_delete_ttl_ms
                .insert(conv_id.clone(), *ttl);
        }
    }
    let core = Arc::new(CoreHandle::start_with_state(
        initial_state,
        runner,
        Handle::current(),
    ));

    let mut snapshots = BTreeMap::new();
    let mut host_cursor = 0usize;
    let mut last_send_result: Option<bool> = None;
    let mut pending_send_task: Option<tokio::task::JoinHandle<bool>> = None;

    let auto_delete_seeded = !case.seed.auto_delete.is_empty();
    let mut selection: Option<TestSelection> = None;
    let mut forward_results: Map<String, Value> = Map::new();
    for (step_idx, step) in case.steps.iter().enumerate() {
        match step {
            Step::Cmd {
                cmd,
                args,
                now_ms,
                rand4,
                timeout_ms,
            } => match cmd.as_str() {
                "start"
                | "refresh_qr"
                | "log_out"
                | "session_expired"
                | "apply_account_profile"
                | "drain_chat_polling" => {
                    let parsed = parse_command(cmd, args)?;
                    match parsed {
                        Command::LogOut | Command::SessionExpired { .. } => {
                            let _ = tokio::time::timeout(Duration::from_secs(5), core.wait_idle())
                                .await;
                            core.send(parsed);
                        }
                        Command::RefreshQr => {
                            let _ =
                                tokio::time::timeout(Duration::from_millis(500), core.wait_idle())
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
                        _ => {}
                    }
                }
                // U4-messages
                "open" => {
                    let _ = tokio::time::timeout(Duration::from_secs(5), core.wait_idle()).await;
                    let id = str_arg(args, "id");
                    host.set_open_conversation(Some(id.clone()));
                    core.request_unit(Command::OpenConversation {
                        id,
                        preloaded: Vec::new(),
                        skip_local_read: false,
                    })
                    .await;
                }
                "close" => {
                    host.set_open_conversation(None);
                    core.request_unit(Command::CloseConversation).await;
                }
                "load_older" => {
                    let _ = tokio::time::timeout(Duration::from_secs(5), core.wait_idle()).await;
                    let id = str_arg(args, "id");
                    core.request_unit(Command::LoadOlderMessages { id }).await;
                }
                // U4-bootstrap
                "bootstrap" => {
                    let _ = tokio::time::timeout(Duration::from_secs(5), core.wait_idle()).await;
                    let ts_ms = now_ms.unwrap_or(1_700_000_000_000);
                    core.request_unit(Command::Bootstrap { now_ms: ts_ms })
                        .await;
                }
                "apply_batch" => {
                    let _ = tokio::time::timeout(Duration::from_secs(5), core.wait_idle()).await;
                    let payload = args.get("payload").cloned().unwrap_or_else(|| json!({}));
                    let default_cmd = args
                        .get("default_cmd")
                        .and_then(Value::as_u64)
                        .and_then(|v| u16::try_from(v).ok())
                        .unwrap_or(0);
                    let fallback_conv_id = args.get("fallback_conv_id").and_then(Value::as_str);
                    let is_group_hint = args.get("is_group_hint").and_then(Value::as_bool);
                    let increment_unread = args
                        .get("increment_unread")
                        .and_then(Value::as_bool)
                        .unwrap_or(false);
                    let persist_conversations = args
                        .get("persist_conversations")
                        .and_then(Value::as_bool)
                        .unwrap_or(true);
                    let delta = host.process_direct_batch(
                        &payload,
                        default_cmd,
                        fallback_conv_id,
                        is_group_hint,
                        increment_unread,
                        persist_conversations,
                    );
                    core.request_unit(Command::ApplyBatchDelta(delta)).await;
                }
                "ensure_known_contacts" => {
                    core.request_unit(Command::EnsureKnownContacts).await;
                }
                "resolve_missing_names" => {
                    core.request_unit(Command::ResolveMissingNames).await;
                }
                "refresh_mention_previews" => {
                    core.request_unit(Command::RefreshMentionPreviews).await;
                }
                "update_contacts" => {
                    let table = host.update_contacts(args);
                    core.request_unit(Command::UpdateIdentities(table)).await;
                }
                "open_conversation" => {
                    let id_opt = args
                        .get("id")
                        .and_then(Value::as_str)
                        .filter(|s| !s.is_empty())
                        .map(str::to_owned);
                    let load = args.get("load").and_then(Value::as_bool).unwrap_or(false);
                    host.set_open_conversation(id_opt.clone());
                    core.request_unit(Command::SetOpenConversation { id: id_opt.clone() })
                        .await;
                    if load && let Some(conv_id) = id_opt {
                        let local_latest = host.load_local_messages_for_open(&conv_id);
                        let api = ZaloApi::from_shared(Arc::clone(&client));
                        let mut fetched = 0usize;
                        if let Ok(page) = api.fetch_history(&conv_id, None, 50, Some(false)).await {
                            let delta = host.process_direct_batch(
                                &Value::Object(page),
                                0,
                                Some(&conv_id),
                                None,
                                false,
                                false,
                            );
                            fetched = delta.applied_count as usize;
                        }
                        let latest = host.load_local_messages_for_open(&conv_id).or(local_latest);
                        let missing_preview = core.full_snapshot().await.is_some_and(|s| {
                            s.conversations
                                .conversations
                                .iter()
                                .find(|c| c.id == conv_id)
                                .is_none_or(|c| c.preview.is_none())
                        });
                        if (fetched > 0 || missing_preview)
                            && let Some(msg) = latest
                        {
                            core.request_unit(Command::UpdateConversationOnMessage {
                                msg: MessagePreviewInput::from_chat_message(&msg),
                                increment_unread: false,
                            })
                            .await;
                        }
                        let seen_target = host.seen_target_for(&conv_id);
                        core.request_unit(Command::MarkConversationRead {
                            id: conv_id,
                            seen_target,
                        })
                        .await;
                    }
                }
                "pin" => {
                    let id = str_arg(args, "id");
                    core.request_unit(Command::PinConversation { id }).await;
                }
                "unpin" => {
                    let id = str_arg(args, "id");
                    core.request_unit(Command::UnpinConversation { id }).await;
                }
                "pin_board" => {
                    let id = str_arg(args, "id");
                    let _ = core.request_pin_board(id).await;
                }
                "pin_replacing" => {
                    let unpin_ids = str_vec_arg(args, "unpin");
                    let pin_id = str_arg(args, "id");
                    let _ = core
                        .request_action(Command::PinReplacing { unpin_ids, pin_id })
                        .await;
                }
                "move" => {
                    let id = str_arg(args, "id");
                    let to_other = args
                        .get("to_other")
                        .and_then(Value::as_bool)
                        .unwrap_or(true);
                    core.request_unit(Command::MoveConversation { id, to_other })
                        .await;
                }
                "request_delete" => {
                    let id = str_arg(args, "id");
                    core.request_unit(Command::RequestDeleteConversation { id })
                        .await;
                }
                "confirm_delete" => {
                    let id = str_arg(args, "id");
                    let last_cli_msg_id = host.last_message_id(&id);
                    core.request_unit(Command::ConfirmDeleteConversation {
                        id: id.clone(),
                        last_cli_msg_id,
                    })
                    .await;
                    host.remove_messages(&id);
                }
                "mark_read" => {
                    let id = str_arg(args, "id");
                    if is_u5 {
                        core.request_unit(Command::MarkRead { id }).await;
                        if pending_send_task.is_none() {
                            let _ = tokio::time::timeout(Duration::from_secs(5), core.wait_idle())
                                .await;
                        }
                    } else {
                        let seen_target = host.seen_target_for(&id);
                        core.request_unit(Command::MarkConversationRead { id, seen_target })
                            .await;
                    }
                }
                "mark_unread" => {
                    let id = str_arg(args, "id");
                    core.request_unit(Command::MarkConversationUnread { id })
                        .await;
                }
                "hide" => {
                    let id = str_arg(args, "id");
                    let pin = str_arg(args, "pin");
                    let _ = core
                        .request_action(Command::HideConversation { id, pin })
                        .await;
                }
                "hide_new_pin" => {
                    let id = str_arg(args, "id");
                    let pin = str_arg(args, "pin");
                    let _ = core
                        .request_action(Command::HideConversationNewPin { id, pin })
                        .await;
                }
                "unhide" => {
                    let id = str_arg(args, "id");
                    let pin = args.get("pin").and_then(Value::as_str).map(str::to_owned);
                    let _ = core
                        .request_action(Command::UnhideConversation { id, pin })
                        .await;
                }
                "set_pin" => {
                    let pin = str_arg(args, "pin");
                    let changed = args
                        .get("changed")
                        .and_then(Value::as_bool)
                        .unwrap_or(false);
                    let _ = core
                        .request_action(Command::SetHiddenPin { pin, changed })
                        .await;
                }
                "reset_pin" => {
                    let _ = core.request_action(Command::ResetHiddenPin).await;
                }
                "sync_hidden" => {
                    core.request_unit(Command::SyncHiddenConversations).await;
                }
                "apply_server_hidden" => {
                    let pin = str_arg(args, "pin");
                    let thread_ids = str_vec_arg(args, "thread_ids");
                    core.request_unit(Command::ApplyServerHiddenConversations { pin, thread_ids })
                        .await;
                }
                "hidden_search" => {
                    let query = str_arg(args, "query");
                    let _ = core.request_hidden_search(query).await;
                }
                "unlock_from_pin_search" => {
                    let id = str_arg(args, "id");
                    let _ = core.request_bool(Command::UnlockFromPinSearch { id }).await;
                }
                "relock_hidden" => {
                    core.request_unit(Command::RelockHidden).await;
                }
                "handle_conversation_actions" => {
                    let state = args
                        .get("state")
                        .and_then(Value::as_object)
                        .cloned()
                        .unwrap_or_default();
                    core.request_unit(Command::HandleConversationActions { state })
                        .await;
                }
                "handle_conversation_extras" => {
                    let _ = tokio::time::timeout(Duration::from_secs(5), core.wait_idle()).await;
                    let state = args
                        .get("state")
                        .and_then(Value::as_object)
                        .cloned()
                        .unwrap_or_default();
                    core.request_unit(Command::HandleConversationExtras { state })
                        .await;
                }
                "label_create" => {
                    let name = str_arg(args, "name");
                    let color_hex = args
                        .get("color_hex")
                        .and_then(Value::as_str)
                        .unwrap_or("#0068FF")
                        .to_owned();
                    let conversation_ids = str_vec_arg(args, "conversation_ids");
                    let ms = now_ms.unwrap_or(1_700_000_000_000);
                    let r4 = rand4.clone().unwrap_or_else(|| "0000".to_owned());
                    core.request_unit(Command::CreateConversationLabel {
                        name,
                        color_hex,
                        conversation_ids,
                        now_ms: ms,
                        rand4: r4,
                    })
                    .await;
                }
                "label_update" => {
                    let id = str_arg(args, "id");
                    let name = str_arg(args, "name");
                    let color_hex = args
                        .get("color_hex")
                        .and_then(Value::as_str)
                        .unwrap_or("#0068FF")
                        .to_owned();
                    core.request_unit(Command::UpdateConversationLabel {
                        id,
                        name,
                        color_hex,
                    })
                    .await;
                }
                "label_delete" => {
                    let id = str_arg(args, "id");
                    core.request_unit(Command::DeleteConversationLabel { id })
                        .await;
                }
                "label_assign" => {
                    let conversation_id = str_arg(args, "conversation_id");
                    let label_id = args
                        .get("label_id")
                        .and_then(Value::as_str)
                        .map(str::to_owned);
                    core.request_unit(Command::SetConversationLabel {
                        conversation_id,
                        label_id,
                    })
                    .await;
                }
                "label_reorder" => {
                    let ids = str_vec_arg(args, "ids");
                    core.request_unit(Command::ReorderConversationLabels { ids })
                        .await;
                }
                "set_filter" => {
                    let filter_type = args
                        .get("type")
                        .and_then(Value::as_i64)
                        .and_then(|v| i32::try_from(v).ok())
                        .unwrap_or(0);
                    let label_ids = str_vec_arg(args, "label_ids");
                    core.request_unit(Command::SetConversationFilter {
                        filter_type,
                        label_ids,
                    })
                    .await;
                }
                "sync_labels" => {
                    core.request_unit(Command::SyncConversationLabels).await;
                }
                // U5 send domain commands
                "send_text" => {
                    let id = str_arg(args, "id");
                    let text_arg = str_arg(args, "text");
                    let quote_id = args
                        .get("quote_id")
                        .and_then(Value::as_str)
                        .filter(|s| !s.is_empty())
                        .map(str::to_owned);
                    let mentions: Vec<Mention> = args
                        .get("mentions")
                        .and_then(Value::as_array)
                        .map(|arr| {
                            arr.iter()
                                .map(|m| Mention {
                                    uid: m
                                        .get("uid")
                                        .and_then(Value::as_str)
                                        .unwrap_or_default()
                                        .to_owned(),
                                    pos: m.get("pos").and_then(Value::as_i64).unwrap_or(0),
                                    len: m.get("len").and_then(Value::as_i64).unwrap_or(0),
                                    is_all: m
                                        .get("is_all")
                                        .and_then(Value::as_bool)
                                        .unwrap_or(false),
                                })
                                .collect()
                        })
                        .unwrap_or_default();
                    let styles: Vec<TextStyle> = args
                        .get("styles")
                        .and_then(Value::as_array)
                        .map(|arr| {
                            arr.iter()
                                .map(|st| TextStyle {
                                    start: st.get("start").and_then(Value::as_i64).unwrap_or(0),
                                    len: st.get("len").and_then(Value::as_i64).unwrap_or(0),
                                    st: st
                                        .get("st")
                                        .and_then(Value::as_str)
                                        .unwrap_or_default()
                                        .to_owned(),
                                })
                                .collect()
                        })
                        .unwrap_or_default();
                    let urgency = args.get("urgency").and_then(Value::as_i64).unwrap_or(0);
                    let is_async = args.get("async").and_then(Value::as_bool).unwrap_or(false);
                    let ts_ms = now_ms.unwrap_or(1_700_000_000_000);
                    let client_id = if !text_arg.trim().is_empty() && !id.is_empty() {
                        client.next_client_id()
                    } else {
                        0
                    };
                    let send_cmd = Command::SendText {
                        conv_id: id,
                        text: text_arg,
                        quote_id,
                        mentions,
                        styles,
                        urgency,
                        client_id,
                        now_ms: ts_ms,
                        is_e2ee: None,
                        ttl_ms: None,
                    };
                    if is_async {
                        let target_held = transport.held_arrived_count() + 1;
                        let core_bg = Arc::clone(&core);
                        pending_send_task =
                            Some(tokio::spawn(
                                async move { core_bg.request_bool(send_cmd).await },
                            ));
                        let _ = core.settle().await;
                        let _ = tokio::time::timeout(
                            Duration::from_millis(200),
                            transport.wait_for_held_arrival(target_held),
                        )
                        .await;
                    } else {
                        let ok = core.request_bool(send_cmd).await;
                        last_send_result = Some(ok);
                    }
                }
                "await_send" => {
                    if let Some(handle) = pending_send_task.take() {
                        let ok = handle
                            .await
                            .map_err(|e| format!("await_send join error: {e}"))?;
                        last_send_result = Some(ok);
                    }
                }
                "notify_typing" => {
                    let id = str_arg(args, "id");
                    let ts_ms = now_ms.unwrap_or(1_700_000_000_000);
                    core.request_unit(Command::NotifyTyping {
                        conv_id: id,
                        now_ms: ts_ms,
                    })
                    .await;
                    if pending_send_task.is_none() {
                        let _ =
                            tokio::time::timeout(Duration::from_secs(5), core.wait_idle()).await;
                    }
                }
                "handle_typing" => {
                    let state_map = args
                        .get("state")
                        .and_then(Value::as_object)
                        .cloned()
                        .unwrap_or_default();
                    core.request_unit(Command::HandleTyping { state: state_map })
                        .await;
                }
                "set_pref" => {
                    let key = str_arg(args, "key");
                    if key == "olaz.sendTyping" {
                        let enabled = args.get("value").and_then(Value::as_bool).unwrap_or(true);
                        core.request_unit(Command::SetSendTypingEnabled { enabled })
                            .await;
                    }
                }
                "clear_client_auth" => {
                    client.with_session(|s| {
                        s.zpw_sek = None;
                        s.secret_key = None;
                        s.account = None;
                    });
                }
                "await_typing_expiry" => {
                    let id = str_arg(args, "id");
                    let dur = Duration::from_millis(timeout_ms.unwrap_or(15_000));
                    let wait_fut = async {
                        loop {
                            if core
                                .full_snapshot()
                                .await
                                .is_none_or(|snap| !snap.typing.contains_key(&id))
                            {
                                break;
                            }
                            tokio::time::sleep(Duration::from_millis(50)).await;
                        }
                    };
                    tokio::time::timeout(dur, wait_fut)
                        .await
                        .map_err(|_| format!("timed out awaiting typing expiry for `{id}`"))?;
                }
                "request_forward" => {
                    let conv_id = str_arg(args, "conv_id");
                    let msg_id = str_arg(args, "msg_id");
                    let msg = core
                        .full_snapshot()
                        .await
                        .and_then(|s| {
                            s.messages
                                .windows
                                .get(&conv_id)?
                                .iter()
                                .find(|m| m.id == msg_id)
                                .cloned()
                        })
                        .ok_or_else(|| {
                            format!("request_forward missing msg {msg_id} in {conv_id}")
                        })?;
                    core.request_unit(Command::RequestForward {
                        message: Box::new(msg),
                    })
                    .await;
                    let _ = tokio::time::timeout(Duration::from_secs(5), core.wait_idle()).await;
                }
                "select" => {
                    let conv_id = str_arg(args, "conv_id");
                    let ids = str_vec_arg(args, "ids");
                    if ids.is_empty() {
                        selection = None;
                    } else {
                        let list = core
                            .full_snapshot()
                            .await
                            .and_then(|s| s.messages.windows.get(&conv_id).cloned())
                            .unwrap_or_default();
                        let first_msg =
                            list.iter()
                                .find(|m| m.id == ids[0])
                                .cloned()
                                .ok_or_else(|| {
                                    format!("select missing first msg {} in {conv_id}", ids[0])
                                })?;
                        let mut sel = TestSelection {
                            conv_id: first_msg.conversation_id.clone(),
                            ids: Vec::new(),
                            anchor: None,
                        };
                        if is_selectable_msg(&first_msg) {
                            sel.ids.push(first_msg.id.clone());
                            sel.anchor = Some(first_msg.id.clone());
                        }
                        for toggle_id in ids.iter().skip(1) {
                            let Some(target) = list.iter().find(|m| &m.id == toggle_id) else {
                                continue;
                            };
                            if !is_selectable_msg(target) {
                                continue;
                            }
                            if let Some(pos) = sel.ids.iter().position(|x| x == toggle_id) {
                                sel.ids.remove(pos);
                                sel.anchor = Some(toggle_id.clone());
                            } else if sel.ids.len() < 100 {
                                sel.ids.push(toggle_id.clone());
                                sel.anchor = Some(toggle_id.clone());
                            }
                        }
                        selection = Some(sel);
                    }
                }
                "forward_selection" => {
                    let selected: Vec<ChatMessage> = if let Some(sel) = selection.as_ref() {
                        let id_set: std::collections::HashSet<&str> =
                            sel.ids.iter().map(String::as_str).collect();
                        core.full_snapshot()
                            .await
                            .and_then(|s| s.messages.windows.get(&sel.conv_id).cloned())
                            .unwrap_or_default()
                            .into_iter()
                            .filter(|m| id_set.contains(m.id.as_str()))
                            .collect()
                    } else {
                        Vec::new()
                    };
                    core.request_unit(Command::ForwardSelection { messages: selected })
                        .await;
                    let _ = tokio::time::timeout(Duration::from_secs(5), core.wait_idle()).await;
                }
                "forward" => {
                    let conv_id = str_arg(args, "conv_id");
                    let msg_id = str_arg(args, "msg_id");
                    let targets = str_vec_arg(args, "targets");
                    let ts_ms = now_ms.unwrap_or(1_700_000_000_000);
                    let msg = core
                        .full_snapshot()
                        .await
                        .and_then(|s| {
                            s.messages
                                .windows
                                .get(&conv_id)?
                                .iter()
                                .find(|m| m.id == msg_id)
                                .cloned()
                        })
                        .ok_or_else(|| format!("forward missing msg {msg_id} in {conv_id}"))?;
                    let outcome = core
                        .request_forward_outcome(Command::Forward {
                            message: Box::new(msg),
                            targets,
                            now_ms: ts_ms,
                        })
                        .await;
                    let _ = tokio::time::timeout(Duration::from_secs(5), core.wait_idle()).await;
                    forward_results
                        .insert(step_idx.to_string(), encode_forward_outcome_json(&outcome));
                }
                "forward_all" => {
                    let targets = str_vec_arg(args, "targets");
                    let ts_ms = now_ms.unwrap_or(1_700_000_000_000);
                    // Drain any earlier mirror changes so clear_selection reflects this op.
                    while let Ok(Some(_)) =
                        tokio::time::timeout(Duration::ZERO, core.next_changes()).await
                    {
                    }
                    let outcome = core
                        .request_forward_outcome(Command::ForwardAll {
                            targets,
                            now_ms: ts_ms,
                        })
                        .await;
                    let _ = tokio::time::timeout(Duration::from_secs(5), core.wait_idle()).await;
                    while let Ok(Some(batch)) =
                        tokio::time::timeout(Duration::ZERO, core.next_changes()).await
                    {
                        if batch.clear_selection {
                            selection = None;
                        }
                    }
                    forward_results
                        .insert(step_idx.to_string(), encode_forward_outcome_json(&outcome));
                }
                other => return Err(format!("unknown step cmd: {other}")),
            },
            Step::Await {
                predicate,
                timeout_ms,
            } => {
                if case.domain == "session" {
                    let wait_fut = core.wait_until(|snap| predicate.matches(snap));
                    let _ = tokio::time::timeout(Duration::from_secs(3600), wait_fut).await;
                } else {
                    let dur = Duration::from_millis(timeout_ms.unwrap_or(10_000));
                    let wait_fut = core.wait_for_predicate(|snap| predicate.matches(snap));
                    let _ = tokio::time::timeout(dur, wait_fut).await;
                }
            }
            Step::AwaitHost {
                await_host,
                timeout_ms,
            } => {
                let dur = Duration::from_millis(timeout_ms.unwrap_or(15_000));
                tokio::time::timeout(dur, host.await_call(await_host, &mut host_cursor))
                    .await
                    .map_err(|_| format!("timed out awaiting host call `{await_host}`"))?;
                if is_u3 && (await_host == "apply_parsed_events" || await_host == "apply_batch") {
                    if pending_send_task.is_some() {
                        inner_runner.flush_host().await;
                        let _ = core.settle().await;
                        inner_runner.flush_store().await;
                        let _ = core.settle().await;
                    } else {
                        let _ =
                            tokio::time::timeout(Duration::from_secs(5), core.wait_idle()).await;
                    }
                }
            }
            Step::WsPush { ws_push } => {
                ws_driver.push(*ws_push);
            }
            Step::HttpRelease { http_release } => {
                transport.release_http(*http_release);
            }
            Step::Snapshot { snapshot } => {
                if is_u3 {
                    if pending_send_task.is_some() {
                        inner_runner.flush_host().await;
                        let _ = core.settle().await;
                        inner_runner.flush_store().await;
                        let _ = core.settle().await;
                    } else {
                        let _ =
                            tokio::time::timeout(Duration::from_secs(5), core.wait_idle()).await;
                    }
                }
                let fwd_ctx = ForwardSnapCtx {
                    is_u8,
                    auto_delete_seeded,
                    last_send_result,
                    selection: selection.as_ref(),
                    results: &forward_results,
                };
                if let Some(snap) =
                    capture_case_snapshot(&core, &host, is_u3, is_u4, is_u5, &send_logs, &fwd_ctx)
                        .await
                {
                    snapshots.insert(snapshot.clone(), snap);
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

    if let Some(handle) = pending_send_task.take() {
        let ok = handle
            .await
            .map_err(|e| format!("trailing send task join error: {e}"))?;
        last_send_result = Some(ok);
    }
    let fwd_ctx = ForwardSnapCtx {
        is_u8,
        auto_delete_seeded,
        last_send_result,
        selection: selection.as_ref(),
        results: &forward_results,
    };
    let final_state =
        capture_case_snapshot(&core, &host, is_u3, is_u4, is_u5, &send_logs, &fwd_ctx)
            .await
            .ok_or_else(|| "actor stopped before final snapshot".to_owned())?;
    core.stop();

    Ok(CaseRunResult {
        snapshots,
        final_state,
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
