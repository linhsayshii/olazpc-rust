//! UniFFI record and enum bindings for the U3 conversations & conversation actions domain.
//!
//! All user-facing text, conversation IDs, names, avatars, and PINs are redacted in `Debug`
//! output (ADR-008).

use std::collections::BTreeMap;
use std::fmt;

use olaz_core::conversations::{
    BatchApplyDelta, CachedGroup, CachedProfile, ConvMessageDelta, ConvPreviewOverride,
    ConversationActionResult, ConversationActionUI, ConversationActionsState, ConversationExtras,
    ConversationLabel, ConversationLeaveType, ConversationPreview, ConversationPrompt,
    ConversationRemoval, ConversationSummary, ConversationToast, FriendIdentity, GroupIdentity,
    IdentityTable, MessagePreviewInput, PinBoard, StrangerBox,
};
use olaz_core::input::SeenTarget;
use olaz_wire::Mention;

#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct ConversationPreviewRecord {
    pub text: String,
    pub date_ms: Option<i64>,
    pub from_me: bool,
}

impl fmt::Debug for ConversationPreviewRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ConversationPreviewRecord")
            .field("text_len", &self.text.len())
            .field("has_date", &self.date_ms.is_some())
            .field("from_me", &self.from_me)
            .finish()
    }
}

impl From<ConversationPreview> for ConversationPreviewRecord {
    fn from(p: ConversationPreview) -> Self {
        Self {
            text: p.text,
            date_ms: p.date_ms,
            from_me: p.from_me,
        }
    }
}

impl From<ConversationPreviewRecord> for ConversationPreview {
    fn from(p: ConversationPreviewRecord) -> Self {
        Self {
            text: p.text,
            date_ms: p.date_ms,
            from_me: p.from_me,
        }
    }
}

#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct ConversationSummaryRecord {
    pub id: String,
    pub is_group: bool,
    pub name: String,
    pub avatar: Option<String>,
    pub pinned: bool,
    pub members: i64,
    pub unread: i64,
    pub preview: Option<ConversationPreviewRecord>,
}

impl fmt::Debug for ConversationSummaryRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ConversationSummaryRecord")
            .field("is_group", &self.is_group)
            .field("pinned", &self.pinned)
            .field("members", &self.members)
            .field("unread", &self.unread)
            .field("has_avatar", &self.avatar.is_some())
            .field("has_preview", &self.preview.is_some())
            .finish()
    }
}

impl From<ConversationSummary> for ConversationSummaryRecord {
    fn from(c: ConversationSummary) -> Self {
        Self {
            id: c.id,
            is_group: c.is_group,
            name: c.name,
            avatar: c.avatar,
            pinned: c.pinned,
            members: c.members,
            unread: c.unread,
            preview: c.preview.map(Into::into),
        }
    }
}

impl From<ConversationSummaryRecord> for ConversationSummary {
    fn from(c: ConversationSummaryRecord) -> Self {
        Self {
            id: c.id,
            is_group: c.is_group,
            name: c.name,
            avatar: c.avatar,
            pinned: c.pinned,
            members: c.members,
            unread: c.unread,
            preview: c.preview.map(Into::into),
        }
    }
}

#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct FlagEntry {
    pub id: String,
    pub bits: i32,
}

impl fmt::Debug for FlagEntry {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("FlagEntry")
            .field("bits", &self.bits)
            .finish()
    }
}

#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct LeaveEntry {
    pub id: String,
    pub kind: String,
}

impl fmt::Debug for LeaveEntry {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("LeaveEntry")
            .field("kind", &self.kind)
            .finish()
    }
}

#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct ConversationActionsRecord {
    pub loaded: bool,
    pub hidden_known: bool,
    pub flags: Vec<FlagEntry>,
    pub left: Vec<LeaveEntry>,
    pub hidden_enabled: bool,
    pub has_hidden_pin: bool,
    pub hidden_ids: Vec<String>,
    pub mark_unread_enabled: bool,
    pub late_epoch: i64,
    pub late_seq: i64,
}

