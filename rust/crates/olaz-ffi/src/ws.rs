//! `zpw_ws` client (`olaz-ws` transport) as a Swift object plus a callback interface.

use std::collections::HashMap;
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use olaz_json::to_swift_json_string;
use olaz_wire::{
    NameLookup, WireParseOptions, collect_name_uids, extract_batch_events, is_plain_chat_envelope,
};
use olaz_ws::{
    CryptoDecryptor, CursorMap, WsClient, WsConfig, WsEvent, WsHandle, WsQueueCursorSnapshot,
};
use serde_json::{Map, Value};
use tokio::sync::{mpsc, watch};

use crate::error::CoreError;
use crate::runtime::{run, runtime};
use crate::wire::{NameEntry, WireEvent, convert};

/// Queue cursor of one `<cmd>_<sub>` queue (`wsQueueCursors` preference entry).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CursorEntry {
    pub queue_key: String,
    pub last_id: String,
    pub pre_ids: Vec<String>,
}

fn to_entries(map: &CursorMap) -> Vec<CursorEntry> {
    map.iter()
        .map(|(k, v)| CursorEntry {
            queue_key: k.clone(),
            last_id: v.last_id.clone(),
            pre_ids: v.pre_ids.clone(),
        })
        .collect()
}

fn to_map(entries: Vec<CursorEntry>) -> CursorMap {
    entries
        .into_iter()
        .map(|e| {
            (
                e.queue_key,
                WsQueueCursorSnapshot {
                    last_id: e.last_id,
                    pre_ids: e.pre_ids,
                },
            )
        })
        .collect()
}

/// Input of [`ws_start`].
#[derive(Debug, Clone, uniffi::Record)]
pub struct WsConfigRecord {
    /// `wss://host` bases, rotated on reconnect. Empty means the built-in defaults.
    #[uniffi(default = [])]
    pub endpoints: Vec<String>,
    /// Session key (`zpw_sek`). Sent as cookie/header only, never logged.
    pub zpw_sek: String,
    /// Cursors to resume from.
    #[uniffi(default = [])]
    pub seed_cursors: Vec<CursorEntry>,
    /// Capacity of the event channel (default 1024).
    #[uniffi(default = None)]
    pub event_capacity: Option<u32>,
    /// Signed-in uid and "My Cloud" conversation id, used to parse chat envelopes in the socket task. Swift verifies
    /// them on every delivery (`WirePayload::resolve`), so a wrong or late value only costs a re-parse.
    #[uniffi(default = None)]
    pub my_uid: Option<String>,
    #[uniffi(default = None)]
    pub self_conv_id: Option<String>,
}

/// One decoded push/pull event. `payload_json` is the decrypted body as JSON text; parse it with
/// `parse_wire_batch` / `parse_wire_event` (ids are exact there).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct WsEventRecord {
    pub cmd: u16,
    pub sub_cmd: u8,
    pub version: u8,
    pub payload_json: String,
}

impl From<&WsEvent> for WsEventRecord {
    fn from(e: &WsEvent) -> Self {
        Self {
            cmd: e.cmd,
            sub_cmd: e.sub_cmd,
            version: e.version,
            payload_json: to_swift_json_string(&Value::Object(e.payload.clone())),
        }
    }
}

/// Parse context of a session: who we are, plus the contact names Swift last confirmed (`uid -> NameLookup`).
#[derive(Default)]
pub(crate) struct ParseState {
    my_uid: String,
    self_conv_id: Option<String>,
    names: HashMap<String, NameLookup>,
}

type SharedParse = Arc<Mutex<ParseState>>;

#[cfg(test)]
pub(crate) fn test_parse_state(my_uid: &str) -> ParseState {
    ParseState {
        my_uid: my_uid.to_owned(),
        ..ParseState::default()
    }
}

fn parse_with(
    cmd: u16,
    root: &Value,
    my_uid: &str,
    self_conv_id: Option<&str>,
    names: &HashMap<String, NameLookup>,
) -> Vec<WireEvent> {
    let lookup = |uid: &str| names.get(uid).cloned();
    let opts = WireParseOptions {
        cmd,
        fallback_conv_id: None,
        is_group_hint: None,
        self_conv_id,
        name_lookup: if names.is_empty() {
            None
        } else {
            Some(&lookup)
        },
    };
    extract_batch_events(root, my_uid, &opts)
        .into_iter()
        .map(convert)
        .collect()
}

