//! Store-side names over the shared `olaz-wire` / `olaz-json` helpers.

use serde_json::Value;

pub(crate) use olaz_wire::{
    is_group_id, is_signal_ciphertext, sanitize_profile_uid, strip_user_prefix,
    url_has_undecrypted_signal_cipher,
};

/// Swift `trimmingCharacters(in: .whitespacesAndNewlines)`.
pub(crate) fn trim_ws(s: &str) -> &str {
    crate::search_text::trim_search_query(s)
}

/// `JSONLossless.parseObject`.
pub(crate) fn lossless_parse_object(data: &[u8]) -> Option<serde_json::Map<String, Value>> {
    olaz_json::parse_object(data)
}

/// `JSONLossless.string`.
pub(crate) fn json_string(v: Option<&Value>) -> String {
    olaz_json::string(v)
}

/// `JSONLossless.int64`.
pub(crate) fn json_int64(v: &Value) -> Option<i64> {
    olaz_json::int64(Some(v))
}

/// Foundation `JSONSerialization` text (compact, `\/`, sorted keys).
pub(crate) fn to_swift_json(v: &Value) -> Option<String> {
    Some(olaz_json::to_swift_json_string(v))
}
