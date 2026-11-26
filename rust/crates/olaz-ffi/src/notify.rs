//! UniFFI records and pure policy exports for U16 (`notify` + card actions + invites + reminders + sticker suggest).

use std::collections::BTreeMap;
use std::fmt;

use olaz_core::{
    CARD_DEFAULT_FAILED, CARD_DEFAULT_UNSUPPORTED, CardActionOutcomeData, ContactCardStateResult,
    ContactProfileResult, FriendRequestOriginKind, FriendRequestPrepResult, GroupInviteMember,
    GroupInvitePreviewResult, GroupJoinResultData, MuteInfo, NotifAuthorization,
    NotificationSettingsSnapshot, NotifyBannerPayload, PinReminderRef, ReminderResponderPerson,
    ReminderRespondersData, ReminderSnapshotData, RespondReminderResult, SaveAliasResult,
    SubmitFriendRequestResult, SuggestedStickerItem, notification_policy as core_policy,
};

// --- Pure NotificationPolicy exports ---

#[uniffi::export]
#[must_use]
pub fn notification_policy_should_suppress(
    app_is_active: bool,
    main_window_visible: bool,
    open_conversation: Option<String>,
    tag: String,
    user_idle_seconds: f64,
    idle_threshold: f64,
) -> bool {
    core_policy::should_suppress(
        app_is_active,
        main_window_visible,
        open_conversation.as_deref(),
        &tag,
        user_idle_seconds,
        idle_threshold,
    )
}

#[uniffi::export]
#[must_use]
pub fn notification_policy_refuses_reply(
    hidden_state_known: bool,
    conversation_locked: bool,
) -> bool {
    core_policy::refuses_reply(hidden_state_known, conversation_locked)
}

#[uniffi::export]
#[must_use]
pub fn notification_policy_newly_hidden(old: Vec<String>, new: Vec<String>) -> Vec<String> {
    core_policy::newly_hidden(&old, &new)
}

#[uniffi::export]
#[must_use]
pub fn notification_policy_body(raw_body: String, shows_preview: bool) -> String {
    core_policy::body(&raw_body, shows_preview)
}

#[uniffi::export]
#[must_use]
pub fn mute_info_format_description(
    start_time: f64,
    duration: f64,
    hh_mm: Option<String>,
    dd_mm_if_other_day: Option<String>,
) -> String {
    MuteInfo {
        start_time,
        duration,
    }
    .format_description(hh_mm.as_deref(), dd_mm_if_other_day.as_deref())
}

#[uniffi::export]
#[must_use]
pub fn mute_info_format_status_text(
    start_time: f64,
    duration: f64,
    hh_mm: Option<String>,
    dd_mm_if_other_day: Option<String>,
) -> String {
    MuteInfo {
        start_time,
        duration,
    }
    .format_status_text(hh_mm.as_deref(), dd_mm_if_other_day.as_deref())
}

// --- Notification settings & banner records ---

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum NotifAuthorizationRecord {
    Unknown,
    NotDetermined,
    Denied,
    Authorized,
    Unavailable,
}

impl From<NotifAuthorization> for NotifAuthorizationRecord {
    fn from(a: NotifAuthorization) -> Self {
        match a {
            NotifAuthorization::Unknown => Self::Unknown,
            NotifAuthorization::NotDetermined => Self::NotDetermined,
            NotifAuthorization::Denied => Self::Denied,
            NotifAuthorization::Authorized => Self::Authorized,
            NotifAuthorization::Unavailable => Self::Unavailable,
        }
    }
}

impl From<NotifAuthorizationRecord> for NotifAuthorization {
    fn from(r: NotifAuthorizationRecord) -> Self {
        match r {
            NotifAuthorizationRecord::Unknown => Self::Unknown,
            NotifAuthorizationRecord::NotDetermined => Self::NotDetermined,
            NotifAuthorizationRecord::Denied => Self::Denied,
            NotifAuthorizationRecord::Authorized => Self::Authorized,
            NotifAuthorizationRecord::Unavailable => Self::Unavailable,
        }
    }
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct MuteInfoEntryRecord {
    pub id: String,
    pub start_time: f64,
    pub duration: f64,
}

#[derive(Clone, PartialEq, uniffi::Record)]
pub struct NotificationSettingsRecord {
    pub is_loaded: bool,
    pub enabled: bool,
    pub sound: bool,
    pub has_sound_setting: bool,
    pub shows_preview: bool,
    pub authorization: NotifAuthorizationRecord,
    pub mutes: Vec<MuteInfoEntryRecord>,
}

impl fmt::Debug for NotificationSettingsRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("NotificationSettingsRecord")
            .field("is_loaded", &self.is_loaded)
            .field("enabled", &self.enabled)
            .field("sound", &self.sound)
            .field("has_sound_setting", &self.has_sound_setting)
            .field("shows_preview", &self.shows_preview)
            .field("authorization", &self.authorization)
            .field("mutes_count", &self.mutes.len())
            .finish()
    }
}

