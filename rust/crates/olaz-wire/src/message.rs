//! `parseWireMessage` and the small pure helpers around it (message types, reactions, timestamps, previews).

use std::collections::HashSet;
use std::hash::{BuildHasher, Hasher};
use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::{Map, Value, json};

use crate::ids::{clean_group_id, group_conv_id, is_group_id, strip_user_prefix};
use crate::lossless::{self, int64, string};
use crate::model::{ChatMessage, Kind, ParsedWireEvent, ReactionIcon, StoredMessage, UNKNOWN_NAME};
use crate::signal::{is_signal_ciphertext, url_has_undecrypted_signal_cipher};
use crate::util::{
    as_bool_cast, as_dict, as_dict_array, first_non_empty, ns_bool, ns_double, pick, pick_opt,
};

/// `ZaloWebSocket.cmdPullMsgGroup`.
pub const CMD_PULL_MSG_GROUP: u16 = 511;
/// `ZaloWebSocket.cmdPushMsgGroup`.
pub const CMD_PUSH_MSG_GROUP: u16 = 521;

/// Signature of the `nameLookup` callback.
pub type NameLookupFn<'a> = dyn Fn(&str) -> Option<NameLookup> + 'a;

/// Result of the `nameLookup` callback: cached contact name and avatar.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct NameLookup {
    pub name: String,
    pub avatar: String,
}

/// Optional arguments of `parseWireMessage` / `extractBatchEvents`.
#[derive(Default, Clone, Copy)]
pub struct WireParseOptions<'a> {
    pub cmd: u16,
    pub fallback_conv_id: Option<&'a str>,
    pub is_group_hint: Option<bool>,
    pub self_conv_id: Option<&'a str>,
    pub name_lookup: Option<&'a NameLookupFn<'a>>,
}

fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

fn random_hex6() -> String {
    let v = std::collections::hash_map::RandomState::new()
        .build_hasher()
        .finish();
    format!("{:06X}", v & 0xFF_FFFF)
}

// MARK: - Pure helpers

/// `reactionSpec(forEmoji:)`: `(rIcon, rType)` the official client sends for an emoji.
pub fn reaction_spec(emoji: &str) -> (&'static str, i64) {
    let normalized = emoji.replace('\u{FE0F}', "");
    match normalized.trim() {
        "👍" | "/-strong" => ("/-strong", 3),
        "❤" | "/-heart" => ("/-heart", 5),
        "😆" | ":>" => (":>", 0),
        "😮" | ":o" => (":o", 32),
        "😢" | ":-((" | ":-(" => (":-((", 2),
        "😡" | "😠" | ":-h" => (":-h", 20),
        _ => ("/-strong", 3),
    }
}

/// `reactionIcon(rType:rIcon:)`.
pub fn reaction_icon(r_type: &str, r_icon: &str) -> Option<ReactionIcon> {
    let t = r_type.trim();
    let k = r_icon.trim();
    if let Ok(n) = t.parse::<i64>()
        && n < 0
    {
        return None;
    }
    if t == "3" || k == "/-strong" {
        return Some(ReactionIcon::new("3", "/-strong", "👍"));
    }
    if t == "5" || k == "/-heart" {
        return Some(ReactionIcon::new("5", "/-heart", "❤️"));
    }
    if t == "0" || k == ":>" {
        return Some(ReactionIcon::new("0", ":>", "😆"));
    }
    if t == "32" || k == ":o" {
        return Some(ReactionIcon::new("32", ":o", "😮"));
    }
    if t == "2" || k == ":-((" || k == ":-(" {
        return Some(ReactionIcon::new("2", ":-((", "😢"));
    }
    if t == "20" || k == ":-h" {
        return Some(ReactionIcon::new("20", ":-h", "😡"));
    }
    if k.is_empty() {
        return None;
    }
    let fallback_type = if t.is_empty() { k } else { t };
    Some(ReactionIcon::new(fallback_type, k, k))
}

/// `reactionClientMsgType(for:)`.
pub fn reaction_client_msg_type(kind: &Kind) -> i64 {
    match kind {
        Kind::Text => 1,
        Kind::Voice { .. } => 31,
        Kind::Photo { .. } => 32,
        Kind::Sticker { .. } => 36,
        Kind::Link { .. } | Kind::ContactCard(_) => 38,
        Kind::Location(_) => 43,
        Kind::Video { .. } => 44,
        Kind::File { .. } => 46,
        Kind::Gif { .. } => 49,
        _ => 1,
    }
}

/// `stickerCDNURL(cateId:stickerId:)`.
pub fn sticker_cdn_url(cate_id: i64, sticker_id: &str) -> String {
    let sid = sticker_id.trim();
    if sid.is_empty() {
        return String::new();
    }
    if cate_id == 0
        && let Ok(n) = sid.parse::<i64>()
        && (1..=30).contains(&n)
    {
        return format!("https://stc-chat.zdn.vn/images/stickers/default/thumb/{n}.png");
    }
    format!("https://api.zaloapp.com/api/emoticon/sticker/webpc?eid={sid}&size=130")
}

/// `normalizedMsgType`: numeric `msgType` codes to their string names.
pub fn normalized_msg_type(raw_type: &str) -> String {
    match raw_type.trim() {
        "1" => "webchat",
        "2" => "chat.photo",
        "3" => "chat.voice",
        "4" => "chat.video.msg",
        "5" => "chat.sticker",
        "19" => "share.file",
        "24" => "chat.location.new",
        "31" => "chat.undo",
        _ => return raw_type.to_string(),
    }
    .to_string()
}

