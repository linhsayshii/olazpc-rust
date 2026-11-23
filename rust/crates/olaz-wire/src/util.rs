//! Small helpers shared by the parsers: Foundation-flavoured casts over `serde_json::Value`.

use serde_json::{Map, Value};

/// `trimmingCharacters(in: .whitespacesAndNewlines)`.
pub fn trim(s: &str) -> &str {
    s.trim()
}

/// `firstNonEmpty(...)`: the first value that is non-blank after trimming (returned untrimmed), else "".
pub fn first_non_empty(values: &[&str]) -> String {
    for v in values {
        if !v.trim().is_empty() {
            return (*v).to_string();
        }
    }
    String::new()
}

/// First present key (an explicit JSON `null` counts as present, like Swift's `??` over `NSNull`).
pub fn pick<'a>(map: &'a Map<String, Value>, keys: &[&str]) -> Option<&'a Value> {
    keys.iter().find_map(|k| map.get(*k))
}

/// `pick` over an optional map.
pub fn pick_opt<'a>(map: Option<&'a Map<String, Value>>, keys: &[&str]) -> Option<&'a Value> {
    map.and_then(|m| pick(m, keys))
}

/// `x as? [String: Any]`.
pub fn as_dict(v: Option<&Value>) -> Option<&Map<String, Value>> {
    v.and_then(Value::as_object)
}

/// `x as? [[String: Any]]`: every element must be a dictionary (Swift's cast is all or nothing).
pub fn as_dict_array(v: Option<&Value>) -> Option<Vec<&Map<String, Value>>> {
    let arr = v?.as_array()?;
    arr.iter().map(Value::as_object).collect()
}

/// `x as? String`.
pub fn as_str(v: Option<&Value>) -> Option<&str> {
    v.and_then(Value::as_str)
}

/// `x as? Bool`: a JSON boolean, or a number that is exactly 0 or 1 (Foundation bridges those).
pub fn as_bool_cast(v: Option<&Value>) -> Option<bool> {
    match v? {
        Value::Bool(b) => Some(*b),
        Value::Number(n) => {
            let f = n.as_f64()?;
            if f == 0.0 {
                Some(false)
            } else if f == 1.0 {
                Some(true)
            } else {
                None
            }
        }
        _ => None,
    }
}

/// `(x as? NSNumber)?.doubleValue`: JSON numbers and booleans (both are `NSNumber`).
pub fn ns_double(v: Option<&Value>) -> Option<f64> {
    match v? {
        Value::Bool(b) => Some(if *b { 1.0 } else { 0.0 }),
        Value::Number(n) => n.as_f64(),
        _ => None,
    }
}

/// `(x as? NSNumber)?.boolValue`.
pub fn ns_bool(v: Option<&Value>) -> Option<bool> {
    ns_double(v).map(|d| d != 0.0)
}

/// `(x as? NSNumber)?.intValue`.
pub fn ns_int(v: Option<&Value>) -> Option<i64> {
    match v? {
        Value::Bool(b) => Some(i64::from(*b)),
        Value::Number(n) => Some(number_to_i64(n)),
        _ => None,
    }
}

/// `NSNumber.int64Value`: integers wrap, floats truncate (saturating, NaN -> 0).
pub fn number_to_i64(n: &serde_json::Number) -> i64 {
    if let Some(i) = n.as_i64() {
        i
    } else if let Some(u) = n.as_u64() {
        u as i64
    } else {
        n.as_f64().unwrap_or(0.0) as i64
    }
}

/// `clampedInt(Double)`: non-finite -> 0, otherwise clamped to +-9e15.
pub fn clamped_int(value: f64) -> i64 {
    if !value.is_finite() {
        return 0;
    }
    value.clamp(-9e15, 9e15) as i64
}

/// `Double` -> milliseconds as `i64` rounded (Date round trip).
pub fn round_i64(value: f64) -> i64 {
    if !value.is_finite() {
        return 0;
    }
    value.round() as i64
}
