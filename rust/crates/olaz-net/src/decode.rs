//! Response decoding: status check, lossless JSON, encrypted `data` unwrap, `error_code` mapping.

use olaz_crypto::{decode_aes, int64, parse_any, parse_object, string};
use serde_json::{Map, Value};
use tracing::debug;

use crate::error::{NetError, ZaloSessionError};
use crate::http::RawResponse;
use crate::request::is_valid_secret_key;

fn looks_like_json(s: &str) -> bool {
    s.starts_with('{') || s.starts_with('[')
}

fn usable_key(key: Option<&[u8]>) -> Option<&[u8]> {
    key.filter(|k| is_valid_secret_key(k))
}

/// Decrypts and parses `text` (Base64 AES) into JSON.
fn decrypt_json(key: &[u8], text: &str) -> Option<Value> {
    let plain = decode_aes(key, text).ok()?;
    parse_any(plain.as_bytes())
}

/// Swift `unwrapDecryptedResponse`: turns a string `data` field into JSON.
///
/// A `data` that already looks like JSON is parsed. Otherwise it is AES-decrypted with `key`; if
/// the plaintext is an object carrying `error_code` or `data` it replaces the whole response (its
/// own string `data` unwrapped once more), else it becomes the new `data`.
pub fn unwrap_decrypted_response(
    response: &Map<String, Value>,
    key: Option<&[u8]>,
) -> Map<String, Value> {
    let mut out = response.clone();
    let Some(Value::String(data_str)) = out.get("data") else {
        return out;
    };
    let trimmed = data_str.trim().to_owned();
    if looks_like_json(&trimmed) {
        if let Some(parsed) = parse_any(trimmed.as_bytes()) {
            out.insert("data".to_owned(), parsed);
        }
        return out;
    }
    let Some(key) = usable_key(key) else {
        return out;
    };
    let Some(decoded) = decrypt_json(key, &trimmed) else {
        return out;
    };
    if let Value::Object(mut dict) = decoded.clone()
        && (dict.contains_key("error_code") || dict.contains_key("data"))
    {
        if let Some(Value::String(nested)) = dict.get("data") {
            let nested_trimmed = nested.trim().to_owned();
            let nested_json = if looks_like_json(&nested_trimmed) {
                parse_any(nested_trimmed.as_bytes())
            } else {
                None
            };
            if let Some(parsed) = nested_json {
                dict.insert("data".to_owned(), parsed);
            } else if let Some(plain) = decrypt_json(key, &nested_trimmed) {
                dict.insert("data".to_owned(), plain);
            }
        }
        return dict;
    }
    out.insert("data".to_owned(), decoded);
    out
}

/// Swift `parseAndDecryptResponse`.
pub fn parse_and_decrypt_response(
    body: &[u8],
    decrypt: bool,
    key: Option<&[u8]>,
) -> Result<Map<String, Value>, NetError> {
    let text = String::from_utf8_lossy(body);
    let trimmed = text.trim();
    if trimmed.is_empty() {
        let mut map = Map::new();
        map.insert("error_code".to_owned(), Value::from(0));
        map.insert("data".to_owned(), Value::Null);
        return Ok(map);
    }
    if let Some(parsed) = parse_object(body) {
        return Ok(if decrypt {
            unwrap_decrypted_response(&parsed, key)
        } else {
            parsed
        });
    }
    if decrypt
        && !looks_like_json(trimmed)
        && let Some(key) = usable_key(key)
        && let Ok(plain) = decode_aes(key, trimmed)
        && let Some(decoded) = parse_object(plain.as_bytes())
    {
        return Ok(unwrap_decrypted_response(&decoded, Some(key)));
    }
    Err(NetError::InvalidJson)
}

/// Swift `checkResponseError`: non-zero `error_code` becomes [`ZaloSessionError`].
pub fn check_response_error(response: &Map<String, Value>, url_path: &str) -> Result<(), NetError> {
    let Some(code) = int64(response.get("error_code")) else {
        return Ok(());
    };
    if code == 0 {
        return Ok(());
    }
    // Board pin disabled/empty codes are expected notices; Swift skips the log line only.
    let expected_board_notice = url_path.contains("/api/board/")
        && (code == 112 || code == 265 || (url_path.contains("/oneone/list") && code == -1));
    if !expected_board_notice {
        debug!(path = url_path, error_code = code, "api error_code");
    }
    Err(ZaloSessionError {
        code,
        message: string(response.get("error_message")),
        url: url_path.to_owned(),
    }
    .into())
}

fn body_prefix(body: &[u8]) -> String {
    let end = body.len().min(200);
    String::from_utf8_lossy(&body[..end]).into_owned()
}

/// Swift `requestWithFailover` per-host handling as a pure function.
///
/// 404 -> `Http{404, ""}`, other non-2xx -> `Http{status, first 200 bytes}`, 2xx -> parsed,
/// decrypted and checked for `error_code`.
pub fn decode_response(
    response: &RawResponse,
    request_path: &str,
    key: Option<&[u8]>,
    decrypt: bool,
) -> Result<Map<String, Value>, NetError> {
    if response.status == 404 {
        return Err(NetError::Http {
            status: 404,
            body: String::new(),
        });
    }
    if !(200..300).contains(&response.status) {
        return Err(NetError::Http {
            status: response.status,
            body: body_prefix(&response.body),
        });
    }
    let result = parse_and_decrypt_response(&response.body, decrypt, key)?;
    check_response_error(&result, request_path)?;
    Ok(result)
}

pub(crate) fn http_error(response: &RawResponse) -> NetError {
    NetError::Http {
        status: response.status,
        body: body_prefix(&response.body),
    }
}
