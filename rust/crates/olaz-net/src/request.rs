//! Pure builders for authenticated API calls (`get` / `post` / `postMultipart` URL shapes).

use std::collections::BTreeMap;

use olaz_crypto::encode_aes;
use serde_json::Value;

use crate::error::NetError;
use crate::http::{common_params, url_encode};

/// One authenticated API call (Swift `get`/`post` arguments).
#[derive(Debug, Clone, PartialEq)]
pub struct ApiRequest {
    pub service: String,
    pub path: String,
    /// Plain query params, appended after `params`, sorted by key.
    pub query: BTreeMap<String, String>,
    /// Extra headers in send order.
    pub headers: Vec<(String, String)>,
    /// JSON object encrypted into `params=` with the session `zpw_enk`.
    pub payload: Option<Value>,
    /// GET only: an already-built plaintext that is encrypted into `params=` instead.
    pub raw_encrypted: Option<String>,
    /// Decrypt the `data` field of the answer (default `true`).
    pub decrypt_response: bool,
}

impl ApiRequest {
    pub fn new(service: impl Into<String>, path: impl Into<String>) -> Self {
        Self {
            service: service.into(),
            path: path.into(),
            query: BTreeMap::new(),
            headers: Vec::new(),
            payload: None,
            raw_encrypted: None,
            decrypt_response: true,
        }
    }

    pub fn query(mut self, key: &str, value: &str) -> Self {
        self.query.insert(key.to_owned(), value.to_owned());
        self
    }

    pub fn header(mut self, key: &str, value: &str) -> Self {
        self.headers.push((key.to_owned(), value.to_owned()));
        self
    }

    pub fn payload(mut self, payload: Value) -> Self {
        self.payload = Some(payload);
        self
    }

    pub fn raw_encrypted(mut self, plaintext: impl Into<String>) -> Self {
        self.raw_encrypted = Some(plaintext.into());
        self
    }

    pub fn decrypt_response(mut self, decrypt: bool) -> Self {
        self.decrypt_response = decrypt;
        self
    }
}

/// File part of a multipart upload (Swift `postMultipart` arguments).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MultipartPart {
    pub field_name: String,
    pub file_name: String,
    pub mime_type: String,
    pub data: Vec<u8>,
}

/// A valid session key is 16 or 32 bytes.
pub fn is_valid_secret_key(key: &[u8]) -> bool {
    key.len() == 16 || key.len() == 32
}

fn require_key(key: Option<&[u8]>) -> Result<&[u8], NetError> {
    match key {
        Some(k) if is_valid_secret_key(k) => Ok(k),
        _ => Err(NetError::NotAuthenticated),
    }
}

/// Rebuilds `value` with every object's keys in ascending order.
///
/// Swift serialized payloads in random key order; the server parses JSON, so any order is
/// equal. Sorting makes the output independent of serde_json's `preserve_order` feature
/// (ADR-009) and the golden tests exact.
pub fn canonical_json(value: &Value) -> Value {
    match value {
        Value::Object(map) => {
            let mut keys: Vec<&String> = map.keys().collect();
            keys.sort();
            let mut out = serde_json::Map::new();
            for k in keys {
                if let Some(v) = map.get(k) {
                    out.insert(k.clone(), canonical_json(v));
                }
            }
            Value::Object(out)
        }
        Value::Array(items) => Value::Array(items.iter().map(canonical_json).collect()),
        other => other.clone(),
    }
}

/// Swift `encodedParams`: compact JSON -> AES-CBC(zpw_enk) -> Base64 -> [`url_encode`].
pub fn encoded_params(key: Option<&[u8]>, payload: &Value) -> Result<String, NetError> {
    let key = require_key(key)?;
    let json =
        serde_json::to_string(&canonical_json(payload)).map_err(|_| NetError::InvalidJson)?;
    Ok(url_encode(&encode_aes(key, &json)?))
}

/// Swift `encodedStringParam`.
pub fn encoded_string_param(key: Option<&[u8]>, plaintext: &str) -> Result<String, NetError> {
    let key = require_key(key)?;
    Ok(url_encode(&encode_aes(key, plaintext)?))
}

fn append_query(suffix: &mut String, query: &BTreeMap<String, String>) {
    // BTreeMap iterates in ascending key order, same as Swift `sorted(by: key <)`.
    for (k, v) in query {
        suffix.push('&');
        suffix.push_str(k);
        suffix.push('=');
        suffix.push_str(&url_encode(v));
    }
}

/// GET suffix: `path?zpw_ver=..&zpw_type=..[&params=<enc>]&k=v...` (extras sorted by key).
pub fn get_suffix(req: &ApiRequest, key: Option<&[u8]>) -> Result<String, NetError> {
    let mut suffix = format!("{}?{}", req.path, common_params());
    if let Some(payload) = &req.payload {
        suffix.push_str("&params=");
        suffix.push_str(&encoded_params(key, payload)?);
    } else if let Some(raw) = &req.raw_encrypted {
        suffix.push_str("&params=");
        suffix.push_str(&encoded_string_param(key, raw)?);
    }
    append_query(&mut suffix, &req.query);
    Ok(suffix)
}

/// POST suffix (`path?common&k=v...`) and form body `params=<enc>`.
pub fn post_suffix_and_body(
    req: &ApiRequest,
    key: Option<&[u8]>,
) -> Result<(String, Vec<u8>), NetError> {
    let mut suffix = format!("{}?{}", req.path, common_params());
    append_query(&mut suffix, &req.query);
    let payload = req.payload.as_ref().ok_or(NetError::InvalidJson)?;
    let enc = encoded_params(key, payload)?;
    Ok((suffix, format!("params={enc}").into_bytes()))
}

/// Multipart suffix: `path?common&params=<enc>&k=v...` (params before the sorted extras).
pub fn multipart_suffix(req: &ApiRequest, key: Option<&[u8]>) -> Result<String, NetError> {
    let payload = req.payload.as_ref().ok_or(NetError::InvalidJson)?;
    let enc = encoded_params(key, payload)?;
    let mut suffix = format!("{}?{}&params={enc}", req.path, common_params());
    append_query(&mut suffix, &req.query);
    Ok(suffix)
}

/// Swift multipart body: one file part, CRLF framing.
pub fn multipart_body(boundary: &str, part: &MultipartPart) -> Vec<u8> {
    let mut body = Vec::with_capacity(part.data.len() + 256);
    body.extend_from_slice(format!("--{boundary}\r\n").as_bytes());
    body.extend_from_slice(
        format!(
            "Content-Disposition: form-data; name=\"{}\"; filename=\"{}\"\r\n",
            part.field_name, part.file_name
        )
        .as_bytes(),
    );
    body.extend_from_slice(format!("Content-Type: {}\r\n\r\n", part.mime_type).as_bytes());
    body.extend_from_slice(&part.data);
    body.extend_from_slice(format!("\r\n--{boundary}--\r\n").as_bytes());
    body
}

/// Chromium's multipart boundary shape, as the official Zalo PC (Chromium 108) sends it:
/// `----WebKitFormBoundary<16 chars of [0-9A-Za-z]>`.
pub fn new_multipart_boundary() -> String {
    format!(
        "----WebKitFormBoundary{}",
        olaz_crypto::random_alphanumeric(16)
    )
}