/// `zdbMsgType(for:)`.
pub fn zdb_msg_type(code: i64) -> &'static str {
    match code {
        1 => "webchat",
        2 | 11 | 12 => "chat.photo",
        3 => "chat.voice",
        4 => "chat.sticker",
        5 => "chat.doodle",
        6 => "chat.recommended",
        7 => "chat.gif",
        17 => "chat.location.new",
        18 => "chat.video.msg",
        19 | 23 => "share.file",
        20 | 25 => "chat.ecard",
        21 => "chat.list.action",
        26 => "group.poll",
        52 => "chat.webcontent",
        53 => "chat.webcontent.v2",
        2511 | -4 => "group.event",
        _ => "webchat",
    }
}

/// `previewLabel(for:text:)`.
pub fn preview_label(kind_tag: &str, text: &str) -> String {
    let trimmed = text.trim();
    if !trimmed.is_empty() {
        return trimmed.to_string();
    }
    match kind_tag {
        "photo" => "[Hình ảnh]",
        "video" => "[Video]",
        "sticker" => "[Sticker]",
        "gif" => "[GIF]",
        "voice" => "[Tin nhắn thoại]",
        "file" => "[Tệp đính kèm]",
        "location" => "[Vị trí]",
        "contactCard" => "[Danh thiếp]",
        "call" => "Cuộc gọi thoại",
        "poll" => "[Bình chọn]",
        "ecard" => "[Thiệp]",
        "recalled" => "Tin nhắn đã được thu hồi",
        _ => "[Tin nhắn]",
    }
    .to_string()
}

/// `uniqueNonEmptyStrings`: trimmed, non-empty, first occurrence wins.
pub fn unique_non_empty_strings(values: &[String]) -> Vec<String> {
    let mut seen = HashSet::new();
    let mut out = Vec::new();
    for raw in values {
        let t = raw.trim();
        if !t.is_empty() && seen.insert(t.to_string()) {
            out.push(t.to_string());
        }
    }
    out
}

/// `normalizedFileName`: appends the extension unless the title already ends with it.
pub fn normalized_file_name(raw_title: &str, file_ext: &str) -> String {
    let title = raw_title.trim();
    let mut ext = file_ext.trim();
    while let Some(rest) = ext.strip_prefix('.') {
        ext = rest;
    }
    let ext: String = ext
        .chars()
        .filter(|c| c.is_alphabetic() || c.is_numeric() || *c == '-' || *c == '_')
        .collect();
    let base = if title.is_empty() {
        "Tệp đính kèm"
    } else {
        title
    };
    if ext.is_empty() {
        return base.to_string();
    }
    if base
        .to_lowercase()
        .ends_with(&format!(".{}", ext.to_lowercase()))
    {
        return base.to_string();
    }
    format!("{base}.{ext}")
}

/// `normalizeTimestampMs` with an explicit clock: missing / non-positive values become `now_ms`; seconds become ms.
pub fn normalize_timestamp_ms_at(value: Option<&Value>, now_ms: i64) -> i64 {
    match int64(value) {
        Some(raw) if raw > 0 => {
            if raw < 10_000_000_000 {
                raw.saturating_mul(1000)
            } else {
                raw
            }
        }
        _ => now_ms,
    }
}

/// `normalizeTimestampMs` using the system clock.
pub fn normalize_timestamp_ms(value: Option<&Value>) -> i64 {
    normalize_timestamp_ms_at(value, now_ms())
}

/// `optionalTimestampMs`: like the above but 0 when unknown.
pub fn optional_timestamp_ms(value: Option<&Value>) -> i64 {
    match int64(value) {
        Some(raw) if raw > 0 => {
            if raw < 10_000_000_000 {
                raw.saturating_mul(1000)
            } else {
                raw
            }
        }
        _ => 0,
    }
}

/// `doubleValue`: numbers, or a trimmed numeric string. Non-finite results count as missing.
fn double_value(value: Option<&Value>) -> Option<f64> {
    let d = match value? {
        Value::String(s) => s.trim().parse::<f64>().ok(),
        v => ns_double(Some(v)),
    }?;
    d.is_finite().then_some(d)
}

fn obj(v: Value) -> Map<String, Value> {
    match v {
        Value::Object(m) => m,
        _ => Map::new(),
    }
}

/// `x as? String`, also accepting a 15+ digit integer literal (what `JSONLossless` would have quoted).
fn as_string_lossless(v: Option<&Value>) -> Option<String> {
    match v? {
        Value::String(s) => Some(s.clone()),
        Value::Number(n) => {
            let t = n.to_string();
            (t.len() >= 15 && t.bytes().all(|b| b.is_ascii_digit())).then_some(t)
        }
        _ => None,
    }
}

/// `JSONLossless.parseAny` on a string, like the `trimmed.hasPrefix("{"/"[")` call sites.
pub(crate) fn parse_nested(s: &str) -> Option<Value> {
    let t = s.trim();
    if t.starts_with('{') || t.starts_with('[') {
        lossless::parse_any(t.as_bytes())
    } else {
        None
    }
}

struct Dicts<'a> {
    cd: Option<&'a Map<String, Value>>,
    cp: Option<&'a Map<String, Value>>,
}

impl<'a> Dicts<'a> {
    fn d(&self, k: &str) -> Option<&'a Value> {
        self.cd.and_then(|m| m.get(k))
    }
    fn p(&self, k: &str) -> Option<&'a Value> {
        self.cp.and_then(|m| m.get(k))
    }
    fn ds(&self, k: &str) -> String {
        string(self.d(k))
    }
    fn ps(&self, k: &str) -> String {
        string(self.p(k))
    }
}

