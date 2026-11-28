//! UniFFI records and conversions for the U4 messages, history freshness, and contacts domain.
//!
//! Credentials and user-facing personal data never reach `Debug` output (ADR-008).

use std::fmt;

use olaz_core::changes::MessageMetaSnapshot;
use olaz_core::messages::{
    BlockedUserState, ContactNotice, ContactSearchState, ContactSearchStatus, ContactsState,
    FoundUserEntry, FriendEntry, FriendRequestEntry, GroupEntry, HistoryFreshness, MuteEntry,
    SaveAliasOutcome, WindowDelta, contact_fold, localized_standard_cmp,
};
use olaz_wire::ChatMessage;

use crate::chat::ChatMessageRecord;
use crate::conversations::StringPairEntry;

/// Coalesced per-conversation message window update delivered via `CoreChangesRecord.window_deltas`.
#[derive(Clone, PartialEq, uniffi::Enum)]
pub enum WindowDeltaRecord {
    Reset {
        conv_id: String,
        messages: Vec<ChatMessageRecord>,
    },
    Append {
        conv_id: String,
        messages: Vec<ChatMessageRecord>,
    },
    Patch {
        conv_id: String,
        upserts: Vec<ChatMessageRecord>,
        removed_ids: Vec<String>,
    },
    Remove {
        conv_id: String,
    },
}

impl fmt::Debug for WindowDeltaRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Reset { messages, .. } => f
                .debug_struct("WindowDeltaRecord::Reset")
                .field("count", &messages.len())
                .finish(),
            Self::Append { messages, .. } => f
                .debug_struct("WindowDeltaRecord::Append")
                .field("count", &messages.len())
                .finish(),
            Self::Patch {
                upserts,
                removed_ids,
                ..
            } => f
                .debug_struct("WindowDeltaRecord::Patch")
                .field("upserts", &upserts.len())
                .field("removed", &removed_ids.len())
                .finish(),
            Self::Remove { .. } => f.debug_struct("WindowDeltaRecord::Remove").finish(),
        }
    }
}

impl From<WindowDelta> for WindowDeltaRecord {
    fn from(d: WindowDelta) -> Self {
        match d {
            WindowDelta::Reset { conv_id, messages } => Self::Reset {
                conv_id,
                messages: messages.into_iter().map(Into::into).collect(),
            },
            WindowDelta::Append { conv_id, messages } => Self::Append {
                conv_id,
                messages: messages.into_iter().map(Into::into).collect(),
            },
            WindowDelta::Patch {
                conv_id,
                upserts,
                removed_ids,
            } => Self::Patch {
                conv_id,
                upserts: upserts.into_iter().map(Into::into).collect(),
                removed_ids,
            },
            WindowDelta::Remove { conv_id } => Self::Remove { conv_id },
        }
    }
}

#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct BoolMapEntry {
    pub conv_id: String,
    pub value: bool,
}

impl fmt::Debug for BoolMapEntry {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("BoolMapEntry")
            .field("value", &self.value)
            .finish()
    }
}

#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct TickMapEntry {
    pub conv_id: String,
    pub tick: u64,
}

impl fmt::Debug for TickMapEntry {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("TickMapEntry")
            .field("tick", &self.tick)
            .finish()
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug, uniffi::Enum)]
pub enum HistoryFreshnessRecord {
    UpToDate,
    Stale,
}

impl From<HistoryFreshness> for HistoryFreshnessRecord {
    fn from(f: HistoryFreshness) -> Self {
        match f {
            HistoryFreshness::UpToDate => Self::UpToDate,
            HistoryFreshness::Stale => Self::Stale,
        }
    }
}

impl From<HistoryFreshnessRecord> for HistoryFreshness {
    fn from(f: HistoryFreshnessRecord) -> Self {
        match f {
            HistoryFreshnessRecord::UpToDate => Self::UpToDate,
            HistoryFreshnessRecord::Stale => Self::Stale,
        }
    }
}

#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct FreshnessMapEntry {
    pub conv_id: String,
    pub freshness: HistoryFreshnessRecord,
}

impl fmt::Debug for FreshnessMapEntry {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("FreshnessMapEntry")
            .field("freshness", &self.freshness)
            .finish()
    }
}

/// Paging & freshness metadata snapshot delivered via `CoreChangesRecord.message_meta`.
#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct MessageMetaRecord {
    pub has_more_history: Vec<BoolMapEntry>,
    pub history_ticks: Vec<TickMapEntry>,
    pub history_freshness: Vec<FreshnessMapEntry>,
}

