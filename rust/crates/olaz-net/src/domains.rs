//! Port of `ZaloDomains.swift`: `SERVICE_MAP_V3` defaults, `getServerInfo` map parsing, host
//! candidate ordering and winner promotion.

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use std::collections::BTreeMap;

pub const ZPW_VER: &str = "694";
pub const ZPW_TYPE: &str = "23";
pub const ZPW_PC_TYPE: &str = "23";
pub const ZPW_WEB_TYPE: &str = "30";
pub const USER_AGENT: &str = "ZaloPC-darwin-23v694";
pub const WS_ORIGIN: &str = "file://";

const CHAT_HOSTS: &[&str] = &[
    "https://tt-chat3-wpa.api.zaloapp.com",
    "https://tt-chat1-wpa.api.zaloapp.com",
    "https://tt-chat2-wpa.api.zaloapp.com",
    "https://tt-chat4-wpa.api.zaloapp.com",
];

/// Authoritative `zpw_service_map_v3` defaults returned by `wpa.zaloapp.com` for `type=23`.
pub fn default_service_hosts(service: &str) -> Option<&'static [&'static str]> {
    Some(match service {
        "profile" => &["https://tt-profile-wpa.zaloapp.com"],
        "friend" => &["https://tt-friend-wpa.zaloapp.com"],
        "conversation" => &["https://tt-convers-wpa.api.zaloapp.com"],
        "chat" | "chat_e2e" => CHAT_HOSTS,
        "group" | "group_e2e" | "group_poll" => &["https://tt-group-wpa.zaloapp.com"],
        "group_board" => &["https://groupboard-wpa.api.zaloapp.com"],
        "group_cloud_message" => &["https://tt-group-cm.api.zaloapp.com"],
        "sticker" => &["https://tt-sticker-wpa.zaloapp.com"],
        "alias" => &["https://tt-alias-wpa.api.zaloapp.com"],
        "label" => &["https://label-wpa.api.zaloapp.com"],
        "reaction" => &["https://reaction.api.zaloapp.com"],
        "emoji_status" => &["https://emoji-status.api.zaloapp.com"],
        "zcloud" => &["https://zcld.chat.zalo.me", "https://zcld.api.zaloapp.com"],
        "zcloud_up_file" => &["https://tt-zcfiles-wpa.zaloapp.com"],
        "file" => &["https://tt-files-wpa.zaloapp.com"],
        "up_file" => &[
            "https://tt-nfiles-wpa.zaloapp.com",
            "https://tt-files-wpa.zaloapp.com",
        ],
        "media_store" => &["https://media-wpa.zaloapp.com"],
        "media_store_send2me" => &["https://mediasend2me-wpa.zaloapp.com"],
        "voice_call" => &["https://voicecall-wpa.zaloapp.com"],
        "znoise" => &["https://zwid.api.zalo.me"],
        "friend_lan" => &["https://friend-lan-wpa.zaloapp.com"],
        "auto_reply" => &["https://autoreply-wpa.api.zaloapp.com"],
        "quick_message" => &["https://quickmsg-wpa.api.zaloapp.com"],
        _ => return None,
    })
}

/// Secondary `.chat.zalo.me` fallbacks used only if all `.zaloapp.com` hosts fail.
pub fn fallback_service_hosts(service: &str) -> Option<&'static [&'static str]> {
    Some(match service {
        "profile" => &["https://tt-profile-wpa.chat.zalo.me"],
        "friend" => &[
            "https://tt-friend-wpa.chat.zalo.me",
            "https://tt-profile-wpa.zaloapp.com",
        ],
        "conversation" => &["https://tt-convers-wpa.chat.zalo.me"],
        "chat" | "chat_e2e" => &["https://tt-chat3-wpa.chat.zalo.me"],
        "group" | "group_e2e" => &["https://tt-group-wpa.chat.zalo.me"],
        "group_board" => &[
            "https://groupboard-wpa.chat.zalo.me",
            "https://groupboard-wpa.zaloapp.com",
        ],
        "group_poll" => &[
            "https://group-poll-wpa.zaloapp.com",
            "https://group-poll-wpa.chat.zalo.me",
        ],
        "group_cloud_message" => &["https://tt-group-cm.chat.zalo.me"],
        "sticker" => &["https://tt-sticker-wpa.chat.zalo.me"],
        "alias" => &[
            "https://tt-alias-wpa.zaloapp.com",
            "https://tt-alias-wpa.chat.zalo.me",
        ],
        "label" => &[
            "https://label-wpa.zaloapp.com",
            "https://label-wpa.chat.zalo.me",
        ],
        "reaction" => &["https://reaction.chat.zalo.me"],
        "zcloud" => &["https://zcld.chat.zalo.me"],
        "file" => &["https://tt-files-wpa.chat.zalo.me"],
        "up_file" => &[
            "https://tt-files-wpa.zaloapp.com",
            "https://tt-files-wpa.chat.zalo.me",
        ],
        "voice_call" => &["https://voicecall-wpa.chat.zalo.me"],
        "znoise" => &["https://tt-profile-wpa.zaloapp.com"],
        _ => return None,
    })
}

/// Service endpoints plus discovered map and per-service preferred host.
///
/// Serializes with the same camelCase keys as the Swift `Codable` struct, so a
/// `native-session.json` written by either side reads on the other.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ZaloDomains {
    pub auth: String,
    pub wpa_chat: String,
    pub lp_chat: String,
    pub lp_control: String,
    pub ws: Vec<String>,
    pub service_candidates: BTreeMap<String, Vec<String>>,
    pub preferred_hosts: BTreeMap<String, String>,
}