/// A plain chat envelope kept Rust-side next to its pre-parsed events. Swift hands back its current uid / names
/// ([`WirePayload::resolve`]) and gets `None` when the events already delivered are exact, or the re-parsed events.
#[derive(uniffi::Object)]
pub struct WirePayload {
    cmd: u16,
    root: Value,
    uids: Vec<String>,
    used_my_uid: String,
    used_self_conv_id: Option<String>,
    used_names: Vec<Option<NameLookup>>,
    state: SharedParse,
}

#[uniffi::export]
impl WirePayload {
    /// Sender / quote-owner uids this envelope may look names up for.
    pub fn uids(&self) -> Vec<String> {
        self.uids.clone()
    }

    /// `None` when the delivered events were parsed with exactly this context; otherwise the events parsed with it
    /// (and the session remembers `names` for the next envelope).
    pub fn resolve(
        &self,
        my_uid: String,
        self_conv_id: Option<String>,
        names: Vec<NameEntry>,
    ) -> Option<Vec<WireEvent>> {
        let wanted: HashMap<&str, &NameEntry> = names.iter().map(|n| (n.uid.as_str(), n)).collect();
        let same_names = self.uids.iter().zip(&self.used_names).all(|(uid, used)| {
            match (wanted.get(uid.as_str()), used) {
                (None, None) => true,
                (Some(w), Some(u)) => w.name == u.name && w.avatar == u.avatar,
                _ => false,
            }
        });
        if same_names && my_uid == self.used_my_uid && self_conv_id == self.used_self_conv_id {
            return None;
        }
        let mut table: HashMap<String, NameLookup> = HashMap::new();
        for n in &names {
            table.insert(
                n.uid.clone(),
                NameLookup {
                    name: n.name.clone(),
                    avatar: n.avatar.clone(),
                },
            );
        }
        let events = parse_with(
            self.cmd,
            &self.root,
            &my_uid,
            self_conv_id.as_deref(),
            &table,
        );
        let mut st = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        st.my_uid = my_uid;
        st.self_conv_id = self_conv_id;
        for uid in &self.uids {
            match table.get(uid) {
                Some(n) => {
                    st.names.insert(uid.clone(), n.clone());
                }
                None => {
                    st.names.remove(uid);
                }
            }
        }
        Some(events)
    }

    /// The decrypted body as JSON text (fallback only: parse with `parse_wire_batch`).
    pub fn json(&self) -> String {
        to_swift_json_string(&self.root)
    }
}

/// Receiver of session events, implemented in Swift.
///
/// Called from tokio's blocking pool, sequentially and in order for one session. Implementations
/// must return quickly (yield into an `AsyncStream` or `Task { @MainActor in ... }`) and must be
/// `Sendable`.
#[uniffi::export(with_foreign)]
pub trait WsListener: Send + Sync {
    /// A decoded event arrived (anything that is not a plain chat-message envelope; `payload_json` is the body).
    fn on_event(&self, event: WsEventRecord);
    /// A plain chat-message envelope (cmd 501 / 510 / 511 / 513-515 / 517 / 518 / 521) already parsed in the core.
    /// `uids` are the contact ids the parse looked names up for: Swift resolves them and calls
    /// `payload.resolve(...)` before trusting `events`.
    fn on_wire_events(
        &self,
        cmd: u16,
        sub_cmd: u8,
        version: u8,
        events: Vec<WireEvent>,
        uids: Vec<String>,
        payload: Arc<WirePayload>,
    );
    /// Queue cursors changed (persist them under the `wsQueueCursors` preference). Coalesced: only
    /// the latest snapshot is delivered when changes outpace the listener.
    fn on_cursors_changed(&self, cursors: Vec<CursorEntry>);
    /// The session ended (`stop`, or every handle dropped). Delivered last, once.
    fn on_stopped(&self);
}

/// A running socket session. Dropping the last reference (Swift `deinit`) stops it.
#[derive(uniffi::Object)]
pub struct WsSession {
    handle: WsHandle,
    state: SharedParse,
}

/// Starts a session on the shared runtime. Returns immediately; the socket connects (and
/// reconnects with backoff and endpoint failover) in the background.
#[uniffi::export]
pub fn ws_start(
    config: WsConfigRecord,
    listener: Arc<dyn WsListener>,
) -> Result<Arc<WsSession>, CoreError> {
    let rt = runtime()?;
    let _guard = rt.enter();
    let mut cfg = WsConfig::new(config.endpoints, config.zpw_sek);
    cfg.seed_cursors = to_map(config.seed_cursors);
    if let Some(cap) = config.event_capacity {
        cfg.event_capacity = usize::try_from(cap).unwrap_or(1024).max(1);
    }
    let (handle, events) = WsClient::start(cfg, Arc::new(CryptoDecryptor));
    let cursors = handle.watch_cursors();
    let state: SharedParse = Arc::new(Mutex::new(ParseState {
        my_uid: config.my_uid.unwrap_or_default(),
        self_conv_id: config.self_conv_id,
        names: HashMap::new(),
    }));
    rt.spawn(pump(events, cursors, listener, Arc::clone(&state)));
    Ok(Arc::new(WsSession { handle, state }))
}

