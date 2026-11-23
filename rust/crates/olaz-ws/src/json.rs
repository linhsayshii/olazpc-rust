//! Thin names over `olaz-json` (the single `JSONLossless` / Foundation JSON port).

use serde_json::{Map, Value};

/// `JSONLossless.string`.
pub fn string_of(v: Option<&Value>) -> String {
    olaz_json::string(v)
}

/// `JSONLossless.int64`.
pub fn int64_of(v: Option<&Value>) -> Option<i64> {
    olaz_json::int64(v)
}

/// `JSONLossless.bool`.
pub fn bool_of(v: Option<&Value>) -> Option<bool> {
    olaz_json::bool_value(v)
}

/// Swift `as? [[String: Any]]`: succeeds only when every element is an object.
pub fn object_array(v: Option<&Value>) -> Option<Vec<&Map<String, Value>>> {
    match v {
        Some(Value::Array(a)) => a.iter().map(Value::as_object).collect(),
        _ => None,
    }
}

/// `JSONLossless.parseObject`: object or nothing.
pub fn parse_object(bytes: &[u8]) -> Option<Map<String, Value>> {
    olaz_json::parse_object(bytes)
}

/// Serializes like Foundation `JSONSerialization` (compact, `/` as `\/`, keys sorted).
pub fn to_swift_json_bytes(v: &Value) -> Vec<u8> {
    olaz_json::to_swift_json_bytes(v)
}

/// Foundation `Data(base64Encoded:)`.
pub fn base64_decode(s: &str) -> Option<Vec<u8>> {
    olaz_json::decode_foundation_base64(s).ok()
}
