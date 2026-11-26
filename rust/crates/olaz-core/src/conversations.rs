//! Conversations & conversation-actions domain state and pure helpers (U3).
//!
//! Port of `ZaloEngine.swift` (list ordering, previews, mention renaming, identity lookup,
//! known contacts merge), `ZaloEngine+Conversations.swift` (labels, filters, stranger box),
//! and `ZaloEngine+ConversationActions.swift` (flags, pin board, hidden chats, toasts, prompts).
//!
//! `Debug` implementations on types carrying names, avatars, message texts, PIN digests, or
//! conversation IDs emit shape-only summaries (ADR-008).

use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::fmt;

use olaz_crypto::{md5_hex, sha256_hex};
use olaz_json::{bool_value, int64, parse_any, parse_object, string, to_swift_json_string};
use olaz_store::{Store, StoredConversation};
use olaz_wire::{
    ChatMessage, Kind, Mention, UNKNOWN_NAME, is_group_id, normalize_thread_id_from_list,
    sanitize_profile_uid, strip_user_prefix,
};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};

/// Official bitmask flags of `ConversationActionFlags` (`ZaloEngine+ConversationActions.swift`).
pub const FLAG_PINNED: i32 = 1;
pub const FLAG_ARCHIVED: i32 = 2;
pub const FLAG_HIDDEN: i32 = 4;
pub const FLAG_CANNOT_PIN: i32 = 8;
pub const FLAG_CANNOT_ARCHIVE: i32 = 16;
pub const FLAG_CANNOT_MUTE: i32 = 32;
pub const FLAG_CANNOT_DELETE: i32 = 64;
pub const FLAG_NO_PIN_MENU: i32 = 128;
pub const FLAG_CANNOT_HIDE: i32 = 256;
pub const FLAG_UNREAD_MARK: i32 = 512;

/// Official id of the list pseudo-row for the stranger folder.
pub const STRANGER_BOX_ID: &str = "stranger_box";

/// Official pin limit for tab 0 (`PIN_LIMIT`).
pub const PIN_LIMIT: usize = 10;

/// Official `FilterType` raw values (`ConversationTypeFilter`).
pub const FILTER_ALL: i32 = 0;
pub const FILTER_UNREAD: i32 = 1;
pub const FILTER_FOCUSED: i32 = 3;
pub const FILTER_OTHER: i32 = 4;

// --- Models ---

/// Preview snippet on a [`ConversationSummary`].
#[derive(Clone, PartialEq, Eq)]
pub struct ConversationPreview {
    pub text: String,
    pub date_ms: Option<i64>,
    pub from_me: bool,
}

impl fmt::Debug for ConversationPreview {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ConversationPreview")
            .field("text_len", &self.text.len())
            .field("has_date", &self.date_ms.is_some())
            .field("from_me", &self.from_me)
            .finish()
    }
}

/// One row of the conversation sidebar (`ZaloEngine.ConversationSummary`).
#[derive(Clone, PartialEq, Eq)]
pub struct ConversationSummary {
    pub id: String,
    pub is_group: bool,
    pub name: String,
    pub avatar: Option<String>,
    pub pinned: bool,
    pub members: i64,
    pub unread: i64,
    pub preview: Option<ConversationPreview>,
}

impl fmt::Debug for ConversationSummary {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ConversationSummary")
            .field("is_group", &self.is_group)
            .field("pinned", &self.pinned)
            .field("members", &self.members)
            .field("unread", &self.unread)
            .field("has_avatar", &self.avatar.is_some())
            .field("has_preview", &self.preview.is_some())
            .finish()
    }
}

/// Why a group no longer lists its normal menu (`ConversationLeaveType`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ConversationLeaveType {
    Kick,
    Disband,
}

impl ConversationLeaveType {
    #[must_use]
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Kick => "kick",
            Self::Disband => "disband",
        }
    }

    #[must_use]
    pub fn from_wire(raw: &str) -> Self {
        match raw {
            "disband" => Self::Disband,
            _ => Self::Kick,
        }
    }
}

/// Mirror of `ConversationActionsState` (per-conversation menu flags & hidden-chat state).
#[derive(Clone, Default, PartialEq, Eq)]
pub struct ConversationActionsState {
    pub loaded: bool,
    pub hidden_known: bool,
    pub flags: BTreeMap<String, i32>,
    pub left: BTreeMap<String, ConversationLeaveType>,
    pub hidden_enabled: bool,
    pub has_hidden_pin: bool,
    pub hidden_ids: BTreeSet<String>,
    pub mark_unread_enabled: bool,
    pub late_epoch: i64,
    pub late_seq: i64,
}

impl ConversationActionsState {
    #[must_use]
    pub fn flags_for(&self, id: &str) -> i32 {
        self.flags.get(id).copied().unwrap_or(0)
    }

    #[must_use]
    pub fn is_pinned(&self, id: &str) -> bool {
        (self.flags_for(id) & FLAG_PINNED) != 0
    }

    #[must_use]
    pub fn is_hidden(&self, id: &str) -> bool {
        self.hidden_ids.contains(id) || (self.flags_for(id) & FLAG_HIDDEN) != 0
    }

    #[must_use]
    pub fn has_unread_mark(&self, id: &str) -> bool {
        (self.flags_for(id) & FLAG_UNREAD_MARK) != 0
    }

    /// Applies a `convActions` JSON object (`ConversationActionsState.apply(json:)`).
    pub fn apply_json(&mut self, json: &Map<String, Value>) {
        if let Some(Value::Object(hidden)) = json.get("hidden") {
            self.hidden_known = true;
            self.hidden_enabled = bool_value(hidden.get("enabled")).unwrap_or(false);
            self.has_hidden_pin = bool_value(hidden.get("hasPin")).unwrap_or(false);
            let mut ids = BTreeSet::new();
            if let Some(Value::Array(arr)) = hidden.get("ids") {
                for item in arr {
                    if let Some(s) = item.as_str() {
                        ids.insert(s.to_owned());
                    }
                }
            }
            self.hidden_ids = ids;
        }
        let Some(Value::Object(raw_flags)) = json.get("flags") else {
            return;
        };
        self.loaded = true;
        let mut next_flags = BTreeMap::new();
        for (id, value) in raw_flags {
            if let Some(bits) = int64(Some(value))
                && bits != 0
                && let Ok(bits_i32) = i32::try_from(bits)
            {
                next_flags.insert(id.clone(), bits_i32);
            }
        }
        self.flags = next_flags;

        let mut leaves = BTreeMap::new();
        if let Some(Value::Object(raw_left)) = json.get("left") {
            for (id, value) in raw_left {
                let leave = value.as_str().map_or(
                    ConversationLeaveType::Kick,
                    ConversationLeaveType::from_wire,
                );
                leaves.insert(id.clone(), leave);
            }
        }
        self.left = leaves;
        self.mark_unread_enabled = bool_value(json.get("markUnread")).unwrap_or(false);
    }
}

impl fmt::Debug for ConversationActionsState {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ConversationActionsState")
            .field("loaded", &self.loaded)
            .field("hidden_known", &self.hidden_known)
            .field("hidden_enabled", &self.hidden_enabled)
            .field("has_hidden_pin", &self.has_hidden_pin)
            .field("hidden_count", &self.hidden_ids.len())
            .field("flags_count", &self.flags.len())
            .field("left_count", &self.left.len())
            .field("mark_unread_enabled", &self.mark_unread_enabled)
            .field("late_epoch", &self.late_epoch)
            .field("late_seq", &self.late_seq)
            .finish()
    }
}

/// Kind of action toast (`ConversationActionUI.Toast.Kind`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ToastKind {
    Success,
    Neutral,
    Failure,
}

impl ToastKind {
    #[must_use]
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Success => "success",
            Self::Neutral => "neutral",
            Self::Failure => "failure",
        }
    }
}

/// Action toast (`ConversationActionUI.Toast`).
#[derive(Clone, PartialEq, Eq)]
pub struct ConversationToast {
    pub seq: i64,
    pub kind: ToastKind,
    pub text: String,
}

impl fmt::Debug for ConversationToast {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ConversationToast")
            .field("seq", &self.seq)
            .field("kind", &self.kind)
            .field("text_len", &self.text.len())
            .finish()
    }
}

/// Conversations that left the visible list (`ConversationActionUI.Removal`).
#[derive(Clone, PartialEq, Eq)]
pub struct ConversationRemoval {
    pub seq: i64,
    pub ids: BTreeSet<String>,
}

impl fmt::Debug for ConversationRemoval {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ConversationRemoval")
            .field("seq", &self.seq)
            .field("count", &self.ids.len())
            .finish()
    }
}

/// Client-side UI state of conversation actions (`ConversationActionUI`).
#[derive(Clone, Default, PartialEq, Eq)]
pub struct ConversationActionUI {
    pub toast: Option<ConversationToast>,
    pub removal: Option<ConversationRemoval>,
    pub unlocked_id: Option<String>,
    pub pin_search_ids: Vec<String>,
    seq: i64,
}

impl ConversationActionUI {
    pub fn show(&mut self, kind: ToastKind, text: impl Into<String>) {
        self.seq = self.seq.saturating_add(1);
        self.toast = Some(ConversationToast {
            seq: self.seq,
            kind,
            text: text.into(),
        });
    }

    pub fn remove(&mut self, ids: BTreeSet<String>) {
        if ids.is_empty() {
            return;
        }
        self.seq = self.seq.saturating_add(1);
        if let Some(unlocked) = &self.unlocked_id
            && ids.contains(unlocked)
        {
            self.unlocked_id = None;
        }
        self.removal = Some(ConversationRemoval { seq: self.seq, ids });
    }

    pub fn unlock(&mut self, id: String) {
        self.unlocked_id = Some(id);
    }

    #[must_use]
    pub fn is_unlocked(&self, id: &str) -> bool {
        self.unlocked_id.as_deref() == Some(id)
    }

    pub fn set_pin_search(&mut self, ids: Vec<String>) {
        if self.pin_search_ids != ids {
            self.pin_search_ids = ids;
        }
    }

    pub fn drop_unlock(&mut self) {
        self.unlocked_id = None;
    }

    pub fn relock(&mut self) {
        self.unlocked_id = None;
        if !self.pin_search_ids.is_empty() {
            self.pin_search_ids.clear();
        }
    }

    pub fn reset(&mut self) {
        self.relock();
        self.toast = None;
        self.removal = None;
    }
}

impl fmt::Debug for ConversationActionUI {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ConversationActionUI")
            .field("has_toast", &self.toast.is_some())
            .field("has_removal", &self.removal.is_some())
            .field("has_unlocked", &self.unlocked_id.is_some())
            .field("pin_search_count", &self.pin_search_ids.len())
            .finish()
    }
}

/// Result of a conversation action (`ConversationActionResult`).
#[derive(Clone, PartialEq, Eq)]
pub struct ConversationActionResult {
    pub ok: bool,
    pub text: String,
    pub full: bool,
    pub bad_pin: bool,
    pub pin_exists: bool,
    pub neutral: bool,
}

impl ConversationActionResult {
    #[must_use]
    pub fn ok(text: impl Into<String>) -> Self {
        Self {
            ok: true,
            text: text.into(),
            full: false,
            bad_pin: false,
            pin_exists: false,
            neutral: false,
        }
    }

    #[must_use]
    pub fn ok_neutral(text: impl Into<String>, neutral: bool) -> Self {
        Self {
            ok: true,
            text: text.into(),
            full: false,
            bad_pin: false,
            pin_exists: false,
            neutral,
        }
    }

    #[must_use]
    pub fn fail(text: impl Into<String>) -> Self {
        Self {
            ok: false,
            text: text.into(),
            full: false,
            bad_pin: false,
            pin_exists: false,
            neutral: false,
        }
    }

    #[must_use]
    pub fn bad_pin(text: impl Into<String>) -> Self {
        Self {
            ok: false,
            text: text.into(),
            full: false,
            bad_pin: true,
            pin_exists: false,
            neutral: false,
        }
    }

    #[must_use]
    pub fn pin_exists(text: impl Into<String>) -> Self {
        Self {
            ok: false,
            text: text.into(),
            full: false,
            bad_pin: false,
            pin_exists: true,
            neutral: false,
        }
    }
}

impl fmt::Debug for ConversationActionResult {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ConversationActionResult")
            .field("ok", &self.ok)
            .field("text_len", &self.text.len())
            .field("full", &self.full)
            .field("bad_pin", &self.bad_pin)
            .field("pin_exists", &self.pin_exists)
            .field("neutral", &self.neutral)
            .finish()
    }
}

/// Full-board dialog payload (`PinBoard`).
#[derive(Clone, PartialEq, Eq)]
pub struct PinBoard {
    pub tab: i32,
    pub limit: i32,
    pub total: i32,
    pub need: i32,
    pub items: Vec<String>,
}

impl fmt::Debug for PinBoard {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("PinBoard")
            .field("tab", &self.tab)
            .field("limit", &self.limit)
            .field("total", &self.total)
            .field("need", &self.need)
            .field("items_count", &self.items.len())
            .finish()
    }
}

/// Sheet / alert prompt requested by a conversation action (`ConversationPrompt`).
#[derive(Clone, PartialEq, Eq)]
pub enum ConversationPrompt {
    Delete(String),
    PinBoard(String),
    Hide(String),
    Unhide(String),
    Unlock(String),
}

