//! `StoredMessage` <-> `ChatMessage` round trip (`decodeStoredMessage`, `encodeChatMessage`, `serializeKind`).

use serde_json::{Map, Value, json};

use crate::model::{Availability, ChatMessage, DeleteMode, Kind, StarMode, StoredMessage, TextStyle};

fn opt(url: &Option<String>) -> &str {
    url.as_deref().unwrap_or("")
}

/// `serializeKind`: the canonical `kind` JSON object and its kind tag.
pub fn serialize_kind(kind: &Kind) -> (Map<String, Value>, &'static str) {
    let (v, tag) = match kind {
        Kind::Text => (json!({"type": "text"}), "text"),
        Kind::Photo { url, width, height } => (
            json!({"type": "photo", "url": opt(url), "width": width, "height": height}),
            "photo",
        ),
        Kind::Sticker { url } => (json!({"type": "sticker", "url": opt(url)}), "sticker"),
        Kind::Gif { url } => (json!({"type": "gif", "url": opt(url)}), "gif"),
        Kind::Video {
            thumbnail,
            duration,
            url,
        } => (
            json!({"type": "video", "thumbnail": opt(thumbnail), "duration": duration, "url": opt(url)}),
            "video",
        ),
        Kind::Voice { url, duration } => (
            json!({"type": "voice", "url": opt(url), "duration": duration}),
            "voice",
        ),
        Kind::File { name, size, url } => (
            json!({"type": "file", "name": name, "size": size, "url": opt(url)}),
            "file",
        ),
        Kind::Link {
            title,
            url,
            thumbnail,
            description,
            source,
        } => (
            json!({
                "type": "link", "title": title, "url": opt(url), "thumbnail": opt(thumbnail),
                "description": description, "source": source
            }),
            "link",
        ),
        Kind::ContactCard(c) => (
            json!({
                "type": "contactCard", "name": c.name, "uid": c.uid, "avatar": opt(&c.avatar),
                "phone": c.phone, "qr": opt(&c.qr), "oaLink": c.oa_link, "isOA": c.is_official_account
            }),
            "contactCard",
        ),
        Kind::Location(info) => (
            json!({
                "type": "location", "title": info.title, "address": info.address,
                "hasCoordinates": info.coordinate.is_some(),
                "latitude": info.coordinate.map_or(0.0, |c| c.0),
                "longitude": info.coordinate.map_or(0.0, |c| c.1),
                "thumbnail": opt(&info.thumbnail)
            }),
            "location",
        ),
        Kind::Call {
            video,
            missed,
            duration,
            title,
            detail,
        } => (
            json!({
                "type": "call", "video": video, "missed": missed, "duration": duration,
                "title": title, "detail": detail
            }),
            "call",
        ),
        Kind::Ecard(card) => (
            json!({
                "type": "ecard", "style": card.style.raw_value(), "image": opt(&card.image),
                "thumb": opt(&card.thumb), "title": card.title, "description": card.description,
                "actions": card.actions, "avatars": card.avatars, "reminderTitle": card.reminder_title,
                "reminderStart": card.reminder_start_ms.unwrap_or(0),
                "reminderRepeat": card.reminder_repeat
            }),
            "ecard",
        ),
        Kind::OaMessage(parts) => {
            let rows: Vec<Value> = parts
                .iter()
                .map(|p| {
                    json!({
                        "header": p.is_header, "title": p.title, "description": p.description,
                        "thumb": opt(&p.thumb), "url": opt(&p.url), "help": p.help
                    })
                })
                .collect();
            (json!({"type": "oaMessage", "parts": rows}), "oaMessage")
        }
        Kind::Poll(poll) => (
            json!({
                "type": "poll", "question": poll.question, "header": poll.header,
                "anonymous": poll.anonymous, "pollId": poll.poll_id,
                "conversationId": poll.conversation_id
            }),
            "poll",
        ),
        Kind::StickerSet { title, thumbnail } => (
            json!({"type": "stickerSet", "title": title, "thumb": opt(thumbnail)}),
            "stickerSet",
        ),
        Kind::Zinstant {
            title,
            text,
            thumbnail,
        } => (
            json!({"type": "zinstant", "title": title, "text": text, "thumb": opt(thumbnail)}),
            "zinstant",
        ),
        Kind::Notice { symbol, text } => (
            json!({"type": "notice", "symbol": symbol, "text": text}),
            "notice",
        ),
        Kind::Placeholder { symbol, text } => (
            json!({"type": "placeholder", "symbol": symbol, "text": text}),
            "placeholder",
        ),
        Kind::System => (json!({"type": "system"}), "system"),
        Kind::Recalled => (json!({"type": "recalled"}), "recalled"),
        Kind::Unsupported { raw_type } => (
            json!({"type": "unsupported", "rawType": raw_type}),
            "unsupported",
        ),
    };
    match v {
        Value::Object(m) => (m, tag),
        _ => (Map::new(), tag),
    }
}