impl fmt::Debug for ConversationActionsRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ConversationActionsRecord")
            .field("loaded", &self.loaded)
            .field("hidden_known", &self.hidden_known)
            .field("flags_count", &self.flags.len())
            .field("left_count", &self.left.len())
            .field("hidden_count", &self.hidden_ids.len())
            .finish()
    }
}

impl From<ConversationActionsState> for ConversationActionsRecord {
    fn from(s: ConversationActionsState) -> Self {
        let flags = s
            .flags
            .into_iter()
            .map(|(id, bits)| FlagEntry { id, bits })
            .collect();
        let left = s
            .left
            .into_iter()
            .map(|(id, k): (String, ConversationLeaveType)| LeaveEntry {
                id,
                kind: k.as_str().to_owned(),
            })
            .collect();
        let hidden_ids = s.hidden_ids.into_iter().collect();
        Self {
            loaded: s.loaded,
            hidden_known: s.hidden_known,
            flags,
            left,
            hidden_enabled: s.hidden_enabled,
            has_hidden_pin: s.has_hidden_pin,
            hidden_ids,
            mark_unread_enabled: s.mark_unread_enabled,
            late_epoch: s.late_epoch,
            late_seq: s.late_seq,
        }
    }
}

#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct ConversationLabelRecord {
    pub id: String,
    pub name: String,
    pub color_hex: String,
    pub conv_ids: Vec<String>,
}

impl fmt::Debug for ConversationLabelRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ConversationLabelRecord")
            .field("color_hex", &self.color_hex)
            .field("conv_count", &self.conv_ids.len())
            .finish()
    }
}

impl From<ConversationLabel> for ConversationLabelRecord {
    fn from(l: ConversationLabel) -> Self {
        Self {
            id: l.id,
            name: l.name,
            color_hex: l.color_hex,
            conv_ids: l.conv_ids,
        }
    }
}

#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct LabelAssignmentEntry {
    pub conv_id: String,
    pub label_id: String,
}

impl fmt::Debug for LabelAssignmentEntry {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("LabelAssignmentEntry(<redacted>)")
    }
}

#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct StrangerBoxRecord {
    pub chats: i64,
    pub unread_chats: i64,
    pub unread_messages: i64,
    pub newest_id: Option<String>,
}

impl fmt::Debug for StrangerBoxRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("StrangerBoxRecord")
            .field("chats", &self.chats)
            .field("unread_chats", &self.unread_chats)
            .field("unread_messages", &self.unread_messages)
            .field("has_newest", &self.newest_id.is_some())
            .finish()
    }
}

impl From<StrangerBox> for StrangerBoxRecord {
    fn from(b: StrangerBox) -> Self {
        Self {
            chats: b.chats,
            unread_chats: b.unread_chats,
            unread_messages: b.unread_messages,
            newest_id: b.newest_id,
        }
    }
}

#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct ConversationExtrasRecord {
    pub loaded: bool,
    pub labels: Vec<ConversationLabelRecord>,
    pub archived_enabled: bool,
    pub type_filter: i32,
    pub label_filter_ids: Vec<String>,
    pub list_ids: Vec<String>,
    pub stranger_ids: Vec<String>,
    pub stranger_folder_ids: Vec<String>,
    pub stranger_box: StrangerBoxRecord,
    pub label_by_conversation: Vec<LabelAssignmentEntry>,
}

impl fmt::Debug for ConversationExtrasRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ConversationExtrasRecord")
            .field("loaded", &self.loaded)
            .field("labels_count", &self.labels.len())
            .field("type_filter", &self.type_filter)
            .field("list_count", &self.list_ids.len())
            .finish()
    }
}