impl ConversationPrompt {
    #[must_use]
    pub fn kind_name(&self) -> &'static str {
        match self {
            Self::Delete(_) => "delete",
            Self::PinBoard(_) => "pin_board",
            Self::Hide(_) => "hide",
            Self::Unhide(_) => "unhide",
            Self::Unlock(_) => "unlock",
        }
    }

    #[must_use]
    pub fn conv_id(&self) -> &str {
        match self {
            Self::Delete(id)
            | Self::PinBoard(id)
            | Self::Hide(id)
            | Self::Unhide(id)
            | Self::Unlock(id) => id,
        }
    }
}

impl fmt::Debug for ConversationPrompt {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ConversationPrompt")
            .field("kind", &self.kind_name())
            .finish()
    }
}

/// One conversation label (`ConversationExtras.Label`).
#[derive(Clone, PartialEq, Eq)]
pub struct ConversationLabel {
    pub id: String,
    pub name: String,
    pub color_hex: String,
    pub conv_ids: Vec<String>,
}

impl fmt::Debug for ConversationLabel {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ConversationLabel")
            .field("name_len", &self.name.len())
            .field("conv_count", &self.conv_ids.len())
            .finish()
    }
}

/// Pseudo-row statistics for the stranger folder (`ConversationExtras.StrangerBox`).
#[derive(Clone, Default, PartialEq, Eq)]
pub struct StrangerBox {
    pub chats: i64,
    pub unread_chats: i64,
    pub unread_messages: i64,
    pub newest_id: Option<String>,
}

impl fmt::Debug for StrangerBox {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("StrangerBox")
            .field("chats", &self.chats)
            .field("unread_chats", &self.unread_chats)
            .field("unread_messages", &self.unread_messages)
            .field("has_newest", &self.newest_id.is_some())
            .finish()
    }
}

/// Labels, filters, stranger folder (`ConversationExtras`).
#[derive(Clone, Default, PartialEq, Eq)]
pub struct ConversationExtras {
    pub loaded: bool,
    pub labels: Vec<ConversationLabel>,
    pub archived_enabled: bool,
    pub type_filter: i32,
    pub label_filter_ids: Vec<String>,
    pub list_ids: Vec<String>,
    pub stranger_ids: BTreeSet<String>,
    pub stranger_folder_ids: Vec<String>,
    pub stranger_box: StrangerBox,
    pub label_by_conversation: BTreeMap<String, String>,
}

impl fmt::Debug for ConversationExtras {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ConversationExtras")
            .field("loaded", &self.loaded)
            .field("labels_count", &self.labels.len())
            .field("archived_enabled", &self.archived_enabled)
            .field("type_filter", &self.type_filter)
            .field("label_filter_count", &self.label_filter_ids.len())
            .field("list_count", &self.list_ids.len())
            .field("stranger_count", &self.stranger_ids.len())
            .field("stranger_folder_count", &self.stranger_folder_ids.len())
            .finish()
    }
}

// --- Identity Mirror Table (pushed synchronously from Swift until U6) ---

#[derive(Clone, PartialEq, Eq)]
pub struct FriendIdentity {
    pub id: String,
    pub name: String,
    pub avatar: Option<String>,
}

impl fmt::Debug for FriendIdentity {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("FriendIdentity")
            .field("has_name", &!self.name.is_empty())
            .field("has_avatar", &self.avatar.is_some())
            .finish()
    }
}

#[derive(Clone, PartialEq, Eq)]
pub struct GroupIdentity {
    pub id: String,
    pub name: String,
    pub avatar: Option<String>,
    pub members: i64,
}

impl fmt::Debug for GroupIdentity {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("GroupIdentity")
            .field("has_name", &!self.name.is_empty())
            .field("has_avatar", &self.avatar.is_some())
            .field("members", &self.members)
            .finish()
    }
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CachedProfile {
    pub name: String,
    pub avatar: String,
}

impl fmt::Debug for CachedProfile {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("CachedProfile")
            .field("has_name", &!self.name.is_empty())
            .field("has_avatar", &!self.avatar.is_empty())
            .finish()
    }
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CachedGroup {
    pub name: String,
    pub avatar: String,
    pub members: i64,
}

impl fmt::Debug for CachedGroup {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("CachedGroup")
            .field("has_name", &!self.name.is_empty())
            .field("has_avatar", &!self.avatar.is_empty())
            .field("members", &self.members)
            .finish()
    }
}

/// Contacts/caches read-only mirror pushed by Swift whenever contacts/aliases/groups/ranks mutate.
#[derive(Clone, Default, PartialEq, Eq)]
pub struct IdentityTable {
    pub friends: Vec<FriendIdentity>,
    pub groups: Vec<GroupIdentity>,
    pub friends_loaded: bool,
    pub groups_loaded: bool,
    pub aliases: BTreeMap<String, String>,
    pub cached_profiles: BTreeMap<String, CachedProfile>,
    pub cached_groups: BTreeMap<String, CachedGroup>,
    /// `uid -> globalId` (Swift `cachedFriendGlobalIds`).
    pub friend_global_ids: BTreeMap<String, String>,
    pub activity_ranks: BTreeMap<String, i64>,
}

impl fmt::Debug for IdentityTable {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("IdentityTable")
            .field("friends", &self.friends.len())
            .field("groups", &self.groups.len())
            .field("friends_loaded", &self.friends_loaded)
            .field("groups_loaded", &self.groups_loaded)
            .field("aliases", &self.aliases.len())
            .field("cached_profiles", &self.cached_profiles.len())
            .field("cached_groups", &self.cached_groups.len())
            .field("friend_global_ids", &self.friend_global_ids.len())
            .field("activity_ranks", &self.activity_ranks.len())
            .finish()
    }
}

// --- Batch & Single-Message Update Deltas ---

/// Per-conversation summary delta returned by Swift after applying a wire batch
/// (approved U3 design: no parallel `seen_msg_ids` set in core).
#[derive(Clone, PartialEq, Eq)]
pub struct ConvMessageDelta {
    pub conv_id: String,
    /// Preview label computed via `message_preview_label` (raw text / kind label, no mention rename).
    pub preview_text: String,
    pub preview_date_ms: i64,
    pub preview_from_me: bool,
    pub is_mine: bool,
    pub sender_name: String,
    pub sender_avatar: Option<String>,
    pub unread_delta: i64,
}

impl fmt::Debug for ConvMessageDelta {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ConvMessageDelta")
            .field("preview_len", &self.preview_text.len())
            .field("preview_from_me", &self.preview_from_me)
            .field("is_mine", &self.is_mine)
            .field("unread_delta", &self.unread_delta)
            .finish()
    }
}

/// Preview override produced by Pass 2 recalls / deletes for a conversation.
#[derive(Clone, PartialEq, Eq)]
pub struct ConvPreviewOverride {
    pub conv_id: String,
    /// Timestamp (ms) of the recalled or deleted message; applied only when the conversation's
    /// current preview date is `<= target_date_ms + 1_000`.
    pub target_date_ms: i64,
    /// Replacement preview (`None` clears `conv.preview` when no remaining message exists).
    pub preview: Option<ConversationPreview>,
}

impl fmt::Debug for ConvPreviewOverride {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ConvPreviewOverride")
            .field("target_date_ms", &self.target_date_ms)
            .field("has_preview", &self.preview.is_some())
            .finish()
    }
}

/// Result returned by `Host::apply_batch` and `Host::apply_parsed_events`.
#[derive(Clone, Default, PartialEq, Eq)]
pub struct BatchApplyDelta {
    /// Total number of parsed events applied in this batch (`0` means no-op).
    pub applied_count: u32,
    /// Per-conversation latest message + unread delta from Pass 1.
    pub updates: Vec<ConvMessageDelta>,
    /// Per-conversation preview overrides from Pass 2 recalls / deletes, applied in order after `updates`.
    pub preview_overrides: Vec<ConvPreviewOverride>,
    /// Whether `conversations` should be persisted to SQLite after applying this batch.
    pub persist_conversations: bool,
}

impl fmt::Debug for BatchApplyDelta {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("BatchApplyDelta")
            .field("applied_count", &self.applied_count)
            .field("updates_count", &self.updates.len())
            .field("preview_overrides_count", &self.preview_overrides.len())
            .field("persist_conversations", &self.persist_conversations)
            .finish()
    }
}

/// Input to `update_conversation_on_message` (single message path with `@mention` renaming).
#[derive(Clone, PartialEq, Eq)]
pub struct MessagePreviewInput {
    pub conv_id: String,
    pub text: String,
    pub mentions: Vec<Mention>,
    /// Result of `message_preview_label(msg)`.
    pub preview_label: String,
    pub date_ms: i64,
    pub is_mine: bool,
    pub sender_name: String,
    pub sender_avatar: Option<String>,
}

impl MessagePreviewInput {
    /// Builds a [`MessagePreviewInput`] from a decoded [`ChatMessage`].
    #[must_use]
    pub fn from_chat_message(msg: &ChatMessage) -> Self {
        Self {
            conv_id: msg.conversation_id.clone(),
            text: msg.text.clone(),
            mentions: msg.mentions.clone(),
            preview_label: message_preview_label(msg),
            date_ms: msg.date_ms,
            is_mine: msg.is_mine,
            sender_name: msg.sender_name.clone(),
            sender_avatar: msg.sender_avatar.clone().filter(|s| !s.is_empty()),
        }
    }
}

impl fmt::Debug for MessagePreviewInput {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("MessagePreviewInput")
            .field("text_len", &self.text.len())
            .field("mentions_count", &self.mentions.len())
            .field("is_mine", &self.is_mine)
            .finish()
    }
}

/// Snapshot of local SQLite data hydrated during `prepare_store` / `loadLocalAccountState`.
#[derive(Clone, Default, PartialEq)]
pub struct LocalAccountHydration {
    pub conversations: Vec<StoredConversation>,
    pub pinned_ids: Vec<String>,
    pub archived_ids: Vec<String>,
    pub unread_marks: Vec<String>,
    pub hidden_ids: Vec<String>,
    pub hidden_pin_md5: Option<String>,
    pub hidden_pin_hash: Option<String>,
    pub labels: Vec<ConversationLabel>,
    pub aliases: BTreeMap<String, String>,
    pub cached_profiles: BTreeMap<String, CachedProfile>,
    pub cached_groups: BTreeMap<String, CachedGroup>,
    pub activity_ranks: BTreeMap<String, i64>,
    pub friend_global_ids: BTreeMap<String, String>,
    /// Latest decoded message for group conversations whose preview contains `@`.
    pub group_latest_messages: BTreeMap<String, MessagePreviewInput>,
    // U6
    pub starred_ids: Vec<String>,
    pub seen_reaction_event_ids: Vec<String>,
    // U16
    pub notif_enabled: bool,
    pub notif_sound: bool,
    pub muted_threads: Option<BTreeMap<String, crate::notify::MuteInfo>>,
}

impl fmt::Debug for LocalAccountHydration {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("LocalAccountHydration")
            .field("conversations", &self.conversations.len())
            .field("pinned_ids", &self.pinned_ids.len())
            .field("archived_ids", &self.archived_ids.len())
            .field("unread_marks", &self.unread_marks.len())
            .field("hidden_ids", &self.hidden_ids.len())
            .field("has_hidden_md5", &self.hidden_pin_md5.is_some())
            .field("has_hidden_hash", &self.hidden_pin_hash.is_some())
            .field("labels", &self.labels.len())
            .field("aliases", &self.aliases.len())
            .field("cached_profiles", &self.cached_profiles.len())
            .field("cached_groups", &self.cached_groups.len())
            .field("activity_ranks", &self.activity_ranks.len())
            .finish()
    }
}

// --- Conversations Domain State ---

/// Full conversations & conversation-actions domain state inside `CoreState`.
#[derive(Clone, Default)]
pub struct ConversationsState {
    pub conversations: Vec<ConversationSummary>,
    pub actions: ConversationActionsState,
    pub ui: ConversationActionUI,
    pub extras: ConversationExtras,
    pub prompt: Option<ConversationPrompt>,
    pub identities: IdentityTable,
    pub pinned_ids: BTreeSet<String>,
    pub archived_ids: BTreeSet<String>,
    pub unread_marks: BTreeSet<String>,
    pub hidden_pin_md5: Option<String>,
    pub hidden_pin_hash: Option<String>,
    pub open_conversation_id: Option<String>,
    pub last_pin_board: Option<PinBoard>,
    pub last_action_result: Option<ConversationActionResult>,
}

impl ConversationsState {
    /// Resets all conversation-domain state on log out / session expiry.
    pub fn reset(&mut self) {
        self.conversations.clear();
        self.actions = ConversationActionsState::default();
        self.ui.reset();
        self.extras = ConversationExtras::default();
        self.prompt = None;
        self.identities = IdentityTable::default();
        self.pinned_ids.clear();
        self.archived_ids.clear();
        self.unread_marks.clear();
        self.hidden_pin_md5 = None;
        self.hidden_pin_hash = None;
        self.open_conversation_id = None;
        self.last_pin_board = None;
        self.last_action_result = None;
    }

