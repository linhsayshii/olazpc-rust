//! Socket-free session state machine: everything `handleBinaryFrame` and the
//! request helpers do, expressed as "bytes in -> outcome out".

use std::collections::BTreeMap;

use serde_json::{Map, Value};

use crate::consts::*;
use crate::event::WsEvent;
use crate::files::{FileWait, FileWaiters, FileWake, WaiterToken, extract_file_done_events};
use crate::frame::{
    Frame, decode_frame, encode_frame_json, encode_request_frame, get_msg_frame, ping_frame,
    pull_frame, pull_next_frame,
};
use crate::json::{base64_decode, int64_of, parse_object, string_of};
use crate::queue::{QueueCursors, WsQueueCursorSnapshot, queues_from_auth};
use crate::requests::RequestWaiters;

/// Failure reported by a [`FrameDecryptor`] (bad key, bad ciphertext, inflate error...).
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
#[error("ws frame decrypt failed: {0}")]
pub struct DecryptError(pub String);

/// Hook for `ZaloCrypto.decryptWSFrame` (implemented in `olaz-crypto`, plugged in by the
/// transport). `encrypt`: 0 plain, 1 AES-GCM, 2/3 AES-GCM + inflate; `data_field` is the
/// envelope `data` string (empty when absent).
pub trait FrameDecryptor {
    fn decrypt_ws_frame(
        &self,
        cipher_key: Option<&[u8]>,
        encrypt: u8,
        data_field: &str,
    ) -> Result<Vec<u8>, DecryptError>;
}

impl<F> FrameDecryptor for F
where
    F: Fn(Option<&[u8]>, u8, &str) -> Result<Vec<u8>, DecryptError>,
{
    fn decrypt_ws_frame(
        &self,
        cipher_key: Option<&[u8]>,
        encrypt: u8,
        data_field: &str,
    ) -> Result<Vec<u8>, DecryptError> {
        self(cipher_key, encrypt, data_field)
    }
}

/// Close the socket (Swift: `cancel(with: .policyViolation)` = close code 1008).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CloseRequest {
    PolicyViolation,
}

/// A reply matched to a pending request.
#[derive(Debug, Clone, PartialEq)]
pub struct ResolvedRequest {
    pub req_id: String,
    pub token: WaiterToken,
    pub payload: Map<String, Value>,
}

/// Everything the transport must do after one inbound frame, in order:
/// resolve waiters, send `sends`, forward `event`, persist `cursors_changed`, close.
#[derive(Debug, Default, PartialEq)]
pub struct FrameOutcome {
    pub event: Option<WsEvent>,
    pub sends: Vec<Vec<u8>>,
    pub resolved_request: Option<ResolvedRequest>,
    pub file_wakes: Vec<FileWake>,
    pub cursors_changed: Option<BTreeMap<String, WsQueueCursorSnapshot>>,
    pub close: Option<CloseRequest>,
    /// Shape-only log lines (no tokens or bodies), as written by Swift's `EngineLog`.
    pub log: Vec<String>,
}

/// A request frame ready to send plus its registered waiter.
#[derive(Debug, Clone, PartialEq)]
pub struct PreparedRequest {
    pub req_id: String,
    pub frame: Vec<u8>,
    pub token: WaiterToken,
    /// Waiter previously registered under the same reqId (resolve with `None`).
    pub replaced: Option<WaiterToken>,
}

/// Per-connection engine state (`authed`, `cipherKey`, `reqCounter`, cursors, waiters).
#[derive(Debug)]
pub struct WsCore {
    cipher_key: Option<Vec<u8>>,
    authed: bool,
    req_counter: u64,
    next_token: WaiterToken,
    pub cursors: QueueCursors,
    pub requests: RequestWaiters,
    pub files: FileWaiters,
}

impl Default for WsCore {
    fn default() -> Self {
        Self::new()
    }
}

impl WsCore {
    pub fn new() -> Self {
        Self {
            cipher_key: None,
            authed: false,
            req_counter: 1,
            next_token: 1,
            cursors: QueueCursors::default(),
            requests: RequestWaiters::default(),
            files: FileWaiters::default(),
        }
    }