impl From<NotificationSettingsSnapshot> for NotificationSettingsRecord {
    fn from(s: NotificationSettingsSnapshot) -> Self {
        Self {
            is_loaded: s.is_loaded,
            enabled: s.enabled,
            sound: s.sound,
            has_sound_setting: s.has_sound_setting,
            shows_preview: s.shows_preview,
            authorization: s.authorization.into(),
            mutes: s
                .mutes
                .into_iter()
                .map(|(id, info)| MuteInfoEntryRecord {
                    id,
                    start_time: info.start_time,
                    duration: info.duration,
                })
                .collect(),
        }
    }
}

#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct NotifyBannerPayloadRecord {
    pub title: String,
    pub body: String,
    pub conv_id: String,
    pub sender_id: String,
    pub sender_name: String,
    pub is_group: bool,
    pub avatar_url: Option<String>,
    pub silent: bool,
}

impl fmt::Debug for NotifyBannerPayloadRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("NotifyBannerPayloadRecord")
            .field("is_group", &self.is_group)
            .field("silent", &self.silent)
            .field("has_avatar", &self.avatar_url.is_some())
            .finish()
    }
}

impl From<NotifyBannerPayload> for NotifyBannerPayloadRecord {
    fn from(p: NotifyBannerPayload) -> Self {
        Self {
            title: p.title,
            body: p.body,
            conv_id: p.conv_id,
            sender_id: p.sender_id,
            sender_name: p.sender_name,
            is_group: p.is_group,
            avatar_url: p.avatar_url,
            silent: p.silent,
        }
    }
}

#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct AliasEntryRecord {
    pub uid: String,
    pub alias: String,
}

impl fmt::Debug for AliasEntryRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("AliasEntryRecord")
            .field("alias_len", &self.alias.len())
            .finish()
    }
}

pub(crate) fn alias_map_to_records(map: BTreeMap<String, String>) -> Vec<AliasEntryRecord> {
    map.into_iter()
        .map(|(uid, alias)| AliasEntryRecord { uid, alias })
        .collect()
}

// --- Card action, sticker suggest, contact/friend, invite, reminder records ---

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum CardActionOutcomeRecord {
    Done,
    Unsupported { text: String },
    Locked { text: String },
    Failed { text: String },
    Pending { text: String },
}

impl From<CardActionOutcomeData> for CardActionOutcomeRecord {
    fn from(d: CardActionOutcomeData) -> Self {
        match d {
            CardActionOutcomeData::Done => Self::Done,
            CardActionOutcomeData::Unsupported(text) => Self::Unsupported { text },
            CardActionOutcomeData::Locked(text) => Self::Locked { text },
            CardActionOutcomeData::Failed(text) => Self::Failed { text },
            CardActionOutcomeData::Pending(text) => Self::Pending { text },
        }
    }
}

impl From<CardActionOutcomeRecord> for CardActionOutcomeData {
    fn from(r: CardActionOutcomeRecord) -> Self {
        match r {
            CardActionOutcomeRecord::Done => Self::Done,
            CardActionOutcomeRecord::Unsupported { text } => Self::Unsupported(text),
            CardActionOutcomeRecord::Locked { text } => Self::Locked(text),
            CardActionOutcomeRecord::Failed { text } => Self::Failed(text),
            CardActionOutcomeRecord::Pending { text } => Self::Pending(text),
        }
    }
}

#[must_use]
pub fn default_unsupported_card_record() -> CardActionOutcomeRecord {
    CardActionOutcomeRecord::Unsupported {
        text: CARD_DEFAULT_UNSUPPORTED.to_owned(),
    }
}

#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct SuggestedStickerRecord {
    pub sticker_ref: String,
    pub url: String,
}

impl fmt::Debug for SuggestedStickerRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("SuggestedStickerRecord")
            .field("sticker_ref", &self.sticker_ref)
            .finish()
    }
}