    /// Looks up a person's display name and avatar URL (`ZaloEngine.lookupPersonInfo`).
    #[must_use]
    pub fn lookup_person_info(
        &self,
        uid: &str,
        my_uid: &str,
        my_avatar: Option<&str>,
    ) -> Option<(String, String)> {
        let clean = strip_user_prefix(uid);
        if clean.is_empty()
            || clean == "0"
            || clean == "-1"
            || clean == "__legacy__"
            || clean == "unknown"
        {
            return None;
        }
        let mut candidates = vec![clean.clone()];
        if let Some(sanitized) = sanitize_profile_uid(&clean)
            && sanitized != clean
        {
            candidates.push(sanitized);
        }
        // Reverse lookup gid -> uid (first key matching value in BTreeMap order).
        if let Some(mapped_uid) = candidates.iter().find_map(|cand| {
            self.identities
                .friend_global_ids
                .iter()
                .find_map(|(u, g)| (g == cand).then(|| u.clone()))
        }) && !candidates.contains(&mapped_uid)
        {
            candidates.push(mapped_uid);
        }

        let clean_my_uid = strip_user_prefix(my_uid);
        let sanitized_my_uid = sanitize_profile_uid(&clean_my_uid).unwrap_or(clean_my_uid.clone());
        if !clean_my_uid.is_empty()
            && candidates
                .iter()
                .any(|c| c == &clean_my_uid || c == &sanitized_my_uid)
        {
            return Some(("Bạn".to_owned(), my_avatar.unwrap_or("").to_owned()));
        }

        for candidate in &candidates {
            let alias = self.identities.aliases.get(candidate).map(String::as_str);
            if let Some(f) = self.identities.friends.iter().find(|f| f.id == *candidate) {
                let avt = f
                    .avatar
                    .as_deref()
                    .or_else(|| {
                        self.identities
                            .cached_profiles
                            .get(candidate)
                            .map(|p| p.avatar.as_str())
                    })
                    .unwrap_or("")
                    .to_owned();
                let name = match alias {
                    Some(a) if !a.is_empty() => a.to_owned(),
                    _ => f.name.clone(),
                };
                return Some((name, avt));
            }
            if let Some(p) = self.identities.cached_profiles.get(candidate) {
                let best = match alias {
                    Some(a) if !a.is_empty() => a,
                    _ => p.name.as_str(),
                };
                let valid_best = if best == UNKNOWN_NAME { "" } else { best };
                if !valid_best.is_empty() || !p.avatar.is_empty() {
                    return Some((valid_best.to_owned(), p.avatar.clone()));
                }
            }
            if let Some(a) = alias
                && !a.is_empty()
                && a != UNKNOWN_NAME
            {
                return Some((a.to_owned(), String::new()));
            }
        }

        for candidate in &candidates {
            if let Some(conv) = self.conversations.iter().find(|c| c.id == *candidate) {
                let trimmed = conv.name.trim();
                let valid_name =
                    if !trimmed.is_empty() && trimmed != conv.id && trimmed != UNKNOWN_NAME {
                        trimmed
                    } else {
                        ""
                    };
                let avt = conv.avatar.as_deref().unwrap_or("");
                if !valid_name.is_empty() || !avt.is_empty() {
                    return Some((valid_name.to_owned(), avt.to_owned()));
                }
            }
        }
        None
    }

    /// Mention display name for a UID (`ZaloEngine.mentionDisplayName`).
    #[must_use]
    pub fn mention_display_name(
        &self,
        uid: &str,
        my_uid: &str,
        my_avatar: Option<&str>,
    ) -> Option<String> {
        let clean = strip_user_prefix(uid);
        if clean.is_empty() || clean == "-1" || clean == strip_user_prefix(my_uid) {
            return None;
        }
        let (raw_name, _) = self.lookup_person_info(&clean, my_uid, my_avatar)?;
        let name = raw_name.trim();
        if name.is_empty() || name == clean || name == "Bạn" || name == UNKNOWN_NAME {
            return None;
        }
        Some(name.to_owned())
    }

    /// Resolves `(name, avatar, members)` for a conversation (`ZaloEngine.lookupConversationIdentity`).
    #[must_use]
    pub fn lookup_conversation_identity(
        &self,
        conv_id: &str,
        self_conv_id: Option<&str>,
    ) -> (String, Option<String>, i64) {
        if self_conv_id == Some(conv_id) {
            return ("Cloud của tôi".to_owned(), None, 0);
        }
        if is_group_id(conv_id) {
            if let Some(g) = self.identities.groups.iter().find(|g| g.id == conv_id) {
                return (g.name.clone(), g.avatar.clone(), g.members);
            }
            if let Some(cg) = self.identities.cached_groups.get(conv_id) {
                let name = if cg.name.is_empty() {
                    conv_id.to_owned()
                } else {
                    cg.name.clone()
                };
                let avatar = (!cg.avatar.is_empty()).then(|| cg.avatar.clone());
                return (name, avatar, cg.members);
            }
            return (conv_id.to_owned(), None, 0);
        }

        let clean = strip_user_prefix(conv_id);
        let alias = self.identities.aliases.get(&clean).map(String::as_str);
        if let Some(f) = self.identities.friends.iter().find(|f| f.id == clean) {
            let avt = f.avatar.clone().or_else(|| {
                self.identities
                    .cached_profiles
                    .get(&clean)
                    .and_then(|p| (!p.avatar.is_empty()).then(|| p.avatar.clone()))
            });
            let name = match alias {
                Some(a) if !a.is_empty() => a.to_owned(),
                _ => f.name.clone(),
            };
            return (name, avt, 0);
        }
        if let Some(p) = self.identities.cached_profiles.get(&clean) {
            let best_name = match alias {
                Some(a) if !a.is_empty() => a.to_owned(),
                _ => p.name.clone(),
            };
            let avt = (!p.avatar.is_empty()).then(|| p.avatar.clone());
            return (best_name, avt, 0);
        }
        if let Some(a) = alias
            && !a.is_empty()
        {
            return (a.to_owned(), None, 0);
        }
        (String::new(), None, 0)
    }

    /// Recomputes `actions` flags from current conversations & sets (`rebuildConversationFlags`).
    /// Returns `true` if `actions` changed.
    pub fn rebuild_conversation_flags(&mut self, self_conv_id: Option<&str>) -> bool {
        let mut next = self.actions.clone();
        next.hidden_known = true;
        next.loaded = true;
        next.hidden_enabled = true;
        next.mark_unread_enabled = true;
        let mut next_flags = BTreeMap::new();
        for c in &self.conversations {
            let mut f = 0_i32;
            if self.pinned_ids.contains(&c.id) || c.pinned {
                f |= FLAG_PINNED;
            }
            if self.archived_ids.contains(&c.id) {
                f |= FLAG_ARCHIVED;
            }
            if next.hidden_ids.contains(&c.id) {
                f |= FLAG_HIDDEN;
            }
            if self.unread_marks.contains(&c.id) {
                f |= FLAG_UNREAD_MARK;
            }
            if self_conv_id == Some(c.id.as_str()) {
                f |= FLAG_CANNOT_DELETE | FLAG_CANNOT_HIDE | FLAG_CANNOT_ARCHIVE;
            }
            if f != 0 {
                next_flags.insert(c.id.clone(), f);
            }
        }
        next.flags = next_flags;
        if next != self.actions {
            self.actions = next;
            true
        } else {
            false
        }
    }

    /// Recomputes `extras` (stranger box, filtered list ids) (`rebuildConversationExtras`).
    /// Returns `true` if `extras` changed.
    pub fn rebuild_conversation_extras(&mut self, self_conv_id: Option<&str>) -> bool {
        let mut next = self.extras.clone();
        next.loaded = true;
        next.archived_enabled = true;

        let visible: Vec<&ConversationSummary> = self
            .conversations
            .iter()
            .filter(|c| !self.actions.is_hidden(&c.id))
            .collect();
        let friend_ids: BTreeSet<&str> = self
            .identities
            .friends
            .iter()
            .map(|f| f.id.as_str())
            .collect();

        let mut computed_strangers = BTreeSet::new();
        let mut stranger_folder = Vec::new();
        let mut unread_stranger_chats = 0_i64;
        let mut unread_stranger_messages = 0_i64;
        let mut newest_stranger_id: Option<String> = None;

        if self.identities.friends_loaded {
            for conv in &visible {
                if conv.is_group
                    || self_conv_id == Some(conv.id.as_str())
                    || friend_ids.contains(conv.id.as_str())
                {
                    continue;
                }
                computed_strangers.insert(conv.id.clone());
                let last_from_me = conv.preview.as_ref().is_some_and(|p| p.from_me);
                if !last_from_me || conv.unread > 0 {
                    stranger_folder.push(conv.id.clone());
                    if newest_stranger_id.is_none() {
                        newest_stranger_id = Some(conv.id.clone());
                    }
                    if conv.unread > 0 {
                        unread_stranger_chats += 1;
                        unread_stranger_messages += conv.unread;
                    }
                }
            }
        }
        next.stranger_ids = computed_strangers;
        next.stranger_folder_ids = stranger_folder.clone();
        next.stranger_box = StrangerBox {
            chats: i64::try_from(stranger_folder.len()).unwrap_or(i64::MAX),
            unread_chats: unread_stranger_chats,
            unread_messages: unread_stranger_messages,
            newest_id: newest_stranger_id,
        };

        let stranger_set: BTreeSet<&str> = stranger_folder.iter().map(String::as_str).collect();
        let mut filtered: Vec<&ConversationSummary> = match next.type_filter {
            FILTER_OTHER => visible
                .into_iter()
                .filter(|c| self.archived_ids.contains(&c.id))
                .collect(),
            FILTER_UNREAD => visible
                .into_iter()
                .filter(|c| c.unread > 0 || self.unread_marks.contains(&c.id))
                .collect(),
            FILTER_FOCUSED => visible
                .into_iter()
                .filter(|c| !self.archived_ids.contains(&c.id))
                .collect(),
            _ => visible,
        };

        if !next.label_filter_ids.is_empty() {
            let label_set: BTreeSet<&str> =
                next.label_filter_ids.iter().map(String::as_str).collect();
            filtered.retain(|c| {
                next.label_by_conversation
                    .get(&c.id)
                    .is_some_and(|assigned| label_set.contains(assigned.as_str()))
            });
            next.list_ids = filtered.into_iter().map(|c| c.id.clone()).collect();
        } else if matches!(next.type_filter, FILTER_FOCUSED | FILTER_ALL)
            || !matches!(next.type_filter, FILTER_UNREAD | FILTER_OTHER)
        {
            if !stranger_set.is_empty() {
                let mut ids = Vec::with_capacity(filtered.len());
                let mut emitted_box = false;
                for conv in filtered {
                    if stranger_set.contains(conv.id.as_str())
                        && !self.pinned_ids.contains(&conv.id)
                    {
                        if !emitted_box {
                            ids.push(STRANGER_BOX_ID.to_owned());
                            emitted_box = true;
                        }
                        continue;
                    }
                    ids.push(conv.id.clone());
                }
                next.list_ids = ids;
            } else {
                next.list_ids = filtered.into_iter().map(|c| c.id.clone()).collect();
            }
        } else {
            next.list_ids = filtered.into_iter().map(|c| c.id.clone()).collect();
        }

        if next != self.extras {
            self.extras = next;
            true
        } else {
            false
        }
    }

    /// Hydrates local state loaded from SQLite during `prepare_store` (`loadLocalAccountState`).
    pub fn hydrate_from_local(
        &mut self,
        data: LocalAccountHydration,
        my_uid: &str,
        my_avatar: Option<&str>,
        self_conv_id: Option<&str>,
    ) {
        self.pinned_ids = data.pinned_ids.into_iter().collect();
        self.archived_ids = data.archived_ids.into_iter().collect();
        self.unread_marks = data.unread_marks.into_iter().collect();
        if !data.aliases.is_empty() {
            self.identities.aliases = data.aliases;
        }
        if !data.cached_profiles.is_empty() {
            self.identities.cached_profiles = data.cached_profiles;
        }
        if !data.cached_groups.is_empty() {
            self.identities.cached_groups = data.cached_groups;
        }
        if !data.activity_ranks.is_empty() {
            self.identities.activity_ranks = data.activity_ranks;
        }
        for (uid, gid) in data.friend_global_ids {
            self.identities.friend_global_ids.insert(uid, gid);
        }

        let mut summaries: Vec<ConversationSummary> = data
            .conversations
            .into_iter()
            .map(|c| {
                let ident = self.lookup_conversation_identity(&c.id, self_conv_id);
                let effective_name = if !ident.0.is_empty() && ident.0 != c.id {
                    ident.0
                } else if c.name.is_empty() {
                    c.id.clone()
                } else {
                    c.name
                };
                let effective_avatar = ident
                    .1
                    .or_else(|| (!c.avatar.is_empty()).then_some(c.avatar));
                let effective_members = if ident.2 > 0 { ident.2 } else { c.members };
                let preview = if c.preview_ts_ms > 0 || !c.preview_text.is_empty() {
                    Some(ConversationPreview {
                        text: c.preview_text,
                        date_ms: (c.preview_ts_ms > 0).then_some(c.preview_ts_ms),
                        from_me: c.preview_from_me,
                    })
                } else {
                    None
                };
                let pinned = self.pinned_ids.contains(&c.id) || c.pinned;
                ConversationSummary {
                    id: c.id,
                    is_group: c.is_group,
                    name: effective_name,
                    avatar: effective_avatar,
                    pinned,
                    members: effective_members,
                    unread: c.unread,
                    preview,
                }
            })
            .collect();
        sort_conversations(&mut summaries, &self.identities.activity_ranks);
        self.conversations = summaries;

        // Refresh @mention previews from the latest stored message per group conversation.
        self.apply_mention_preview_messages(&data.group_latest_messages, my_uid, my_avatar);

        self.hidden_pin_hash = data.hidden_pin_hash.filter(|s| !s.is_empty());
        self.hidden_pin_md5 = data.hidden_pin_md5.filter(|s| !s.is_empty());
        let mut actions = self.actions.clone();
        actions.hidden_known = true;
        actions.loaded = true;
        actions.hidden_enabled = true;
        actions.has_hidden_pin = self.hidden_pin_hash.is_some() || self.hidden_pin_md5.is_some();
        actions.hidden_ids = data.hidden_ids.into_iter().collect();
        actions.mark_unread_enabled = true;
        self.actions = actions;
        self.rebuild_conversation_flags(self_conv_id);

        if !data.labels.is_empty() {
            self.set_labels_in_memory(data.labels);
        }
        self.rebuild_conversation_extras(self_conv_id);
    }

