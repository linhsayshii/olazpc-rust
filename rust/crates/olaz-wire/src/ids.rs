//! Conversation / user id normalization (`ZaloWireParser` "Conversation ID Normalization").

fn all_ascii_digits(s: &str) -> bool {
    s.chars().all(|c| c.is_ascii_digit())
}

/// `cleanGroupId`: strips a `group_` prefix or a lone `g`/`G` prefix followed only by digits.
pub fn clean_group_id(raw: &str) -> String {
    let s = raw.trim();
    if let Some(rest) = s.strip_prefix("group_") {
        return rest.to_string();
    }
    if let Some(rest) = s.strip_prefix(['g', 'G'])
        && all_ascii_digits(rest)
    {
        return rest.to_string();
    }
    s.to_string()
}

/// `groupConvId`: `"g<id>"`, or "" for empty / `0`.
pub fn group_conv_id(raw: &str) -> String {
    let clean = clean_group_id(raw);
    if clean.is_empty() || clean == "0" {
        String::new()
    } else {
        format!("g{clean}")
    }
}

/// `isGroupId`.
pub fn is_group_id(id: &str) -> bool {
    if let Some(rest) = id.strip_prefix("group_") {
        return !rest.is_empty() && rest != "0";
    }
    match id.strip_prefix('g') {
        Some(rest) => !rest.is_empty() && id != "g0" && all_ascii_digits(rest),
        None => false,
    }
}

/// `stripUserPrefix`: only trims whitespace (the prefix handling is gone upstream).
pub fn strip_user_prefix(id: &str) -> String {
    id.trim().to_string()
}

/// `sanitizeProfileUid`: a plain numeric uid (1...24 digits), tolerating a `u` prefix and a `_<digits>` suffix.
pub fn sanitize_profile_uid(raw: &str) -> Option<String> {
    let mut s = raw.trim().to_string();
    if s.is_empty() {
        return None;
    }
    if let Some(idx) = s.find('_') {
        let suffix = &s[idx + 1..];
        if suffix.is_empty() || !all_ascii_digits(suffix) {
            return None;
        }
        s.truncate(idx);
    }
    if let Some(rest) = s.strip_prefix('u')
        && !rest.is_empty()
        && all_ascii_digits(rest)
    {
        s = rest.to_string();
    }
    let n = s.chars().count();
    if s.is_empty()
        || s == "0"
        || s.chars().all(|c| c == '0')
        || !(1..=24).contains(&n)
        || !all_ascii_digits(&s)
    {
        return None;
    }
    Some(s)
}

/// `normalizeThreadIdFromList`: strips the `u` prefix used by pin/archive list APIs; groups become `g<id>`.
pub fn normalize_thread_id_from_list(id: &str) -> String {
    if let Some(rest) = id.strip_prefix('u')
        && !rest.is_empty()
        && all_ascii_digits(rest)
    {
        return rest.to_string();
    }
    if id.starts_with('g') || id.starts_with("group_") {
        return group_conv_id(id);
    }
    id.to_string()
}
