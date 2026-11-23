//! Typed chat message records (`ChatMessage` in `ChatModels.swift`) so Swift builds its values field by field instead of
//! re-parsing JSON. Ids are decimal strings, timestamps Unix milliseconds. Mirrors `olaz_wire::ChatMessage`.

use olaz_wire::{
    Availability, CardButton, ChatMessage, ContactCard, DeleteMode, ECard, ECardStyle, Kind,
    LocationInfo, Mention, MessageMenu, OaPart, PollInfo, Quote, Reaction, ReactionIcon, StarMode,
    Status,
};

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct MessageMention {
    pub uid: String,
    pub pos: i64,
    pub len: i64,
    pub is_all: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ReactionIconRecord {
    pub kind: String,
    pub key: String,
    pub emoji: String,
    pub image: String,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct UserCountRecord {
    pub uid: String,
    pub count: i64,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ReactionRecord {
    pub icon: ReactionIconRecord,
    pub count: i64,
    pub includes_me: bool,
    pub names: Vec<String>,
    pub people: i64,
    pub user_counts: Vec<UserCountRecord>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct QuoteRecord {
    pub sender_name: String,
    pub text: String,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CardButtonRecord {
    pub reference: String,
    pub label: String,
    pub enabled: bool,
    pub help: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum StatusRecord {
    Sending,
    Sent,
    Delivered,
    Seen,
    Failed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum AvailabilityRecord {
    Hidden,
    Available,
    Blocked,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum DeleteModeRecord {
    Plain,
    ForMe,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum StarModeRecord {
    Star,
    Unstar,
    Blocked,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct MenuRecord {
    pub forward: AvailabilityRecord,
    pub recall: bool,
    pub delete: Option<DeleteModeRecord>,
    pub pin: bool,
    pub star: Option<StarModeRecord>,
    pub starred: bool,
    pub pinned: bool,
    pub is_protected: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ContactCardRecord {
    pub name: String,
    pub uid: String,
    pub avatar: Option<String>,
    pub phone: String,
    pub qr: Option<String>,
    pub oa_link: String,
    pub is_official_account: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, uniffi::Record)]
pub struct CoordinateRecord {
    pub latitude: f64,
    pub longitude: f64,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct LocationRecord {
    pub title: String,
    pub address: String,
    pub coordinate: Option<CoordinateRecord>,
    pub thumbnail: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ECardStyleRecord {
    Banner,
    Friend,
    Birthday,
    Reminder,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ECardRecord {
    pub style: ECardStyleRecord,
    pub image: Option<String>,
    pub thumb: Option<String>,
    pub title: String,
    pub description: String,
    pub actions: Vec<String>,
    pub avatars: Vec<String>,
    pub reminder_title: String,
    pub reminder_start_ms: Option<i64>,
    pub reminder_repeat: String,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct OaPartRecord {
    pub is_header: bool,
    pub title: String,
    pub description: String,
    pub thumb: Option<String>,
    pub url: Option<String>,
    pub help: String,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct PollRecord {
    pub question: String,
    pub header: String,
    pub anonymous: bool,
    pub poll_id: String,
    pub conversation_id: String,
}

/// `ChatMessage.Kind`. URLs are strings (Swift maps them with `URL(string:)`).
#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum KindRecord {
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
    ContactCard {
        card: ContactCardRecord,
    },
    Location {
        info: LocationRecord,
    },
    Call {
        video: bool,
        missed: bool,
        duration: i64,
        title: String,
        detail: String,
    },
    Ecard {
        card: ECardRecord,
    },
    OaMessage {
        parts: Vec<OaPartRecord>,
    },
    Poll {
        poll: PollRecord,
    },
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

/// Every field of Swift's `ChatMessage`.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ChatMessageRecord {
    pub id: String,
    pub conversation_id: String,
    pub sender_id: String,
    pub sender_name: String,
    pub sender_avatar: Option<String>,
    pub is_mine: bool,
    pub kind: KindRecord,
    pub text: String,
    pub date_ms: i64,
    pub status: StatusRecord,
    pub quote: Option<QuoteRecord>,
    pub reactions: Vec<ReactionRecord>,
    pub is_e2ee: bool,
    pub mentions: Vec<MessageMention>,
    pub card_buttons: Vec<CardButtonRecord>,
    pub suggests_stickers: bool,
    pub menu: MenuRecord,
    pub fallback_urls: Vec<String>,
    pub client_id: String,
}

// ----- ChatMessage -> record -------------------------------------------------------------------

impl From<Status> for StatusRecord {
    fn from(s: Status) -> Self {
        match s {
            Status::Sending => Self::Sending,
            Status::Sent => Self::Sent,
            Status::Delivered => Self::Delivered,
            Status::Seen => Self::Seen,
            Status::Failed => Self::Failed,
        }
    }
}

impl From<StatusRecord> for Status {
    fn from(s: StatusRecord) -> Self {
        match s {
            StatusRecord::Sending => Self::Sending,
            StatusRecord::Sent => Self::Sent,
            StatusRecord::Delivered => Self::Delivered,
            StatusRecord::Seen => Self::Seen,
            StatusRecord::Failed => Self::Failed,
        }
    }
}

impl From<ECardStyle> for ECardStyleRecord {
    fn from(s: ECardStyle) -> Self {
        match s {
            ECardStyle::Banner => Self::Banner,
            ECardStyle::Friend => Self::Friend,
            ECardStyle::Birthday => Self::Birthday,
            ECardStyle::Reminder => Self::Reminder,
        }
    }
}

impl From<ECardStyleRecord> for ECardStyle {
    fn from(s: ECardStyleRecord) -> Self {
        match s {
            ECardStyleRecord::Banner => Self::Banner,
            ECardStyleRecord::Friend => Self::Friend,
            ECardStyleRecord::Birthday => Self::Birthday,
            ECardStyleRecord::Reminder => Self::Reminder,
        }
    }
}

impl From<&MessageMenu> for MenuRecord {
    fn from(m: &MessageMenu) -> Self {
        Self {
            forward: match m.forward {
                Availability::Hidden => AvailabilityRecord::Hidden,
                Availability::Available => AvailabilityRecord::Available,
                Availability::Blocked => AvailabilityRecord::Blocked,
            },
            recall: m.recall,
            delete: m.delete.map(|d| match d {
                DeleteMode::Plain => DeleteModeRecord::Plain,
                DeleteMode::ForMe => DeleteModeRecord::ForMe,
            }),
            pin: m.pin,
            star: m.star.map(|s| match s {
                StarMode::Star => StarModeRecord::Star,
                StarMode::Unstar => StarModeRecord::Unstar,
                StarMode::Blocked => StarModeRecord::Blocked,
            }),
            starred: m.starred,
            pinned: m.pinned,
            is_protected: m.is_protected,
        }
    }
}

impl From<&MenuRecord> for MessageMenu {
    fn from(m: &MenuRecord) -> Self {
        Self {
            forward: match m.forward {
                AvailabilityRecord::Hidden => Availability::Hidden,
                AvailabilityRecord::Available => Availability::Available,
                AvailabilityRecord::Blocked => Availability::Blocked,
            },
            recall: m.recall,
            delete: m.delete.map(|d| match d {
                DeleteModeRecord::Plain => DeleteMode::Plain,
                DeleteModeRecord::ForMe => DeleteMode::ForMe,
            }),
            pin: m.pin,
            star: m.star.map(|s| match s {
                StarModeRecord::Star => StarMode::Star,
                StarModeRecord::Unstar => StarMode::Unstar,
                StarModeRecord::Blocked => StarMode::Blocked,
            }),
            starred: m.starred,
            pinned: m.pinned,
            is_protected: m.is_protected,
        }
    }
}

impl From<&Kind> for KindRecord {
    fn from(k: &Kind) -> Self {
        match k {
            Kind::Text => Self::Text,
            Kind::Photo { url, width, height } => Self::Photo {
                url: url.clone(),
                width: *width,
                height: *height,
            },
            Kind::Sticker { url } => Self::Sticker { url: url.clone() },
            Kind::Gif { url } => Self::Gif { url: url.clone() },
            Kind::Video {
                thumbnail,
                duration,
                url,
            } => Self::Video {
                thumbnail: thumbnail.clone(),
                duration: *duration,
                url: url.clone(),
            },
            Kind::Voice { url, duration } => Self::Voice {
                url: url.clone(),
                duration: *duration,
            },
            Kind::File { name, size, url } => Self::File {
                name: name.clone(),
                size: *size,
                url: url.clone(),
            },
            Kind::Link {
                title,
                url,
                thumbnail,
                description,
                source,
            } => Self::Link {
                title: title.clone(),
                url: url.clone(),
                thumbnail: thumbnail.clone(),
                description: description.clone(),
                source: source.clone(),
            },
            Kind::ContactCard(c) => Self::ContactCard {
                card: ContactCardRecord {
                    name: c.name.clone(),
                    uid: c.uid.clone(),
                    avatar: c.avatar.clone(),
                    phone: c.phone.clone(),
                    qr: c.qr.clone(),
                    oa_link: c.oa_link.clone(),
                    is_official_account: c.is_official_account,
                },
            },
            Kind::Location(l) => Self::Location {
                info: LocationRecord {
                    title: l.title.clone(),
                    address: l.address.clone(),
                    coordinate: l.coordinate.map(|(latitude, longitude)| CoordinateRecord {
                        latitude,
                        longitude,
                    }),
                    thumbnail: l.thumbnail.clone(),
                },
            },
            Kind::Call {
                video,
                missed,
                duration,
                title,
                detail,
            } => Self::Call {
                video: *video,
                missed: *missed,
                duration: *duration,
                title: title.clone(),
                detail: detail.clone(),
            },
            Kind::Ecard(e) => Self::Ecard {
                card: ECardRecord {
                    style: e.style.into(),
                    image: e.image.clone(),
                    thumb: e.thumb.clone(),
                    title: e.title.clone(),
                    description: e.description.clone(),
                    actions: e.actions.clone(),
                    avatars: e.avatars.clone(),
                    reminder_title: e.reminder_title.clone(),
                    reminder_start_ms: e.reminder_start_ms,
                    reminder_repeat: e.reminder_repeat.clone(),
                },
            },
            Kind::OaMessage(parts) => Self::OaMessage {
                parts: parts
                    .iter()
                    .map(|p| OaPartRecord {
                        is_header: p.is_header,
                        title: p.title.clone(),
                        description: p.description.clone(),
                        thumb: p.thumb.clone(),
                        url: p.url.clone(),
                        help: p.help.clone(),
                    })
                    .collect(),
            },
            Kind::Poll(p) => Self::Poll {
                poll: PollRecord {
                    question: p.question.clone(),
                    header: p.header.clone(),
                    anonymous: p.anonymous,
                    poll_id: p.poll_id.clone(),
                    conversation_id: p.conversation_id.clone(),
                },
            },
            Kind::StickerSet { title, thumbnail } => Self::StickerSet {
                title: title.clone(),
                thumbnail: thumbnail.clone(),
            },
            Kind::Zinstant {
                title,
                text,
                thumbnail,
            } => Self::Zinstant {
                title: title.clone(),
                text: text.clone(),
                thumbnail: thumbnail.clone(),
            },
            Kind::Notice { symbol, text } => Self::Notice {
                symbol: symbol.clone(),
                text: text.clone(),
            },
            Kind::Placeholder { symbol, text } => Self::Placeholder {
                symbol: symbol.clone(),
                text: text.clone(),
            },
            Kind::System => Self::System,
            Kind::Recalled => Self::Recalled,
            Kind::Unsupported { raw_type } => Self::Unsupported {
                raw_type: raw_type.clone(),
            },
        }
    }
}

impl From<&KindRecord> for Kind {
    fn from(k: &KindRecord) -> Self {
        match k {
            KindRecord::Text => Self::Text,
            KindRecord::Photo { url, width, height } => Self::Photo {
                url: url.clone(),
                width: *width,
                height: *height,
            },
            KindRecord::Sticker { url } => Self::Sticker { url: url.clone() },
            KindRecord::Gif { url } => Self::Gif { url: url.clone() },
            KindRecord::Video {
                thumbnail,
                duration,
                url,
            } => Self::Video {
                thumbnail: thumbnail.clone(),
                duration: *duration,
                url: url.clone(),
            },
            KindRecord::Voice { url, duration } => Self::Voice {
                url: url.clone(),
                duration: *duration,
            },
            KindRecord::File { name, size, url } => Self::File {
                name: name.clone(),
                size: *size,
                url: url.clone(),
            },
            KindRecord::Link {
                title,
                url,
                thumbnail,
                description,
                source,
            } => Self::Link {
                title: title.clone(),
                url: url.clone(),
                thumbnail: thumbnail.clone(),
                description: description.clone(),
                source: source.clone(),
            },
            KindRecord::ContactCard { card: c } => Self::ContactCard(ContactCard {
                name: c.name.clone(),
                uid: c.uid.clone(),
                avatar: c.avatar.clone(),
                phone: c.phone.clone(),
                qr: c.qr.clone(),
                oa_link: c.oa_link.clone(),
                is_official_account: c.is_official_account,
            }),
            KindRecord::Location { info: l } => Self::Location(LocationInfo {
                title: l.title.clone(),
                address: l.address.clone(),
                coordinate: l.coordinate.map(|c| (c.latitude, c.longitude)),
                thumbnail: l.thumbnail.clone(),
            }),
            KindRecord::Call {
                video,
                missed,
                duration,
                title,
                detail,
            } => Self::Call {
                video: *video,
                missed: *missed,
                duration: *duration,
                title: title.clone(),
                detail: detail.clone(),
            },
            KindRecord::Ecard { card: e } => Self::Ecard(ECard {
                style: e.style.into(),
                image: e.image.clone(),
                thumb: e.thumb.clone(),
                title: e.title.clone(),
                description: e.description.clone(),
                actions: e.actions.clone(),
                avatars: e.avatars.clone(),
                reminder_title: e.reminder_title.clone(),
                reminder_start_ms: e.reminder_start_ms,
                reminder_repeat: e.reminder_repeat.clone(),
            }),
            KindRecord::OaMessage { parts } => Self::OaMessage(
                parts
                    .iter()
                    .map(|p| OaPart {
                        is_header: p.is_header,
                        title: p.title.clone(),
                        description: p.description.clone(),
                        thumb: p.thumb.clone(),
                        url: p.url.clone(),
                        help: p.help.clone(),
                    })
                    .collect(),
            ),
            KindRecord::Poll { poll: p } => Self::Poll(PollInfo {
                question: p.question.clone(),
                header: p.header.clone(),
                anonymous: p.anonymous,
                poll_id: p.poll_id.clone(),
                conversation_id: p.conversation_id.clone(),
            }),
            KindRecord::StickerSet { title, thumbnail } => Self::StickerSet {
                title: title.clone(),
                thumbnail: thumbnail.clone(),
            },
            KindRecord::Zinstant {
                title,
                text,
                thumbnail,
            } => Self::Zinstant {
                title: title.clone(),
                text: text.clone(),
                thumbnail: thumbnail.clone(),
            },
            KindRecord::Notice { symbol, text } => Self::Notice {
                symbol: symbol.clone(),
                text: text.clone(),
            },
            KindRecord::Placeholder { symbol, text } => Self::Placeholder {
                symbol: symbol.clone(),
                text: text.clone(),
            },
            KindRecord::System => Self::System,
            KindRecord::Recalled => Self::Recalled,
            KindRecord::Unsupported { raw_type } => Self::Unsupported {
                raw_type: raw_type.clone(),
            },
        }
    }
}

impl From<ChatMessage> for ChatMessageRecord {
    /// Moves the strings out of `m` (the hot path owns its messages).
    fn from(m: ChatMessage) -> Self {
        let kind = KindRecord::from(&m.kind);
        Self {
            id: m.id,
            conversation_id: m.conversation_id,
            sender_id: m.sender_id,
            sender_name: m.sender_name,
            sender_avatar: m.sender_avatar,
            is_mine: m.is_mine,
            kind,
            text: m.text,
            date_ms: m.date_ms,
            status: m.status.into(),
            quote: m.quote.map(|q| QuoteRecord {
                sender_name: q.sender_name,
                text: q.text,
            }),
            reactions: m
                .reactions
                .into_iter()
                .map(|r: Reaction| ReactionRecord {
                    icon: {
                        let i: ReactionIcon = r.icon;
                        ReactionIconRecord {
                            kind: i.r#type,
                            key: i.key,
                            emoji: i.emoji,
                            image: i.image,
                        }
                    },
                    count: r.count,
                    includes_me: r.includes_me,
                    names: r.names,
                    people: r.people,
                    user_counts: r
                        .user_counts
                        .into_iter()
                        .map(|(uid, count)| UserCountRecord { uid, count })
                        .collect(),
                })
                .collect(),
            is_e2ee: m.is_e2ee,
            mentions: m
                .mentions
                .into_iter()
                .map(|x: Mention| MessageMention {
                    uid: x.uid,
                    pos: x.pos,
                    len: x.len,
                    is_all: x.is_all,
                })
                .collect(),
            card_buttons: m
                .card_buttons
                .into_iter()
                .map(|b: CardButton| CardButtonRecord {
                    reference: b.r#ref,
                    label: b.label,
                    enabled: b.enabled,
                    help: b.help,
                })
                .collect(),
            suggests_stickers: m.suggests_stickers,
            menu: (&m.menu).into(),
            fallback_urls: m.fallback_urls,
            client_id: m.client_id,
        }
    }
}

impl From<&ChatMessageRecord> for ChatMessage {
    fn from(r: &ChatMessageRecord) -> Self {
        Self {
            id: r.id.clone(),
            conversation_id: r.conversation_id.clone(),
            sender_id: r.sender_id.clone(),
            sender_name: r.sender_name.clone(),
            sender_avatar: r.sender_avatar.clone(),
            is_mine: r.is_mine,
            kind: (&r.kind).into(),
            text: r.text.clone(),
            date_ms: r.date_ms,
            status: r.status.into(),
            quote: r.quote.as_ref().map(|q: &QuoteRecord| Quote {
                sender_name: q.sender_name.clone(),
                text: q.text.clone(),
            }),
            reactions: r
                .reactions
                .iter()
                .map(|x| Reaction {
                    icon: ReactionIcon {
                        r#type: x.icon.kind.clone(),
                        key: x.icon.key.clone(),
                        emoji: x.icon.emoji.clone(),
                        image: x.icon.image.clone(),
                    },
                    count: x.count,
                    includes_me: x.includes_me,
                    names: x.names.clone(),
                    people: x.people,
                    user_counts: x
                        .user_counts
                        .iter()
                        .map(|u| (u.uid.clone(), u.count))
                        .collect(),
                })
                .collect(),
            is_e2ee: r.is_e2ee,
            mentions: r
                .mentions
                .iter()
                .map(|m| Mention {
                    uid: m.uid.clone(),
                    pos: m.pos,
                    len: m.len,
                    is_all: m.is_all,
                })
                .collect(),
            card_buttons: r
                .card_buttons
                .iter()
                .map(|b| CardButton {
                    r#ref: b.reference.clone(),
                    label: b.label.clone(),
                    enabled: b.enabled,
                    help: b.help.clone(),
                })
                .collect(),
            suggests_stickers: r.suggests_stickers,
            menu: (&r.menu).into(),
            fallback_urls: r.fallback_urls.clone(),
            client_id: r.client_id.clone(),
        }
    }
}