    /// Rewrites in-memory group previews whose text contains `@` and matches `message_preview_label(latest)`.
    /// Does NOT persist to SQLite (matches Swift `refreshMentionPreviews`).
    pub fn apply_mention_preview_messages(
        &mut self,
        latest_by_conv: &BTreeMap<String, MessagePreviewInput>,
        my_uid: &str,
        my_avatar: Option<&str>,
    ) -> bool {
        let mut changed = false;
        // Collect target replacements first to avoid borrowing `self` mutably while reading `self`.
        let mut replacements: Vec<(usize, String)> = Vec::new();
        for (idx, conv) in self.conversations.iter().enumerate() {
            if !conv.is_group {
                continue;
            }
            let Some(preview) = &conv.preview else {
                continue;
            };
            if !preview.text.contains('@') {
                continue;
            }
            let Some(latest) = latest_by_conv.get(&conv.id) else {
                continue;
            };
            if latest.mentions.is_empty() {
                continue;
            }
            if preview.text != latest.preview_label {
                continue;
            }
            let renamed = conversation_preview_text_for_input(latest, |uid| {
                self.mention_display_name(uid, my_uid, my_avatar)
            });
            if renamed != preview.text {
                replacements.push((idx, renamed));
            }
        }
        for (idx, text) in replacements {
            if let Some(conv) = self.conversations.get_mut(idx)
                && let Some(preview) = &mut conv.preview
            {
                preview.text = text;
                changed = true;
            }
        }
        changed
    }

    /// Merges self conversation, groups, pinned ids, and ranked active threads into `conversations`
    /// and updates metadata from contacts/aliases/groups (`ensureKnownContactsInConversations`).
    /// Returns `true` if `conversations` changed.
    pub fn ensure_known_contacts(&mut self, self_conv_id: Option<&str>) -> bool {
        let mut existing: HashMap<String, ConversationSummary> = self
            .conversations
            .iter()
            .cloned()
            .map(|c| (c.id.clone(), c))
            .collect();

        if let Some(self_id) = self_conv_id
            && !self_id.is_empty()
            && !existing.contains_key(self_id)
        {
            existing.insert(
                self_id.to_owned(),
                ConversationSummary {
                    id: self_id.to_owned(),
                    is_group: false,
                    name: "Cloud của tôi".to_owned(),
                    avatar: None,
                    pinned: self.pinned_ids.contains(self_id),
                    members: 0,
                    unread: 0,
                    preview: None,
                },
            );
        }

        for grp in &self.identities.groups {
            if !existing.contains_key(&grp.id) {
                existing.insert(
                    grp.id.clone(),
                    ConversationSummary {
                        id: grp.id.clone(),
                        is_group: true,
                        name: grp.name.clone(),
                        avatar: grp.avatar.clone(),
                        pinned: self.pinned_ids.contains(&grp.id),
                        members: grp.members,
                        unread: 0,
                        preview: None,
                    },
                );
            }
        }

        for pinned_id in &self.pinned_ids {
            if !existing.contains_key(pinned_id) {
                let info = self.lookup_conversation_identity(pinned_id, self_conv_id);
                existing.insert(
                    pinned_id.clone(),
                    ConversationSummary {
                        id: pinned_id.clone(),
                        is_group: is_group_id(pinned_id),
                        name: if info.0.is_empty() {
                            pinned_id.clone()
                        } else {
                            info.0
                        },
                        avatar: info.1,
                        pinned: true,
                        members: info.2,
                        unread: 0,
                        preview: None,
                    },
                );
            }
        }

        let known_group_set: BTreeSet<&str> = self
            .identities
            .groups
            .iter()
            .map(|g| g.id.as_str())
            .collect();
        for (active_id, &rank) in &self.identities.activity_ranks {
            if rank <= 0 || existing.contains_key(active_id) {
                continue;
            }
            let is_grp = is_group_id(active_id);
            if is_grp
                && !known_group_set.contains(active_id.as_str())
                && !self.identities.groups.is_empty()
            {
                continue;
            }
            let info = self.lookup_conversation_identity(active_id, self_conv_id);
            existing.insert(
                active_id.clone(),
                ConversationSummary {
                    id: active_id.clone(),
                    is_group: is_grp,
                    name: if info.0.is_empty() {
                        active_id.clone()
                    } else {
                        info.0
                    },
                    avatar: info.1,
                    pinned: self.pinned_ids.contains(active_id),
                    members: info.2,
                    unread: 0,
                    preview: None,
                },
            );
        }

        // Apply updated friend/alias/group metadata to existing entries.
        let ids: Vec<String> = existing.keys().cloned().collect();
        for id in ids {
            let info = self.lookup_conversation_identity(&id, self_conv_id);
            if let Some(summary) = existing.get_mut(&id) {
                if !info.0.is_empty() && summary.name != info.0 {
                    summary.name = info.0;
                }
                if let Some(av) = info.1 {
                    summary.avatar = Some(av);
                }
                if info.2 > 0 {
                    summary.members = info.2;
                }
                summary.pinned = self.pinned_ids.contains(&id);
            }
        }

        let mut list: Vec<ConversationSummary> = existing.into_values().collect();
        sort_conversations(&mut list, &self.identities.activity_ranks);
        if list != self.conversations {
            self.conversations = list;
            true
        } else {
            false
        }
    }

    /// Applies a [`BatchApplyDelta`] from Swift (`applyParsedEvents` tail).
    /// Returns `(conversations_changed, flags_changed, extras_changed)`.
    pub fn apply_batch_delta(
        &mut self,
        delta: &BatchApplyDelta,
        self_conv_id: Option<&str>,
    ) -> (bool, bool, bool) {
        if delta.applied_count == 0
            && delta.updates.is_empty()
            && delta.preview_overrides.is_empty()
        {
            return (false, false, false);
        }
        let mut by_id: HashMap<String, ConversationSummary> = self
            .conversations
            .iter()
            .cloned()
            .map(|c| (c.id.clone(), c))
            .collect();

        for upd in &delta.updates {
            let is_grp = is_group_id(&upd.conv_id);
            let info = self.lookup_conversation_identity(&upd.conv_id, self_conv_id);
            let prev = ConversationPreview {
                text: upd.preview_text.clone(),
                date_ms: Some(upd.preview_date_ms),
                from_me: upd.preview_from_me,
            };
            let existing = by_id.get(&upd.conv_id);
            let best_name = if !info.0.is_empty() {
                info.0
            } else if !upd.is_mine && !is_grp {
                upd.sender_name.clone()
            } else {
                existing.map_or_else(|| upd.conv_id.clone(), |e| e.name.clone())
            };
            let effective_prev = match existing.and_then(|e| e.preview.as_ref()) {
                Some(ep) if ep.date_ms.unwrap_or(i64::MIN) > upd.preview_date_ms => ep.clone(),
                _ => prev,
            };
            let avatar = info
                .1
                .or_else(|| existing.and_then(|e| e.avatar.clone()))
                .or_else(|| {
                    (!is_grp && !upd.is_mine)
                        .then(|| upd.sender_avatar.clone())
                        .flatten()
                });
            let members = if info.2 > 0 {
                info.2
            } else {
                existing.map_or(0, |e| e.members)
            };
            let unread = existing.map_or(0, |e| e.unread) + upd.unread_delta;
            by_id.insert(
                upd.conv_id.clone(),
                ConversationSummary {
                    id: upd.conv_id.clone(),
                    is_group: is_grp,
                    name: if best_name.is_empty() {
                        upd.conv_id.clone()
                    } else {
                        best_name
                    },
                    avatar,
                    pinned: self.pinned_ids.contains(&upd.conv_id),
                    members,
                    unread,
                    preview: Some(effective_prev),
                },
            );
        }

        for ov in &delta.preview_overrides {
            if let Some(conv) = by_id.get_mut(&ov.conv_id) {
                let existing_date = conv
                    .preview
                    .as_ref()
                    .and_then(|p| p.date_ms)
                    .unwrap_or(i64::MIN);
                if existing_date <= ov.target_date_ms.saturating_add(1_000) {
                    conv.preview = ov.preview.clone();
                }
            }
        }

        let mut list: Vec<ConversationSummary> = by_id.into_values().collect();
        sort_conversations(&mut list, &self.identities.activity_ranks);
        let convs_changed = if list != self.conversations {
            self.conversations = list;
            true
        } else {
            false
        };
        let flags_changed = self.rebuild_conversation_flags(self_conv_id);
        let extras_changed = self.rebuild_conversation_extras(self_conv_id);
        (convs_changed, flags_changed, extras_changed)
    }

    /// Updates a single conversation from one message (`ZaloEngine.updateConversationOnMessage`).
    /// Returns `true` if the conversation list mutated (caller should persist to SQLite).
    pub fn update_conversation_on_message(
        &mut self,
        input: &MessagePreviewInput,
        increment_unread: bool,
        my_uid: &str,
        my_avatar: Option<&str>,
        self_conv_id: Option<&str>,
    ) -> bool {
        let is_grp = is_group_id(&input.conv_id);
        let preview_text = conversation_preview_text_for_input(input, |uid| {
            self.mention_display_name(uid, my_uid, my_avatar)
        });
        let preview = ConversationPreview {
            text: preview_text,
            date_ms: Some(input.date_ms),
            from_me: input.is_mine,
        };
        let mut list = self.conversations.clone();
        if let Some(idx) = list.iter().position(|c| c.id == input.conv_id) {
            let mut item = list[idx].clone();
            if item
                .preview
                .as_ref()
                .and_then(|p| p.date_ms)
                .unwrap_or(i64::MIN)
                <= input.date_ms
            {
                item.preview = Some(preview);
            }
            if increment_unread {
                item.unread += 1;
            }
            if item == list[idx] {
                return false;
            }
            list[idx] = item;
        } else {
            let identity = self.lookup_conversation_identity(&input.conv_id, self_conv_id);
            list.push(ConversationSummary {
                id: input.conv_id.clone(),
                is_group: is_grp,
                name: if identity.0.is_empty() {
                    input.sender_name.clone()
                } else {
                    identity.0
                },
                avatar: identity.1.or_else(|| input.sender_avatar.clone()),
                pinned: self.pinned_ids.contains(&input.conv_id),
                members: identity.2,
                unread: i64::from(increment_unread),
                preview: Some(preview),
            });
        }
        sort_conversations(&mut list, &self.identities.activity_ranks);
        self.conversations = list;
        self.rebuild_conversation_flags(self_conv_id);
        self.rebuild_conversation_extras(self_conv_id);
        true
    }

    /// Collects 1-1 non-self UIDs missing a proper name or avatar, in current display order
    /// (`resolveMissingConversationNames`).
    #[must_use]
    pub fn missing_name_uids(&self, self_conv_id: Option<&str>) -> Vec<String> {
        self.conversations
            .iter()
            .filter_map(|conv| {
                if conv.is_group || self_conv_id == Some(conv.id.as_str()) {
                    return None;
                }
                let trimmed = conv.name.trim();
                if trimmed.is_empty()
                    || trimmed == conv.id
                    || trimmed == UNKNOWN_NAME
                    || conv.avatar.is_none()
                {
                    Some(conv.id.clone())
                } else {
                    None
                }
            })
            .collect()
    }

