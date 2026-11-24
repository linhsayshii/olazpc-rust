//! URL / header policy shared by every route: Zalo CDN detection, cache file names, header
//! sanitising and redirect header stripping (Swift `MediaLoader` statics).

use url::Url;

/// Hosts for which the DoH fallback is allowed.
pub const DOH_HOST_SUFFIXES: [&str; 8] = [
    "zadn.vn",
    "zdn.vn",
    "dlfl.vn",
    "zalo.me",
    "zaloapp.com",
    "zingcdn.me",
    "zalo.vn",
    "zing.vn",
];

/// Headers that must never travel to a non-Zalo host nor survive a cross-host redirect.
pub const SENSITIVE_HEADER_NAMES: [&str; 4] = [
    "cloud-viewer-key",
    "cookie",
    "authorization",
    "proxy-authorization",
];

/// Connection-level headers a caller must not set.
pub const FORBIDDEN_HEADER_NAMES: [&str; 11] = [
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "te",
    "trailer",
    "transfer-encoding",
    "upgrade",
    "host",
    "content-length",
    "expect",
    "accept-encoding",
];

/// Default Zalo CDN test (`MediaLoader.isZaloCDN`).
#[must_use]
pub fn is_zalo_cdn(host: &str) -> bool {
    is_suffix_match(host, DOH_HOST_SUFFIXES.iter().copied())
}

pub(crate) fn is_suffix_match<'a>(host: &str, suffixes: impl IntoIterator<Item = &'a str>) -> bool {
    let host = host.to_lowercase();
    suffixes
        .into_iter()
        .any(|s| host == s || host.ends_with(&format!(".{s}")))
}

/// FNV-1a 64-bit as lowercase hex without padding (`MediaLoader.stableHash`).
#[must_use]
pub fn stable_hash(text: &str) -> String {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for byte in text.bytes() {
        hash ^= u64::from(byte);
        hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
    }
    format!("{hash:x}")
}

/// File name under the files cache: `hash(seed)` plus `.ext` (`MediaLoader.cachedFileLocation`).
/// `ext` is the already-filtered extension (letters and digits, at most 8, computed by the caller).
#[must_use]
pub fn cached_file_name(seed: &str, ext: &str) -> String {
    let ext: String = ext
        .chars()
        .filter(|c| c.is_alphanumeric())
        .take(8)
        .collect();
    let name = stable_hash(seed);
    if ext.is_empty() {
        name
    } else {
        format!("{name}.{ext}")
    }
}

fn is_token_char(c: char) -> bool {
    c.is_ascii_alphanumeric() || "!#$%&'*+-.^_`|~".contains(c)
}

fn value_ok(value: &str) -> bool {
    value
        .chars()
        .all(|c| (c as u32 >= 0x20 && c as u32 != 0x7f) || c as u32 == 0x09)
}

/// Headers safe to send to `url` (`MediaLoader.sanitizedHeaders`): names are RFC 7230 tokens,
/// values hold no CR/LF/control characters, hop-by-hop names are dropped, and sensitive ones only
/// go to https Zalo hosts. A later duplicate (case-insensitive) replaces an earlier one.
#[must_use]
pub fn sanitize_headers(
    headers: &[(String, String)],
    url: &Url,
    to_zalo: impl Fn(&str) -> bool,
) -> Vec<(String, String)> {
    let allowed = url.scheme() == "https" && to_zalo(url.host_str().unwrap_or(""));
    let mut out: Vec<(String, String)> = Vec::new();
    for (name, value) in headers {
        let lower = name.to_lowercase();
        if name.is_empty()
            || !name.chars().all(is_token_char)
            || FORBIDDEN_HEADER_NAMES.contains(&lower.as_str())
            || !value_ok(value)
        {
            continue;
        }
        if SENSITIVE_HEADER_NAMES.contains(&lower.as_str()) && !allowed {
            continue;
        }
        out.retain(|(n, _)| !n.eq_ignore_ascii_case(name));
        out.push((name.clone(), value.clone()));
    }
    out
}

/// Headers to send on a redirect to `next`: sensitive ones do not leave the host they were meant
/// for (`MediaLoader.redirectedRequest`).
#[must_use]
pub fn redirect_headers(
    headers: &[(String, String)],
    origin_host: &str,
    next: &Url,
) -> Vec<(String, String)> {
    let same = next
        .host_str()
        .is_some_and(|h| h.to_lowercase() == origin_host);
    headers
        .iter()
        .filter(|(name, _)| same || !SENSITIVE_HEADER_NAMES.contains(&name.to_lowercase().as_str()))
        .cloned()
        .collect()
}

