//! Detection of undecrypted Signal v3 ciphertext (`isSignalCiphertext`, `urlHasUndecryptedSignalCipher`).

/// `String.removingPercentEncoding`: `None` on a malformed escape or non-UTF-8 result.
pub fn removing_percent_encoding(s: &str) -> Option<String> {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' {
            let hi = bytes.get(i + 1).and_then(|b| (*b as char).to_digit(16))?;
            let lo = bytes.get(i + 2).and_then(|b| (*b as char).to_digit(16))?;
            out.push((hi * 16 + lo) as u8);
            i += 3;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    String::from_utf8(out).ok()
}

/// True when `raw` is a Zalo Signal v3 wire ciphertext (`[0x01..0x03, 0x33, <protobuf tag>, ...]`).
pub fn is_signal_ciphertext(raw: &str) -> bool {
    let trimmed = raw.trim();
    let count = trimmed.chars().count();
    if !(52..=16_384).contains(&count) {
        return false;
    }
    if trimmed.chars().any(char::is_whitespace) {
        return false;
    }
    let candidate = removing_percent_encoding(trimmed).unwrap_or_else(|| trimmed.to_string());
    let Ok(bytes) = olaz_json::decode_foundation_base64(&candidate) else {
        return false;
    };
    if bytes.len() < 40 {
        return false;
    }
    let (msg_type, version, tag) = (bytes[0], bytes[1], bytes[2]);
    if !(1..=3).contains(&msg_type) || version != 0x33 {
        return false;
    }
    matches!(tag, 0x08 | 0x0A | 0x10 | 0x12 | 0x18 | 0x22 | 0x28 | 0x30)
}

/// True when a sticker / CDN URL still carries an undecrypted Signal ciphertext in `eid` or `e2esession`.
pub fn url_has_undecrypted_signal_cipher(raw_url: &str) -> bool {
    let trimmed = raw_url.trim();
    if trimmed.is_empty() {
        return false;
    }
    let before_fragment = trimmed.split('#').next().unwrap_or("");
    if let Some((_, query)) = before_fragment.split_once('?') {
        for item in query.split('&') {
            let (name, value) = match item.split_once('=') {
                Some((n, v)) => (n, Some(v)),
                None => (item, None),
            };
            let name = removing_percent_encoding(name).unwrap_or_else(|| name.to_string());
            if (name == "eid" || name == "e2esession")
                && let Some(v) = value
            {
                let v = removing_percent_encoding(v).unwrap_or_else(|| v.to_string());
                if is_signal_ciphertext(&v) {
                    return true;
                }
            }
        }
    }
    ["eid=AzM", "eid=AjM", "e2esession=AzM", "e2esession=AjM"]
        .iter()
        .any(|m| trimmed.contains(m))
}