    /// Applies one chunk of fetched profile rows (`resolveMissingConversationNames` loop body).
    /// Returns `(profiles_cache_changed, conversations_changed)`.
    pub fn apply_resolved_profiles(&mut self, profiles_map: &Map<String, Value>) -> (bool, bool) {
        if profiles_map.is_empty() {
            return (false, false);
        }
        let mut profiles_cache_changed = false;
        for (uid, row_val) in profiles_map {
            let Some(row) = row_val.as_object() else {
                continue;
            };
            let clean = strip_user_prefix(uid);
            let fetched_name = preferred_profile_name(row);
            let avt = string(row.get("avatar").or_else(|| row.get("avt")));
            if !clean.is_empty() && (!fetched_name.is_empty() || !avt.is_empty()) {
                self.identities.cached_profiles.insert(
                    clean,
                    CachedProfile {
                        name: fetched_name,
                        avatar: avt,
                    },
                );
                profiles_cache_changed = true;
            }
        }

        let mut convs_changed = false;
        for conv in &mut self.conversations {
            if conv.is_group {
                continue;
            }
            let Some(row) = profiles_map.get(&conv.id).and_then(Value::as_object) else {
                continue;
            };
            let alias = self.identities.aliases.get(&conv.id).map(String::as_str);
            let fetched_name = preferred_profile_name(row);
            let best_name = match alias {
                Some(a) if !a.is_empty() => a.to_owned(),
                _ => fetched_name,
            };
            let avt = string(row.get("avatar").or_else(|| row.get("avt")));
            if !best_name.is_empty() && conv.name != best_name {
                conv.name = best_name;
                convs_changed = true;
            }
            if !avt.is_empty() && conv.avatar.is_none() {
                conv.avatar = Some(avt);
                convs_changed = true;
            }
        }
        (profiles_cache_changed, convs_changed)
    }

    /// Updates pinned status of `id`, re-sorts, and rebuilds flags & extras (`applyPinStatus`).
    pub fn apply_pin_status(&mut self, id: &str, pinned: bool, self_conv_id: Option<&str>) {
        if let Some(conv) = self.conversations.iter_mut().find(|c| c.id == id) {
            conv.pinned = pinned;
        }
        sort_conversations(&mut self.conversations, &self.identities.activity_ranks);
        self.rebuild_conversation_flags(self_conv_id);
        self.rebuild_conversation_extras(self_conv_id);
    }

    /// Computes the full-board dialog payload (`pinBoard(for:)`).
    #[must_use]
    pub fn compute_pin_board(&self) -> PinBoard {
        let items: Vec<String> = self
            .conversations
            .iter()
            .filter(|c| self.pinned_ids.contains(&c.id) || c.pinned)
            .map(|c| c.id.clone())
            .collect();
        let total = i32::try_from(items.len()).unwrap_or(i32::MAX);
        let limit = i32::try_from(PIN_LIMIT).unwrap_or(10);
        let need = (total - limit + 1).max(1);
        PinBoard {
            tab: 0,
            limit,
            total,
            need,
            items,
        }
    }

    /// Shows a toast for a [`ConversationActionResult`] (`ZaloEngine.report(_:)`).
    pub fn report(&mut self, result: &ConversationActionResult) -> bool {
        if result.text.is_empty() || result.full || result.pin_exists {
            return false;
        }
        let kind = if result.ok {
            if result.neutral {
                ToastKind::Neutral
            } else {
                ToastKind::Success
            }
        } else {
            ToastKind::Failure
        };
        self.ui.show(kind, result.text.clone());
        true
    }

    /// Checks a plaintext PIN against stored MD5 (preferred) or SHA-256 fallback digest.
    #[must_use]
    pub fn check_hidden_pin(&self, pin: &str) -> bool {
        if let Some(md5_stored) = self.hidden_pin_md5.as_deref().filter(|s| !s.is_empty()) {
            return hidden_pin_md5(pin) == md5_stored.to_ascii_lowercase();
        }
        if let Some(sha_stored) = self.hidden_pin_hash.as_deref().filter(|s| !s.is_empty()) {
            return hidden_pin_sha256(pin) == sha_stored;
        }
        false
    }

    /// Updates `extras.labels` and rebuilds `extras.label_by_conversation`.
    pub fn set_labels_in_memory(&mut self, labels: Vec<ConversationLabel>) {
        let mut map = BTreeMap::new();
        for label in &labels {
            for cid in &label.conv_ids {
                map.insert(cid.clone(), label.id.clone());
            }
        }
        self.extras.labels = labels;
        self.extras.label_by_conversation = map;
    }

    /// Applies `handleConversationActions(state:)` JSON payload.
    /// Returns `(actions_changed, ui_changed)`.
    pub fn handle_conversation_actions_json(&mut self, state: &Map<String, Value>) -> (bool, bool) {
        let Some(Value::Object(json)) = state.get("convActions") else {
            return (false, false);
        };
        let mut next = self.actions.clone();
        next.apply_json(json);
        let epoch = int64(json.get("epoch")).unwrap_or(next.late_epoch);
        if epoch != next.late_epoch {
            next.late_epoch = epoch;
            next.late_seq = 0;
        }
        let mut ui_changed = false;
        if let Some(Value::Object(late)) = json.get("late")
            && let Some(seq) = int64(late.get("seq"))
            && seq > next.late_seq
        {
            next.late_seq = seq;
            let text = late.get("text").and_then(Value::as_str).unwrap_or("");
            let ok = late.get("ok").and_then(Value::as_bool).unwrap_or(false);
            let neutral = late
                .get("neutral")
                .and_then(Value::as_bool)
                .unwrap_or(false);
            if !text.is_empty() {
                let kind = if ok {
                    if neutral {
                        ToastKind::Neutral
                    } else {
                        ToastKind::Success
                    }
                } else {
                    ToastKind::Failure
                };
                self.ui.show(kind, text.to_owned());
                ui_changed = true;
            }
            if let Some(removed) = late.get("removedId").and_then(Value::as_str)
                && !removed.is_empty()
            {
                self.ui.remove(BTreeSet::from([removed.to_owned()]));
                ui_changed = true;
            }
        }
        let actions_changed = if next != self.actions {
            self.actions = next;
            true
        } else {
            false
        };
        (actions_changed, ui_changed)
    }

    /// Applies `handleConversationExtras(state:)` JSON payload.
    /// Returns `(extras_changed, optional_new_self_conv_id)`.
    pub fn handle_conversation_extras_json(
        &mut self,
        state: &Map<String, Value>,
    ) -> (bool, Option<String>) {
        let Some(Value::Object(json)) = state.get("conversationExtras") else {
            return (false, None);
        };
        let mut next = self.extras.clone();
        next.loaded = true;
        let new_self_id = json
            .get("selfConversationId")
            .and_then(Value::as_str)
            .filter(|s| !s.is_empty())
            .map(str::to_owned);
        if let Some(flag) = json.get("archivedEnabled").and_then(Value::as_bool) {
            next.archived_enabled = flag;
        }
        let changed = if next != self.extras {
            self.extras = next;
            true
        } else {
            false
        };
        (changed, new_self_id)
    }

    /// Converts current `conversations` to SQLite `StoredConversation` rows (`persistConversationsToSQLite`).
    #[must_use]
    pub fn stored_conversation_rows(&self, now_ms: i64) -> Vec<StoredConversation> {
        self.conversations
            .iter()
            .map(|c| StoredConversation {
                id: c.id.clone(),
                is_group: c.is_group,
                name: c.name.clone(),
                avatar: c.avatar.clone().unwrap_or_default(),
                pinned: c.pinned,
                members: c.members,
                unread: c.unread,
                preview_text: c
                    .preview
                    .as_ref()
                    .map_or_else(String::new, |p| p.text.clone()),
                preview_ts_ms: c.preview.as_ref().and_then(|p| p.date_ms).unwrap_or(0),
                preview_from_me: c.preview.as_ref().is_some_and(|p| p.from_me),
                updated_at_ms: now_ms,
            })
            .collect()
    }

    /// Projects the U3 domain fields into a Case format v1 JSON map (matching `ConversationSnapshot.capture`).
    #[must_use]
    pub fn to_case_json_fields(&self, store: Option<&Store>) -> Map<String, Value> {
        let mut out = Map::new();

        // 1. conversations
        let convs_json: Vec<Value> = self
            .conversations
            .iter()
            .map(|c| {
                let preview_val = match &c.preview {
                    None => Value::Null,
                    Some(p) => json!({
                        "text": p.text,
                        "date_ms": p.date_ms,
                        "from_me": p.from_me,
                    }),
                };
                json!({
                    "id": c.id,
                    "is_group": c.is_group,
                    "name": c.name,
                    "avatar": c.avatar,
                    "pinned": c.pinned,
                    "members": c.members,
                    "unread": c.unread,
                    "preview": preview_val,
                })
            })
            .collect();
        out.insert("conversations".to_owned(), Value::Array(convs_json));

        // 2. flags
        let mut flags_map = Map::new();
        for (id, &bits) in &self.actions.flags {
            flags_map.insert(id.clone(), Value::from(bits));
        }
        let mut left_map = Map::new();
        for (id, &leave) in &self.actions.left {
            left_map.insert(id.clone(), Value::String(leave.as_str().to_owned()));
        }
        let removal_val = match &self.ui.removal {
            None => Value::Null,
            Some(r) => json!({
                "seq": r.seq,
                "ids": r.ids.iter().cloned().collect::<Vec<_>>(),
            }),
        };
        let mut pin_search_sorted = self.ui.pin_search_ids.clone();
        pin_search_sorted.sort();
        out.insert(
            "flags".to_owned(),
            json!({
                "loaded": self.actions.loaded,
                "hidden_known": self.actions.hidden_known,
                "hidden_enabled": self.actions.hidden_enabled,
                "has_hidden_pin": self.actions.has_hidden_pin,
                "hidden_ids": self.actions.hidden_ids.iter().cloned().collect::<Vec<_>>(),
                "mark_unread_enabled": self.actions.mark_unread_enabled,
                "flags": Value::Object(flags_map),
                "left": Value::Object(left_map),
                "late_epoch": self.actions.late_epoch,
                "late_seq": self.actions.late_seq,
                "unlocked_id": self.ui.unlocked_id,
                "pin_search_ids": pin_search_sorted,
                "removal": removal_val,
            }),
        );

        // 3. labels
        let label_items: Vec<Value> = self
            .extras
            .labels
            .iter()
            .map(|l| {
                json!({
                    "id": l.id,
                    "name": l.name,
                    "color_hex": l.color_hex,
                    "conv_ids": l.conv_ids,
                })
            })
            .collect();
        let mut label_by_conv = Map::new();
        for (k, v) in &self.extras.label_by_conversation {
            label_by_conv.insert(k.clone(), Value::String(v.clone()));
        }
        out.insert(
            "labels".to_owned(),
            json!({
                "loaded": self.extras.loaded,
                "archived_enabled": self.extras.archived_enabled,
                "labels": Value::Array(label_items),
                "label_by_conversation": Value::Object(label_by_conv),
                "type_filter": self.extras.type_filter,
                "label_filter_ids": self.extras.label_filter_ids,
                "list_ids": self.extras.list_ids,
                "stranger_ids": self.extras.stranger_ids.iter().cloned().collect::<Vec<_>>(),
                "stranger_folder_ids": self.extras.stranger_folder_ids,
                "stranger_box": {
                    "chats": self.extras.stranger_box.chats,
                    "unread_chats": self.extras.stranger_box.unread_chats,
                    "unread_messages": self.extras.stranger_box.unread_messages,
                    "newest_id": self.extras.stranger_box.newest_id,
                },
            }),
        );

        // 4. store
        let store_val = match store {
            None => Value::Null,
            Some(s) => {
                let mut rows = s.load_conversations().unwrap_or_default();
                rows.sort_by(|a, b| a.id.cmp(&b.id));
                let conv_rows_json: Vec<Value> = rows
                    .into_iter()
                    .map(|row| {
                        json!({
                            "id": row.id,
                            "is_group": row.is_group,
                            "name": row.name,
                            "avatar": row.avatar,
                            "pinned": row.pinned,
                            "members": row.members,
                            "unread": row.unread,
                            "preview_text": row.preview_text,
                            "preview_ts_ms": row.preview_ts_ms,
                            "preview_from_me": row.preview_from_me,
                            "updated_at_ms": "<volatile>",
                        })
                    })
                    .collect();

                let mut pinned_ids = s.get_preference_strings("pinnedIds").unwrap_or_default();
                pinned_ids.sort();
                let mut archived_ids = s.get_preference_strings("archivedIds").unwrap_or_default();
                archived_ids.sort();
                let mut unread_marks = s.get_preference_strings("unreadMarks").unwrap_or_default();
                unread_marks.sort();
                let mut hidden_ids = s.get_preference_strings("hiddenIds").unwrap_or_default();
                hidden_ids.sort();

                let labels_json = s
                    .get_preference_data("labels")
                    .ok()
                    .flatten()
                    .and_then(|d| parse_any(&d))
                    .unwrap_or_else(|| Value::Array(Vec::new()));
                let profiles_json = s
                    .get_preference_data("cachedProfiles")
                    .ok()
                    .flatten()
                    .and_then(|d| parse_any(&d))
                    .unwrap_or_else(|| Value::Object(Map::new()));
                let md5_str = s
                    .get_preference_string("hiddenPinMD5")
                    .ok()
                    .flatten()
                    .filter(|v| !v.is_empty());
                let hash_str = s
                    .get_preference_string("hiddenPinHash")
                    .ok()
                    .flatten()
                    .filter(|v| !v.is_empty());

                json!({
                    "conversations": Value::Array(conv_rows_json),
                    "prefs": {
                        "pinned_ids": pinned_ids,
                        "archived_ids": archived_ids,
                        "unread_marks": unread_marks,
                        "hidden_ids": hidden_ids,
                        "labels": labels_json,
                        "cached_profiles": profiles_json,
                        "hidden_pin_md5": md5_str,
                        "hidden_pin_hash": hash_str,
                    },
                })
            }
        };
        out.insert("store".to_owned(), store_val);

        // 5. toast
        let toast_val = match &self.ui.toast {
            None => Value::Null,
            Some(t) => json!({
                "seq": t.seq,
                "kind": t.kind.as_str(),
                "ok": t.kind != ToastKind::Failure,
                "text": t.text,
            }),
        };
        out.insert("toast".to_owned(), toast_val);

        // 6. prompt
        let prompt_val = match &self.prompt {
            None => Value::Null,
            Some(p) => json!({
                "kind": p.kind_name(),
                "id": p.conv_id(),
            }),
        };
        out.insert("prompt".to_owned(), prompt_val);

        // 7. pin_board & last_action_result
        let pin_board_val = match &self.last_pin_board {
            None => Value::Null,
            Some(b) => json!({
                "tab": b.tab,
                "limit": b.limit,
                "total": b.total,
                "need": b.need,
                "items": b.items,
            }),
        };
        out.insert("pin_board".to_owned(), pin_board_val);

        let last_res_val = match &self.last_action_result {
            None => Value::Null,
            Some(r) => json!({
                "ok": r.ok,
                "text": r.text,
                "full": r.full,
                "bad_pin": r.bad_pin,
                "pin_exists": r.pin_exists,
                "neutral": r.neutral,
            }),
        };
        out.insert("last_action_result".to_owned(), last_res_val);

        out
    }
}