fn content_dict_of(raw_content: Option<&Value>) -> Option<Map<String, Value>> {
    match raw_content? {
        Value::Object(m) => Some(m.clone()),
        Value::Array(_) => as_dict_array(raw_content)?.first().map(|m| (*m).clone()),
        Value::String(s) => {
            let t = s.trim();
            if t.starts_with('{') {
                return lossless::parse_object(t.as_bytes());
            }
            if t.starts_with('[')
                && let Some(parsed) = lossless::parse_any(t.as_bytes())
                && let Some(arr) = as_dict_array(Some(&parsed))
                && let Some(first) = arr.first()
            {
                return Some((*first).clone());
            }
            None
        }
        _ => None,
    }
}

fn duration_seconds(raw: i64) -> i64 {
    if raw > 10_000 { raw / 1000 } else { raw }
}

// MARK: - parseWireMessage

/// Parses one wire message dictionary (HTTP history row or `zpw_ws` push body) into an event.
pub fn parse_wire_message(
    raw: &Map<String, Value>,
    my_uid: &str,
    opts: &WireParseOptions<'_>,
) -> ParsedWireEvent {
    let uid_from = strip_user_prefix(&string(pick(raw, &["uidFrom", "senderId"])));
    let id_to_raw = string(pick(raw, &["idTo", "toId", "convId", "grid"]));
    let msg_id = string(pick(raw, &["msgId", "globalMsgId", "id"]));
    let cli_msg_id = string(pick(raw, &["cliMsgId", "clientId"]));
    let raw_msg_type = string(pick(raw, &["msgType", "type"]));
    let msg_type = normalized_msg_type(&raw_msg_type);

    let sanitized_fallback: Option<String> = opts.fallback_conv_id.and_then(|f| {
        let f = f.trim();
        (!f.is_empty() && f != "0" && f != "g0").then(|| f.to_string())
    });
    let self_conv = opts.self_conv_id;

    let inferred_group = if let Some(h) = opts.is_group_hint {
        h
    } else if opts.cmd == CMD_PUSH_MSG_GROUP
        || opts.cmd == CMD_PULL_MSG_GROUP
        || is_group_id(&id_to_raw)
        || sanitized_fallback.as_deref().is_some_and(is_group_id)
    {
        true
    } else if let Some(g) = as_bool_cast(raw.get("isGroup")) {
        g
    } else {
        as_string_lossless(raw.get("grid"))
            .is_some_and(|grid| !grid.is_empty() && clean_group_id(&grid) != "0")
    };

    let clean_id_to = clean_group_id(&id_to_raw);
    let is_explicit_self_cloud = self_conv.is_some_and(|s| {
        !s.is_empty() && (sanitized_fallback.as_deref() == Some(s) || clean_id_to == s)
    });
    let is_self_cloud_envelope = is_explicit_self_cloud
        || (!inferred_group
            && (id_to_raw == "0" || id_to_raw.is_empty())
            && (uid_from == "0" || uid_from.is_empty()));

    let is_mine = is_self_cloud_envelope
        || uid_from == my_uid
        || uid_from == "0"
        || as_bool_cast(raw.get("isMine")) == Some(true);

    let conv_id: String = 'conv: {
        if is_explicit_self_cloud && let Some(s) = self_conv {
            break 'conv s.to_string();
        }
        if inferred_group {
            let raw_group = if !id_to_raw.is_empty() && id_to_raw != "0" {
                id_to_raw.clone()
            } else {
                sanitized_fallback.clone().unwrap_or_default()
            };
            let g = group_conv_id(&raw_group);
            if !g.is_empty() {
                break 'conv g;
            }
            if let Some(f) = &sanitized_fallback
                && is_group_id(f)
            {
                break 'conv f.clone();
            }
        }
        if is_self_cloud_envelope {
            break 'conv first_non_empty(&[
                self_conv.unwrap_or(""),
                sanitized_fallback.as_deref().unwrap_or(""),
                my_uid,
            ]);
        }
        if let Some(s) = self_conv
            && !s.is_empty()
            && (id_to_raw == s || (uid_from == my_uid && id_to_raw == my_uid))
        {
            break 'conv s.to_string();
        }
        if is_mine {
            if !id_to_raw.is_empty() && id_to_raw != "0" && id_to_raw != my_uid {
                break 'conv strip_user_prefix(&id_to_raw);
            }
            if let Some(f) = &sanitized_fallback {
                break 'conv strip_user_prefix(f);
            }
            break 'conv first_non_empty(&[self_conv.unwrap_or(""), my_uid]);
        }
        if !uid_from.is_empty() && uid_from != "0" && uid_from != my_uid {
            break 'conv uid_from.clone();
        }
        if let Some(f) = &sanitized_fallback {
            break 'conv strip_user_prefix(f);
        }
        strip_user_prefix(&id_to_raw)
    };

    if conv_id.is_empty() || conv_id == "0" || conv_id == "g0" {
        return ParsedWireEvent::Ignore;
    }

    // Content may arrive as a string, parsed JSON dict, or array of photo items (`MSG.PHOTO_GROUP`).
    let raw_content = raw.get("content");
    let content_dict = content_dict_of(raw_content);
    let content_params: Option<Map<String, Value>> =
        content_dict.as_ref().and_then(|cd| match cd.get("params") {
            Some(Value::Object(p)) => Some(p.clone()),
            Some(Value::String(s)) => lossless::parse_object(s.as_bytes()),
            _ => None,
        });
    let dd = Dicts {
        cd: content_dict.as_ref(),
        cp: content_params.as_ref(),
    };

    // Control message types
    match msg_type.as_str() {
        "chat.undo" => {
            let undo_msg_id = match pick_opt(dd.cd, &["globalMsgId"]).or(raw.get("globalMsgId")) {
                Some(v) => string(Some(v)),
                None => msg_id.clone(),
            };
            let undo_cli_id = match pick_opt(dd.cd, &["cliMsgId"]).or(raw.get("cliMsgId")) {
                Some(v) => string(Some(v)),
                None => cli_msg_id.clone(),
            };
            return ParsedWireEvent::Undo {
                conv_id,
                msg_id: undo_msg_id,
                cli_msg_id: undo_cli_id,
            };
        }
        "chat.delete" => {
            let del_msg_id = match pick_opt(dd.cd, &["globalDelMsgId", "globalMsgId"]) {
                Some(v) => string(Some(v)),
                None => msg_id.clone(),
            };
            let del_cli_id = match pick_opt(dd.cd, &["clientDelMsgId", "cliMsgId"]) {
                Some(v) => string(Some(v)),
                None => cli_msg_id.clone(),
            };
            return ParsedWireEvent::Delete {
                conv_id,
                msg_id: del_msg_id,
                cli_msg_id: del_cli_id,
            };
        }
        "chat.reaction" => {
            let r_msg_raw: Option<Value> = dd.d("rMsg").map(|raw_r| {
                if let Value::String(s) = raw_r
                    && let Some(parsed) = parse_nested(s)
                {
                    return parsed;
                }
                raw_r.clone()
            });
            let (target_msg_id, target_cli_id);
            let from_array: Option<Vec<&Map<String, Value>>> = match r_msg_raw.as_ref() {
                Some(Value::Array(a)) => Some(a.iter().filter_map(Value::as_object).collect()),
                _ => None,
            };
            let key_ids = |m: &Map<String, Value>| {
                (
                    string(pick(m, &["gMsgID", "msgId", "globalMsgId"])),
                    string(pick(m, &["cMsgID", "cliMsgId", "clientId"])),
                )
            };
            if let Some(first) = from_array.as_ref().and_then(|v| v.first()) {
                (target_msg_id, target_cli_id) = key_ids(first);
            } else if let Some(Value::Object(single)) = r_msg_raw.as_ref() {
                (target_msg_id, target_cli_id) = key_ids(single);
            } else {
                let scalar = if matches!(r_msg_raw, Some(Value::String(_))) {
                    string(r_msg_raw.as_ref())
                } else {
                    String::new()
                };
                target_msg_id = first_non_empty(&[
                    &string(pick_opt(dd.cd, &["gMsgID", "msgId", "globalMsgId"])),
                    &scalar,
                ]);
                target_cli_id = string(pick_opt(dd.cd, &["cMsgID", "cliMsgId", "clientId"]));
            }
            let r_icon = dd.ds("rIcon");
            let r_type = dd.ds("rType");
            if (target_msg_id.is_empty() && target_cli_id.is_empty())
                || (r_type.is_empty() && r_icon.is_empty())
            {
                return ParsedWireEvent::Ignore;
            }
            let event_id = first_non_empty(&[&string(raw.get("actionId")), &msg_id, &cli_msg_id]);
            let sender_alt = strip_user_prefix(&string(
                raw.get("fromUid")
                    .or_else(|| pick_opt(dd.cd, &["uidFrom", "fromUid"])),
            ));
            let reaction_sender = first_non_empty(&[&uid_from, &sender_alt]);
            let ts = pick(raw, &["ts", "time", "sendTime"]).or(dd.d("ts"));
            let seq = int64(pick(raw, &["actionId", "msgId", "cliMsgId"])).unwrap_or(0);
            let sender_name = string(pick(raw, &["dName", "senderName"]).or(dd.d("dName")));
            return ParsedWireEvent::Reaction {
                conv_id,
                msg_id: target_msg_id,
                cli_msg_id: target_cli_id,
                sender_id: reaction_sender,
                r_type,
                r_icon,
                event_id,
                react_client_id: cli_msg_id,
                ts_ms: optional_timestamp_ms(ts),
                seq_id: seq,
                sender_name,
            };
        }
        _ => {}
    }

    let stable_id = if !msg_id.is_empty() && msg_id != "0" {
        msg_id.clone()
    } else if !cli_msg_id.is_empty() {
        cli_msg_id.clone()
    } else {
        format!("{}_{}", now_ms(), random_hex6())
    };

    let ts_ms = normalize_timestamp_ms(pick(raw, &["ts", "time", "sendTime", "date"]));

    let lookup: Option<NameLookup> = if uid_from.is_empty() || uid_from == "0" {
        None
    } else {
        opts.name_lookup.and_then(|f| f(&uid_from))
    };
    let wire_sender_name = string(pick(raw, &["dName", "senderName"]));
    let resolved_contact_name = match &lookup {
        Some(l) if !l.name.is_empty() && l.name != uid_from && l.name != UNKNOWN_NAME => {
            l.name.clone()
        }
        _ => String::new(),
    };
    let sender_name = first_non_empty(&[
        if is_mine {
            "Bạn"
        } else {
            &resolved_contact_name
        },
        &wire_sender_name,
        lookup.as_ref().map(|l| l.name.as_str()).unwrap_or(""),
        if is_mine { "Bạn" } else { UNKNOWN_NAME },
    ]);
    let sender_avatar = first_non_empty(&[
        lookup.as_ref().map(|l| l.avatar.as_str()).unwrap_or(""),
        &string(pick(raw, &["avt", "senderAvatar"])),
    ]);

    let mut text_body: String;
    let mut kind_dict: Map<String, Value>;
    let mut kind_tag = "text".to_string();
    let mut buttons: Vec<Value> = Vec::new();
    let mut suggests_stickers = false;
    let raw_content_str = raw_content.and_then(Value::as_str);

    match msg_type.as_str() {
        "" | "webchat" | "chat.text" => {
            if let (Some(s), None) = (raw_content_str, &content_dict) {
                text_body = s.to_string();
            } else if dd.ds("action") == "rtf" {
                text_body =
                    first_non_empty(&[&dd.ps("text"), &dd.ds("title"), &dd.ds("description")]);
            } else {
                text_body = string(pick_opt(dd.cd, &["title", "msg", "text"]).or(raw.get("text")));
            }
            kind_dict = obj(json!({"type": "text"}));
            kind_tag = "text".into();
        }
        "chat.photo" | "chat.doodle" => {
            let candidates = unique_non_empty_strings(&[
                dd.ps("hd"),
                dd.ps("hdUrl"),
                dd.ds("hd"),
                dd.ds("hdUrl"),
                dd.ps("rawUrl"),
                dd.ds("oriUrl"),
                dd.ds("rawUrl"),
                dd.ds("normalUrl"),
                dd.ds("href"),
                dd.ds("url"),
                dd.ds("fileUrl"),
                dd.ds("thumb"),
                dd.ds("thumbUrl"),
                dd.ps("thumb"),
            ]);
            let url = candidates.first().cloned().unwrap_or_default();
            let fallbacks: Vec<String> = candidates.iter().skip(1).cloned().collect();
            let w = int64(dd.p("width").or(dd.d("width"))).unwrap_or(0);
            let h = int64(dd.p("height").or(dd.d("height"))).unwrap_or(0);
            text_body = first_non_empty(&[&dd.ds("title"), &dd.ds("description")]);
            if text_body == "[Hình ảnh]" {
                text_body.clear();
            }
            let mut p = obj(json!({"type": "photo", "url": url, "width": w, "height": h}));
            if !fallbacks.is_empty() {
                p.insert("fallbacks".into(), json!(fallbacks));
            }
            kind_dict = p;
            kind_tag = "photo".into();
        }
        "chat.sticker" => {
            let sticker_id = string(
                pick_opt(dd.cd, &["id", "stickerId"])
                    .or_else(|| pick_opt(dd.cp, &["id", "stickerId"])),
            );
            let cate_id = int64(
                pick_opt(dd.cd, &["catId", "cateId"])
                    .or_else(|| pick_opt(dd.cp, &["catId", "cateId"])),
            )
            .unwrap_or(-1);
            let url = first_non_empty(&[
                &dd.ds("stickerUrl"),
                &dd.ds("href"),
                &sticker_cdn_url(cate_id, &sticker_id),
            ]);
            kind_dict = obj(json!({"type": "sticker", "url": url}));
            kind_tag = "sticker".into();
            text_body = "[Sticker]".into();
        }
        "chat.gif" => {
            let url = first_non_empty(&[
                &dd.ds("href"),
                &dd.ds("oriUrl"),
                &dd.ds("hd"),
                &dd.ds("hdUrl"),
                &dd.ds("normalUrl"),
                &dd.ds("thumb"),
                &dd.ds("thumbUrl"),
            ]);
            kind_dict = obj(json!({"type": "gif", "url": url}));
            kind_tag = "gif".into();
            text_body = "[GIF]".into();
        }
        "chat.video.msg" => {
            let candidates = unique_non_empty_strings(&[
                dd.ds("href"),
                dd.ds("fileUrl"),
                dd.ds("videoUrl"),
                dd.ds("url"),
                dd.ds("oriUrl"),
                dd.ds("hd"),
                dd.ds("hdUrl"),
                dd.ds("normalUrl"),
                dd.ps("fileUrl"),
                dd.ps("hd"),
                dd.ps("href"),
            ]);
            let url = candidates.first().cloned().unwrap_or_default();
            let fallbacks: Vec<String> = candidates.iter().skip(1).cloned().collect();
            let thumb = first_non_empty(&[&dd.ds("thumb"), &dd.ds("thumbUrl"), &dd.ps("thumb")]);
            let dur = duration_seconds(int64(dd.p("duration").or(dd.d("duration"))).unwrap_or(0));
            text_body = dd.ds("title");
            let mut v =
                obj(json!({"type": "video", "thumbnail": thumb, "duration": dur, "url": url}));
            if !fallbacks.is_empty() {
                v.insert("fallbacks".into(), json!(fallbacks));
            }
            kind_dict = v;
            kind_tag = "video".into();
        }
        "chat.voice" => {
            let url = first_non_empty(&[
                &dd.ds("href"),
                &dd.ds("oriUrl"),
                &dd.ds("voiceUrl"),
                &dd.ds("fileUrl"),
                &dd.ps("m4a"),
            ]);
            let dur = duration_seconds(int64(dd.p("duration").or(dd.d("duration"))).unwrap_or(0));
            kind_dict = obj(json!({"type": "voice", "url": url, "duration": dur}));
            kind_tag = "voice".into();
            text_body = "[Tin nhắn thoại]".into();
        }
        "share.file" => {
            let url = first_non_empty(&[
                &dd.ds("href"),
                &dd.ds("fileUrl"),
                &dd.ds("url"),
                &dd.ps("href"),
                &dd.ps("fileUrl"),
                &dd.ps("url"),
            ]);
            let raw_title = first_non_empty(&[&dd.ds("title"), &dd.ps("fileName"), "Tệp đính kèm"]);
            let raw_ext = string(dd.p("fileExt").or(dd.d("fileExt")));
            let file_name = normalized_file_name(&raw_title, &raw_ext);
            let size = int64(dd.p("fileSize").or(dd.d("fileSize"))).unwrap_or(0);
            kind_dict = obj(json!({"type": "file", "name": file_name, "size": size, "url": url}));
            kind_tag = "file".into();
            text_body = file_name;
        }
        "chat.recommended" => {
            let action = dd.ds("action");
            match action.as_str() {
                "recommened.link" | "recommended.link" => {
                    let url = dd.ds("href");
                    let title = first_non_empty(&[&dd.ds("title"), &url]);
                    let src = string(dd.p("src").or(dd.d("src")));
                    kind_dict = obj(json!({
                        "type": "link", "title": title, "url": url, "thumbnail": dd.ds("thumb"),
                        "description": dd.ds("description"), "source": src
                    }));
                    kind_tag = "link".into();
                    text_body = title;
                }
                "recommened.user" | "recommened.vip" | "recommended.user" => {
                    let raw_params_str = dd
                        .d("params")
                        .and_then(Value::as_str)
                        .map(str::trim)
                        .unwrap_or("");
                    let plain_param_uid = if content_params.is_none()
                        && !raw_params_str.is_empty()
                        && !raw_params_str.starts_with('{')
                    {
                        strip_user_prefix(raw_params_str)
                    } else {
                        String::new()
                    };
                    let card_uid =
                        first_non_empty(&[&dd.ps("uid"), &plain_param_uid, &dd.ds("title")]);
                    let card_name = first_non_empty(&[
                        &dd.ps("userName"),
                        &if plain_param_uid.is_empty() {
                            String::new()
                        } else {
                            dd.ds("title")
                        },
                        &dd.ds("description"),
                        &card_uid,
                    ]);
                    let avatar = string(dd.d("thumb").or(dd.p("avatar")));
                    let is_oa = action == "recommened.vip";
                    kind_dict = obj(json!({
                        "type": "contactCard", "name": card_name, "uid": card_uid, "avatar": avatar,
                        "phone": dd.ps("phone"), "qr": dd.ps("qr"), "oaLink": dd.ps("oaLink"), "isOA": is_oa
                    }));
                    kind_tag = "contactCard".into();
                    text_body = format!("[Danh thiếp] {card_name}");
                }
                "recommened.calltime" | "recommened.misscall" => {
                    let missed = action == "recommened.misscall";
                    let call_type = int64(dd.p("callType").or(dd.p("type"))).unwrap_or(0);
                    let is_video =
                        call_type == 2 || dd.ps("callType").to_lowercase().contains("video");
                    let dur = int64(dd.p("duration")).unwrap_or(0);
                    let title = match (is_video, missed) {
                        (true, true) => "Cuộc gọi video nhỡ",
                        (true, false) => "Cuộc gọi video",
                        (false, true) => "Cuộc gọi nhỡ",
                        (false, false) => "Cuộc gọi thoại",
                    };
                    kind_dict = obj(json!({
                        "type": "call", "video": is_video, "missed": missed, "duration": dur,
                        "title": title, "detail": ""
                    }));
                    kind_tag = "call".into();
                    text_body = title.to_string();
                    buttons =
                        vec![json!({"ref": "call:back", "label": "Gọi lại", "enabled": true})];
                }
                "rtf" => {
                    kind_dict = obj(json!({"type": "text"}));
                    kind_tag = "text".into();
                    text_body =
                        first_non_empty(&[&dd.ps("text"), &dd.ds("title"), &dd.ds("description")]);
                }
                "msginfo.actionlist" => {
                    kind_dict = obj(json!({"type": "system"}));
                    kind_tag = "system".into();
                    text_body = first_non_empty(&[
                        &dd.ds("title"),
                        &dd.ds("description"),
                        "Thông báo hệ thống",
                    ]);
                }
                _ => {
                    let url = dd.ds("href");
                    let title = dd.ds("title");
                    if !url.is_empty() {
                        let shown = if title.is_empty() {
                            url.clone()
                        } else {
                            title.clone()
                        };
                        kind_dict = obj(json!({
                            "type": "link", "title": shown, "url": url, "thumbnail": dd.ds("thumb"),
                            "description": dd.ds("description"), "source": ""
                        }));
                        kind_tag = "link".into();
                        text_body = shown;
                    } else {
                        kind_dict = obj(json!({"type": "text"}));
                        text_body = first_non_empty(&[&title, &dd.ds("description"), "[Tin nhắn]"]);
                    }
                }
            }
        }
        "chat.location.new" | "chat.location" => {
            let lat =
                double_value(pick_opt(dd.cp, &["lat", "latitude"]).or(dd.d("lat"))).unwrap_or(0.0);
            let lon = double_value(
                pick_opt(dd.cp, &["lon", "lo", "lng", "longitude"])
                    .or(pick_opt(dd.cd, &["lo", "lon"])),
            )
            .unwrap_or(0.0);
            let title = first_non_empty(&[&dd.ps("locationName"), &dd.ds("title"), "Vị trí"]);
            let address = string(dd.p("address").or(dd.d("description")));
            kind_dict = obj(json!({
                "type": "location", "title": title, "address": address,
                "hasCoordinates": lat != 0.0 || lon != 0.0,
                "latitude": lat, "longitude": lon, "thumbnail": dd.ds("thumb")
            }));
            kind_tag = "location".into();
            text_body = title;
        }
        "chat.ecard" => {
            let action = dd.ds("action");
            let style = if action.contains("reminder") {
                "reminder"
            } else if action.contains("birthday") {
                "birthday"
            } else if action.contains("friend") {
                "friend"
            } else {
                "banner"
            };
            let title = dd.ds("title");
            let desc = dd.ds("description");
            suggests_stickers = dd
                .p("stickerList")
                .and_then(Value::as_array)
                .is_some_and(|a| !a.is_empty())
                || style == "friend"
                || style == "birthday";
            let reminder_title = match dd.p("topicTitle") {
                Some(v) => string(Some(v)),
                None => title.clone(),
            };
            kind_dict = obj(json!({
                "type": "ecard", "style": style, "image": dd.ds("href"), "thumb": dd.ds("thumb"),
                "title": title, "description": desc, "reminderTitle": reminder_title,
                "reminderStart": int64(dd.p("startTime")).unwrap_or(0),
                "reminderRepeat": dd.ps("repeatLabel")
            }));
            kind_tag = "ecard".into();
            text_body = first_non_empty(&[&title, &desc, "[Thiệp]"]);
        }
        "group.poll" | "chat.poll" => {
            let poll_id = string(pick_opt(dd.cp, &["poll_id", "pollId"]).or(dd.d("pollId")));
            let question =
                first_non_empty(&[&string(dd.p("question").or(dd.d("title"))), "Bình chọn"]);
            kind_dict = obj(json!({
                "type": "poll", "question": question, "header": dd.ds("description"),
                "anonymous": ns_bool(dd.p("is_anonymous")).unwrap_or(false),
                "pollId": poll_id, "conversationId": conv_id
            }));
            kind_tag = "poll".into();
            text_body = question;
        }
        "group.event" | "chat.sys" => {
            let title =
                first_non_empty(&[&dd.ds("title"), &dd.ds("description"), "Thông báo hệ thống"]);
            kind_dict = obj(json!({"type": "system"}));
            kind_tag = "system".into();
            text_body = title;
        }
        "chat.list.action" => {
            let items = as_dict_array(raw_content)
                .or_else(|| as_dict_array(dd.d("items")))
                .unwrap_or_default();
            let first_item: Option<&Map<String, Value>> = items.first().copied().or(dd.cd);
            let title = string(first_item.and_then(|m| m.get("title")));
            let desc = string(first_item.and_then(|m| m.get("description")));
            let combined = if !title.is_empty() && !desc.is_empty() && title != desc {
                format!("{title}\n{desc}")
            } else {
                first_non_empty(&[&title, &desc, "[Thông báo]"])
            };
            kind_dict = obj(json!({"type": "text"}));
            kind_tag = "text".into();
            text_body = combined;
        }
        "chat.webcontent" | "chat.webcontent.v2" => {
            let mut z_title = first_non_empty(&[&dd.ds("title"), &dd.ds("description")]);
            let vi_en = |custom: &Map<String, Value>| {
                first_non_empty(&[&string(custom.get("vi")), &string(custom.get("en"))])
            };
            if z_title.is_empty()
                && let Some(z_msg) = dd.d("zinstant_msg").and_then(Value::as_str)
                && let Some(z_obj) = lossless::parse_object(z_msg.as_bytes())
                && let Some(custom) =
                    as_dict(z_obj.get("customMsg")).and_then(|c| as_dict(c.get("msg")))
            {
                z_title = vi_en(custom);
            }
            if z_title.is_empty()
                && let Some(custom) = as_dict(dd.p("customMsg")).and_then(|c| as_dict(c.get("msg")))
            {
                z_title = vi_en(custom);
            }
            kind_dict = obj(json!({"type": "text"}));
            kind_tag = "text".into();
            text_body = first_non_empty(&[&z_title, "[Thẻ thông tin]"]);
        }
        _ => {
            if let (Some(s), None) = (raw_content_str, &content_dict)
                && !s.is_empty()
            {
                kind_dict = obj(json!({"type": "text"}));
                kind_tag = "text".into();
                text_body = s.to_string();
            } else {
                kind_dict = obj(json!({"type": "unsupported", "rawType": msg_type}));
                kind_tag = "unsupported".into();
                text_body = first_non_empty(&[
                    &dd.ds("title"),
                    &dd.ds("description"),
                    &format!("[{msg_type}]"),
                ]);
            }
        }
    }

    // Mentions
    let mut mentions: Vec<Value> = Vec::new();
    let raw_mentions =
        as_dict_array(raw.get("mentions")).or_else(|| as_dict_array(dd.d("mentions")));
    if let Some(list) = raw_mentions {
        for m in list {
            let m_uid = strip_user_prefix(&string(m.get("uid")));
            if m_uid.is_empty() {
                continue;
            }
            let pos = int64(m.get("pos")).unwrap_or(0);
            let len = int64(m.get("len")).unwrap_or(0);
            let is_all = int64(m.get("type")) == Some(1)
                || m_uid == "-1"
                || as_bool_cast(m.get("isAll")) == Some(true);
            mentions.push(json!({"uid": m_uid, "pos": pos, "len": len, "isAll": is_all}));
        }
    }

    // Quote
    let mut quote: Option<Value> = None;
    if let Some(q) = as_dict(raw.get("quote")) {
        let q_owner = strip_user_prefix(&string(pick(q, &["ownerId", "senderId"])));
        let q_lookup_name = if q_owner.is_empty() || q_owner == "0" {
            String::new()
        } else {
            match opts.name_lookup.and_then(|f| f(&q_owner)) {
                Some(l) if !l.name.is_empty() && l.name != q_owner && l.name != UNKNOWN_NAME => {
                    l.name
                }
                _ => String::new(),
            }
        };
        let q_is_me = q_owner == my_uid;
        let raw_q_name = first_non_empty(&[
            if q_is_me { "Bạn" } else { &q_lookup_name },
            &string(pick(q, &["fromD", "senderName"])),
            if q_is_me { "Bạn" } else { UNKNOWN_NAME },
        ]);
        let q_name = if is_signal_ciphertext(&raw_q_name) {
            (if q_is_me { "Bạn" } else { UNKNOWN_NAME }).to_string()
        } else {
            raw_q_name
        };
        let raw_q_text = first_non_empty(&[&string(pick(q, &["msg", "text"])), "[Tin nhắn]"]);
        let q_text = if is_signal_ciphertext(&raw_q_text) {
            "[Tin nhắn mã hóa đầu cuối]".to_string()
        } else {
            raw_q_text
        };
        if !q_name.is_empty() || !q_text.is_empty() {
            quote = Some(json!({"senderName": q_name, "text": q_text}));
        }
    }

    // Detect any E2EE payload whose Signal ciphertext could not be decrypted on this device yet.
    let mut is_e2ee_flag = msg_type.contains("e2ee")
        || as_bool_cast(raw.get("isE2EE")) == Some(true)
        || int64(raw.get("e2eeStatus")) == Some(1);
    let mut is_undecrypted_e2ee = false;

    let kind_url = string(kind_dict.get("url"));
    let kind_file_name = string(kind_dict.get("name"));
    let placeholder =
        |text: String| obj(json!({"type": "placeholder", "symbol": "lock.fill", "text": text}));
    if kind_tag == "text" && is_signal_ciphertext(&text_body) {
        is_e2ee_flag = true;
        is_undecrypted_e2ee = true;
        kind_dict = placeholder("Tin nhắn mã hóa đầu cuối — Đồng bộ từ điện thoại để xem".into());
        kind_tag = "placeholder".into();
        text_body = "🔒 Tin nhắn mã hóa đầu cuối".into();
    } else if kind_tag == "sticker"
        && (is_signal_ciphertext(&kind_url) || url_has_undecrypted_signal_cipher(&kind_url))
    {
        is_e2ee_flag = true;
        is_undecrypted_e2ee = true;
        kind_dict = placeholder("Sticker mã hóa đầu cuối — Đồng bộ từ điện thoại để xem".into());
        kind_tag = "placeholder".into();
        text_body = "[Sticker]".into();
    } else if ["photo", "video", "voice", "file", "gif"].contains(&kind_tag.as_str())
        && (is_signal_ciphertext(&kind_url)
            || url_has_undecrypted_signal_cipher(&kind_url)
            || is_signal_ciphertext(&kind_file_name))
    {
        is_e2ee_flag = true;
        is_undecrypted_e2ee = true;
        let media_title = match kind_tag.as_str() {
            "photo" => "Hình ảnh",
            "video" => "Video",
            "voice" => "Tin nhắn thoại",
            "file" => "Tệp đính kèm",
            "gif" => "GIF",
            _ => "Nội dung",
        };
        kind_dict = placeholder(format!(
            "{media_title} mã hóa đầu cuối — Đồng bộ từ điện thoại để xem"
        ));
        kind_tag = "placeholder".into();
        text_body = format!("[{media_title}]");
    } else if is_signal_ciphertext(&text_body) {
        is_e2ee_flag = true;
        text_body.clear();
    }

    // Context menu defaults
    let can_recall = is_mine
        && !is_self_cloud_envelope
        && !["call", "system", "notice", "recalled", "placeholder"].contains(&kind_tag.as_str());
    let menu = json!({
        "forward": if is_undecrypted_e2ee { "blocked" } else { "ok" },
        "recall": can_recall,
        "delete": if is_self_cloud_envelope { "plain" } else { "forMe" },
        "pin": inferred_group && !is_self_cloud_envelope && !is_undecrypted_e2ee,
        "star": "star",
        "starred": false,
        "pinned": false,
        "protected": false
    });

    let mut canonical = obj(json!({
        "id": stable_id,
        "clientId": cli_msg_id,
        "conversationId": conv_id,
        "senderId": uid_from,
        "senderName": sender_name,
        "senderAvatar": sender_avatar,
        "isMine": is_mine,
        "kind": Value::Object(kind_dict),
        "text": text_body,
        "date": ts_ms,
        "status": "sent",
        "reactions": [],
        "isE2EE": is_e2ee_flag,
        "mentions": mentions,
        "buttons": buttons,
        "stickers": suggests_stickers,
        "menu": menu
    }));
    if is_undecrypted_e2ee {
        canonical.insert("undecryptedE2EE".into(), Value::Bool(true));
    }
    if let Some(q) = quote {
        canonical.insert("quote".into(), q);
    }

    let Ok(raw_json_data) = serde_json::to_vec(&canonical) else {
        return ParsedWireEvent::Ignore;
    };
    let Some(chat_message) = ChatMessage::from_json(&canonical, &conv_id) else {
        return ParsedWireEvent::Ignore;
    };
    let stored = StoredMessage {
        id: stable_id,
        conv_id,
        client_id: cli_msg_id,
        sender_id: uid_from,
        sender_name,
        sender_avatar,
        is_mine,
        text: text_body,
        kind_tag,
        ts_ms,
        status: if is_undecrypted_e2ee {
            "e2ee_locked"
        } else {
            "sent"
        }
        .to_string(),
        raw_json_data,
    };
    ParsedWireEvent::Message(Box::new(chat_message), Box::new(stored))
}
