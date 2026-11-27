//! Captured API/image headers: original project's reanalysis/wire-fingerprint.md (26.10.20).
//! Media-other uses its MediaLoader `.cors` flavour; WS additions are Chromium behaviour,
//! since the passive capture did not include a WebSocket upgrade.

use crate::identity::{USER_AGENT, WS_ORIGIN};

pub const ACCEPT_ENCODING: &str = "gzip, deflate, br";
pub const SEC_CH_UA: &str = "\"Not?A_Brand\";v=\"8\", \"Chromium\";v=\"108\"";
pub const IMAGE_ACCEPT: &str = "image/webp,image/apng,image/*,*/*;q=0.8";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RequestKind {
    Api,
    MediaImage,
    MediaOther,
}

/// No base-language expansion: a single system preference sends exactly that language.
#[must_use]
pub fn accept_language(preferred: &[String]) -> String {
    if preferred.is_empty() {
        return "en-US".to_owned();
    }
    preferred
        .iter()
        .enumerate()
        .map(|(index, language)| {
            let language = language.replace('_', "-");
            if index == 0 {
                language
            } else {
                format!("{language};q={:.1}", 1.0 - 0.1 * index as f64)
            }
        })
        .collect::<Vec<_>>()
        .join(",")
}

#[must_use]
pub fn domain_matches(host: &str, domain: &str) -> bool {
    let host = host.to_ascii_lowercase();
    host == domain
        || host
            .strip_suffix(domain)
            .is_some_and(|prefix| prefix.ends_with('.'))
}

#[must_use]
pub fn is_api_host(host: &str) -> bool {
    ["zalo.me", "zaloapp.com", "zadn.vn"]
        .iter()
        .any(|domain| domain_matches(host, domain))
}

/// Two domain cookies were captured only on chat.zalo.me and its subdomains. Other host
/// families conservatively get one; callers enforce their own allowed-host and HTTPS policy.
#[must_use]
pub fn session_cookie(host: &str, sek: &str) -> Option<String> {
    if sek.is_empty() {
        return None;
    }
    let cookie = format!("zpw_sek={sek}");
    Some(if domain_matches(host, "chat.zalo.me") {
        format!("{cookie}; {cookie}")
    } else {
        cookie
    })
}

/// Case-insensitive caller overrides, matching the original proxy's `setDefault` behaviour.
#[must_use]
pub fn request_headers(
    kind: RequestKind,
    preferred: &[String],
    extra: &[(String, String)],
) -> Vec<(String, String)> {
    let mut headers: Vec<(String, String)> = Vec::new();
    for (name, value) in extra {
        if name.eq_ignore_ascii_case("zpw_sek") {
            continue;
        }
        let value = if name.eq_ignore_ascii_case("cookie") {
            value
                .split(';')
                .map(str::trim)
                .filter(|part| {
                    !part
                        .split_once('=')
                        .is_some_and(|(name, _)| name.trim().eq_ignore_ascii_case("_zlang"))
                })
                .collect::<Vec<_>>()
                .join("; ")
        } else {
            value.clone()
        };
        headers.retain(|(n, _)| !n.eq_ignore_ascii_case(name));
        if !name.eq_ignore_ascii_case("cookie") || !value.is_empty() {
            headers.push((name.clone(), value));
        }
    }
    let mut default = |name: &str, value: &str| {
        if !headers.iter().any(|(n, _)| n.eq_ignore_ascii_case(name)) {
            headers.push((name.to_owned(), value.to_owned()));
        }
    };
    default("user-agent", USER_AGENT);
    default("sec-ch-ua", SEC_CH_UA);
    default("sec-ch-ua-mobile", "?0");
    default("sec-ch-ua-platform", "\"macOS\"");
    default("accept-language", &accept_language(preferred));
    default("accept-encoding", ACCEPT_ENCODING);
    let (accept, dest, mode) = match kind {
        RequestKind::Api => ("application/json, text/plain, */*", "empty", "cors"),
        RequestKind::MediaImage => (IMAGE_ACCEPT, "image", "no-cors"),
        RequestKind::MediaOther => ("*/*", "empty", "cors"),
    };
    default("accept", accept);
    default("sec-fetch-dest", dest);
    default("sec-fetch-mode", mode);
    default("sec-fetch-site", "cross-site");
    if kind == RequestKind::Api {
        default("content-type", "application/x-www-form-urlencoded");
    }
    headers
}

