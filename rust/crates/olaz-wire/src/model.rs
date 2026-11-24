//! Model types the parser fills (`ChatModels.swift`, `StoredMessage` in `ZaloSQLiteStore.swift`).
//!
//! URLs are kept as strings (Swift used `URL`). Dates are Unix milliseconds (`Date` in Swift).

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};

use crate::util::{
    as_bool_cast, as_dict, as_dict_array, as_str, clamped_int, ns_bool, ns_double, ns_int,
    round_i64,
};

/// Name shown for an unknown sender (`ReactionDetail.unknownName`).
pub const UNKNOWN_NAME: &str = "Người dùng Zalo";

/// An @mention: `pos` / `len` are raw UTF-16 offsets into the message text (never used to slice a Rust string).
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct Mention {
    pub uid: String,
    pub pos: i64,
    pub len: i64,
    pub is_all: bool,
}

/// One styled range of a rich-text message (official `textProperties.styles`): `start` / `len` are UTF-16 offsets,
/// `st` the comma-separated style tokens (`b`, `i`, `u`, `s`, `c_<hex>`, `f_<size>`, `lst_1`, `lst_2`, `ind_<n>`).
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct TextStyle {
    pub start: i64,
    pub len: i64,
    pub st: String,
}

impl TextStyle {
    /// `[{start, len, st}]`; entries without a style or a positive length are dropped.
    pub fn list(value: Option<&Value>) -> Vec<TextStyle> {
        as_dict_array(value)
            .unwrap_or_default()
            .into_iter()
            .filter_map(|m| {
                let st = as_str(m.get("st")).unwrap_or("").trim().to_string();
                let start = clamped_int(ns_double(m.get("start")).unwrap_or(0.0));
                let len = clamped_int(ns_double(m.get("len")).unwrap_or(0.0));
                (!st.is_empty() && len > 0 && start >= 0).then_some(TextStyle { start, len, st })
            })
            .collect()
    }