impl fmt::Debug for ConversationsState {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ConversationsState")
            .field("conversations", &self.conversations.len())
            .field("actions", &self.actions)
            .field("ui", &self.ui)
            .field("extras", &self.extras)
            .field("prompt", &self.prompt)
            .field("pinned_count", &self.pinned_ids.len())
            .field("archived_count", &self.archived_ids.len())
            .field("unread_marks_count", &self.unread_marks.len())
            .field("has_open_conv", &self.open_conversation_id.is_some())
            .finish()
    }
}

// --- Pure Functions ---

/// Sorts conversations in display order (`ZaloEngine.sortConversations`):
/// `pinned` desc -> `preview.date_ms` desc (`None` = `i64::MIN`) -> `activity_ranks[id]` desc -> `id` asc.
pub fn sort_conversations(
    list: &mut [ConversationSummary],
    activity_ranks: &BTreeMap<String, i64>,
) {
    list.sort_by(|a, b| {
        b.pinned
            .cmp(&a.pinned)
            .then_with(|| {
                let ad = a
                    .preview
                    .as_ref()
                    .and_then(|p| p.date_ms)
                    .unwrap_or(i64::MIN);
                let bd = b
                    .preview
                    .as_ref()
                    .and_then(|p| p.date_ms)
                    .unwrap_or(i64::MIN);
                bd.cmp(&ad)
            })
            .then_with(|| {
                let ra = activity_ranks.get(&a.id).copied().unwrap_or(0);
                let rb = activity_ranks.get(&b.id).copied().unwrap_or(0);
                rb.cmp(&ra)
            })
            .then_with(|| a.id.cmp(&b.id))
    });
}

/// Pure display order without `activity_ranks` (`ZaloEngine.listOrder`).
#[must_use]
pub fn list_order(conversations: &[ConversationSummary]) -> Vec<ConversationSummary> {
    let mut out = conversations.to_vec();
    out.sort_by(|a, b| {
        b.pinned
            .cmp(&a.pinned)
            .then_with(|| {
                let ad = a
                    .preview
                    .as_ref()
                    .and_then(|p| p.date_ms)
                    .unwrap_or(i64::MIN);
                let bd = b
                    .preview
                    .as_ref()
                    .and_then(|p| p.date_ms)
                    .unwrap_or(i64::MIN);
                bd.cmp(&ad)
            })
            .then_with(|| a.id.cmp(&b.id))
    });
    out
}

/// Raw preview label for a message (`ZaloEngine.messagePreviewLabel`).
#[must_use]
pub fn message_preview_label(msg: &ChatMessage) -> String {
    let trimmed = msg.text.trim();
    if !trimmed.is_empty() {
        return trimmed.to_owned();
    }
    match &msg.kind {
        Kind::Photo { .. } => "[Hình ảnh]".to_owned(),
        Kind::Video { .. } => "[Video]".to_owned(),
        Kind::Sticker { .. } => "[Sticker]".to_owned(),
        Kind::Gif { .. } => "[GIF]".to_owned(),
        Kind::Voice { .. } => "[Tin nhắn thoại]".to_owned(),
        Kind::File { name, .. } => {
            if name.is_empty() {
                "[Tệp đính kèm]".to_owned()
            } else {
                name.clone()
            }
        }
        Kind::Location(_) => "[Vị trí]".to_owned(),
        Kind::ContactCard(c) => format!("[Danh thiếp] {}", c.name),
        Kind::Call { video, title, .. } => {
            if title.is_empty() {
                if *video {
                    "Cuộc gọi video".to_owned()
                } else {
                    "Cuộc gọi thoại".to_owned()
                }
            } else {
                title.clone()
            }
        }
        Kind::Poll(p) => {
            if p.question.is_empty() {
                "[Bình chọn]".to_owned()
            } else {
                p.question.clone()
            }
        }
        Kind::Ecard(e) => {
            if e.title.is_empty() {
                "[Thiệp]".to_owned()
            } else {
                e.title.clone()
            }
        }
        Kind::Placeholder { text, .. } => {
            if text.contains("Sticker") {
                "[Sticker]".to_owned()
            } else {
                "🔒 Tin nhắn mã hóa đầu cuối".to_owned()
            }
        }
        Kind::Recalled => "Tin nhắn đã được thu hồi".to_owned(),
        _ => "[Tin nhắn]".to_owned(),
    }
}

/// UTF-16 offset mention renaming (`ChatFormat.renamingMentions`).
#[must_use]
pub fn renaming_mentions(
    s: &str,
    mentions: &[Mention],
    name: impl Fn(&str) -> Option<String>,
) -> (String, Vec<Mention>) {
    if mentions.is_empty() {
        return (s.to_owned(), Vec::new());
    }
    let orig_utf16: Vec<u16> = s.encode_utf16().collect();
    let total_len = orig_utf16.len();

    let mut valid: Vec<Mention> = Vec::with_capacity(mentions.len());
    for m in mentions {
        let Ok(pos) = usize::try_from(m.pos) else {
            return (s.to_owned(), mentions.to_vec());
        };
        let Ok(len) = usize::try_from(m.len) else {
            return (s.to_owned(), mentions.to_vec());
        };
        if len <= 1 || pos.checked_add(len).is_none_or(|end| end > total_len) {
            return (s.to_owned(), mentions.to_vec());
        }
        if orig_utf16.get(pos) != Some(&0x0040) {
            return (s.to_owned(), mentions.to_vec());
        }
        valid.push(m.clone());
    }

    valid.sort_by_key(|m| m.pos);
    for pair in valid.windows(2) {
        if pair[0].pos.saturating_add(pair[0].len) > pair[1].pos {
            return (s.to_owned(), mentions.to_vec());
        }
    }

    let mut out_utf16 = orig_utf16.clone();
    let mut renamed: Vec<Mention> = Vec::with_capacity(valid.len());
    let mut shift: isize = 0;

    for mut m in valid {
        let Ok(orig_pos) = usize::try_from(m.pos) else {
            return (s.to_owned(), mentions.to_vec());
        };
        let Ok(orig_len) = usize::try_from(m.len) else {
            return (s.to_owned(), mentions.to_vec());
        };
        let replacement = if m.is_all {
            None
        } else {
            name(&m.uid).map(|n| format!("@{n}"))
        };
        let shifted_pos_i = (orig_pos as isize).saturating_add(shift);
        let Ok(shifted_pos) = usize::try_from(shifted_pos_i) else {
            return (s.to_owned(), mentions.to_vec());
        };
        m.pos = i64::try_from(shifted_pos).unwrap_or(m.pos);

        if let Some(repl) = replacement {
            let repl_utf16: Vec<u16> = repl.encode_utf16().collect();
            let orig_slice = orig_utf16.get(orig_pos..orig_pos + orig_len);
            if orig_slice != Some(repl_utf16.as_slice())
                && shifted_pos + orig_len <= out_utf16.len()
            {
                out_utf16.splice(
                    shifted_pos..shifted_pos + orig_len,
                    repl_utf16.iter().copied(),
                );
                let new_len = repl_utf16.len();
                shift = shift
                    .saturating_add(new_len as isize)
                    .saturating_sub(orig_len as isize);
                m.len = i64::try_from(new_len).unwrap_or(m.len);
            }
        }
        renamed.push(m);
    }

    let out_str =
        String::from_utf16(&out_utf16).unwrap_or_else(|_| String::from_utf16_lossy(&out_utf16));
    (out_str, renamed)
}

/// Preview text for a single message (`ZaloEngine.conversationPreviewText`).
#[must_use]
pub fn conversation_preview_text_for_input(
    input: &MessagePreviewInput,
    lookup_mention: impl Fn(&str) -> Option<String>,
) -> String {
    if input.mentions.is_empty() || input.preview_label != input.text.trim() {
        return input.preview_label.clone();
    }
    renaming_mentions(&input.text, &input.mentions, lookup_mention)
        .0
        .trim()
        .to_owned()
}

/// Lowercase MD5 hex of a hidden-chat PIN (`ZaloSessionClient.hiddenPinMD5Hex`).
#[must_use]
pub fn hidden_pin_md5(pin: &str) -> String {
    md5_hex(pin.as_bytes())
}

/// Local fallback SHA-256 hex of a hidden-chat PIN (`ZaloEngine.hashPIN`).
#[must_use]
pub fn hidden_pin_sha256(pin: &str) -> String {
    let mut salted = String::with_capacity("olaz-hidden-pin:".len() + pin.len());
    salted.push_str("olaz-hidden-pin:");
    salted.push_str(pin);
    sha256_hex(salted.as_bytes())
}

/// Localized default name for a server `textKey` (`ZaloEngine.localizedDefaultLabelName`).
#[must_use]
pub fn localized_default_label_name(key: &str) -> &str {
    match key {
        "STR_LABEL_CUSTOMER" => "Khách hàng",
        "STR_LABEL_FAMILY" => "Gia đình",
        "STR_LABEL_WORK" => "Công việc",
        "STR_LABEL_FRIENDS" => "Bạn bè",
        "STR_LABEL_REPLY_LATER" => "Trả lời sau",
        "STR_LABEL_COLLEAGUE" => "Đồng nghiệp",
        _ => key,
    }
}

/// Preferred display name from a profile row (`ZaloWireParser.preferredName`).
#[must_use]
pub fn preferred_profile_name(row: &Map<String, Value>) -> String {
    for key in [
        "zaloName",
        "zalo_name",
        "displayName",
        "display_name",
        "dName",
        "name",
    ] {
        let value = string(row.get(key)).trim().to_owned();
        if !value.is_empty() {
            return value;
        }
    }
    String::new()
}

/// Serializes labels for SQLite `labels` preference (sorted keys).
#[must_use]
pub fn serialize_labels_local_json(labels: &[ConversationLabel]) -> Vec<u8> {
    let arr: Vec<Value> = labels
        .iter()
        .map(|l| {
            json!({
                "color": l.color_hex,
                "convIds": l.conv_ids,
                "id": l.id,
                "name": l.name,
            })
        })
        .collect();
    to_swift_json_string(&Value::Array(arr)).into_bytes()
}

/// Serializes labels for `/api/convlabel/update` `labelData` (sorted keys; integer id when numeric).
#[must_use]
pub fn serialize_labels_server_json(labels: &[ConversationLabel]) -> String {
    let arr: Vec<Value> = labels
        .iter()
        .enumerate()
        .map(|(idx, l)| {
            let id_val =
                l.id.parse::<i64>()
                    .map_or_else(|_| Value::String(l.id.clone()), Value::from);
            json!({
                "color": l.color_hex,
                "conversations": l.conv_ids,
                "id": id_val,
                "offset": idx,
                "text": l.name,
            })
        })
        .collect();
    to_swift_json_string(&Value::Array(arr))
}

/// Parses labels from SQLite `labels` preference JSON bytes.
#[must_use]
pub fn parse_labels_pref_json(data: &[u8]) -> Option<Vec<ConversationLabel>> {
    let Value::Array(rows) = parse_any(data)? else {
        return None;
    };
    let mut out = Vec::with_capacity(rows.len());
    for row in rows {
        let Some(obj) = row.as_object() else {
            continue;
        };
        let Some(id) = obj.get("id").and_then(Value::as_str) else {
            continue;
        };
        let name = obj
            .get("name")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_owned();
        let color_hex = obj
            .get("color")
            .and_then(Value::as_str)
            .unwrap_or("#0068FF")
            .to_owned();
        let conv_ids = obj
            .get("convIds")
            .and_then(Value::as_array)
            .map(|a| {
                a.iter()
                    .filter_map(|v| v.as_str().map(str::to_owned))
                    .collect()
            })
            .unwrap_or_default();
        out.push(ConversationLabel {
            id: id.to_owned(),
            name,
            color_hex,
            conv_ids,
        });
    }
    Some(out)
}