/// Forwards events and cursor changes to the foreign listener. Each callback runs on the blocking
/// pool and is awaited before the next, which keeps order and lets a slow listener back-pressure
/// only this session.
async fn pump(
    mut events: mpsc::Receiver<WsEvent>,
    mut cursors: watch::Receiver<CursorMap>,
    listener: Arc<dyn WsListener>,
    state: SharedParse,
) {
    loop {
        tokio::select! {
            biased;
            // Deliver each frame before its cursor update, so the persisted cursor
            // never runs ahead of the applied batch.
            ev = events.recv() => {
                let Some(ev) = ev else { break };
                let l = Arc::clone(&listener);
                let st = Arc::clone(&state);
                // Parsing and the callback share one blocking-pool task: order is kept (each is awaited) and the
                // runtime workers never parse.
                let _ = tokio::task::spawn_blocking(move || deliver(ev, &l, &st)).await;
            }
            Ok(()) = cursors.changed() => {
                let entries = to_entries(&cursors.borrow_and_update());
                let l = Arc::clone(&listener);
                let _ = tokio::task::spawn_blocking(move || l.on_cursors_changed(entries)).await;
            }
        }
    }
    let l = Arc::clone(&listener);
    let _ = tokio::task::spawn_blocking(move || l.on_stopped()).await;
}

/// Parses a plain chat envelope with the session's context: the typed events, the uids to resolve and the payload handle.
/// `None` when the envelope is not plain (it takes the raw-JSON path) or yields nothing the engine would apply.
fn typed_envelope(
    cmd: u16,
    payload: Map<String, Value>,
    state: &SharedParse,
) -> Option<(Vec<WireEvent>, Vec<String>, Arc<WirePayload>)> {
    if !is_plain_chat_envelope(cmd, &payload) {
        return None;
    }
    let root = Value::Object(payload);
    let (my_uid, self_conv_id, names) = {
        let st = state.lock().unwrap_or_else(PoisonError::into_inner);
        (st.my_uid.clone(), st.self_conv_id.clone(), st.names.clone())
    };
    let events = parse_with(cmd, &root, &my_uid, self_conv_id.as_deref(), &names);
    if events.iter().all(|e| matches!(e, WireEvent::Ignore)) {
        // Nothing for the engine to apply (it returned early on an empty batch).
        return None;
    }
    let uids = collect_name_uids(&root);
    let used_names = uids.iter().map(|u| names.get(u).cloned()).collect();
    let handle = Arc::new(WirePayload {
        cmd,
        root,
        uids: uids.clone(),
        used_my_uid: my_uid,
        used_self_conv_id: self_conv_id,
        used_names,
        state: Arc::clone(state),
    });
    Some((events, uids, handle))
}

/// Typed delivery for plain chat envelopes, the raw `on_event` for everything else.
pub(crate) fn deliver(ev: WsEvent, listener: &Arc<dyn WsListener>, state: &SharedParse) {
    if !is_plain_chat_envelope(ev.cmd, &ev.payload) {
        listener.on_event(WsEventRecord::from(&ev));
        return;
    }
    let (cmd, sub_cmd, version) = (ev.cmd, ev.sub_cmd, ev.version);
    if let Some((events, uids, payload)) = typed_envelope(cmd, ev.payload, state) {
        listener.on_wire_events(cmd, sub_cmd, version, events, uids, payload);
    }
}

/// Result of [`WireParseProbe::parse`].
#[derive(uniffi::Record)]
pub struct TypedEnvelope {
    pub events: Vec<WireEvent>,
    pub uids: Vec<String>,
    pub payload: Arc<WirePayload>,
}

/// The socket task's envelope parser without a socket (benchmarks, tests): same code and the same per-session name
/// table as a live `WsSession`.
#[derive(uniffi::Object)]
pub struct WireParseProbe {
    state: SharedParse,
}

#[uniffi::export]
impl WireParseProbe {
    #[uniffi::constructor]
    pub fn new(my_uid: String, self_conv_id: Option<String>) -> Arc<Self> {
        Arc::new(Self {
            state: Arc::new(Mutex::new(ParseState {
                my_uid,
                self_conv_id,
                names: HashMap::new(),
            })),
        })
    }