impl Default for ZaloDomains {
    fn default() -> Self {
        Self {
            auth: "https://wpa.zaloapp.com".to_owned(),
            wpa_chat: "https://wpa.chat.zalo.me".to_owned(),
            lp_chat: "https://p4-msg-chat.zaloapp.com".to_owned(),
            lp_control: "https://p4-ctl-chat.zaloapp.com".to_owned(),
            ws: (1..=4)
                .map(|n| format!("wss://ws{n}-msg.chat.zalo.me"))
                .collect(),
            service_candidates: BTreeMap::new(),
            preferred_hosts: BTreeMap::new(),
        }
    }
}

/// Maps legacy service aliases to their canonical name.
pub fn canonical_service(name: &str) -> &str {
    match name {
        "convers_api" => "conversation",
        "cloud_msg" => "group_cloud_message",
        other => other,
    }
}

/// Trims, adds `https://` when there is no scheme, drops one trailing `/`. Empty stays empty.
pub fn normalize_host(raw: &str) -> String {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return String::new();
    }
    let with_scheme = if trimmed.contains("://") {
        trimmed.to_owned()
    } else {
        format!("https://{trimmed}")
    };
    match with_scheme.strip_suffix('/') {
        Some(stripped) => stripped.to_owned(),
        None => with_scheme,
    }
}

fn first_url(raw: Option<&Value>) -> Option<String> {
    let host = match raw? {
        Value::String(s) => normalize_host(s),
        Value::Array(items) => match items.first() {
            Some(Value::String(s)) => normalize_host(s),
            _ => return None,
        },
        _ => return None,
    };
    (!host.is_empty()).then_some(host)
}

impl ZaloDomains {
    /// Clears stale `.chat.zalo.me` HTTP preferred hosts left over from legacy `zpw_type=30`
    /// sessions (except `zcloud`) and rewrites old `-msg.zaloapp.com` WebSocket hosts.
    pub fn heal_from_verified(&mut self) {
        self.preferred_hosts
            .retain(|key, current| !(current.contains(".chat.zalo.me") && key != "zcloud"));
        for host in &mut self.ws {
            *host = host.replace("-msg.zaloapp.com", "-msg.chat.zalo.me");
        }
    }

    /// Merges a `getServerInfo` / `getLoginInfo` data object: long-poll hosts (`zpw_chts_new`,
    /// `zpw_ctrs_new`), WebSocket hosts (`zpw_ws`, only `ws(s)://` kept, only if any) and the
    /// service map (`zpw_service_map_v3`, else `zpw_service_map_new`).
    pub fn apply_server_info(&mut self, data: &Map<String, Value>) {
        if let Some(lp) = first_url(data.get("zpw_chts_new")) {
            self.lp_chat = lp;
        }
        if let Some(ctrl) = first_url(data.get("zpw_ctrs_new")) {
            self.lp_control = ctrl;
        }
        if let Some(Value::Array(list)) = data.get("zpw_ws") {
            let parsed: Vec<String> = list
                .iter()
                .filter_map(Value::as_str)
                .map(normalize_host)
                .filter(|h| h.starts_with("wss://") || h.starts_with("ws://"))
                .collect();
            if !parsed.is_empty() {
                self.ws = parsed;
            }
        }
        let service_map = match data.get("zpw_service_map_v3") {
            Some(Value::Object(m)) => Some(m),
            _ => match data.get("zpw_service_map_new") {
                Some(Value::Object(m)) => Some(m),
                _ => None,
            },
        };
        let Some(service_map) = service_map else {
            return;
        };
        for (raw_key, val) in service_map {
            let key = canonical_service(raw_key).to_owned();
            let mut hosts: Vec<String> = Vec::new();
            match val {
                Value::String(single) => {
                    let h = normalize_host(single);
                    if !h.is_empty() {
                        hosts.push(h);
                    }
                }
                Value::Array(items) => {
                    for item in items {
                        if let Value::String(s) = item {
                            let h = normalize_host(s);
                            if !h.is_empty() && !hosts.contains(&h) {
                                hosts.push(h);
                            }
                        }
                    }
                }
                _ => {}
            }
            if !hosts.is_empty() {
                self.service_candidates.insert(key, hosts);
            }
        }
    }

    /// Ordered, de-duplicated hosts to try for `service`:
    /// preferred winner, discovered map, (`auth` only: `auth` + `wpaChat`), authoritative
    /// defaults, `.chat.zalo.me` fallbacks.
    pub fn candidates(&self, service: &str) -> Vec<String> {
        let key = canonical_service(service);
        let mut list: Vec<String> = Vec::new();
        let mut append_unique = |raw: &str| {
            let h = normalize_host(raw);
            if !h.is_empty() && !list.contains(&h) {
                list.push(h);
            }
        };
        if let Some(preferred) = self.preferred_hosts.get(key) {
            append_unique(preferred);
        }
        if let Some(mapped) = self.service_candidates.get(key) {
            for host in mapped {
                append_unique(host);
            }
        }
        if key == "auth" {
            append_unique(&self.auth);
            append_unique(&self.wpa_chat);
        }
        if let Some(defaults) = default_service_hosts(key) {
            for host in defaults {
                append_unique(host);
            }
        }
        if let Some(fallbacks) = fallback_service_hosts(key) {
            for host in fallbacks {
                append_unique(host);
            }
        }
        list
    }

    /// Remembers the host that just answered so it is tried first next time.
    pub fn remember_winner(&mut self, service: &str, host: &str) {
        let key = canonical_service(service).to_owned();
        let norm = normalize_host(host);
        if norm.is_empty() {
            return;
        }
        self.preferred_hosts.insert(key, norm);
    }
}