/// Parses `/api/convlabel/get` `data` object into [`ConversationLabel`]s (`syncConversationLabelsFromServer`).
#[must_use]
pub fn parse_server_labels_response(data: &Map<String, Value>) -> Vec<ConversationLabel> {
    let raw_label_data = data.get("labelData");
    let rows: Vec<Map<String, Value>> = match raw_label_data {
        Some(Value::Array(arr)) => arr.iter().filter_map(Value::as_object).cloned().collect(),
        Some(Value::String(s)) => {
            if let Some(Value::Array(arr)) = parse_any(s.as_bytes()) {
                arr.into_iter()
                    .filter_map(|v| match v {
                        Value::Object(m) => Some(m),
                        _ => None,
                    })
                    .collect()
            } else if let Some(map) = parse_object(s.as_bytes()) {
                map.into_values()
                    .filter_map(|v| match v {
                        Value::Object(m) => Some(m),
                        _ => None,
                    })
                    .collect()
            } else {
                Vec::new()
            }
        }
        Some(Value::Object(map)) => map.values().filter_map(Value::as_object).cloned().collect(),
        _ => Vec::new(),
    };
    if rows.is_empty() {
        return Vec::new();
    }

    let mut sorted_rows = rows;
    sorted_rows.sort_by_key(|r| int64(r.get("offset")).unwrap_or(0));

    let mut parsed = Vec::with_capacity(sorted_rows.len());
    for row in sorted_rows {
        let id = string(row.get("id"));
        if id.is_empty() {
            continue;
        }
        let raw_text = string(row.get("text").or_else(|| row.get("name")));
        let text_key = string(row.get("textKey"));
        let resolved_name = if raw_text.is_empty() {
            localized_default_label_name(&text_key).to_owned()
        } else {
            raw_text
        };
        if resolved_name.is_empty() {
            continue;
        }
        let color_raw = string(row.get("color"));
        let color_hex = if color_raw.is_empty() {
            "#0068FF".to_owned()
        } else {
            color_raw
        };
        let conv_arr = row
            .get("conversations")
            .and_then(Value::as_array)
            .or_else(|| row.get("convIds").and_then(Value::as_array));
        let conv_ids: Vec<String> = conv_arr
            .map(|arr| {
                arr.iter()
                    .map(|v| normalize_thread_id_from_list(&string(Some(v))))
                    .filter(|s| !s.is_empty())
                    .collect()
            })
            .unwrap_or_default();
        parsed.push(ConversationLabel {
            id,
            name: resolved_name,
            color_hex,
            conv_ids,
        });
    }
    parsed
}

/// Reads local account state from SQLite (`loadLocalAccountState` store queries + ghost cleanup).
/// Note: mutates SQLite to rescue legacy `"g0"` 1-1 messages and delete ghost rows (`"g0"`, `"0"`, `"g<selfId>"`),
/// matching Swift `loadLocalAccountState` verbatim.
pub fn load_local_account_from_store(
    store: &mut Store,
    my_uid: &str,
    my_avatar: Option<&str>,
    self_conv_id: Option<&str>,
    existing_identities: &IdentityTable,
) -> LocalAccountHydration {
    let _ = store.repair_undecrypted_e2ee_messages();
    let _ = store.repair_legacy_reactions(my_uid);
    let mut out = LocalAccountHydration {
        pinned_ids: store
            .get_preference_strings("pinnedIds")
            .unwrap_or_default(),
        archived_ids: store
            .get_preference_strings("archivedIds")
            .unwrap_or_default(),
        unread_marks: store
            .get_preference_strings("unreadMarks")
            .unwrap_or_default(),
        hidden_ids: store
            .get_preference_strings("hiddenIds")
            .unwrap_or_default(),
        hidden_pin_md5: store
            .get_preference_string("hiddenPinMD5")
            .ok()
            .flatten()
            .filter(|s| !s.is_empty()),
        hidden_pin_hash: store
            .get_preference_string("hiddenPinHash")
            .ok()
            .flatten()
            .filter(|s| !s.is_empty()),
        starred_ids: store
            .get_preference_strings("starredIds")
            .unwrap_or_default(),
        seen_reaction_event_ids: store
            .get_preference_strings("seenReactionEventIds")
            .unwrap_or_default(),
        notif_enabled: store.get_preference_bool("notifEnabled", true).unwrap_or(true),
        notif_sound: store.get_preference_bool("notifSound", true).unwrap_or(true),
        muted_threads: store.get_preference_data("mutedThreads").ok().flatten().and_then(|data| {
            let Some(Value::Array(rows)) = parse_any(&data) else {
                return None;
            };
            let mut mutes = BTreeMap::new();
            for row in rows {
                if let Some(obj) = row.as_object()
                    && let Some((id, info)) = crate::notify::MuteInfo::parse_row(obj)
                {
                    mutes.insert(id, info);
                }
            }
            Some(mutes)
        }),
        ..LocalAccountHydration::default()
    };

    if let Ok(Some(data)) = store.get_preference_data("aliases")
        && let Some(Value::Object(map)) = parse_any(&data)
    {
        for (k, v) in map {
            if let Some(s) = v.as_str() {
                out.aliases.insert(k, s.to_owned());
            }
        }
    }
    if let Ok(Some(data)) = store.get_preference_data("cachedProfiles")
        && let Ok(decoded) = serde_json::from_slice::<BTreeMap<String, CachedProfile>>(&data)
    {
        out.cached_profiles = decoded;
    }
    if let Ok(Some(data)) = store.get_preference_data("cachedGroups")
        && let Ok(decoded) = serde_json::from_slice::<BTreeMap<String, CachedGroup>>(&data)
    {
        out.cached_groups = decoded;
    }
    if let Ok(Some(data)) = store.get_preference_data("activityRanks")
        && let Some(Value::Object(map)) = parse_any(&data)
    {
        for (k, v) in map {
            if let Some(val) = int64(Some(&v))
                && val > 0
            {
                out.activity_ranks.insert(k, val);
            }
        }
    }
    if let Ok(Some(data)) = store.get_preference_data("gidToUidMap")
        && let Some(Value::Object(map)) = parse_any(&data)
    {
        for (gid, v) in map {
            if let Some(uid) = v.as_str()
                && !gid.is_empty()
                && !uid.is_empty()
            {
                out.friend_global_ids.insert(uid.to_owned(), gid);
            }
        }
    }
    if let Ok(Some(data)) = store.get_preference_data("labels")
        && let Some(labels) = parse_labels_pref_json(&data)
    {
        out.labels = labels;
    }

    // Build temporary lookup state for rescuing legacy "g0" messages.
    let mut temp_state = ConversationsState {
        identities: existing_identities.clone(),
        pinned_ids: out.pinned_ids.iter().cloned().collect(),
        ..ConversationsState::default()
    };
    if !out.aliases.is_empty() {
        temp_state.identities.aliases = out.aliases.clone();
    }
    if !out.cached_profiles.is_empty() {
        temp_state.identities.cached_profiles = out.cached_profiles.clone();
    }
    if !out.cached_groups.is_empty() {
        temp_state.identities.cached_groups = out.cached_groups.clone();
    }
    for (uid, gid) in &out.friend_global_ids {
        temp_state
            .identities
            .friend_global_ids
            .insert(uid.clone(), gid.clone());
    }

    let mut ghost_ids: BTreeSet<String> = BTreeSet::from(["g0".to_owned(), "0".to_owned()]);
    if let Some(self_id) = self_conv_id
        && !self_id.is_empty()
    {
        ghost_ids.insert(format!("g{self_id}"));
    }

    if let Ok(g0_msgs) = store.messages("g0", None, 200)
        && !g0_msgs.is_empty()
    {
        let mut rescued = Vec::new();
        for mut m in g0_msgs {
            if m.is_mine || m.sender_id.is_empty() || m.sender_id == "0" || m.sender_id == my_uid {
                continue;
            }
            let peer_id = strip_user_prefix(&m.sender_id);
            if peer_id.is_empty() || peer_id == "0" || is_group_id(&peer_id) {
                continue;
            }
            m.conv_id = peer_id.clone();
            if let Some((name, avatar)) = temp_state.lookup_person_info(&peer_id, my_uid, my_avatar)
            {
                if !name.is_empty() {
                    m.sender_name = name;
                }
                if !avatar.is_empty() {
                    m.sender_avatar = avatar;
                }
            }
            if let Some(mut obj) = parse_object(&m.raw_json_data) {
                obj.insert("conversationId".to_owned(), Value::String(peer_id));
                obj.insert(
                    "senderName".to_owned(),
                    Value::String(m.sender_name.clone()),
                );
                obj.insert(
                    "senderAvatar".to_owned(),
                    Value::String(m.sender_avatar.clone()),
                );
                m.raw_json_data = to_swift_json_string(&Value::Object(obj)).into_bytes();
            }
            rescued.push(m);
        }
        if !rescued.is_empty() {
            let _ = store.save_messages(&rescued);
            for m in &rescued {
                let ident = temp_state.lookup_conversation_identity(&m.conv_id, self_conv_id);
                let conv = StoredConversation {
                    id: m.conv_id.clone(),
                    is_group: false,
                    name: if ident.0.is_empty() {
                        m.sender_name.clone()
                    } else {
                        ident.0
                    },
                    avatar: ident.1.unwrap_or_else(|| m.sender_avatar.clone()),
                    pinned: temp_state.pinned_ids.contains(&m.conv_id),
                    members: 0,
                    unread: 0,
                    preview_text: olaz_wire::preview_label(&m.kind_tag, &m.text),
                    preview_ts_ms: m.ts_ms,
                    preview_from_me: false,
                    updated_at_ms: m.ts_ms,
                };
                let _ = store.upsert_conversation(&conv);
            }
        }
    }

    if let Ok(saved_convs) = store.load_conversations() {
        for ghost in &ghost_ids {
            if saved_convs.iter().any(|c| c.id == *ghost) {
                let _ = store.delete_conversation(ghost);
            }
        }
        let filtered: Vec<StoredConversation> = saved_convs
            .into_iter()
            .filter(|c| !ghost_ids.contains(&c.id))
            .collect();

        for conv in &filtered {
            if conv.is_group
                && conv.preview_text.contains('@')
                && let Ok(msgs) = store.messages(&conv.id, None, 1)
                && let Some(latest_stored) = msgs.last()
                && let Some(decoded) =
                    olaz_wire::decode_stored_message(&to_wire_stored(latest_stored))
            {
                out.group_latest_messages.insert(
                    conv.id.clone(),
                    MessagePreviewInput::from_chat_message(&decoded),
                );
            }
        }
        out.conversations = filtered;
    }

    out
}

