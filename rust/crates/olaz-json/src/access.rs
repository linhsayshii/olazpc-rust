//! `JSONLossless.string` / `int64` / `bool` coercions over `serde_json::Value`.
//!
//! `serde_json` runs with `arbitrary_precision`, so numbers keep their literal text. Positive
//! integer literals of 15+ digits are normally quoted by the parser; the accessors still treat
//! them like Swift did (string-like) in case a `Value` was built by other means.

use serde_json::Value;

/// Classified numeric literal.
enum Num {
    Int(i64),
    /// Positive integer literal outside `i64` (Swift: kept as a string).
    BigPositive(String),
    Float(f64),
}

fn classify(lit: &str) -> Num {
    let is_float = lit.bytes().any(|b| matches!(b, b'.' | b'e' | b'E'));
    if !is_float {
        if let Ok(i) = lit.parse::<i64>() {
            return Num::Int(i);
        }
        if !lit.starts_with('-') {
            return Num::BigPositive(lit.to_owned());
        }
    }
    Num::Float(lit.parse::<f64>().unwrap_or(0.0))
}

/// C `%.16g`, which is what Foundation `NSNumber.stringValue` prints for doubles.
fn format_g16(v: f64) -> String {
    let sign = if v.is_sign_negative() { "-" } else { "" };
    let a = v.abs();
    if a == 0.0 {
        return format!("{sign}0");
    }
    let sci = format!("{a:.15e}");
    let Some((mant, exp)) = sci.split_once('e') else {
        return sci;
    };
    let exp: i32 = exp.parse().unwrap_or(0);
    let digits: String = mant.chars().filter(|c| *c != '.').collect();
    let body = if !(-4..16).contains(&exp) {
        let d = digits.trim_end_matches('0');
        let (head, rest) = d.split_at(1);
        let mant = if rest.is_empty() {
            head.to_owned()
        } else {
            format!("{head}.{rest}")
        };
        let esign = if exp < 0 { '-' } else { '+' };
        format!("{mant}e{esign}{:02}", exp.unsigned_abs())
    } else if exp >= 0 {
        let split = usize::try_from(exp).unwrap_or(0) + 1;
        let (int, frac) = digits.split_at(split);
        let frac = frac.trim_end_matches('0');
        if frac.is_empty() {
            int.to_owned()
        } else {
            format!("{int}.{frac}")
        }
    } else {
        let zeros = "0".repeat(usize::try_from(-exp - 1).unwrap_or(0));
        let frac = format!("{zeros}{digits}");
        format!("0.{}", frac.trim_end_matches('0'))
    };
    format!("{sign}{body}")
}

/// Text of a JSON value as Swift `JSONLossless.string` produced it.
///
/// Strings pass through, bools are `"true"`/`"false"`, numbers print like `NSNumber.stringValue`
/// (integers exact, doubles `%.16g`), null/array/object/`None` are `""`.
pub fn string(value: Option<&Value>) -> String {
    match value {
        Some(Value::String(s)) => s.clone(),
        Some(Value::Bool(b)) => b.to_string(),
        Some(Value::Number(n)) => match classify(&n.to_string()) {
            Num::Int(i) => i.to_string(),
            Num::BigPositive(s) => s,
            Num::Float(f) => format_g16(f),
        },
        _ => String::new(),
    }
}

/// Integer coercion as Swift `JSONLossless.int64`.
///
/// Numbers: ints exact; doubles truncate toward zero and saturate; positive ints beyond `i64`
/// give `None`. Bools are 1/0. Strings are trimmed then parsed as base-10 `i64`.
pub fn int64(value: Option<&Value>) -> Option<i64> {
    match value? {
        Value::Number(n) => match classify(&n.to_string()) {
            Num::Int(i) => Some(i),
            Num::BigPositive(_) => None,
            Num::Float(f) => Some(f as i64),
        },
        Value::Bool(b) => Some(i64::from(*b)),
        Value::String(s) => s.trim().parse().ok(),
        _ => None,
    }
}

/// Bool coercion as Swift `JSONLossless.bool`.
///
/// Bools pass; numbers are `int != 0` (doubles truncate first); a positive integer literal of
/// 15+ digits is `None` (Swift treated it as a string); strings match `true`/`1`/`false`/`0`
/// case-insensitively without trimming, else `None`.
pub fn bool_value(value: Option<&Value>) -> Option<bool> {
    match value? {
        Value::Bool(b) => Some(*b),
        Value::Number(n) => match classify(&n.to_string()) {
            // Swift quoted positive 15+ digit literals into strings, which are not bools.
            Num::Int(i) if i > 0 && i.to_string().len() >= 15 => None,
            Num::Int(i) => Some(i != 0),
            Num::BigPositive(_) => None,
            Num::Float(f) => Some((f as i64) != 0),
        },
        Value::String(s) => match s.to_lowercase().as_str() {
            "true" | "1" => Some(true),
            "false" | "0" => Some(false),
            _ => None,
        },
        _ => None,
    }
}