/// `https`/`http` URL with a host; `http` is upgraded to `https` unless `allow_plain_http`
/// (`MediaLoader.normalized`, ATS: Zalo CDN serves https).
#[must_use]
pub fn normalize_url(url: &Url, allow_plain_http: bool) -> Option<Url> {
    let scheme = url.scheme().to_lowercase();
    if (scheme != "https" && scheme != "http") || url.host_str().is_none_or(str::is_empty) {
        return None;
    }
    let mut out = url.clone();
    if scheme == "http" && !allow_plain_http {
        out.set_scheme("https").ok()?;
    }
    Some(out)
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used)]

    use super::*;

    fn pair(a: &str, b: &str) -> (String, String) {
        (a.to_owned(), b.to_owned())
    }

    #[test]
    fn stable_hash_matches_swift_golden() {
        // Produced by running `MediaLoader.stableHash` in Swift.
        assert_eq!(stable_hash("a"), "af63dc4c8601ec8c");
        assert_eq!(stable_hash(""), "cbf29ce484222325");
        // Non-ASCII goes through UTF-8 bytes like `text.utf8`.
        assert_ne!(stable_hash("é"), stable_hash("e"));
        assert_eq!(
            stable_hash("https://res-zalo.zadn.vn/upload/x.json"),
            "c063989352bd3693"
        );
        assert_eq!(
            stable_hash("dec1:https://a.zdn.vn/é?x=1"),
            "cd3fcbd3a9e2f16"
        );
    }

    #[test]
    fn cached_name_layout() {
        assert_eq!(cached_file_name("a", ""), "af63dc4c8601ec8c");
        assert_eq!(cached_file_name("a", "json"), "af63dc4c8601ec8c.json");
        assert_eq!(
            cached_file_name("a", "abcdefghijk"),
            "af63dc4c8601ec8c.abcdefgh"
        );
        assert_eq!(cached_file_name("a", "a-b"), "af63dc4c8601ec8c.ab");
        // Exact URLs from Swift `RustMediaTests.stableHashAndFileNamesMatchSwift`.
        assert_eq!(
            cached_file_name("https://res-zalo.zadn.vn/upload/x.json", "json"),
            format!(
                "{}.json",
                stable_hash("https://res-zalo.zadn.vn/upload/x.json")
            )
        );
        assert_eq!(
            cached_file_name("https://a.zdn.vn/p/pic.jpeg?x=1", "jpeg"),
            format!("{}.jpeg", stable_hash("https://a.zdn.vn/p/pic.jpeg?x=1"))
        );
        assert_eq!(
            cached_file_name("https://a.zdn.vn/noext", ""),
            stable_hash("https://a.zdn.vn/noext")
        );
        assert_eq!(
            cached_file_name(
                "https://a.zdn.vn/a.verylongextension99",
                "verylongextension99"
            ),
            format!(
                "{}.verylong",
                stable_hash("https://a.zdn.vn/a.verylongextension99")
            )
        );
        assert_eq!(
            cached_file_name("https://a.zdn.vn/x.jxl?jxlstatus=1", "jxl"),
            format!("{}.jxl", stable_hash("https://a.zdn.vn/x.jxl?jxlstatus=1"))
        );
    }

    #[test]
    fn cdn_detection_matches_swift_cases() {
        for host in [
            "s160-26-ava-talk.zadn.vn",
            "res-zalo.zadn.vn",
            "stc-zaloprofile.zdn.vn",
            "chat.zalo.me",
            "tt-convers-wpa.api.zaloapp.com",
            "ZADN.VN",
        ] {
            assert!(is_zalo_cdn(host), "{host}");
        }
        for host in [
            "evil.com",
            "zadn.vn.evil.com",
            "notzadn.vn",
            "example.org",
            "localhost",
            "192.168.1.1",
        ] {
            assert!(!is_zalo_cdn(host), "{host}");
        }
    }

    #[test]
    fn sensitive_headers_only_reach_https_zalo_hosts() {
        let headers = vec![
            pair("cloud-viewer-key", "k"),
            pair("X-Custom", "v"),
            pair("Cookie", "c"),
        ];
        let zalo = Url::parse("https://res-zalo.zadn.vn/a").unwrap();
        let other = Url::parse("https://example.org/a").unwrap();
        let plain = Url::parse("http://res-zalo.zadn.vn/a").unwrap();
        assert_eq!(sanitize_headers(&headers, &zalo, is_zalo_cdn).len(), 3);
        assert_eq!(
            sanitize_headers(&headers, &other, is_zalo_cdn),
            vec![pair("X-Custom", "v")]
        );
        assert_eq!(sanitize_headers(&headers, &plain, is_zalo_cdn).len(), 1);
    }

    #[test]
    fn bad_headers_are_dropped() {
        let url = Url::parse("https://res-zalo.zadn.vn/a").unwrap();
        let headers = vec![
            pair("Bad Name", "v"),
            pair("", "v"),
            pair("Host", "evil"),
            pair("Content-Length", "1"),
            pair("Accept-Encoding", "gzip"),
            pair("X-Inject", "a\r\nb: c"),
            pair("X-Tab", "a\tb"),
            pair("X-Del", "a\u{7f}"),
            pair("Good", "ok"),
        ];
        let out = sanitize_headers(&headers, &url, is_zalo_cdn);
        assert_eq!(out, vec![pair("X-Tab", "a\tb"), pair("Good", "ok")]);
    }

    #[test]
    fn redirect_strips_sensitive_headers_across_hosts_only() {
        let headers = vec![pair("Cloud-Viewer-Key", "k"), pair("X-A", "1")];
        let same = Url::parse("https://res-zalo.zadn.vn/b").unwrap();
        let other = Url::parse("https://cdn.example.org/b").unwrap();
        assert_eq!(
            redirect_headers(&headers, "res-zalo.zadn.vn", &same),
            headers
        );
        assert_eq!(
            redirect_headers(&headers, "res-zalo.zadn.vn", &other),
            vec![pair("X-A", "1")]
        );
    }

    #[test]
    fn normalize_upgrades_http() {
        let http = Url::parse("http://a.zadn.vn/x").unwrap();
        assert_eq!(normalize_url(&http, false).unwrap().scheme(), "https");
        assert_eq!(normalize_url(&http, true).unwrap().scheme(), "http");
        assert!(normalize_url(&Url::parse("ftp://a.zadn.vn/x").unwrap(), false).is_none());
        assert!(normalize_url(&Url::parse("file:///tmp/x").unwrap(), false).is_none());
    }
}