#[must_use]
pub fn websocket_headers(
    host: &str,
    sek: &str,
    preferred: &[String],
) -> Vec<(&'static str, String)> {
    let mut headers = vec![
        ("Origin", WS_ORIGIN.to_owned()),
        ("User-Agent", USER_AGENT.to_owned()),
        ("Accept-Encoding", ACCEPT_ENCODING.to_owned()),
        ("Accept-Language", accept_language(preferred)),
        ("Pragma", "no-cache".to_owned()),
        ("Cache-Control", "no-cache".to_owned()),
    ];
    if is_api_host(host)
        && let Some(cookie) = session_cookie(host, sek)
    {
        headers.push(("Cookie", cookie));
    }
    headers
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeMap;

    #[test]
    fn exact_http_header_sets() {
        for (kind, accept, dest, mode) in [
            (
                RequestKind::Api,
                "application/json, text/plain, */*",
                "empty",
                "cors",
            ),
            (RequestKind::MediaImage, IMAGE_ACCEPT, "image", "no-cors"),
            (RequestKind::MediaOther, "*/*", "empty", "cors"),
        ] {
            let actual: BTreeMap<_, _> =
                request_headers(kind, &["vi_VN".into(), "en-US".into()], &[])
                    .into_iter()
                    .collect();
            let mut expected: BTreeMap<String, String> = [
                ("user-agent", "ZaloPC-darwin-23v695"),
                (
                    "sec-ch-ua",
                    "\"Not?A_Brand\";v=\"8\", \"Chromium\";v=\"108\"",
                ),
                ("sec-ch-ua-mobile", "?0"),
                ("sec-ch-ua-platform", "\"macOS\""),
                ("accept-language", "vi-VN,en-US;q=0.9"),
                ("accept-encoding", "gzip, deflate, br"),
                ("accept", accept),
                ("sec-fetch-dest", dest),
                ("sec-fetch-mode", mode),
                ("sec-fetch-site", "cross-site"),
            ]
            .into_iter()
            .map(|(k, v)| (k.into(), v.into()))
            .collect();
            if kind == RequestKind::Api {
                expected.insert(
                    "content-type".into(),
                    "application/x-www-form-urlencoded".into(),
                );
            }
            assert_eq!(actual, expected);
        }
    }

    #[test]
    fn preferred_languages_and_caller_overrides() {
        assert_eq!(accept_language(&[]), "en-US");
        assert_eq!(accept_language(&["en_US".into()]), "en-US");
        assert_eq!(
            accept_language(&["vi".into(), "en_US".into(), "ja".into()]),
            "vi,en-US;q=0.9,ja;q=0.8"
        );
        for kind in [
            RequestKind::Api,
            RequestKind::MediaImage,
            RequestKind::MediaOther,
        ] {
            let extra = vec![
                ("ACCEPT".into(), "custom".into()),
                (
                    "Content-Type".into(),
                    "multipart/form-data; boundary=x".into(),
                ),
                ("Accept-Language".into(), "ja".into()),
                ("zpw_sek".into(), "removed".into()),
                ("Cookie".into(), "zpw_sek=sek; _zlang=vi; zpw_uin=42".into()),
            ];
            let h: BTreeMap<_, _> = request_headers(kind, &[], &extra)
                .into_iter()
                .map(|(k, v)| (k.to_ascii_lowercase(), v))
                .collect();
            assert_eq!(h.get("accept").map(String::as_str), Some("custom"));
            assert_eq!(
                h.get("content-type").map(String::as_str),
                Some("multipart/form-data; boundary=x")
            );
            assert_eq!(h.get("accept-language").map(String::as_str), Some("ja"));
            assert_eq!(
                h.get("cookie").map(String::as_str),
                Some("zpw_sek=sek; zpw_uin=42")
            );
            assert!(!h.contains_key("zpw_sek"));
            assert!(h.values().all(|v| !v.contains("_zlang")));
        }
    }

    #[test]
    fn cookie_domain_boundaries_and_ws_set() {
        for host in ["chat.zalo.me", "ws1-msg.chat.zalo.me", "ZCLD.CHAT.ZALO.ME"] {
            assert_eq!(
                session_cookie(host, "sek").as_deref(),
                Some("zpw_sek=sek; zpw_sek=sek")
            );
        }
        for host in [
            "wpa.zaloapp.com",
            "api.zalo.me",
            "photo.zadn.vn",
            "chat.zalo.me.attacker.test",
            "notchat.zalo.me",
        ] {
            assert_eq!(session_cookie(host, "sek").as_deref(), Some("zpw_sek=sek"));
        }
        for host in ["notzalo.me", "zalo.me.attacker.test", "localhost"] {
            assert!(!is_api_host(host));
        }
        let h: BTreeMap<_, _> = websocket_headers("ws1-msg.chat.zalo.me", "sek", &["vi".into()])
            .into_iter()
            .collect();
        assert_eq!(
            h,
            BTreeMap::from([
                ("Origin", "file://".into()),
                ("User-Agent", "ZaloPC-darwin-23v695".into()),
                ("Accept-Encoding", "gzip, deflate, br".into()),
                ("Accept-Language", "vi".into()),
                ("Pragma", "no-cache".into()),
                ("Cache-Control", "no-cache".into()),
                ("Cookie", "zpw_sek=sek; zpw_sek=sek".into()),
            ])
        );
        assert!(
            !websocket_headers("zalo.me.attacker.test", "sek", &[])
                .iter()
                .any(|(k, _)| *k == "Cookie")
        );
        assert_eq!(session_cookie("chat.zalo.me", ""), None);
    }
}