impl fmt::Debug for MessageMetaRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("MessageMetaRecord")
            .field("has_more_history", &self.has_more_history.len())
            .field("history_ticks", &self.history_ticks.len())
            .field("history_freshness", &self.history_freshness.len())
            .finish()
    }
}

impl From<MessageMetaSnapshot> for MessageMetaRecord {
    fn from(m: MessageMetaSnapshot) -> Self {
        Self {
            has_more_history: m
                .has_more_history
                .into_iter()
                .map(|(conv_id, value)| BoolMapEntry { conv_id, value })
                .collect(),
            history_ticks: m
                .history_ticks
                .into_iter()
                .map(|(conv_id, tick)| TickMapEntry { conv_id, tick })
                .collect(),
            history_freshness: m
                .history_freshness
                .into_iter()
                .map(|(conv_id, f)| FreshnessMapEntry {
                    conv_id,
                    freshness: f.into(),
                })
                .collect(),
        }
    }
}

#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct MuteEntryRecord {
    pub conv_id: String,
    pub start: i64,
    pub duration: i64,
}

impl fmt::Debug for MuteEntryRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("MuteEntryRecord")
            .field("start", &self.start)
            .field("duration", &self.duration)
            .finish()
    }
}

impl From<MuteEntry> for MuteEntryRecord {
    fn from(m: MuteEntry) -> Self {
        Self {
            conv_id: m.conv_id,
            start: m.start,
            duration: m.duration,
        }
    }
}

#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct FriendEntryRecord {
    pub id: String,
    pub name: String,
    pub zalo_name: String,
    pub avatar: Option<String>,
    pub last_active_ms: Option<i64>,
    pub online: bool,
    pub section: String,
    pub sort_key: String,
}

impl fmt::Debug for FriendEntryRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("FriendEntryRecord")
            .field("online", &self.online)
            .finish()
    }
}

impl From<FriendEntry> for FriendEntryRecord {
    fn from(f: FriendEntry) -> Self {
        Self {
            id: f.id,
            name: f.name,
            zalo_name: f.zalo_name,
            avatar: f.avatar,
            last_active_ms: f.last_active_ms,
            online: f.online,
            section: f.section,
            sort_key: f.sort_key,
        }
    }
}

impl From<FriendEntryRecord> for FriendEntry {
    fn from(f: FriendEntryRecord) -> Self {
        Self {
            id: f.id,
            name: f.name,
            zalo_name: f.zalo_name,
            avatar: f.avatar,
            last_active_ms: f.last_active_ms,
            online: f.online,
            section: f.section,
            sort_key: f.sort_key,
        }
    }
}

#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct GroupEntryRecord {
    pub id: String,
    pub name: String,
    pub avatar: Option<String>,
    pub members: i64,
    pub sort_key: String,
}

impl fmt::Debug for GroupEntryRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("GroupEntryRecord")
            .field("members", &self.members)
            .finish()
    }
}

impl From<GroupEntry> for GroupEntryRecord {
    fn from(g: GroupEntry) -> Self {
        Self {
            id: g.id,
            name: g.name,
            avatar: g.avatar,
            members: g.members,
            sort_key: g.sort_key,
        }
    }
}

impl From<GroupEntryRecord> for GroupEntry {
    fn from(g: GroupEntryRecord) -> Self {
        Self {
            id: g.id,
            name: g.name,
            avatar: g.avatar,
            members: g.members,
            sort_key: g.sort_key,
        }
    }
}

#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct FriendRequestEntryRecord {
    pub id: String,
    pub name: String,
    pub avatar: Option<String>,
    pub message: String,
    pub time_ms: Option<i64>,
}

impl fmt::Debug for FriendRequestEntryRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("FriendRequestEntryRecord")
            .field("has_time", &self.time_ms.is_some())
            .finish()
    }
}

impl From<FriendRequestEntry> for FriendRequestEntryRecord {
    fn from(r: FriendRequestEntry) -> Self {
        Self {
            id: r.id,
            name: r.name,
            avatar: r.avatar,
            message: r.message,
            time_ms: r.time_ms,
        }
    }
}

impl From<FriendRequestEntryRecord> for FriendRequestEntry {
    fn from(r: FriendRequestEntryRecord) -> Self {
        Self {
            id: r.id,
            name: r.name,
            avatar: r.avatar,
            message: r.message,
            time_ms: r.time_ms,
        }
    }
}