impl From<ConversationExtras> for ConversationExtrasRecord {
    fn from(e: ConversationExtras) -> Self {
        let label_by_conversation = e
            .label_by_conversation
            .into_iter()
            .map(|(conv_id, label_id)| LabelAssignmentEntry { conv_id, label_id })
            .collect();
        Self {
            loaded: e.loaded,
            labels: e.labels.into_iter().map(Into::into).collect(),
            archived_enabled: e.archived_enabled,
            type_filter: e.type_filter,
            label_filter_ids: e.label_filter_ids,
            list_ids: e.list_ids,
            stranger_ids: e.stranger_ids.into_iter().collect(),
            stranger_folder_ids: e.stranger_folder_ids,
            stranger_box: e.stranger_box.into(),
            label_by_conversation,
        }
    }
}

#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct ToastRecord {
    pub seq: i64,
    pub kind: String,
    pub text: String,
}

impl fmt::Debug for ToastRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ToastRecord")
            .field("seq", &self.seq)
            .field("kind", &self.kind)
            .finish()
    }
}

impl From<ConversationToast> for ToastRecord {
    fn from(t: ConversationToast) -> Self {
        Self {
            seq: t.seq,
            kind: t.kind.as_str().to_owned(),
            text: t.text,
        }
    }
}

#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct RemovalRecord {
    pub seq: i64,
    pub ids: Vec<String>,
}

impl fmt::Debug for RemovalRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("RemovalRecord")
            .field("seq", &self.seq)
            .field("count", &self.ids.len())
            .finish()
    }
}

impl From<ConversationRemoval> for RemovalRecord {
    fn from(r: ConversationRemoval) -> Self {
        Self {
            seq: r.seq,
            ids: r.ids.into_iter().collect(),
        }
    }
}

#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct ConversationActionUiRecord {
    pub toast: Option<ToastRecord>,
    pub removal: Option<RemovalRecord>,
    pub unlocked_id: Option<String>,
    pub pin_search_ids: Vec<String>,
}

impl fmt::Debug for ConversationActionUiRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ConversationActionUiRecord")
            .field("has_toast", &self.toast.is_some())
            .field("has_removal", &self.removal.is_some())
            .field("has_unlocked", &self.unlocked_id.is_some())
            .field("pin_search_count", &self.pin_search_ids.len())
            .finish()
    }
}

impl From<ConversationActionUI> for ConversationActionUiRecord {
    fn from(u: ConversationActionUI) -> Self {
        Self {
            toast: u.toast.map(Into::into),
            removal: u.removal.map(Into::into),
            unlocked_id: u.unlocked_id,
            pin_search_ids: u.pin_search_ids,
        }
    }
}

#[derive(Clone, PartialEq, Eq, uniffi::Enum)]
pub enum ConversationPromptRecord {
    Delete { id: String },
    PinBoard { id: String },
    Hide { id: String },
    Unhide { id: String },
    Unlock { id: String },
}

impl fmt::Debug for ConversationPromptRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Delete { .. } => f.write_str("Delete"),
            Self::PinBoard { .. } => f.write_str("PinBoard"),
            Self::Hide { .. } => f.write_str("Hide"),
            Self::Unhide { .. } => f.write_str("Unhide"),
            Self::Unlock { .. } => f.write_str("Unlock"),
        }
    }
}

impl From<ConversationPrompt> for ConversationPromptRecord {
    fn from(p: ConversationPrompt) -> Self {
        match p {
            ConversationPrompt::Delete(id) => Self::Delete { id },
            ConversationPrompt::PinBoard(id) => Self::PinBoard { id },
            ConversationPrompt::Hide(id) => Self::Hide { id },
            ConversationPrompt::Unhide(id) => Self::Unhide { id },
            ConversationPrompt::Unlock(id) => Self::Unlock { id },
        }
    }
}