    pub fn is_authed(&self) -> bool {
        self.authed
    }

    pub fn cipher_key(&self) -> Option<&[u8]> {
        self.cipher_key.as_deref()
    }

    /// `nextReqId`: `req_1`, `req_2`, ... (counter survives reconnects).
    pub fn next_req_id(&mut self) -> String {
        let id = format!("req_{}", self.req_counter);
        self.req_counter += 1;
        id
    }

    pub fn new_token(&mut self) -> WaiterToken {
        let t = self.next_token;
        self.next_token += 1;
        t
    }

    /// Start of `runSingleSession`: fresh key, unauthenticated.
    pub fn on_connect(&mut self) {
        self.cipher_key = None;
        self.authed = false;
    }

    /// End of a session: clears `authed`, fails pending requests (resolve with `None`).
    pub fn on_disconnect(&mut self) -> Vec<(String, WaiterToken)> {
        self.authed = false;
        self.requests.fail_all()
    }

    /// `stop`: wipes key/auth/waiters, optionally cursors. Returns request and file
    /// waiters to resolve with `None`.
    pub fn stop(&mut self, reset_cursors: bool) -> (Vec<WaiterToken>, Vec<WaiterToken>) {
        self.cipher_key = None;
        self.authed = false;
        let files = self.files.clear();
        let reqs = self
            .requests
            .fail_all()
            .into_iter()
            .map(|(_, t)| t)
            .collect();
        if reset_cursors {
            self.cursors.clear();
        }
        (reqs, files)
    }

    /// `sendFrame`: None unless authenticated.
    pub fn frame_if_authed(
        &self,
        cmd: u16,
        sub_cmd: u8,
        version: u8,
        data: Option<&Map<String, Value>>,
    ) -> Option<Vec<u8>> {
        self.authed
            .then(|| encode_frame_json(cmd, sub_cmd, version, data))
    }

    /// `sendRequestFrame` (send side): None unless authenticated; otherwise registers the
    /// waiter and returns the frame. The transport sends it, then calls
    /// `requests.finish(req_id)` on timeout (`REQUEST_TIMEOUT_SECS`) or send failure.
    pub fn prepare_request(
        &mut self,
        cmd: u16,
        sub_cmd: u8,
        version: u8,
        explicit_req_id: Option<&str>,
        inner_data: &Map<String, Value>,
    ) -> Option<PreparedRequest> {
        if !self.authed {
            return None;
        }
        let req_id = match explicit_req_id {
            Some(r) => r.to_owned(),
            None => self.next_req_id(),
        };
        let frame = encode_request_frame(cmd, sub_cmd, version, &req_id, inner_data);
        let token = self.new_token();
        let replaced = self.requests.register(&req_id, token);
        Some(PreparedRequest {
            req_id,
            frame,
            token,
            replaced,
        })
    }

    /// `waitForFileDone` (register side); the transport arms a `FILE_WAIT_TIMEOUT_SECS` timer.
    pub fn wait_for_file_done(&mut self, file_id: &str) -> FileWait {
        let token = self.new_token();
        self.files.wait(file_id, token)
    }

    /// `sendPing`: None unless authenticated. Send every `PING_INTERVAL_SECS`.
    pub fn ping_frame_if_authed(&self, now_ms: i64) -> Option<Vec<u8>> {
        self.authed.then(|| ping_frame(now_ms))
    }