impl From<SuggestedStickerItem> for SuggestedStickerRecord {
    fn from(s: SuggestedStickerItem) -> Self {
        Self {
            sticker_ref: s.sticker_ref,
            url: s.url,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct ContactCardStateRecord {
    pub is_self: bool,
    pub is_friend: bool,
}

impl From<ContactCardStateResult> for ContactCardStateRecord {
    fn from(r: ContactCardStateResult) -> Self {
        Self {
            is_self: r.is_self,
            is_friend: r.is_friend,
        }
    }
}

#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct ContactProfileRecord {
    pub uid: String,
    pub name: String,
    pub zalo_name: String,
    pub avatar: Option<String>,
    pub bio: String,
    pub is_self: bool,
    pub is_friend: bool,
    pub is_oa: bool,
}

impl fmt::Debug for ContactProfileRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ContactProfileRecord")
            .field("is_self", &self.is_self)
            .field("is_friend", &self.is_friend)
            .finish()
    }
}

impl From<ContactProfileResult> for ContactProfileRecord {
    fn from(p: ContactProfileResult) -> Self {
        Self {
            uid: p.uid,
            name: p.name,
            zalo_name: p.zalo_name,
            avatar: p.avatar,
            bio: p.bio,
            is_self: p.is_self,
            is_friend: p.is_friend,
            is_oa: p.is_oa,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum FriendRequestOriginRecord {
    Add,
    Card,
    None,
}

impl From<FriendRequestOriginRecord> for FriendRequestOriginKind {
    fn from(r: FriendRequestOriginRecord) -> Self {
        match r {
            FriendRequestOriginRecord::Add => Self::Add,
            FriendRequestOriginRecord::Card => Self::Card,
            FriendRequestOriginRecord::None => Self::None,
        }
    }
}

#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct FriendRequestPrepRecord {
    pub state: String,
    pub default_message: String,
    pub max_message: i64,
}

impl fmt::Debug for FriendRequestPrepRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("FriendRequestPrepRecord")
            .field("state", &self.state)
            .field("max_message", &self.max_message)
            .finish()
    }
}

impl From<FriendRequestPrepResult> for FriendRequestPrepRecord {
    fn from(r: FriendRequestPrepResult) -> Self {
        Self {
            state: r.state,
            default_message: r.default_message,
            max_message: r.max_message,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SubmitFriendRecord {
    pub ok: bool,
    pub text: String,
    pub pending: bool,
}

impl From<SubmitFriendRequestResult> for SubmitFriendRecord {
    fn from(r: SubmitFriendRequestResult) -> Self {
        Self {
            ok: r.ok,
            text: r.text,
            pending: r.pending,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SaveAliasRecord {
    pub ok: bool,
    pub text: String,
}

impl From<SaveAliasResult> for SaveAliasRecord {
    fn from(r: SaveAliasResult) -> Self {
        Self {
            ok: r.ok,
            text: r.text,
        }
    }
}

#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct GroupInviteMemberRecord {
    pub id: String,
    pub name: String,
    pub avatar: Option<String>,
    pub admin: bool,
}

impl fmt::Debug for GroupInviteMemberRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("GroupInviteMemberRecord")
            .field("admin", &self.admin)
            .finish()
    }
}

impl From<GroupInviteMember> for GroupInviteMemberRecord {
    fn from(m: GroupInviteMember) -> Self {
        Self {
            id: m.id,
            name: m.name,
            avatar: m.avatar,
            admin: m.admin,
        }
    }
}

#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct GroupInvitePreviewRecord {
    pub state: String,
    pub group_id: String,
    pub name: String,
    pub avatar: Option<String>,
    pub total_member: i64,
    pub desc: String,
    pub community: bool,
    pub creator_name: String,
    pub members: Vec<GroupInviteMemberRecord>,
    pub text: String,
}

impl fmt::Debug for GroupInvitePreviewRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("GroupInvitePreviewRecord")
            .field("state", &self.state)
            .field("total_member", &self.total_member)
            .finish()
    }
}

impl From<GroupInvitePreviewResult> for GroupInvitePreviewRecord {
    fn from(r: GroupInvitePreviewResult) -> Self {
        Self {
            state: r.state,
            group_id: r.group_id,
            name: r.name,
            avatar: r.avatar,
            total_member: r.total_member,
            desc: r.desc,
            community: r.community,
            creator_name: r.creator_name,
            members: r.members.into_iter().map(Into::into).collect(),
            text: r.text,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct GroupJoinRecord {
    pub state: String,
    pub group_id: String,
    pub text: String,
}

impl From<GroupJoinResultData> for GroupJoinRecord {
    fn from(r: GroupJoinResultData) -> Self {
        Self {
            state: r.state,
            group_id: r.group_id,
            text: r.text,
        }
    }
}

#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct PinReminderRefRecord {
    pub msg_id: String,
    pub cli_msg_id: String,
    pub reminder_ref: String,
}

impl fmt::Debug for PinReminderRefRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("PinReminderRefRecord")
            .field("has_ref", &!self.reminder_ref.is_empty())
            .finish()
    }
}