impl From<ConversationPromptRecord> for ConversationPrompt {
    fn from(p: ConversationPromptRecord) -> Self {
        match p {
            ConversationPromptRecord::Delete { id } => Self::Delete(id),
            ConversationPromptRecord::PinBoard { id } => Self::PinBoard(id),
            ConversationPromptRecord::Hide { id } => Self::Hide(id),
            ConversationPromptRecord::Unhide { id } => Self::Unhide(id),
            ConversationPromptRecord::Unlock { id } => Self::Unlock(id),
        }
    }
}

/// Wrapper for `Option<Option<ConversationPrompt>>` in `CoreChangesRecord` (UniFFI forbids nested Option).
#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct PromptUpdateRecord {
    pub prompt: Option<ConversationPromptRecord>,
}

impl fmt::Debug for PromptUpdateRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("PromptUpdateRecord")
            .field("prompt", &self.prompt)
            .finish()
    }
}

#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct ConversationActionResultRecord {
    pub ok: bool,
    pub text: String,
    pub full: bool,
    pub bad_pin: bool,
    pub pin_exists: bool,
    pub neutral: bool,
}

impl fmt::Debug for ConversationActionResultRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ConversationActionResultRecord")
            .field("ok", &self.ok)
            .field("full", &self.full)
            .field("bad_pin", &self.bad_pin)
            .field("pin_exists", &self.pin_exists)
            .field("neutral", &self.neutral)
            .finish()
    }
}

impl From<ConversationActionResult> for ConversationActionResultRecord {
    fn from(r: ConversationActionResult) -> Self {
        Self {
            ok: r.ok,
            text: r.text,
            full: r.full,
            bad_pin: r.bad_pin,
            pin_exists: r.pin_exists,
            neutral: r.neutral,
        }
    }
}

impl From<ConversationActionResultRecord> for ConversationActionResult {
    fn from(r: ConversationActionResultRecord) -> Self {
        Self {
            ok: r.ok,
            text: r.text,
            full: r.full,
            bad_pin: r.bad_pin,
            pin_exists: r.pin_exists,
            neutral: r.neutral,
        }
    }
}

#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct PinBoardRecord {
    pub tab: i32,
    pub limit: i32,
    pub total: i32,
    pub need: i32,
    pub items: Vec<String>,
}

impl fmt::Debug for PinBoardRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("PinBoardRecord")
            .field("tab", &self.tab)
            .field("limit", &self.limit)
            .field("total", &self.total)
            .field("need", &self.need)
            .field("items_count", &self.items.len())
            .finish()
    }
}

impl From<PinBoard> for PinBoardRecord {
    fn from(b: PinBoard) -> Self {
        Self {
            tab: b.tab,
            limit: b.limit,
            total: b.total,
            need: b.need,
            items: b.items,
        }
    }
}

#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct FriendIdentityRecord {
    pub id: String,
    pub name: String,
    pub avatar: Option<String>,
}

impl fmt::Debug for FriendIdentityRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("FriendIdentityRecord(<redacted>)")
    }
}

#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct GroupIdentityRecord {
    pub id: String,
    pub name: String,
    pub avatar: Option<String>,
    pub members: i64,
}

impl fmt::Debug for GroupIdentityRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("GroupIdentityRecord")
            .field("members", &self.members)
            .finish()
    }
}

#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct CachedProfileEntry {
    pub uid: String,
    pub name: String,
    pub avatar: String,
}

impl fmt::Debug for CachedProfileEntry {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("CachedProfileEntry(<redacted>)")
    }
}

#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct CachedGroupEntry {
    pub gid: String,
    pub name: String,
    pub avatar: String,
    pub members: i64,
}

impl fmt::Debug for CachedGroupEntry {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("CachedGroupEntry")
            .field("members", &self.members)
            .finish()
    }
}

#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct StringPairEntry {
    pub key: String,
    pub value: String,
}

impl fmt::Debug for StringPairEntry {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("StringPairEntry(<redacted>)")
    }
}

#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct RankEntry {
    pub conv_id: String,
    pub rank: i64,
}