/// `decodeStoredMessage`: parses `raw_json_data` (plain JSON, not lossless: ids are strings there).
pub fn decode_stored_message(stored: &StoredMessage) -> Option<ChatMessage> {
    let Value::Object(dict) = serde_json::from_slice::<Value>(&stored.raw_json_data).ok()? else {
        return None;
    };
    let mut msg = ChatMessage::from_json(&dict, &stored.conv_id)?;
    if msg.client_id.is_empty() && !stored.client_id.is_empty() {
        msg.client_id = stored.client_id.clone();
    }
    Some(msg)
}

/// `encodeChatMessage`: `client_id` empty means "use the message's own".
pub fn encode_chat_message(msg: &ChatMessage, client_id: &str) -> Option<StoredMessage> {
    let effective_client_id = if client_id.is_empty() {
        msg.client_id.as_str()
    } else {
        client_id
    };
    let (mut kind_dict, kind_tag) = serialize_kind(&msg.kind);
    if !msg.fallback_urls.is_empty() {
        kind_dict.insert("fallbacks".into(), json!(msg.fallback_urls));
    }
    let reactions: Vec<Value> = msg
        .reactions
        .iter()
        .map(|r| {
            let mut d = json!({
                "type": r.icon.r#type, "key": r.icon.key, "emoji": r.icon.emoji,
                "image": r.icon.image, "count": r.count, "includesMe": r.includes_me,
                "names": r.names, "people": r.people
            });
            if !r.user_counts.is_empty()
                && let Value::Object(m) = &mut d
            {
                m.insert("userCounts".into(), json!(r.user_counts));
            }
            d
        })
        .collect();
    let mentions: Vec<Value> = msg
        .mentions
        .iter()
        .map(|m| json!({"uid": m.uid, "pos": m.pos, "len": m.len, "isAll": m.is_all}))
        .collect();
    let buttons: Vec<Value> = msg
        .card_buttons
        .iter()
        .map(|b| json!({"ref": b.r#ref, "label": b.label, "enabled": b.enabled, "help": b.help}))
        .collect();
    let menu = json!({
        "forward": match msg.menu.forward {
            Availability::Available => "ok",
            Availability::Blocked => "blocked",
            Availability::Hidden => "",
        },
        "recall": msg.menu.recall,
        "delete": match msg.menu.delete {
            Some(DeleteMode::Plain) => "plain",
            Some(DeleteMode::ForMe) => "forMe",
            None => "",
        },
        "pin": msg.menu.pin,
        "star": match msg.menu.star {
            Some(StarMode::Star) => "star",
            Some(StarMode::Unstar) => "unstar",
            Some(StarMode::Blocked) => "blocked",
            None => "",
        },
        "starred": msg.menu.starred,
        "pinned": msg.menu.pinned,
        "protected": msg.menu.is_protected
    });
    let sender_avatar = msg.sender_avatar.clone().unwrap_or_default();
    let mut canonical = json!({
        "id": msg.id,
        "clientId": effective_client_id,
        "conversationId": msg.conversation_id,
        "senderId": msg.sender_id,
        "senderName": msg.sender_name,
        "senderAvatar": sender_avatar,
        "isMine": msg.is_mine,
        "kind": Value::Object(kind_dict),
        "text": msg.text,
        "date": msg.date_ms,
        "status": msg.status.raw_value(),
        "reactions": reactions,
        "isE2EE": msg.is_e2ee,
        "mentions": mentions,
        "buttons": buttons,
        "stickers": msg.suggests_stickers,
        "menu": menu
    });
    if let (true, Value::Object(m)) = (msg.ttl_ms > 0, &mut canonical) {
        m.insert("ttl".into(), Value::from(msg.ttl_ms));
    }
    if let (false, Value::Object(m)) = (msg.text_styles.is_empty(), &mut canonical) {
        m.insert("styles".into(), TextStyle::to_json(&msg.text_styles));
    }
    if let (Some(q), Value::Object(m)) = (&msg.quote, &mut canonical) {
        m.insert(
            "quote".into(),
            json!({"senderName": q.sender_name, "text": q.text}),
        );
    }
    let data = serde_json::to_vec(&canonical).ok()?;
    Some(StoredMessage {
        id: msg.id.clone(),
        conv_id: msg.conversation_id.clone(),
        client_id: effective_client_id.to_string(),
        sender_id: msg.sender_id.clone(),
        sender_name: msg.sender_name.clone(),
        sender_avatar,
        is_mine: msg.is_mine,
        text: msg.text.clone(),
        kind_tag: kind_tag.to_string(),
        ts_ms: msg.date_ms,
        status: msg.status.raw_value().to_string(),
        raw_json_data: data,
    })
}