#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct FoundUserRecord {
    pub id: String,
    pub name: String,
    pub zalo_name: String,
    pub avatar: Option<String>,
    pub bio: String,
    pub is_friend: bool,
    pub is_self: bool,
    pub requested: bool,
    pub requesting: bool,
    pub default_message: String,
    pub max_message: i64,
}

impl fmt::Debug for FoundUserRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("FoundUserRecord")
            .field("is_friend", &self.is_friend)
            .field("is_self", &self.is_self)
            .finish()
    }
}

impl From<FoundUserEntry> for FoundUserRecord {
    fn from(u: FoundUserEntry) -> Self {
        Self {
            id: u.id,
            name: u.name,
            zalo_name: u.zalo_name,
            avatar: u.avatar,
            bio: u.bio,
            is_friend: u.is_friend,
            is_self: u.is_self,
            requested: u.requested,
            requesting: u.requesting,
            default_message: u.default_message,
            max_message: u.max_message,
        }
    }
}

impl From<FoundUserRecord> for FoundUserEntry {
    fn from(u: FoundUserRecord) -> Self {
        Self {
            id: u.id,
            name: u.name,
            zalo_name: u.zalo_name,
            avatar: u.avatar,
            bio: u.bio,
            is_friend: u.is_friend,
            is_self: u.is_self,
            requested: u.requested,
            requesting: u.requesting,
            default_message: u.default_message,
            max_message: u.max_message,
        }
    }
}

#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct ContactSearchRecord {
    pub status: String,
    pub error: Option<String>,
    pub user: Option<FoundUserRecord>,
}

impl fmt::Debug for ContactSearchRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ContactSearchRecord")
            .field("status", &self.status)
            .field("has_user", &self.user.is_some())
            .finish()
    }
}

impl From<ContactSearchState> for ContactSearchRecord {
    fn from(s: ContactSearchState) -> Self {
        Self {
            status: s.status.as_str().to_owned(),
            error: s.error,
            user: s.user.map(Into::into),
        }
    }
}

impl From<ContactSearchRecord> for ContactSearchState {
    fn from(s: ContactSearchRecord) -> Self {
        Self {
            status: ContactSearchStatus::parse(&s.status),
            error: s.error,
            user: s.user.map(Into::into),
        }
    }
}

#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct ContactNoticeRecord {
    pub seq: i64,
    pub ok: bool,
    pub text: String,
}

impl fmt::Debug for ContactNoticeRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ContactNoticeRecord")
            .field("seq", &self.seq)
            .field("ok", &self.ok)
            .finish()
    }
}

impl From<ContactNotice> for ContactNoticeRecord {
    fn from(n: ContactNotice) -> Self {
        Self {
            seq: n.seq,
            ok: n.ok,
            text: n.text,
        }
    }
}

impl From<ContactNoticeRecord> for ContactNotice {
    fn from(n: ContactNoticeRecord) -> Self {
        Self {
            seq: n.seq,
            ok: n.ok,
            text: n.text,
        }
    }
}

#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct BlockedUserRecord {
    pub id: String,
    pub name: String,
    pub avatar: Option<String>,
}

impl fmt::Debug for BlockedUserRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("BlockedUserRecord")
            .field("has_avatar", &self.avatar.is_some())
            .finish()
    }
}

impl From<BlockedUserState> for BlockedUserRecord {
    fn from(b: BlockedUserState) -> Self {
        Self {
            id: b.id,
            name: b.name,
            avatar: b.avatar,
        }
    }
}

impl From<BlockedUserRecord> for BlockedUserState {
    fn from(b: BlockedUserRecord) -> Self {
        Self {
            id: b.id,
            name: b.name,
            avatar: b.avatar,
        }
    }
}

#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct SaveAliasResultRecord {
    pub ok: bool,
    pub text: String,
}

impl fmt::Debug for SaveAliasResultRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("SaveAliasResultRecord")
            .field("ok", &self.ok)
            .finish()
    }
}

impl From<SaveAliasOutcome> for SaveAliasResultRecord {
    fn from(o: SaveAliasOutcome) -> Self {
        Self {
            ok: o.ok,
            text: o.text,
        }
    }
}