impl fmt::Debug for RankEntry {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("RankEntry")
            .field("rank", &self.rank)
            .finish()
    }
}

#[derive(Clone, Default, PartialEq, Eq, uniffi::Record)]
pub struct IdentityTableRecord {
    pub friends: Vec<FriendIdentityRecord>,
    pub groups: Vec<GroupIdentityRecord>,
    pub friends_loaded: bool,
    pub groups_loaded: bool,
    pub aliases: Vec<StringPairEntry>,
    pub cached_profiles: Vec<CachedProfileEntry>,
    pub cached_groups: Vec<CachedGroupEntry>,
    pub activity_ranks: Vec<RankEntry>,
    pub friend_global_ids: Vec<StringPairEntry>,
}

impl fmt::Debug for IdentityTableRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("IdentityTableRecord")
            .field("friends", &self.friends.len())
            .field("groups", &self.groups.len())
            .field("aliases", &self.aliases.len())
            .field("cached_profiles", &self.cached_profiles.len())
            .field("cached_groups", &self.cached_groups.len())
            .field("activity_ranks", &self.activity_ranks.len())
            .finish()
    }
}

impl From<IdentityTableRecord> for IdentityTable {
    fn from(r: IdentityTableRecord) -> Self {
        let mut aliases = BTreeMap::new();
        for e in r.aliases {
            aliases.insert(e.key, e.value);
        }
        let mut cached_profiles = BTreeMap::new();
        for e in r.cached_profiles {
            cached_profiles.insert(
                e.uid,
                CachedProfile {
                    name: e.name,
                    avatar: e.avatar,
                },
            );
        }
        let mut cached_groups = BTreeMap::new();
        for e in r.cached_groups {
            cached_groups.insert(
                e.gid,
                CachedGroup {
                    name: e.name,
                    avatar: e.avatar,
                    members: e.members,
                },
            );
        }
        let mut activity_ranks = BTreeMap::new();
        for e in r.activity_ranks {
            activity_ranks.insert(e.conv_id, e.rank);
        }
        let mut friend_global_ids = BTreeMap::new();
        for e in r.friend_global_ids {
            friend_global_ids.insert(e.key, e.value);
        }
        Self {
            friends: r
                .friends
                .into_iter()
                .map(|f| FriendIdentity {
                    id: f.id,
                    name: f.name,
                    avatar: f.avatar,
                })
                .collect(),
            groups: r
                .groups
                .into_iter()
                .map(|g| GroupIdentity {
                    id: g.id,
                    name: g.name,
                    avatar: g.avatar,
                    members: g.members,
                })
                .collect(),
            friends_loaded: r.friends_loaded,
            groups_loaded: r.groups_loaded,
            aliases,
            cached_profiles,
            cached_groups,
            activity_ranks,
            friend_global_ids,
        }
    }
}

#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct ConvMessageDeltaRecord {
    pub conv_id: String,
    pub preview_text: String,
    pub preview_date_ms: i64,
    pub preview_from_me: bool,
    pub is_mine: bool,
    pub sender_name: String,
    pub sender_avatar: Option<String>,
    pub unread_delta: i64,
}

impl fmt::Debug for ConvMessageDeltaRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ConvMessageDeltaRecord")
            .field("preview_len", &self.preview_text.len())
            .field("unread_delta", &self.unread_delta)
            .finish()
    }
}

impl From<ConvMessageDeltaRecord> for ConvMessageDelta {
    fn from(d: ConvMessageDeltaRecord) -> Self {
        Self {
            conv_id: d.conv_id,
            preview_text: d.preview_text,
            preview_date_ms: d.preview_date_ms,
            preview_from_me: d.preview_from_me,
            is_mine: d.is_mine,
            sender_name: d.sender_name,
            sender_avatar: d.sender_avatar,
            unread_delta: d.unread_delta,
        }
    }
}

#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct ConvPreviewOverrideRecord {
    pub conv_id: String,
    pub target_date_ms: i64,
    pub preview: Option<ConversationPreviewRecord>,
}

