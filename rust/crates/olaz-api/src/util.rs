use olaz_wire::{clean_group_id, is_group_id, strip_user_prefix};
use serde_json::{Map, Value};

/// `(isGroup, cleanId)` as every Swift call derives them from a conversation id.
pub(crate) fn conv_target(conv_id: &str) -> (bool, String) {
    let is_group = is_group_id(conv_id);
    let clean = if is_group {
        clean_group_id(conv_id)
    } else {
        strip_user_prefix(conv_id)
    };
    (is_group, clean)
}

/// `JSONSerialization.data(withJSONObject:)` as a string: `/` escaped, keys sorted (ADR-009).
pub(crate) fn swift_json(v: &Value) -> String {
    olaz_json::to_swift_json_string(v)
}

/// `resp["data"] as? [String: Any] ?? [:]`.
pub(crate) fn data_object(resp: &Map<String, Value>) -> Map<String, Value> {
    resp.get("data")
        .and_then(Value::as_object)
        .cloned()
        .unwrap_or_default()
}

/// `x as? [Any]` mapped with `JSONLossless.string` and filtered non-empty.
pub(crate) fn non_empty_strings(arr: &[Value]) -> Vec<String> {
    arr.iter()
        .map(|v| olaz_json::string(Some(v)))
        .filter(|s| !s.is_empty())
        .collect()
}

/// `x as? [String]`: every element must be a string.
pub(crate) fn as_string_array(v: Option<&Value>) -> Option<Vec<String>> {
    v?.as_array()?
        .iter()
        .map(|i| i.as_str().map(str::to_owned))
        .collect()
}

/// Swift `Int64(String)`: strict base-10 parse, no trimming.
pub(crate) fn parse_i64(s: &str) -> Option<i64> {
    s.parse().ok()
}
