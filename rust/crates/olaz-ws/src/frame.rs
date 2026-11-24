//! Binary frame codec: `u8 version | u16 LE cmd | u8 subCmd | UTF-8 JSON body`.

use serde_json::{Map, Value};

use crate::json::{int64_of, parse_object, to_swift_json_bytes};

pub const HEADER_LEN: usize = 4;

#[derive(Debug, Clone, PartialEq, thiserror::Error)]
pub enum FrameError {
    #[error("frame shorter than {HEADER_LEN}-byte header")]
    TooShort,
    #[error("frame body is not a JSON object")]
    BadBody,
}

/// A decoded inbound frame (`decodeFrame`).
#[derive(Debug, Clone, PartialEq)]
pub struct Frame {
    pub version: u8,
    pub cmd: u16,
    pub sub_cmd: u8,
    pub envelope: Map<String, Value>,
}

impl Frame {
    /// `encrypt` field: `UInt8(clamping: max(0, int64 ?? 0))`.
    pub fn encrypt(&self) -> u8 {
        let n = int64_of(self.envelope.get("encrypt"))
            .unwrap_or(0)
            .clamp(0, 255);
        n as u8
    }

    /// `data` field when it is a string (ciphertext), else None.
    pub fn data_field(&self) -> Option<&str> {
        self.envelope.get("data").and_then(Value::as_str)
    }

    /// `key` field when it is a non-empty string (base64 cipher key on AUTHEN).
    pub fn key_field(&self) -> Option<&str> {
        self.envelope
            .get("key")
            .and_then(Value::as_str)
            .filter(|s| !s.is_empty())
    }
}

/// `encodeFrame(payloadJSON:)`: header + payload (an empty payload adds nothing).
pub fn encode_frame(cmd: u16, sub_cmd: u8, version: u8, payload_json: Option<&[u8]>) -> Vec<u8> {
    let mut out = Vec::with_capacity(HEADER_LEN + payload_json.map_or(0, <[u8]>::len));
    out.push(version);
    out.extend_from_slice(&cmd.to_le_bytes());
    out.push(sub_cmd);
    if let Some(p) = payload_json {
        out.extend_from_slice(p);
    }
    out
}

/// `encodeFrame(data:)`: `None` gives a header-only frame, `Some(map)` the JSON body.
pub fn encode_frame_json(
    cmd: u16,
    sub_cmd: u8,
    version: u8,
    data: Option<&Map<String, Value>>,
) -> Vec<u8> {
    match data {
        Some(m) => {
            let body = to_swift_json_bytes(&Value::Object(m.clone()));
            encode_frame(cmd, sub_cmd, version, Some(&body))
        }
        None => encode_frame(cmd, sub_cmd, version, None),
    }
}

/// `encodeRequestFrame`: body `{"data": inner, "reqId": req_id}`.
pub fn encode_request_frame(
    cmd: u16,
    sub_cmd: u8,
    version: u8,
    req_id: &str,
    inner_data: &Map<String, Value>,
) -> Vec<u8> {
    let mut body = Map::new();
    body.insert("data".into(), Value::Object(inner_data.clone()));
    body.insert("reqId".into(), Value::String(req_id.to_owned()));
    encode_frame_json(cmd, sub_cmd, version, Some(&body))
}

/// `decodeFrame`: header-only frame gives an empty envelope.
pub fn decode_frame(data: &[u8]) -> Result<Frame, FrameError> {
    if data.len() < HEADER_LEN {
        return Err(FrameError::TooShort);
    }
    let cmd = u16::from(data[1]) | (u16::from(data[2]) << 8);
    let body = &data[HEADER_LEN..];
    let envelope = if body.is_empty() {
        Map::new()
    } else {
        parse_object(body).ok_or(FrameError::BadBody)?
    };
    Ok(Frame {
        version: data[0],
        cmd,
        sub_cmd: data[3],
        envelope,
    })
}

/// `pullFrame`: first-pull flag is `int64(lastId) == 1`.
pub fn pull_frame(
    cmd: u16,
    sub_cmd: u8,
    req_id: &str,
    last_id: &Value,
    pre_ids: &Value,
) -> Vec<u8> {
    let first = int64_of(Some(last_id)) == Some(1);
    pull_body(cmd, sub_cmd, req_id, first, last_id, pre_ids)
}

/// `pullNextFrame`: `first` is always false.
pub fn pull_next_frame(
    cmd: u16,
    sub_cmd: u8,
    req_id: &str,
    last_id: &Value,
    pre_ids: &Value,
) -> Vec<u8> {
    pull_body(cmd, sub_cmd, req_id, false, last_id, pre_ids)
}

fn pull_body(
    cmd: u16,
    sub_cmd: u8,
    req_id: &str,
    first: bool,
    last_id: &Value,
    pre_ids: &Value,
) -> Vec<u8> {
    let mut m = Map::new();
    m.insert("first".into(), Value::Bool(first));
    m.insert("reqId".into(), Value::String(req_id.to_owned()));
    m.insert("lastId".into(), last_id.clone());
    m.insert("preIds".into(), pre_ids.clone());
    encode_frame_json(cmd, sub_cmd, crate::consts::FRAME_VERSION, Some(&m))
}

/// Keep-alive ping (`sendPing`): cmd 2, sub 1, `{"eventId": nowMs}`.
pub fn ping_frame(now_ms: i64) -> Vec<u8> {
    let mut m = Map::new();
    m.insert("eventId".into(), Value::from(now_ms));
    encode_frame_json(
        crate::consts::CMD_PING,
        crate::consts::SUB_KEEP_CONNECTION,
        crate::consts::FRAME_VERSION,
        Some(&m),
    )
}

/// `GET_MSG` (570) follow-up to a `HAS_MSG` (533) push.
pub fn get_msg_frame(queue_id: &Value, ids: &Value, req_id: &str) -> Vec<u8> {
    let mut m = Map::new();
    m.insert("queueId".into(), queue_id.clone());
    m.insert("ids".into(), ids.clone());
    m.insert("lastId".into(), Value::String("1".into()));
    m.insert("reqId".into(), Value::String(req_id.to_owned()));
    encode_frame_json(
        crate::consts::CMD_GET_MSG,
        0,
        crate::consts::FRAME_VERSION,
        Some(&m),
    )
}
