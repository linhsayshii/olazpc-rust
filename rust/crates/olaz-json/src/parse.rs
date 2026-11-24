use serde_json::{Map, Value};

fn is_number_continuation(b: u8) -> bool {
    b.is_ascii_digit() || matches!(b, b'.' | b'e' | b'E' | b'-')
}

/// `JSONLossless.quoteLargeIntegerLiterals`: wraps every bare digit run of 15+ digits (outside
/// strings, not part of a fraction/exponent/negative literal) in quotes so 64-bit ids arrive as
/// strings.
pub fn quote_large_integer_literals(data: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(data.len() + 64);
    let mut i = 0;
    let mut in_string = false;
    let mut escaped = false;
    while i < data.len() {
        let b = data[i];
        if in_string {
            out.push(b);
            if escaped {
                escaped = false;
            } else if b == b'\\' {
                escaped = true;
            } else if b == b'"' {
                in_string = false;
            }
            i += 1;
            continue;
        }
        if b == b'"' {
            in_string = true;
            out.push(b);
            i += 1;
            continue;
        }
        let prev = if i > 0 { data[i - 1] } else { 0 };
        if b.is_ascii_digit() && !is_number_continuation(prev) {
            let mut end = i;
            while end < data.len() && data[end].is_ascii_digit() {
                end += 1;
            }
            let next = data.get(end).copied().unwrap_or(0);
            if end - i >= 15 && !matches!(next, b'.' | b'e' | b'E') {
                out.push(b'"');
                out.extend_from_slice(&data[i..end]);
                out.push(b'"');
                i = end;
                continue;
            }
        }
        out.push(b);
        i += 1;
    }
    out
}

/// `JSONLossless.parseAny` (fragments allowed); `None` on invalid JSON. A leading UTF-8 BOM is
/// skipped (Foundation accepts it).
pub fn parse_any(data: &[u8]) -> Option<Value> {
    let data = data.strip_prefix(&[0xEF, 0xBB, 0xBF]).unwrap_or(data);
    serde_json::from_slice(&quote_large_integer_literals(data)).ok()
}

/// `JSONLossless.parseObject`: only a top-level object counts.
pub fn parse_object(data: &[u8]) -> Option<Map<String, Value>> {
    match parse_any(data)? {
        Value::Object(map) => Some(map),
        _ => None,
    }
}

/// `JSONLossless.parseObject(string:)`.
pub fn parse_object_str(s: &str) -> Option<Map<String, Value>> {
    parse_object(s.as_bytes())
}
