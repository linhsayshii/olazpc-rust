//! Shared Unicode search folding, trimming, and substring matching.
//!
//! Both SQLite (`olaz-store` `olaz_fold` / `olaz_contains` / `olaz_trim`) and in-memory search
//! (`olaz-core`) call this module so memory and store matching cannot drift apart.
//!
//! Matches Swift `ZaloEngine+Search.swift`:
//! - Query trim: `String.trimmingCharacters(in: .whitespacesAndNewlines)` (Unicode whitespace +
//!   `U+200B` zero-width space).
//! - Matching: `haystack.lowercased().contains(trimmed.lowercased())` — full Unicode lowercase
//!   (e.g. `Đ` -> `đ`, `K` -> `k`, `ẞ` -> `ß`, `ß` stays `ß`, `İ` -> `i\u{0307}`), canonical
//!   equivalence (NFC == NFD via NFC normalization), and combining-mark grapheme boundary checks
//!   (so `"i\u{0307}"` from Turkish `İ` does not match bare `"i"`).

use icu_normalizer::ComposingNormalizer;
use icu_properties::CodePointMapData;
use icu_properties::props::GeneralCategory;

/// Exact predicate matching Foundation's `CharacterSet.whitespacesAndNewlines` across all
/// Unicode scalar values (`char::is_whitespace()` + `U+200B` ZERO WIDTH SPACE).
#[inline]
#[must_use]
pub fn is_swift_whitespace_or_newline(c: char) -> bool {
    c.is_whitespace() || c == '\u{200B}'
}

/// Trims leading and trailing characters matching Swift's `.whitespacesAndNewlines`.
#[inline]
#[must_use]
pub fn trim_search_query(s: &str) -> &str {
    s.trim_matches(is_swift_whitespace_or_newline)
}

/// Shared search fold function: Unicode lowercase followed by NFC canonical composition.
///
/// Used by both `olaz-store` SQLite scalar functions (`olaz_fold`, `olaz_contains`) and
/// `olaz-core` in-memory search matching.
#[must_use]
pub fn fold_search_text(s: &str) -> String {
    if s.is_ascii() {
        return s.to_ascii_lowercase();
    }
    let lower = s.to_lowercase();
    ComposingNormalizer::new_nfc()
        .normalize(&lower)
        .into_owned()
}

#[inline]
fn is_combining_mark(c: char) -> bool {
    matches!(
        CodePointMapData::<GeneralCategory>::new().get(c),
        GeneralCategory::NonspacingMark
            | GeneralCategory::SpacingMark
            | GeneralCategory::EnclosingMark
    )
}

/// Returns `true` when `folded_haystack` (already produced by [`fold_search_text`]) contains
/// `folded_needle` (already produced by [`fold_search_text`]) on combining-mark boundaries,
/// matching Swift `String.lowercased().contains(...)`.
#[must_use]
pub fn folded_contains(folded_haystack: &str, folded_needle: &str) -> bool {
    if folded_needle.is_empty() || folded_needle.len() > folded_haystack.len() {
        return false;
    }
    if folded_haystack.is_ascii() && folded_needle.is_ascii() {
        return folded_haystack.contains(folded_needle);
    }
    let needle_starts_combining = folded_needle.chars().next().is_some_and(is_combining_mark);
    let mut offset = 0usize;
    while offset <= folded_haystack.len() - folded_needle.len() {
        let Some(rel) = folded_haystack[offset..].find(folded_needle) else {
            return false;
        };
        let pos = offset + rel;
        let end = pos + folded_needle.len();
        let start_ok = pos == 0 || !needle_starts_combining;
        let end_ok = end == folded_haystack.len()
            || !folded_haystack[end..]
                .chars()
                .next()
                .is_some_and(is_combining_mark);
        if start_ok && end_ok {
            return true;
        }
        let step = folded_haystack[pos..]
            .chars()
            .next()
            .map_or(1, char::len_utf8);
        offset = pos + step;
    }
    false
}

/// Returns `true` when `haystack` matches pre-folded `folded_needle` (produced by
/// [`fold_search_text`]). Avoids heap allocation on the ASCII fast path.
#[must_use]
pub fn search_text_contains_folded(haystack: &str, folded_needle: &str) -> bool {
    if folded_needle.is_empty() {
        return false;
    }
    if haystack.is_ascii() && folded_needle.is_ascii() {
        let hay_bytes = haystack.as_bytes();
        let needle_bytes = folded_needle.as_bytes();
        if needle_bytes.len() > hay_bytes.len() {
            return false;
        }
        return hay_bytes
            .windows(needle_bytes.len())
            .any(|w| w.eq_ignore_ascii_case(needle_bytes));
    }
    let folded_hay = fold_search_text(haystack);
    folded_contains(&folded_hay, folded_needle)
}