/// Converts an `olaz_store::StoredMessage` into `olaz_wire::StoredMessage` for `decode_stored_message`.
#[must_use]
pub fn to_wire_stored(m: &olaz_store::StoredMessage) -> olaz_wire::StoredMessage {
    olaz_wire::StoredMessage {
        id: m.id.clone(),
        conv_id: m.conv_id.clone(),
        client_id: m.client_id.clone(),
        sender_id: m.sender_id.clone(),
        sender_name: m.sender_name.clone(),
        sender_avatar: m.sender_avatar.clone(),
        is_mine: m.is_mine,
        text: m.text.clone(),
        kind_tag: m.kind_tag.clone(),
        ts_ms: m.ts_ms,
        status: m.status.clone(),
        raw_json_data: m.raw_json_data.clone(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use olaz_wire::{ContactCard, ECard, ECardStyle, LocationInfo, PollInfo};

    fn make_conv(id: &str, pinned: bool, date_ms: Option<i64>) -> ConversationSummary {
        ConversationSummary {
            id: id.to_owned(),
            is_group: is_group_id(id),
            name: id.to_owned(),
            avatar: None,
            pinned,
            members: 0,
            unread: 0,
            preview: date_ms.map(|ms| ConversationPreview {
                text: "hi".to_owned(),
                date_ms: Some(ms),
                from_me: false,
            }),
        }
    }

    #[test]
    fn sort_conversations_orders_pinned_date_rank_id() {
        let mut list = vec![
            make_conv("b", false, None),
            make_conv("a", false, None),
            make_conv("c", false, Some(100)),
            make_conv("d", false, Some(200)),
            make_conv("p1", true, Some(50)),
            make_conv("p2", true, Some(150)),
            make_conv("r1", false, None),
        ];
        let ranks = BTreeMap::from([("r1".to_owned(), 50), ("b".to_owned(), 10)]);
        sort_conversations(&mut list, &ranks);
        let ids: Vec<&str> = list.iter().map(|c| c.id.as_str()).collect();
        assert_eq!(ids, vec!["p2", "p1", "d", "c", "r1", "b", "a"]);

        // list_order ignores activity_ranks.
        let ordered = list_order(&list);
        let ids2: Vec<&str> = ordered.iter().map(|c| c.id.as_str()).collect();
        assert_eq!(ids2, vec!["p2", "p1", "d", "c", "a", "b", "r1"]);
    }

    #[test]
    fn message_preview_label_covers_all_kinds() {
        let base = |kind: Kind, text: &str| {
            let mut obj = Map::new();
            obj.insert("id".to_owned(), Value::String("1".to_owned()));
            obj.insert("conversationId".to_owned(), Value::String("c1".to_owned()));
            let Some(mut m) = ChatMessage::from_json(&obj, "c1") else {
                unreachable!("valid minimal message JSON");
            };
            m.kind = kind;
            m.text = text.to_owned();
            m
        };
        assert_eq!(
            message_preview_label(&base(Kind::Text, "  hello \n")),
            "hello"
        );
        assert_eq!(
            message_preview_label(&base(
                Kind::Photo {
                    url: None,
                    width: 0,
                    height: 0
                },
                ""
            )),
            "[Hình ảnh]"
        );
        assert_eq!(
            message_preview_label(&base(
                Kind::Video {
                    thumbnail: None,
                    duration: 0,
                    url: None
                },
                ""
            )),
            "[Video]"
        );
        assert_eq!(
            message_preview_label(&base(Kind::Sticker { url: None }, "")),
            "[Sticker]"
        );
        assert_eq!(
            message_preview_label(&base(Kind::Gif { url: None }, "")),
            "[GIF]"
        );
        assert_eq!(
            message_preview_label(&base(
                Kind::Voice {
                    url: None,
                    duration: 0
                },
                ""
            )),
            "[Tin nhắn thoại]"
        );
        assert_eq!(
            message_preview_label(&base(
                Kind::File {
                    name: "doc.pdf".to_owned(),
                    size: 1,
                    url: None
                },
                ""
            )),
            "doc.pdf"
        );
        assert_eq!(
            message_preview_label(&base(
                Kind::File {
                    name: String::new(),
                    size: 0,
                    url: None
                },
                ""
            )),
            "[Tệp đính kèm]"
        );
        assert_eq!(
            message_preview_label(&base(Kind::Location(LocationInfo::default()), "")),
            "[Vị trí]"
        );
        assert_eq!(
            message_preview_label(&base(
                Kind::ContactCard(ContactCard {
                    uid: "1".to_owned(),
                    name: "Binh".to_owned(),
                    avatar: None,
                    phone: String::new(),
                    qr: None,
                    is_official_account: false,
                    oa_link: String::new(),
                }),
                ""
            )),
            "[Danh thiếp] Binh"
        );
        assert_eq!(
            message_preview_label(&base(
                Kind::Call {
                    video: true,
                    missed: false,
                    duration: 0,
                    title: String::new(),
                    detail: String::new(),
                },
                ""
            )),
            "Cuộc gọi video"
        );
        assert_eq!(
            message_preview_label(&base(
                Kind::Call {
                    video: false,
                    missed: false,
                    duration: 0,
                    title: String::new(),
                    detail: String::new(),
                },
                ""
            )),
            "Cuộc gọi thoại"
        );
        assert_eq!(
            message_preview_label(&base(
                Kind::Poll(PollInfo {
                    poll_id: "1".to_owned(),
                    header: String::new(),
                    question: "Ăn gì?".to_owned(),
                    conversation_id: "c1".to_owned(),
                    anonymous: false,
                }),
                ""
            )),
            "Ăn gì?"
        );
        assert_eq!(
            message_preview_label(&base(
                Kind::Ecard(ECard {
                    style: ECardStyle::default(),
                    title: String::new(),
                    description: String::new(),
                    image: None,
                    thumb: None,
                    avatars: vec![],
                    reminder_title: String::new(),
                    reminder_start_ms: None,
                    reminder_repeat: String::new(),
                    actions: vec![],
                }),
                ""
            )),
            "[Thiệp]"
        );
        assert_eq!(
            message_preview_label(&base(
                Kind::Placeholder {
                    symbol: String::new(),
                    text: "Sticker mã hóa".to_owned()
                },
                ""
            )),
            "[Sticker]"
        );
        assert_eq!(
            message_preview_label(&base(
                Kind::Placeholder {
                    symbol: String::new(),
                    text: "locked".to_owned()
                },
                ""
            )),
            "🔒 Tin nhắn mã hóa đầu cuối"
        );
        assert_eq!(
            message_preview_label(&base(Kind::Recalled, "")),
            "Tin nhắn đã được thu hồi"
        );
        assert_eq!(
            message_preview_label(&base(Kind::Text, "   ")),
            "[Tin nhắn]"
        );
    }

    #[test]
    fn renaming_mentions_handles_utf16_emojis_and_invalid_ranges() {
        // "👋 @Old và @All" — 👋 is 2 UTF-16 code units, space is 1 -> @Old starts at UTF-16 pos 3, len 4.
        let text = "👋 @Old và @All";
        let mentions = vec![
            Mention {
                uid: "100".to_owned(),
                pos: 3,
                len: 4,
                is_all: false,
            },
            Mention {
                uid: "-1".to_owned(),
                pos: 11,
                len: 4,
                is_all: true,
            },
        ];
        let (out, renamed) = renaming_mentions(text, &mentions, |uid| {
            (uid == "100").then(|| "Alice Nguyễn".to_owned())
        });
        assert_eq!(out, "👋 @Alice Nguyễn và @All");
        assert_eq!(renamed[0].pos, 3);
        assert_eq!(
            renamed[0].len,
            "@Alice Nguyễn".encode_utf16().count() as i64
        );
        assert_eq!(renamed[1].pos, 3 + renamed[0].len + 4);

        // Overlapping mentions reject entire batch.
        let overlap = vec![
            Mention {
                uid: "1".to_owned(),
                pos: 0,
                len: 5,
                is_all: false,
            },
            Mention {
                uid: "2".to_owned(),
                pos: 3,
                len: 4,
                is_all: false,
            },
        ];
        let (out2, _) = renaming_mentions("@abc@def", &overlap, |_| Some("X".to_owned()));
        assert_eq!(out2, "@abc@def");
    }

    #[test]
    fn hidden_pin_hashes_match_swift_constants() {
        assert_eq!(hidden_pin_md5("1234"), "81dc9bdb52d04dc20036dbd8313ed055");
        let sha = hidden_pin_sha256("1234");
        assert_eq!(sha.len(), 64);
        assert!(
            sha.chars()
                .all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase())
        );
    }

    #[test]
    fn stranger_box_and_label_filters_match_swift_rules() {
        let mut st = ConversationsState::default();
        st.identities.friends_loaded = true;
        st.identities.friends = vec![FriendIdentity {
            id: "f1".to_owned(),
            name: "Friend".to_owned(),
            avatar: None,
        }];
        st.conversations = vec![
            ConversationSummary {
                id: "f1".to_owned(),
                is_group: false,
                name: "Friend".to_owned(),
                avatar: None,
                pinned: false,
                members: 0,
                unread: 0,
                preview: Some(ConversationPreview {
                    text: "hi".to_owned(),
                    date_ms: Some(300),
                    from_me: false,
                }),
            },
            ConversationSummary {
                id: "s1".to_owned(),
                is_group: false,
                name: "Stranger 1".to_owned(),
                avatar: None,
                pinned: false,
                members: 0,
                unread: 2,
                preview: Some(ConversationPreview {
                    text: "hey".to_owned(),
                    date_ms: Some(200),
                    from_me: false,
                }),
            },
            ConversationSummary {
                id: "s2".to_owned(),
                is_group: false,
                name: "Stranger 2".to_owned(),
                avatar: None,
                pinned: false,
                members: 0,
                unread: 0,
                preview: Some(ConversationPreview {
                    text: "replied".to_owned(),
                    date_ms: Some(100),
                    from_me: true,
                }),
            },
        ];
        st.rebuild_conversation_flags(Some("self"));
        st.rebuild_conversation_extras(Some("self"));
        assert_eq!(
            st.extras.stranger_ids,
            BTreeSet::from(["s1".to_owned(), "s2".to_owned()])
        );
        assert_eq!(st.extras.stranger_folder_ids, vec!["s1".to_owned()]);
        assert_eq!(st.extras.stranger_box.chats, 1);
        assert_eq!(st.extras.stranger_box.unread_chats, 1);
        assert_eq!(st.extras.stranger_box.unread_messages, 2);
        assert_eq!(st.extras.stranger_box.newest_id.as_deref(), Some("s1"));
        assert_eq!(st.extras.list_ids, vec!["f1", STRANGER_BOX_ID, "s2"]);
    }

    #[test]
    fn debug_output_never_leaks_pii_or_pins() {
        let mut st = ConversationsState::default();
        st.conversations.push(ConversationSummary {
            id: "SECRET_CONV_ID".to_owned(),
            is_group: false,
            name: "SECRET_NAME".to_owned(),
            avatar: Some("https://secret.invalid/av.jpg".to_owned()),
            pinned: false,
            members: 0,
            unread: 1,
            preview: Some(ConversationPreview {
                text: "SECRET_MESSAGE_BODY".to_owned(),
                date_ms: Some(1),
                from_me: false,
            }),
        });
        st.hidden_pin_md5 = Some("SECRET_PIN_MD5".to_owned());
        st.ui.show(ToastKind::Success, "SECRET_TOAST");
        let dbg = format!("{st:?}");
        assert!(!dbg.contains("SECRET_CONV_ID"));
        assert!(!dbg.contains("SECRET_NAME"));
        assert!(!dbg.contains("SECRET_MESSAGE_BODY"));
        assert!(!dbg.contains("SECRET_PIN_MD5"));
        assert!(!dbg.contains("SECRET_TOAST"));
    }

    #[test]
    fn batch_preview_overrides_apply_recall_delete_and_empty_clear() {
        let mut st = ConversationsState::default();
        st.conversations.push(ConversationSummary {
            id: "c1".to_owned(),
            is_group: false,
            name: "Peer 1".to_owned(),
            avatar: None,
            pinned: false,
            members: 0,
            unread: 1,
            preview: Some(ConversationPreview {
                text: "Latest".to_owned(),
                date_ms: Some(2_000),
                from_me: false,
            }),
        });
        st.conversations.push(ConversationSummary {
            id: "c2".to_owned(),
            is_group: false,
            name: "Peer 2".to_owned(),
            avatar: None,
            pinned: false,
            members: 0,
            unread: 0,
            preview: Some(ConversationPreview {
                text: "Mid".to_owned(),
                date_ms: Some(1_500),
                from_me: false,
            }),
        });

        // Older recall (>1s before current preview) is ignored.
        let older = BatchApplyDelta {
            applied_count: 1,
            updates: vec![],
            preview_overrides: vec![ConvPreviewOverride {
                conv_id: "c1".to_owned(),
                target_date_ms: 500,
                preview: Some(ConversationPreview {
                    text: "Tin nhắn đã được thu hồi".to_owned(),
                    date_ms: Some(500),
                    from_me: false,
                }),
            }],
            persist_conversations: true,
        };
        let (changed, _, _) = st.apply_batch_delta(&older, None);
        assert!(!changed);
        assert_eq!(
            st.conversations[0]
                .preview
                .as_ref()
                .map(|p| p.text.as_str()),
            Some("Latest")
        );

        // Recall on latest updates text and keeps timestamp.
        let recall = BatchApplyDelta {
            applied_count: 1,
            updates: vec![],
            preview_overrides: vec![ConvPreviewOverride {
                conv_id: "c1".to_owned(),
                target_date_ms: 2_000,
                preview: Some(ConversationPreview {
                    text: "Tin nhắn đã được thu hồi".to_owned(),
                    date_ms: Some(2_000),
                    from_me: false,
                }),
            }],
            persist_conversations: true,
        };
        let (changed, _, _) = st.apply_batch_delta(&recall, None);
        assert!(changed);
        assert_eq!(
            st.conversations[0]
                .preview
                .as_ref()
                .map(|p| p.text.as_str()),
            Some("Tin nhắn đã được thu hồi")
        );

        // Delete recomputes preview to older remaining message and re-sorts c2 ahead of c1.
        let delete_to_older = BatchApplyDelta {
            applied_count: 1,
            updates: vec![],
            preview_overrides: vec![ConvPreviewOverride {
                conv_id: "c1".to_owned(),
                target_date_ms: 2_000,
                preview: Some(ConversationPreview {
                    text: "Older msg".to_owned(),
                    date_ms: Some(1_000),
                    from_me: true,
                }),
            }],
            persist_conversations: true,
        };
        let (changed, _, _) = st.apply_batch_delta(&delete_to_older, None);
        assert!(changed);
        assert_eq!(st.conversations[0].id, "c2");
        assert_eq!(st.conversations[1].id, "c1");
        assert_eq!(
            st.conversations[1].preview,
            Some(ConversationPreview {
                text: "Older msg".to_owned(),
                date_ms: Some(1_000),
                from_me: true,
            })
        );

        // Delete last remaining message clears preview to None.
        let delete_all = BatchApplyDelta {
            applied_count: 1,
            updates: vec![],
            preview_overrides: vec![ConvPreviewOverride {
                conv_id: "c1".to_owned(),
                target_date_ms: 1_000,
                preview: None,
            }],
            persist_conversations: true,
        };
        let (changed, _, _) = st.apply_batch_delta(&delete_all, None);
        assert!(changed);
        assert_eq!(st.conversations[1].preview, None);
    }
}