impl From<PinReminderRefRecord> for PinReminderRef {
    fn from(r: PinReminderRefRecord) -> Self {
        Self {
            msg_id: r.msg_id,
            cli_msg_id: r.cli_msg_id,
            reminder_ref: r.reminder_ref,
        }
    }
}

#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct ReminderSnapshotRecord {
    pub variant: String,
    pub id: String,
    pub title: String,
    pub start_ms: Option<i64>,
    pub repeat_label: String,
    pub creator_name: String,
    pub only_me: bool,
    pub is_group: bool,
    pub mine: String,
    pub accepted_count: i64,
    pub rejected_count: i64,
    pub can_rsvp: bool,
    pub can_view: bool,
    pub deleted: bool,
    pub sig: String,
}

impl fmt::Debug for ReminderSnapshotRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ReminderSnapshotRecord")
            .field("variant", &self.variant)
            .field("deleted", &self.deleted)
            .finish()
    }
}

impl From<ReminderSnapshotData> for ReminderSnapshotRecord {
    fn from(s: ReminderSnapshotData) -> Self {
        Self {
            variant: s.variant,
            id: s.id,
            title: s.title,
            start_ms: s.start_ms,
            repeat_label: s.repeat_label,
            creator_name: s.creator_name,
            only_me: s.only_me,
            is_group: s.is_group,
            mine: s.mine,
            accepted_count: s.accepted_count,
            rejected_count: s.rejected_count,
            can_rsvp: s.can_rsvp,
            can_view: s.can_view,
            deleted: s.deleted,
            sig: s.sig,
        }
    }
}

#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct RespondReminderRecord {
    pub ok: bool,
    pub text: String,
    pub snapshot: Option<ReminderSnapshotRecord>,
}

impl fmt::Debug for RespondReminderRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("RespondReminderRecord")
            .field("ok", &self.ok)
            .field("has_snapshot", &self.snapshot.is_some())
            .finish()
    }
}

impl From<RespondReminderResult> for RespondReminderRecord {
    fn from(r: RespondReminderResult) -> Self {
        Self {
            ok: r.ok,
            text: r.text,
            snapshot: r.snapshot.map(Into::into),
        }
    }
}

#[must_use]
pub fn default_failed_respond_reminder_record() -> RespondReminderRecord {
    RespondReminderRecord {
        ok: false,
        text: CARD_DEFAULT_FAILED.to_owned(),
        snapshot: None,
    }
}

#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct ReminderResponderPersonRecord {
    pub uid: String,
    pub name: String,
    pub avatar: Option<String>,
    pub is_me: bool,
}

impl fmt::Debug for ReminderResponderPersonRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ReminderResponderPersonRecord")
            .field("is_me", &self.is_me)
            .finish()
    }
}

impl From<ReminderResponderPerson> for ReminderResponderPersonRecord {
    fn from(p: ReminderResponderPerson) -> Self {
        Self {
            uid: p.uid,
            name: p.name,
            avatar: p.avatar,
            is_me: p.is_me,
        }
    }
}

#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct ReminderRespondersRecord {
    pub accept: Vec<ReminderResponderPersonRecord>,
    pub reject: Vec<ReminderResponderPersonRecord>,
    pub accept_total: i64,
    pub reject_total: i64,
    pub accept_more: i64,
    pub reject_more: i64,
}

impl fmt::Debug for ReminderRespondersRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ReminderRespondersRecord")
            .field("accept_total", &self.accept_total)
            .field("reject_total", &self.reject_total)
            .finish()
    }
}

impl From<ReminderRespondersData> for ReminderRespondersRecord {
    fn from(r: ReminderRespondersData) -> Self {
        Self {
            accept: r.accept.into_iter().map(Into::into).collect(),
            reject: r.reject.into_iter().map(Into::into).collect(),
            accept_total: r.accept_total,
            reject_total: r.reject_total,
            accept_more: r.accept_more,
            reject_more: r.reject_more,
        }
    }
}