    /// `payload` is the decrypted body (JSON bytes). `None` for a non-plain envelope or one with nothing to apply.
    pub fn parse(&self, payload: Vec<u8>, cmd: u16) -> Option<TypedEnvelope> {
        let map = olaz_json::parse_object(&payload)?;
        typed_envelope(cmd, map, &self.state).map(|(events, uids, payload)| TypedEnvelope {
            events,
            uids,
            payload,
        })
    }
}

fn parse_inner(json: &str) -> Result<Map<String, Value>, CoreError> {
    if json.trim().is_empty() {
        return Ok(Map::new());
    }
    olaz_json::parse_object_str(json).ok_or_else(|| CoreError::Parse {
        message: "request data is not a JSON object".to_owned(),
    })
}

#[uniffi::export]
impl WsSession {
    /// Sends a raw frame. `false` unless authenticated and the write succeeded.
    pub async fn send_frame(
        &self,
        cmd: u16,
        sub_cmd: u8,
        version: u8,
        payload_json: Option<String>,
    ) -> Result<bool, CoreError> {
        let h = self.handle.clone();
        run(async move {
            h.send_frame_versioned(cmd, sub_cmd, version, payload_json.map(String::into_bytes))
                .await
        })
        .await
    }

    /// Sends a request frame and waits for its response (default 10 s). `inner_data_json` is a
    /// JSON object (empty string for none). `None`: not authenticated, send failed, timed out,
    /// disconnected or stopped.
    pub async fn send_request(
        &self,
        cmd: u16,
        sub_cmd: u8,
        req_id: Option<String>,
        inner_data_json: String,
    ) -> Result<Option<String>, CoreError> {
        let inner = parse_inner(&inner_data_json)?;
        let h = self.handle.clone();
        let out = run(async move { h.send_request(cmd, sub_cmd, req_id, inner).await }).await?;
        Ok(out.map(|m| to_swift_json_string(&Value::Object(m))))
    }

    /// Like `send_request` with an explicit timeout in seconds.
    pub async fn send_request_with_timeout(
        &self,
        cmd: u16,
        sub_cmd: u8,
        req_id: Option<String>,
        inner_data_json: String,
        timeout_secs: f64,
    ) -> Result<Option<String>, CoreError> {
        let inner = parse_inner(&inner_data_json)?;
        let timeout = Duration::try_from_secs_f64(timeout_secs).unwrap_or(Duration::from_secs(10));
        let h = self.handle.clone();
        let out = run(async move {
            h.send_request_with_timeout(cmd, sub_cmd, req_id, inner, timeout)
                .await
        })
        .await?;
        Ok(out.map(|m| to_swift_json_string(&Value::Object(m))))
    }

    /// Waits up to `timeout_secs` for the upload `file_id` to finish; the file URL or `None`.
    pub async fn wait_for_file_done(
        &self,
        file_id: String,
        timeout_secs: f64,
    ) -> Result<Option<String>, CoreError> {
        let timeout = Duration::try_from_secs_f64(timeout_secs).unwrap_or(Duration::from_secs(12));
        let h = self.handle.clone();
        run(async move { h.wait_for_file_done_with_timeout(&file_id, timeout).await }).await
    }

    /// Updates the uid / "My Cloud" id typed envelopes are parsed with.
    pub fn set_parse_context(&self, my_uid: String, self_conv_id: Option<String>) {
        let mut st = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        st.my_uid = my_uid;
        st.self_conv_id = self_conv_id;
    }

    pub async fn seed_cursors(&self, cursors: Vec<CursorEntry>) -> Result<(), CoreError> {
        let h = self.handle.clone();
        let map = to_map(cursors);
        run(async move { h.seed_cursors(map).await }).await
    }

    pub async fn current_cursors(&self) -> Result<Vec<CursorEntry>, CoreError> {
        let h = self.handle.clone();
        let map = run(async move { h.current_cursors().await }).await?;
        Ok(to_entries(&map))
    }

    pub async fn is_authed(&self) -> Result<bool, CoreError> {
        let h = self.handle.clone();
        run(async move { h.is_authed().await }).await
    }

    /// Closes the socket and ends the session; returns the cursors left (empty after a reset).
    /// Pass them as `seed_cursors` to a later `ws_start` to resume.
    pub async fn stop(&self, reset_cursors: bool) -> Result<Vec<CursorEntry>, CoreError> {
        let h = self.handle.clone();
        let map = run(async move { h.stop(reset_cursors).await }).await?;
        Ok(to_entries(&map))
    }
}