/// Full U9 contacts state snapshot delivered via `CoreChangesRecord.contacts`.
#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct ContactsStateRecord {
    pub friends: Vec<FriendEntryRecord>,
    pub groups: Vec<GroupEntryRecord>,
    pub received: Vec<FriendRequestEntryRecord>,
    pub sent: Vec<FriendRequestEntryRecord>,
    pub pending_request_count: i64,
    pub friends_loaded: bool,
    pub groups_loaded: bool,
    pub loading_requests: bool,
    pub search: ContactSearchRecord,
    pub notice: Option<ContactNoticeRecord>,
    pub blocked_users: Option<Vec<BlockedUserRecord>>,
    pub aliases: Vec<StringPairEntry>,
    pub group_details_json: Vec<StringPairEntry>,
    pub received_raw_json: Option<String>,
    pub sent_raw_json: Option<String>,
    pub friend_global_ids: Vec<StringPairEntry>,
}

impl fmt::Debug for ContactsStateRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ContactsStateRecord")
            .field("friends", &self.friends.len())
            .field("groups", &self.groups.len())
            .field("pending_request_count", &self.pending_request_count)
            .finish()
    }
}

impl From<ContactsState> for ContactsStateRecord {
    fn from(c: ContactsState) -> Self {
        Self {
            friends: c.friends.into_iter().map(Into::into).collect(),
            groups: c.groups.into_iter().map(Into::into).collect(),
            received: c.received.into_iter().map(Into::into).collect(),
            sent: c.sent.into_iter().map(Into::into).collect(),
            pending_request_count: i64::try_from(c.pending_request_count).unwrap_or(0),
            friends_loaded: c.friends_loaded,
            groups_loaded: c.groups_loaded,
            loading_requests: c.loading_requests,
            search: c.search.into(),
            notice: c.notice.map(Into::into),
            blocked_users: c
                .blocked_users
                .map(|v| v.into_iter().map(Into::into).collect()),
            aliases: c
                .aliases
                .into_iter()
                .map(|(key, value)| StringPairEntry { key, value })
                .collect(),
            group_details_json: c
                .group_details_json
                .into_iter()
                .map(|(key, value)| StringPairEntry { key, value })
                .collect(),
            received_raw_json: c.received_raw_json,
            sent_raw_json: c.sent_raw_json,
            friend_global_ids: c
                .friend_global_ids
                .into_iter()
                .map(|(key, value)| StringPairEntry { key, value })
                .collect(),
        }
    }
}

impl From<ContactsStateRecord> for ContactsState {
    fn from(c: ContactsStateRecord) -> Self {
        Self {
            friends: c.friends.into_iter().map(Into::into).collect(),
            groups: c.groups.into_iter().map(Into::into).collect(),
            received: c.received.into_iter().map(Into::into).collect(),
            sent: c.sent.into_iter().map(Into::into).collect(),
            pending_request_count: usize::try_from(c.pending_request_count.max(0)).unwrap_or(0),
            friends_loaded: c.friends_loaded,
            groups_loaded: c.groups_loaded,
            loading_requests: c.loading_requests,
            search: c.search.into(),
            notice: c.notice.map(Into::into),
            blocked_users: c
                .blocked_users
                .map(|v| v.into_iter().map(Into::into).collect()),
            aliases: c.aliases.into_iter().map(|p| (p.key, p.value)).collect(),
            group_details_json: c
                .group_details_json
                .into_iter()
                .map(|p| (p.key, p.value))
                .collect(),
            received_raw_json: c.received_raw_json,
            sent_raw_json: c.sent_raw_json,
            friend_global_ids: c
                .friend_global_ids
                .into_iter()
                .map(|p| (p.key, p.value))
                .collect(),
            cached_profiles: std::collections::BTreeMap::new(),
            cached_groups: std::collections::BTreeMap::new(),
            activity_ranks: std::collections::BTreeMap::new(),
            search_gen: 0,
            sync_in_flight: 0,
        }
    }
}

#[uniffi::export]
#[must_use]
pub fn contact_fold_ffi(text: String) -> String {
    contact_fold(&text)
}

#[uniffi::export]
#[must_use]
pub fn localized_standard_cmp_ffi(a: String, b: String) -> i8 {
    match localized_standard_cmp(&a, &b) {
        std::cmp::Ordering::Less => -1,
        std::cmp::Ordering::Equal => 0,
        std::cmp::Ordering::Greater => 1,
    }
}

#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct PersonLookupRecord {
    pub name: String,
    pub avatar: String,
}

impl fmt::Debug for PersonLookupRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("PersonLookupRecord")
            .field("has_avatar", &!self.avatar.is_empty())
            .finish()
    }
}

pub(crate) fn records_to_chat_messages(records: Vec<ChatMessageRecord>) -> Vec<ChatMessage> {
    records.iter().map(ChatMessage::from).collect()
}
