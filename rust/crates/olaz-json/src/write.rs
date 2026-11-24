use serde_json::Value;

/// Serializes like Foundation `JSONSerialization`: compact, `/` escaped as `\/`, control
/// characters as lowercase `\u00xx`. Object keys are sorted here, explicitly (ADR-009), so the
/// output never depends on serde_json's `preserve_order` feature; Swift's own order is
/// unspecified.
pub fn to_swift_json_bytes(v: &Value) -> Vec<u8> {
    let mut out = Vec::new();
    write_value(v, &mut out);
    out
}

/// [`to_swift_json_bytes`] as a `String` (the output is always valid UTF-8).
pub fn to_swift_json_string(v: &Value) -> String {
    String::from_utf8_lossy(&to_swift_json_bytes(v)).into_owned()
}

fn write_string(s: &str, out: &mut Vec<u8>) {
    // serde_json escapes `"`, `\`, \b \f \n \r \t and other controls as lowercase `\u00xx`.
    let escaped = serde_json::to_string(s).unwrap_or_else(|_| "\"\"".to_owned());
    for b in escaped.bytes() {
        if b == b'/' {
            out.extend_from_slice(b"\\/");
        } else {
            out.push(b);
        }
    }
}

fn write_value(v: &Value, out: &mut Vec<u8>) {
    match v {
        Value::Null => out.extend_from_slice(b"null"),
        Value::Bool(b) => out.extend_from_slice(if *b { b"true" } else { b"false" }),
        Value::Number(n) => out.extend_from_slice(n.to_string().as_bytes()),
        Value::String(s) => write_string(s, out),
        Value::Array(a) => {
            out.push(b'[');
            for (i, item) in a.iter().enumerate() {
                if i > 0 {
                    out.push(b',');
                }
                write_value(item, out);
            }
            out.push(b']');
        }
        Value::Object(m) => {
            let mut entries: Vec<(&String, &Value)> = m.iter().collect();
            entries.sort_by(|a, b| a.0.cmp(b.0));
            out.push(b'{');
            for (i, (k, item)) in entries.into_iter().enumerate() {
                if i > 0 {
                    out.push(b',');
                }
                write_string(k, out);
                out.push(b':');
                write_value(item, out);
            }
            out.push(b'}');
        }
    }
}