    /// `handleBinaryFrame`. Undecodable frames are ignored (empty outcome).
    pub fn handle_binary_frame(
        &mut self,
        data: &[u8],
        decryptor: &dyn FrameDecryptor,
    ) -> FrameOutcome {
        let mut out = FrameOutcome::default();
        let Ok(frame) = decode_frame(data) else {
            return out;
        };
        let encrypt = frame.encrypt();

        if frame.cmd == CMD_AUTHEN {
            self.handle_auth(&frame, encrypt, decryptor, &mut out);
            return out;
        }

        let payload: Map<String, Value> = if encrypt == 0 {
            // Plain frames can carry `data` as a JSON string (cmd 602 typing): official `decodeEventData`
            // returns `JSON.parse(data)` for encrypt 0.
            frame
                .data_field()
                .and_then(|raw| parse_object(raw.as_bytes()))
                .unwrap_or_else(|| frame.envelope.clone())
        } else {
            frame
                .data_field()
                .and_then(|raw| {
                    decryptor
                        .decrypt_ws_frame(self.cipher_key.as_deref(), encrypt, raw)
                        .ok()
                })
                .and_then(|plain| parse_object(&plain))
                .unwrap_or_else(|| frame.envelope.clone())
        };

        let payload_data = payload.get("data").and_then(Value::as_object);

        // requestAsyncV2 reply: data.reqId ?? reqId ?? envelope.reqId
        let reply_req_id = string_of(
            payload_data
                .and_then(|d| d.get("reqId"))
                .or_else(|| payload.get("reqId"))
                .or_else(|| frame.envelope.get("reqId")),
        );
        if !reply_req_id.is_empty()
            && let Some(token) = self.requests.finish(&reply_req_id)
        {
            out.resolved_request = Some(ResolvedRequest {
                req_id: reply_req_id,
                token,
                payload: payload.clone(),
            });
        }

        for done in extract_file_done_events(&payload) {
            let waiters = self.files.record(&done.file_id, &done.url);
            if !waiters.is_empty() {
                out.file_wakes.push(FileWake {
                    file_id: done.file_id,
                    url: done.url,
                    waiters,
                });
            }
        }

        if frame.cmd == CMD_HAS_MSG
            && let Some(d) = payload_data
            && let (Some(qid), Some(ids)) = (d.get("queueId"), d.get("ids"))
        {
            let req_id = self.next_req_id();
            out.sends.push(get_msg_frame(qid, ids, &req_id));
        }

        if let Some(d) = payload_data {
            let update = self.cursors.apply_payload(frame.cmd, frame.sub_cmd, d);
            out.cursors_changed = update.changed;
            if let Some((last_id, pre_ids)) = update.next_pull {
                let req_id = self.next_req_id();
                out.sends.push(pull_next_frame(
                    frame.cmd,
                    frame.sub_cmd,
                    &req_id,
                    &last_id,
                    &pre_ids,
                ));
            }
        }

        out.event = Some(WsEvent {
            cmd: frame.cmd,
            sub_cmd: frame.sub_cmd,
            version: frame.version,
            payload,
        });
        out
    }

    fn handle_auth(
        &mut self,
        frame: &Frame,
        encrypt: u8,
        decryptor: &dyn FrameDecryptor,
        out: &mut FrameOutcome,
    ) {
        if let Some(key_b64) = frame.key_field() {
            // `Data(base64Encoded:)` -> nil on malformed input (clears the key).
            self.cipher_key = base64_decode(key_b64);
        }
        let raw = frame.data_field().unwrap_or("");
        let auth = decryptor
            .decrypt_ws_frame(self.cipher_key.as_deref(), encrypt, raw)
            .ok()
            .and_then(|plain| parse_object(&plain));
        let Some(auth) = auth else {
            out.log.push("ws: auth decrypt failed".into());
            out.close = Some(CloseRequest::PolicyViolation);
            return;
        };
        let code = int64_of(auth.get("error_code")).unwrap_or(-1);
        let event = |payload: Map<String, Value>| WsEvent {
            cmd: frame.cmd,
            sub_cmd: frame.sub_cmd,
            version: frame.version,
            payload,
        };
        if code != 0 {
            out.log.push(format!("ws: auth rejected error_code={code}"));
            out.event = Some(event(auth));
            out.close = Some(CloseRequest::PolicyViolation);
            return;
        }
        self.authed = true;
        let queues = queues_from_auth(&auth);
        out.log.push(format!("ws: authed queues={}", queues.len()));
        out.event = Some(event(auth));
        for q in queues {
            let (last_id, pre_ids) = self.cursors.initial_pull_args(q);
            let req_id = self.next_req_id();
            out.sends
                .push(pull_frame(q.cmd, q.sub_cmd, &req_id, &last_id, &pre_ids));
        }
    }
}