impl fmt::Debug for ConvPreviewOverrideRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ConvPreviewOverrideRecord")
            .field("target_date_ms", &self.target_date_ms)
            .field("has_preview", &self.preview.is_some())
            .finish()
    }
}

impl From<ConvPreviewOverrideRecord> for ConvPreviewOverride {
    fn from(o: ConvPreviewOverrideRecord) -> Self {
        Self {
            conv_id: o.conv_id,
            target_date_ms: o.target_date_ms,
            preview: o.preview.map(Into::into),
        }
    }
}

#[derive(Clone, Default, PartialEq, Eq, uniffi::Record)]
pub struct BatchApplyDeltaRecord {
    pub applied_count: u32,
    pub updates: Vec<ConvMessageDeltaRecord>,
    pub preview_overrides: Vec<ConvPreviewOverrideRecord>,
    pub persist_conversations: bool,
}

impl fmt::Debug for BatchApplyDeltaRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("BatchApplyDeltaRecord")
            .field("applied_count", &self.applied_count)
            .field("updates", &self.updates.len())
            .field("preview_overrides", &self.preview_overrides.len())
            .field("persist_conversations", &self.persist_conversations)
            .finish()
    }
}

impl From<BatchApplyDeltaRecord> for BatchApplyDelta {
    fn from(d: BatchApplyDeltaRecord) -> Self {
        Self {
            applied_count: d.applied_count,
            updates: d.updates.into_iter().map(Into::into).collect(),
            preview_overrides: d.preview_overrides.into_iter().map(Into::into).collect(),
            persist_conversations: d.persist_conversations,
        }
    }
}

#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct MentionInputRecord {
    pub uid: String,
    pub pos: i64,
    pub len: i64,
    pub is_all: bool,
}

impl fmt::Debug for MentionInputRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("MentionInputRecord")
            .field("pos", &self.pos)
            .field("len", &self.len)
            .field("is_all", &self.is_all)
            .finish()
    }
}

#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct MessagePreviewInputRecord {
    pub conv_id: String,
    pub text: String,
    pub mentions: Vec<MentionInputRecord>,
    pub preview_label: String,
    pub date_ms: i64,
    pub is_mine: bool,
    pub sender_name: String,
    pub sender_avatar: Option<String>,
}

impl fmt::Debug for MessagePreviewInputRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("MessagePreviewInputRecord")
            .field("text_len", &self.text.len())
            .field("mentions", &self.mentions.len())
            .field("is_mine", &self.is_mine)
            .finish()
    }
}

impl From<MessagePreviewInputRecord> for MessagePreviewInput {
    fn from(m: MessagePreviewInputRecord) -> Self {
        Self {
            conv_id: m.conv_id,
            text: m.text,
            mentions: m
                .mentions
                .into_iter()
                .map(|x| Mention {
                    uid: x.uid,
                    pos: x.pos,
                    len: x.len,
                    is_all: x.is_all,
                })
                .collect(),
            preview_label: m.preview_label,
            date_ms: m.date_ms,
            is_mine: m.is_mine,
            sender_name: m.sender_name,
            sender_avatar: m.sender_avatar,
        }
    }
}

#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct SeenTargetRecord {
    pub conv_id: String,
    pub msg_id: String,
    pub cli_msg_id: String,
    pub sender_id: String,
}

impl fmt::Debug for SeenTargetRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("SeenTargetRecord")
            .field("has_conv_id", &!self.conv_id.is_empty())
            .field("has_msg_id", &!self.msg_id.is_empty())
            .finish()
    }
}

impl From<SeenTargetRecord> for SeenTarget {
    fn from(s: SeenTargetRecord) -> Self {
        Self {
            conv_id: s.conv_id,
            msg_id: s.msg_id,
            cli_msg_id: s.cli_msg_id,
            sender_id: s.sender_id,
        }
    }
}