    pub fn to_json(list: &[TextStyle]) -> Value {
        Value::Array(list.iter().map(|s| json!({"start": s.start, "len": s.len, "st": s.st})).collect())
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct ReactionIcon {
    pub r#type: String,
    pub key: String,
    pub emoji: String,
    pub image: String,
}

impl ReactionIcon {
    pub fn new(r#type: &str, key: &str, emoji: &str) -> Self {
        Self {
            r#type: r#type.to_string(),
            key: key.to_string(),
            emoji: emoji.to_string(),
            image: String::new(),
        }
    }

    /// `ReactionIcon.init?(json:)`: strings only (no numeric coercion).
    pub fn from_json(json: &Map<String, Value>) -> Option<Self> {
        let emoji = as_str(json.get("emoji")).unwrap_or("");
        let key = as_str(json.get("key")).unwrap_or("");
        if emoji.is_empty() && key.is_empty() {
            return None;
        }
        let ty = match as_str(json.get("type")) {
            Some(t) if !t.is_empty() => t.to_string(),
            _ => if key.is_empty() { emoji } else { key }.to_string(),
        };
        Some(Self {
            r#type: ty,
            key: key.to_string(),
            emoji: if emoji.is_empty() { key } else { emoji }.to_string(),
            image: as_str(json.get("image")).unwrap_or("").to_string(),
        })
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Reaction {
    pub icon: ReactionIcon,
    pub count: i64,
    pub includes_me: bool,
    pub names: Vec<String>,
    pub people: i64,
    pub user_counts: BTreeMap<String, i64>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ContactCard {
    pub name: String,
    pub uid: String,
    pub avatar: Option<String>,
    pub phone: String,
    pub qr: Option<String>,
    pub oa_link: String,
    pub is_official_account: bool,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct LocationInfo {
    pub title: String,
    pub address: String,
    /// `(latitude, longitude)` when the server sent valid coordinates.
    pub coordinate: Option<(f64, f64)>,
    pub thumbnail: Option<String>,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub enum ECardStyle {
    #[default]
    Banner,
    Friend,
    Birthday,
    Reminder,
}

impl ECardStyle {
    pub fn raw_value(self) -> &'static str {
        match self {
            Self::Banner => "banner",
            Self::Friend => "friend",
            Self::Birthday => "birthday",
            Self::Reminder => "reminder",
        }
    }

    pub fn from_raw(s: &str) -> Option<Self> {
        match s {
            "banner" => Some(Self::Banner),
            "friend" => Some(Self::Friend),
            "birthday" => Some(Self::Birthday),
            "reminder" => Some(Self::Reminder),
            _ => None,
        }
    }
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ECard {
    pub style: ECardStyle,
    pub image: Option<String>,
    pub thumb: Option<String>,
    pub title: String,
    pub description: String,
    pub actions: Vec<String>,
    pub avatars: Vec<String>,
    pub reminder_title: String,
    /// Unix milliseconds (`Date?` in Swift).
    pub reminder_start_ms: Option<i64>,
    pub reminder_repeat: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct OaPart {
    pub is_header: bool,
    pub title: String,
    pub description: String,
    pub thumb: Option<String>,
    pub url: Option<String>,
    pub help: String,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct PollInfo {
    pub question: String,
    pub header: String,
    pub anonymous: bool,
    pub poll_id: String,
    pub conversation_id: String,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub enum Kind {
    Text,
    Photo {
        url: Option<String>,
        width: i64,
        height: i64,
    },
    Sticker {
        url: Option<String>,
    },
    Gif {
        url: Option<String>,
    },
    Video {
        thumbnail: Option<String>,
        duration: i64,
        url: Option<String>,
    },
    Voice {
        url: Option<String>,
        duration: i64,
    },
    File {
        name: String,
        size: i64,
        url: Option<String>,
    },
    Link {
        title: String,
        url: Option<String>,
        thumbnail: Option<String>,
        description: String,
        source: String,
    },
    ContactCard(ContactCard),
    Location(LocationInfo),
    Call {
        video: bool,
        missed: bool,
        duration: i64,
        title: String,
        detail: String,
    },
    Ecard(ECard),
    OaMessage(Vec<OaPart>),
    Poll(PollInfo),
    StickerSet {
        title: String,
        thumbnail: Option<String>,
    },
    Zinstant {
        title: String,
        text: String,
        thumbnail: Option<String>,
    },
    Notice {
        symbol: String,
        text: String,
    },
    Placeholder {
        symbol: String,
        text: String,
    },
    System,
    Recalled,
    Unsupported {
        raw_type: String,
    },
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub enum Status {
    Sending,
    #[default]
    Sent,
    Delivered,
    Seen,
    Failed,
}

impl Status {
    pub fn raw_value(self) -> &'static str {
        match self {
            Self::Sending => "sending",
            Self::Sent => "sent",
            Self::Delivered => "delivered",
            Self::Seen => "seen",
            Self::Failed => "failed",
        }
    }

    pub fn from_raw(s: &str) -> Option<Self> {
        match s {
            "sending" => Some(Self::Sending),
            "sent" => Some(Self::Sent),
            "delivered" => Some(Self::Delivered),
            "seen" => Some(Self::Seen),
            "failed" => Some(Self::Failed),
            _ => None,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Quote {
    pub sender_name: String,
    pub text: String,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub enum Availability {
    #[default]
    Hidden,
    Available,
    Blocked,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum DeleteMode {
    Plain,
    ForMe,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum StarMode {
    Star,
    Unstar,
    Blocked,
}

/// The message context-menu state (`MessageMenu`).
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct MessageMenu {
    pub forward: Availability,
    pub recall: bool,
    pub delete: Option<DeleteMode>,
    pub pin: bool,
    pub star: Option<StarMode>,
    pub starred: bool,
    pub pinned: bool,
    pub is_protected: bool,
}

impl MessageMenu {
    /// `MessageMenu.init(json:)`.
    pub fn from_json(json: Option<&Value>) -> Self {
        let mut m = Self::default();
        let Some(row) = as_dict(json) else { return m };
        m.forward = match as_str(row.get("forward")) {
            Some("ok") => Availability::Available,
            Some("blocked") => Availability::Blocked,
            _ => Availability::Hidden,
        };
        let flag = |k: &str| as_bool_cast(row.get(k)).unwrap_or(false);
        m.recall = flag("recall");
        m.delete = match as_str(row.get("delete")) {
            Some("plain") => Some(DeleteMode::Plain),
            Some("forMe") => Some(DeleteMode::ForMe),
            _ => None,
        };
        m.pin = flag("pin");
        m.star = match as_str(row.get("star")) {
            Some("star") => Some(StarMode::Star),
            Some("unstar") => Some(StarMode::Unstar),
            Some("blocked") => Some(StarMode::Blocked),
            _ => None,
        };
        m.starred = flag("starred");
        m.pinned = flag("pinned");
        m.is_protected = flag("protected");
        m
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct CardButton {
    pub r#ref: String,
    pub label: String,
    pub enabled: bool,
    pub help: String,
}

impl CardButton {
    /// `CardButton.list(json:)`: entries without a ref or label are dropped; `enabled` defaults to false.
    pub fn list(json: Option<&Value>) -> Vec<Self> {
        as_dict_array(json)
            .unwrap_or_default()
            .into_iter()
            .filter_map(|row| {
                let r = as_str(row.get("ref")).unwrap_or("").to_string();
                let label = as_str(row.get("label")).unwrap_or("").trim().to_string();
                if r.is_empty() || label.is_empty() {
                    return None;
                }
                Some(Self {
                    r#ref: r,
                    label,
                    enabled: ns_bool(row.get("enabled")).unwrap_or(false),
                    help: as_str(row.get("help")).unwrap_or("").to_string(),
                })
            })
            .collect()
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ChatMessage {
    pub id: String,
    pub conversation_id: String,
    pub sender_id: String,
    pub sender_name: String,
    pub sender_avatar: Option<String>,
    pub is_mine: bool,
    pub kind: Kind,
    pub text: String,
    /// Unix milliseconds (`Date` in Swift).
    pub date_ms: i64,
    pub status: Status,
    pub quote: Option<Quote>,
    pub reactions: Vec<Reaction>,
    pub is_e2ee: bool,
    pub mentions: Vec<Mention>,
    pub card_buttons: Vec<CardButton>,
    pub suggests_stickers: bool,
    pub menu: MessageMenu,
    pub fallback_urls: Vec<String>,
    pub client_id: String,
    /// Rich-text styles of a text message (empty for plain text).
    pub text_styles: Vec<TextStyle>,
    /// "Tin nhắn tự xóa": lifetime in milliseconds from `date_ms` (0 = kept).
    pub ttl_ms: i64,
}

/// Row of the SQLite message table (`StoredMessage`).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct StoredMessage {
    pub id: String,
    pub conv_id: String,
    pub client_id: String,
    pub sender_id: String,
    pub sender_name: String,
    pub sender_avatar: String,
    pub is_mine: bool,
    pub text: String,
    pub kind_tag: String,
    pub ts_ms: i64,
    pub status: String,
    pub raw_json_data: Vec<u8>,
}

/// One parsed realtime / history event (`ParsedWireEvent`).
#[derive(Clone, Debug, PartialEq)]
pub enum ParsedWireEvent {
    Message(Box<ChatMessage>, Box<StoredMessage>),
    Reaction {
        conv_id: String,
        msg_id: String,
        cli_msg_id: String,
        sender_id: String,
        r_type: String,
        r_icon: String,
        event_id: String,
        react_client_id: String,
        ts_ms: i64,
        seq_id: i64,
        sender_name: String,
    },
    Undo {
        conv_id: String,
        msg_id: String,
        cli_msg_id: String,
    },
    Delete {
        conv_id: String,
        msg_id: String,
        cli_msg_id: String,
    },
    Typing {
        conv_id: String,
        sender_id: String,
        is_group: bool,
    },
    Ignore,
}

// MARK: - URL helpers

/// `URL(string:)` validity, approximated: non-empty and free of control characters. The string is kept verbatim
/// (Foundation may percent-encode non-ASCII on `absoluteString`).
fn valid_url(s: &str) -> Option<String> {
    if s.is_empty() || s.chars().any(char::is_control) {
        None
    } else {
        Some(s.to_string())
    }
}

/// `ChatMessage.init(json:)`'s `url()`: no trimming.
fn url_untrimmed(v: Option<&Value>) -> Option<String> {
    match as_str(v) {
        Some(s) if !s.is_empty() => valid_url(s),
        _ => None,
    }
}

/// `Kind.init(json:)`'s `url()`: trims first.
fn url_trimmed(v: Option<&Value>) -> Option<String> {
    let t = as_str(v)?.trim();
    if t.is_empty() { None } else { valid_url(t) }
}

/// `WebLink.sanitized`: only `http` / `https` URLs with a host.
pub fn web_link_sanitized(url: Option<String>) -> Option<String> {
    let u = url?;
    let (scheme, rest) = u.split_once(':')?;
    let scheme = scheme.to_lowercase();
    if scheme != "http" && scheme != "https" {
        return None;
    }
    let authority = rest.strip_prefix("//")?;
    let end = authority.find(['/', '?', '#']).unwrap_or(authority.len());
    let mut host = &authority[..end];
    if let Some((_, h)) = host.rsplit_once('@') {
        host = h;
    }
    if host.starts_with('[') {
        host = host.split(']').next().unwrap_or("").trim_start_matches('[');
    } else if let Some((h, _)) = host.split_once(':') {
        host = h;
    }
    if host.is_empty() { None } else { Some(u) }
}

impl Kind {
    /// `ChatMessage.Kind.init(json:)`: never fails; unknown types become `Unsupported`.
    pub fn from_json(json: &Map<String, Value>) -> Self {
        let text = |k: &str| as_str(json.get(k)).unwrap_or("").to_string();
        let number = |k: &str| ns_double(json.get(k)).unwrap_or(0.0);
        let flag = |k: &str| ns_bool(json.get(k)).unwrap_or(false);
        let url = |k: &str| url_trimmed(json.get(k));
        match as_str(json.get("type")).unwrap_or("text") {
            "text" => Kind::Text,
            "photo" => Kind::Photo {
                url: url("url"),
                width: clamped_int(number("width")),
                height: clamped_int(number("height")),
            },
            "sticker" => Kind::Sticker { url: url("url") },
            "gif" => Kind::Gif { url: url("url") },
            "video" => Kind::Video {
                thumbnail: url("thumbnail"),
                duration: clamped_int(number("duration")),
                url: url("url"),
            },
            "voice" => Kind::Voice {
                url: url("url"),
                duration: clamped_int(number("duration")),
            },
            "file" => Kind::File {
                name: text("name"),
                size: clamped_int(number("size")),
                url: url("url"),
            },
            "link" => Kind::Link {
                title: text("title"),
                url: web_link_sanitized(url("url")),
                thumbnail: url("thumbnail"),
                description: text("description"),
                source: text("source"),
            },
            "contactCard" => Kind::ContactCard(ContactCard {
                name: text("name"),
                uid: text("uid"),
                avatar: url("avatar"),
                phone: text("phone"),
                qr: url("qr"),
                oa_link: text("oaLink"),
                is_official_account: flag("isOA"),
            }),
            "location" => {
                let mut info = LocationInfo {
                    title: text("title"),
                    address: text("address"),
                    coordinate: None,
                    thumbnail: url("thumbnail"),
                };
                if flag("hasCoordinates") {
                    let (lat, lon) = (number("latitude"), number("longitude"));
                    if lat.abs() <= 90.0 && lon.abs() <= 180.0 {
                        info.coordinate = Some((lat, lon));
                    }
                }
                Kind::Location(info)
            }
            "call" => Kind::Call {
                video: flag("video"),
                missed: flag("missed"),
                duration: clamped_int(number("duration")),
                title: text("title"),
                detail: text("detail"),
            },
            "ecard" => {
                let start = number("reminderStart");
                Kind::Ecard(ECard {
                    style: ECardStyle::from_raw(&text("style")).unwrap_or_default(),
                    image: url("image"),
                    thumb: url("thumb"),
                    title: text("title"),
                    description: text("description"),
                    actions: json
                        .get("actions")
                        .and_then(Value::as_array)
                        .map(|a| {
                            a.iter()
                                .filter_map(Value::as_str)
                                .filter(|s| !s.is_empty())
                                .map(str::to_string)
                                .collect()
                        })
                        .unwrap_or_default(),
                    avatars: json
                        .get("avatars")
                        .and_then(Value::as_array)
                        .map(|a| a.iter().filter_map(|v| url_trimmed(Some(v))).collect())
                        .unwrap_or_default(),
                    reminder_title: text("reminderTitle"),
                    // Plausible timestamps only (1970 ... 2100).
                    reminder_start_ms: if start > 0.0 && start < 4_102_444_800_000.0 {
                        Some(round_i64(start))
                    } else {
                        None
                    },
                    reminder_repeat: text("reminderRepeat"),
                })
            }
            "oaMessage" => {
                let parts = as_dict_array(json.get("parts"))
                    .unwrap_or_default()
                    .into_iter()
                    .filter_map(|row| {
                        let title = as_str(row.get("title")).unwrap_or("").to_string();
                        let thumb = url_trimmed(row.get("thumb"));
                        if title.is_empty() && thumb.is_none() {
                            return None;
                        }
                        Some(OaPart {
                            is_header: ns_bool(row.get("header")).unwrap_or(false),
                            title,
                            description: as_str(row.get("description")).unwrap_or("").to_string(),
                            thumb,
                            url: web_link_sanitized(url_trimmed(row.get("url"))),
                            help: as_str(row.get("help")).unwrap_or("").to_string(),
                        })
                    })
                    .collect();
                Kind::OaMessage(parts)
            }
            "poll" => Kind::Poll(PollInfo {
                question: text("question"),
                header: text("header"),
                anonymous: flag("anonymous"),
                poll_id: text("pollId"),
                conversation_id: text("conversationId"),
            }),
            "stickerSet" => Kind::StickerSet {
                title: text("title"),
                thumbnail: url("thumb"),
            },
            "zinstant" => Kind::Zinstant {
                title: text("title"),
                text: text("text"),
                thumbnail: url("thumb"),
            },
            "notice" => Kind::Notice {
                symbol: if text("symbol").is_empty() {
                    "info.circle".into()
                } else {
                    text("symbol")
                },
                text: text("text"),
            },
            "placeholder" => Kind::Placeholder {
                symbol: if text("symbol").is_empty() {
                    "lock".into()
                } else {
                    text("symbol")
                },
                text: text("text"),
            },
            "system" => Kind::System,
            "recalled" => Kind::Recalled,
            _ => Kind::Unsupported {
                raw_type: text("rawType"),
            },
        }
    }
}

fn reaction_from_json(r: &Map<String, Value>) -> Option<Reaction> {
    let icon = ReactionIcon::from_json(r)?;
    if let Ok(numeric) = icon.r#type.trim().parse::<i64>()
        && numeric < 0
    {
        return None;
    }
    let raw_count = clamped_int(ns_double(r.get("count")).unwrap_or(0.0));
    if raw_count <= 0 {
        return None;
    }
    let includes_me = as_bool_cast(r.get("includesMe")).unwrap_or(false);
    let raw_names: Vec<String> = match r.get("names").and_then(Value::as_array) {
        Some(a) if a.iter().all(Value::is_string) => a
            .iter()
            .filter_map(Value::as_str)
            .map(str::to_string)
            .collect(),
        _ => Vec::new(),
    };
    let has_explicit_user_counts = r.contains_key("userCounts");
    let mut raw_user_counts: BTreeMap<String, i64> = BTreeMap::new();
    if let Some(uc) = as_dict(r.get("userCounts")) {
        for (raw_uid, val) in uc {
            let uid = raw_uid.trim();
            if matches!(uid, "" | "__legacy__" | "unknown" | "-1") {
                continue;
            }
            let c = clamped_int(ns_double(Some(val)).unwrap_or(0.0));
            if c > 0 {
                raw_user_counts.insert(uid.to_string(), c);
            }
        }
    }
    if has_explicit_user_counts && raw_user_counts.is_empty() {
        return None;
    }
    let parsed_people = clamped_int(ns_double(r.get("people")).unwrap_or(0.0));
    let has_explicit_zero_people = ns_int(r.get("people")) == Some(0);
    // Drop corrupted ghost reactions left in local SQLite without valid reactor info.
    if raw_user_counts.is_empty() && !includes_me {
        let only_placeholder = !raw_names.is_empty()
            && raw_names.iter().all(|n| {
                let t = n.trim();
                t.is_empty() || t == UNKNOWN_NAME
            });
        if has_explicit_zero_people
            || (raw_names.is_empty() && parsed_people <= 0)
            || only_placeholder
        {
            return None;
        }
    }
    let cleaned_names: Vec<String> = raw_names
        .iter()
        .filter_map(|n| {
            let t = n.trim();
            if t.is_empty() || t == UNKNOWN_NAME {
                None
            } else {
                Some(t.to_string())
            }
        })
        .collect();
    let effective_count = if raw_user_counts.is_empty() {
        raw_count
    } else {
        raw_user_counts.values().sum()
    };
    if effective_count <= 0 {
        return None;
    }
    let effective_people = if raw_user_counts.is_empty() {
        parsed_people
    } else {
        raw_user_counts.len() as i64
    };
    Some(Reaction {
        icon,
        count: effective_count,
        includes_me,
        names: cleaned_names,
        people: effective_people,
        user_counts: raw_user_counts,
    })
}

impl ChatMessage {
    /// `ChatMessage.init?(json:fallbackConversation:)`: `None` without a string id.
    pub fn from_json(json: &Map<String, Value>, fallback_conversation: &str) -> Option<Self> {
        let id = as_str(json.get("id"))
            .filter(|s| !s.is_empty())?
            .to_string();
        let quote = as_dict(json.get("quote")).map(|q| Quote {
            sender_name: as_str(q.get("senderName")).unwrap_or("").to_string(),
            text: as_str(q.get("text")).unwrap_or("").to_string(),
        });
        let reactions = as_dict_array(json.get("reactions"))
            .unwrap_or_default()
            .into_iter()
            .filter_map(reaction_from_json)
            .collect();
        let mentions = as_dict_array(json.get("mentions"))
            .unwrap_or_default()
            .into_iter()
            .filter_map(|m| {
                let uid = as_str(m.get("uid")).filter(|s| !s.is_empty())?.to_string();
                Some(Mention {
                    uid,
                    pos: clamped_int(ns_double(m.get("pos")).unwrap_or(0.0)),
                    len: clamped_int(ns_double(m.get("len")).unwrap_or(0.0)),
                    is_all: as_bool_cast(m.get("isAll")).unwrap_or(false),
                })
            })
            .collect();
        let empty = Map::new();
        let kind_dict = as_dict(json.get("kind")).unwrap_or(&empty);
        let string_array = |v: Option<&Value>| -> Option<Vec<String>> {
            let a = v?.as_array()?;
            a.iter().map(|x| x.as_str().map(str::to_string)).collect()
        };
        let raw_fallbacks = string_array(kind_dict.get("fallbacks"))
            .or_else(|| string_array(json.get("fallbacks")))
            .unwrap_or_default();
        let fallback_urls = raw_fallbacks
            .iter()
            .filter_map(|s| url_untrimmed(Some(&Value::String(s.clone()))))
            .collect();
        let str_or = |k: &str, d: &str| as_str(json.get(k)).unwrap_or(d).to_string();
        Some(Self {
            id,
            conversation_id: str_or("conversationId", fallback_conversation),
            sender_id: str_or("senderId", ""),
            sender_name: str_or("senderName", ""),
            sender_avatar: url_untrimmed(json.get("senderAvatar")),
            is_mine: as_bool_cast(json.get("isMine")).unwrap_or(false),
            kind: Kind::from_json(kind_dict),
            text: str_or("text", ""),
            date_ms: round_i64(ns_double(json.get("date")).unwrap_or(0.0)),
            status: Status::from_raw(as_str(json.get("status")).unwrap_or("")).unwrap_or_default(),
            quote,
            reactions,
            is_e2ee: as_bool_cast(json.get("isE2EE")).unwrap_or(false),
            mentions,
            card_buttons: CardButton::list(json.get("buttons")),
            suggests_stickers: as_bool_cast(json.get("stickers")).unwrap_or(false),
            menu: MessageMenu::from_json(json.get("menu")),
            fallback_urls,
            client_id: as_str(json.get("clientId"))
                .or_else(|| as_str(json.get("cliMsgId")))
                .unwrap_or("")
                .to_string(),
            text_styles: TextStyle::list(json.get("styles")),
            ttl_ms: round_i64(ns_double(json.get("ttl")).unwrap_or(0.0)).max(0),
        })
    }
}
