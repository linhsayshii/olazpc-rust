//! zCloud domain types, pure aggregation/sorting helpers, and state (U11).
//!
//! Mirrors Swift `ZaloEngine+Cloud.swift` (`CloudState`, `CloudBreakdown`, `CloudItem`,
//! `CloudPage`, `CloudFile`, `CloudFetch`, `CloudActionResult`).
//! `Debug` implementations on types carrying display names, paths, or URLs emit shape-only
//! summaries (ADR-008).

use std::collections::{BTreeMap, BTreeSet};
use std::fmt;

pub use olaz_api::{CloudPlanKind, CloudServerSnapshot, MediaStoreCategory};
use olaz_store::{StoredCloudConversationSummary, StoredCloudMediaItem};
use olaz_wire::{ChatMessage, Kind, is_group_id};

use crate::conversations::ConversationSummary;
use crate::messages::is_valid_url_str;
use crate::state::CoreState;

/// Default quota for the free "Cloud của tôi" plan (1 GiB).
pub const DEFAULT_FREE_CLOUD_QUOTA: i64 = 1_073_741_824;
/// Default per-file limit for the free plan (100 MiB).
pub const DEFAULT_FREE_FILE_LIMIT: i64 = 100 * 1_048_576;
/// Estimated byte size for an unsynced in-memory photo.
pub const ESTIMATED_PHOTO_BYTES: i64 = 150_000;
/// Estimated byte size for an unsynced in-memory video.
pub const ESTIMATED_VIDEO_BYTES: i64 = 1_500_000;
/// Estimated byte size for an unsynced in-memory voice message.
pub const ESTIMATED_VOICE_BYTES: i64 = 40_000;

/// Prefix distinguishing server Media Store `last_id` cursors from local SQLite `"<ts>|<id>"` cursors.
pub const MEDIA_STORE_CURSOR_PREFIX: &str = "ms:";
/// Page size requested from `media_store_send2me` when populating zCloud `CloudList`.
pub const CLOUD_MEDIA_STORE_PAGE_LIMIT: i64 = 100;
/// Maximum pages fetched in a single `CloudList` call to bound worst-case latency.
pub const MAX_CLOUD_MEDIA_STORE_PAGES: usize = 10;

/// User-facing error when a cloud item cannot be located.
pub const CLOUD_NOT_FOUND_ERROR: &str = "Không tìm thấy tệp.";
/// User-facing error when downloading a cloud item fails transiently.
pub const CLOUD_FETCH_FAILED_ERROR: &str =
    "Không tải được nội dung này lúc này. Vui lòng thử lại sau.";
/// User-facing error when reading local SQLite zCloud media fails.
pub const CLOUD_LOCAL_READ_ERROR: &str = "Không đọc được dữ liệu zCloud từ bộ nhớ cục bộ.";
/// User-facing error for unsupported offload toggle on Olaz.
pub const CLOUD_OFFLOAD_UNSUPPORTED_ERROR: &str = "Tự động giải phóng dung lượng zCloud hiện chưa được hỗ trợ trên Olaz. Vui lòng quản lý trên Zalo điện thoại.";

pub use crate::forward::{FileResolutionOutcome, MediaResolutionOutcome};

/// Media category stored in zCloud (Swift `CloudItemKind`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum CloudItemKind {
    Photo,
    Video,
    File,
    Voice,
    Other,
}

impl CloudItemKind {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Photo => "photo",
            Self::Video => "video",
            Self::File => "file",
            Self::Voice => "voice",
            Self::Other => "other",
        }
    }

    #[must_use]
    pub fn from_raw(raw: &str) -> Option<Self> {
        match raw {
            "photo" => Some(Self::Photo),
            "video" => Some(Self::Video),
            "file" => Some(Self::File),
            "voice" => Some(Self::Voice),
            "other" => Some(Self::Other),
            _ => None,
        }
    }
}

/// Shared Media tab category (Swift `SharedMediaKind`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum SharedMediaKind {
    Images,
    Files,
    Links,
}

impl SharedMediaKind {
    #[must_use]
    pub const fn media_store_category(self) -> MediaStoreCategory {
        match self {
            Self::Images => MediaStoreCategory::Media,
            Self::Files => MediaStoreCategory::File,
            Self::Links => MediaStoreCategory::Link,
        }
    }

    #[must_use]
    pub fn kind_tags(self) -> Vec<String> {
        match self {
            Self::Images => vec!["photo".to_owned(), "video".to_owned()],
            Self::Files => vec!["file".to_owned()],
            Self::Links => vec!["link".to_owned()],
        }
    }

    #[must_use]
    pub fn matches_message(self, msg: &ChatMessage) -> bool {
        matches!(
            (self, &msg.kind),
            (Self::Images, Kind::Photo { .. } | Kind::Video { .. })
                | (Self::Files, Kind::File { .. })
                | (Self::Links, Kind::Link { .. })
        )
    }
}

/// Paged Shared Media result (Swift `SharedMediaPage`).
#[derive(Clone, Default, PartialEq)]
pub struct SharedMediaPage {
    pub items: Vec<ChatMessage>,
    pub cursor: Option<String>,
    pub more: bool,
    pub ok: bool,
}

impl fmt::Debug for SharedMediaPage {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("SharedMediaPage")
            .field("items", &self.items.len())
            .field("has_cursor", &self.cursor.is_some())
            .field("more", &self.more)
            .field("ok", &self.ok)
            .finish()
    }
}

/// Per-category fetch directive for `media_store_send2me` inside `Effect::CloudListStore`.
#[derive(Clone, PartialEq, Eq)]
pub struct CloudMediaStoreCategoryFetch {
    pub category: MediaStoreCategory,
    pub start_last_id: Option<String>,
    /// Additional items matching `kind_filter` needed to satisfy the current page, or `None`
    /// to drain all available pages (up to `MAX_CLOUD_MEDIA_STORE_PAGES`) when sorting by size
    /// or ascending date.
    pub target_additional: Option<usize>,
    pub kind_filter: Option<CloudItemKind>,
}

impl fmt::Debug for CloudMediaStoreCategoryFetch {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("CloudMediaStoreCategoryFetch")
            .field("category", &self.category)
            .field("has_start_last_id", &self.start_last_id.is_some())
            .field("target_additional", &self.target_additional)
            .field("kind_filter", &self.kind_filter)
            .finish()
    }
}

/// Server Media Store fetch plan attached to `Effect::CloudListStore` for "Cloud của tôi".
#[derive(Clone, PartialEq, Eq)]
pub struct CloudMediaStoreFetchSpec {
    pub self_conv_id: String,
    pub categories: Vec<CloudMediaStoreCategoryFetch>,
}

impl fmt::Debug for CloudMediaStoreFetchSpec {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("CloudMediaStoreFetchSpec")
            .field("categories", &self.categories)
            .finish()
    }
}

/// Fetched server Media Store items returned inside `Input::CloudListStoreDone`.
#[derive(Clone, PartialEq)]
pub struct CloudMediaStoreBatch {
    pub category: MediaStoreCategory,
    pub items: Vec<ChatMessage>,
    pub last_id: Option<String>,
    pub has_more: bool,
    pub succeeded: bool,
}

impl fmt::Debug for CloudMediaStoreBatch {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("CloudMediaStoreBatch")
            .field("category", &self.category)
            .field("items", &self.items.len())
            .field("has_last_id", &self.last_id.is_some())
            .field("has_more", &self.has_more)
            .field("succeeded", &self.succeeded)
            .finish()
    }
}

/// Returns the server Media Store categories backing a `CloudList` `kind` filter for
/// "Cloud của tôi" (`media_store_send2me`).
#[must_use]
pub const fn cloud_media_store_categories_for_kind(
    kind: Option<CloudItemKind>,
) -> &'static [MediaStoreCategory] {
    match kind {
        Some(CloudItemKind::File) => &[MediaStoreCategory::File],
        Some(CloudItemKind::Photo | CloudItemKind::Video) => &[MediaStoreCategory::Media],
        None => &[MediaStoreCategory::File, MediaStoreCategory::Media],
        Some(CloudItemKind::Voice | CloudItemKind::Other) => &[],
    }
}

/// Bytes per category (Swift `CloudBreakdown`).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct CloudBreakdown {
    pub photo: i64,
    pub video: i64,
    pub file: i64,
    pub voice: i64,
}

impl CloudBreakdown {
    #[must_use]
    pub const fn total(&self) -> i64 {
        self.photo + self.video + self.file + self.voice
    }
}

/// Subscription plan / quota breakdown (Swift `CloudState.Plan`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CloudPlan {
    pub kind: CloudPlanKind,
    pub name: String,
    pub quota: i64,
    pub usage: i64,
    pub family: i64,
    pub cloud_media: i64,
    pub message_backup: i64,
    pub my_cloud: i64,
    pub expire_at_ms: Option<i64>,
    pub auto_renew: Option<bool>,
    pub months: i64,
    pub has_key: bool,
    pub backup_media: bool,
    pub backup_my_cloud: bool,
    pub backup_messages: bool,
    pub file_limit: i64,
}

impl CloudPlan {
    #[must_use]
    pub const fn is_paid(&self) -> bool {
        self.kind.is_paid()
    }

    #[must_use]
    pub fn remaining(&self) -> i64 {
        (self.quota - self.usage - self.family).max(0)
    }

    #[must_use]
    pub fn default_free(my_cloud_total: i64) -> Self {
        Self {
            kind: CloudPlanKind::Free,
            name: "Cloud của tôi".to_owned(),
            quota: DEFAULT_FREE_CLOUD_QUOTA,
            usage: my_cloud_total,
            family: 0,
            cloud_media: 0,
            message_backup: 0,
            my_cloud: my_cloud_total,
            expire_at_ms: None,
            auto_renew: None,
            months: 0,
            has_key: true,
            backup_media: false,
            backup_my_cloud: true,
            backup_messages: true,
            file_limit: DEFAULT_FREE_FILE_LIMIT,
        }
    }
}

/// Per-conversation storage entry (Swift `CloudState.Conversation`).
#[derive(Clone, PartialEq, Eq)]
pub struct CloudConversation {
    pub id: String,
    pub name: String,
    pub avatar: Option<String>,
    pub is_group: bool,
    pub total: i64,
    pub last_activity_ms: Option<i64>,
}

impl fmt::Debug for CloudConversation {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("CloudConversation")
            .field("is_group", &self.is_group)
            .field("has_avatar", &self.avatar.is_some())
            .field("total", &self.total)
            .field("last_activity_ms", &self.last_activity_ms)
            .finish()
    }
}

/// Auto-offload settings (Swift `CloudState.Settings`).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct CloudSettings {
    pub offload_enabled: bool,
    pub offload_available: bool,
    pub last_offload_at_ms: Option<i64>,
    pub last_offload_size: i64,
    pub ttl_days: i64,
}

/// Observable zCloud snapshot published to UI mirrors (Swift `CloudState`).
#[derive(Clone, PartialEq, Eq)]
pub struct CloudSnapshotState {
    pub plan: Option<CloudPlan>,
    pub media: CloudBreakdown,
    pub my_cloud_types: CloudBreakdown,
    pub conversations: Vec<CloudConversation>,
    pub settings: CloudSettings,
    pub changed: i64,
    pub loaded: bool,
    pub hidden_lookup: bool,
    pub self_id: Option<String>,
}

impl Default for CloudSnapshotState {
    fn default() -> Self {
        Self {
            plan: None,
            media: CloudBreakdown::default(),
            my_cloud_types: CloudBreakdown::default(),
            conversations: Vec::new(),
            settings: CloudSettings::default(),
            changed: 0,
            loaded: false,
            hidden_lookup: true,
            self_id: None,
        }
    }
}

impl fmt::Debug for CloudSnapshotState {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("CloudSnapshotState")
            .field("has_plan", &self.plan.is_some())
            .field("media", &self.media)
            .field("my_cloud_types", &self.my_cloud_types)
            .field("conversations_len", &self.conversations.len())
            .field("settings", &self.settings)
            .field("changed", &self.changed)
            .field("loaded", &self.loaded)
            .field("hidden_lookup", &self.hidden_lookup)
            .field("has_self_id", &self.self_id.is_some())
            .finish()
    }
}

/// One media/file item in a zCloud page (Swift `CloudItem`).
#[derive(Clone, PartialEq)]
pub struct CloudItem {
    pub id: String,
    pub kind: CloudItemKind,
    pub conversation_id: String,
    pub conversation_name: String,
    pub size: i64,
    pub date_ms: Option<i64>,
    pub title: String,
    pub ext: String,
    pub duration: f64,
    pub width: i64,
    pub height: i64,
}

impl fmt::Debug for CloudItem {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("CloudItem")
            .field("kind", &self.kind)
            .field("size", &self.size)
            .field("date_ms", &self.date_ms)
            .field("ext", &self.ext)
            .field("duration", &self.duration)
            .field("width", &self.width)
            .field("height", &self.height)
            .finish()
    }
}

/// Paged zCloud media list (Swift `CloudPage`).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct CloudPage {
    pub items: Vec<CloudItem>,
    pub has_more: bool,
    pub error: Option<String>,
}

/// Downloaded/staged cloud item (Swift `CloudFile`).
#[derive(Clone, PartialEq, Eq)]
pub struct CloudFile {
    pub path: String,
    pub kind: CloudItemKind,
    pub title: String,
    pub ext: String,
    pub size: i64,
    pub date_ms: Option<i64>,
}

impl fmt::Debug for CloudFile {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("CloudFile")
            .field("kind", &self.kind)
            .field("ext", &self.ext)
            .field("size", &self.size)
            .field("date_ms", &self.date_ms)
            .finish()
    }
}

/// Outcome of `cloud_fetch` (Swift `CloudFetch`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum CloudFetch {
    Ready(CloudFile),
    Expired,
    Failed(String),
}

/// Outcome of `cloud_delete` or `cloud_set_offload` (Swift `CloudActionResult`).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct CloudActionResult {
    pub ok: bool,
    pub deleted: Vec<String>,
    pub failed: Vec<String>,
    pub error: Option<String>,
}

/// In-flight `cloud_list` request parameters held until the store query finishes.
#[derive(Clone, Debug)]
pub(crate) struct PendingCloudList {
    pub conv_id: Option<String>,
    pub excluding_self: Option<String>,
    pub kind: Option<CloudItemKind>,
    pub sort_by_size: bool,
    pub ascending: bool,
    pub safe_offset: i64,
    pub safe_limit: i64,
    pub is_self_cloud: bool,
    pub force_full_window: bool,
}

/// In-flight `shared_media` request parameters held until store / API fetch finishes.
#[derive(Clone, Debug)]
pub(crate) struct PendingSharedMedia {
    pub conv_id: String,
    pub kind: SharedMediaKind,
    pub after_cursor: Option<String>,
    pub limit: i64,
}

/// In-memory cache of server `media_store_send2me` items per category for "Cloud của tôi".
/// Kept strictly in memory (never inserted into SQLite `messages`, which stores contiguous
/// chat scrollback windows).
#[derive(Clone, Default)]
pub(crate) struct MediaStoreCacheEntry {
    pub items: Vec<ChatMessage>,
    pub last_id: Option<String>,
    pub has_more: bool,
    pub fetched: bool,
}

/// Stage of an in-flight `cloud_fetch` operation.
#[derive(Clone, Debug)]
pub(crate) enum PendingCloudFetchStage {
    LookingUp {
        conv_id: String,
        msg_id: String,
    },
    Resolving {
        kind: CloudItemKind,
        title: String,
        date_ms: Option<i64>,
        fallback_size: i64,
    },
}

/// In-flight `cloud_delete` state machine iterating over keys serially.
#[derive(Clone, Debug)]
pub(crate) struct PendingCloudDelete {
    pub original_keys: Vec<String>,
    pub index: usize,
    pub current_conv_id: String,
    pub current_msg_id: String,
    pub current_cli_msg_id: String,
    pub deleted: Vec<String>,
    pub first_error: Option<String>,
}

/// Domain state owned by `CoreState::cloud`.
#[derive(Clone, Default)]
pub struct CloudState {
    pub snapshot: CloudSnapshotState,
    pub(crate) pending_lists: BTreeMap<u64, PendingCloudList>,
    pub(crate) pending_fetches: BTreeMap<u64, PendingCloudFetchStage>,
    pub(crate) pending_thumbnails: BTreeSet<u64>,
    pub(crate) pending_deletes: BTreeMap<u64, PendingCloudDelete>,
    pub(crate) pending_shared_media: BTreeMap<u64, PendingSharedMedia>,
    pub(crate) my_cloud_media_cache: BTreeMap<MediaStoreCategory, MediaStoreCacheEntry>,
    pub(crate) media_store_messages: BTreeMap<(String, String), ChatMessage>,
}

impl fmt::Debug for CloudState {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("CloudState")
            .field("snapshot", &self.snapshot)
            .field("pending_lists", &self.pending_lists.len())
            .field("pending_fetches", &self.pending_fetches.len())
            .field("pending_thumbnails", &self.pending_thumbnails.len())
            .field("pending_deletes", &self.pending_deletes.len())
            .field("pending_shared_media", &self.pending_shared_media.len())
            .field("my_cloud_media_cache", &self.my_cloud_media_cache.len())
            .field("media_store_messages", &self.media_store_messages.len())
            .finish()
    }
}

impl CloudState {
    /// Resets session-scoped cloud state (used on `LogOut`). Returns `true` if `snapshot` changed.
    pub fn reset_session(&mut self) -> bool {
        self.pending_lists.clear();
        self.pending_fetches.clear();
        self.pending_thumbnails.clear();
        self.pending_deletes.clear();
        self.pending_shared_media.clear();
        self.my_cloud_media_cache.clear();
        self.media_store_messages.clear();
        self.reset_snapshot()
    }

    /// Resets only the observable `snapshot` (used on `ResetCloud`). Returns `true` if changed.
    pub fn reset_snapshot(&mut self) -> bool {
        let default = CloudSnapshotState::default();
        if self.snapshot == default {
            false
        } else {
            self.snapshot = default;
            true
        }
    }

    /// Clears the per-category `media_store_send2me` page cache (used on `RefreshCloud` so
    /// reopening zCloud picks up items uploaded from other devices).
    pub fn clear_media_store_cache(&mut self) {
        self.my_cloud_media_cache.clear();
    }

    /// Clears both the per-category page cache and the message-lookup map (used on `ResetCloud`).
    pub fn clear_all_media_store_caches(&mut self) {
        self.my_cloud_media_cache.clear();
        self.media_store_messages.clear();
    }

    /// Caches server Media Store messages by `(conv_id, msg_id)` so `CloudFetch`, `CloudDelete`,
    /// and media URL/thumbnail resolvers can locate server-only items not present in SQLite.
    pub fn cache_media_store_messages(&mut self, conv_id: &str, items: &[ChatMessage]) {
        for msg in items {
            self.media_store_messages
                .insert((conv_id.to_owned(), msg.id.clone()), msg.clone());
        }
    }

    /// Looks up a cached server Media Store message by `(conv_id, msg_id)`.
    #[must_use]
    pub fn cached_media_store_message(&self, conv_id: &str, msg_id: &str) -> Option<&ChatMessage> {
        self.media_store_messages
            .get(&(conv_id.to_owned(), msg_id.to_owned()))
    }

    /// Looks up a cached server Media Store message across all conversations by `msg_id`.
    #[must_use]
    pub fn cached_media_store_message_any(&self, msg_id: &str) -> Option<&ChatMessage> {
        self.media_store_messages
            .iter()
            .find_map(|((_, mid), msg)| (mid == msg_id).then_some(msg))
    }

    /// Removes a deleted item from both server Media Store caches.
    pub fn remove_cached_media_store_message(&mut self, conv_id: &str, msg_id: &str) {
        self.media_store_messages
            .remove(&(conv_id.to_owned(), msg_id.to_owned()));
        for entry in self.my_cloud_media_cache.values_mut() {
            entry
                .items
                .retain(|m| !(m.conversation_id == conv_id && m.id == msg_id));
        }
    }
}

/// Merges `extra` (e.g. local SQLite or in-memory messages) into `primary` (server page 1),
/// deduplicating by `msg.id` and sorting newest-first (`date_ms DESC, id DESC`).
/// When `has_more_primary` is true, drops `extra` items strictly older than the oldest item in
/// `primary` so they don't jump ahead of later server pages.
#[must_use]
pub fn merge_shared_media_items(
    mut primary: Vec<ChatMessage>,
    extra: impl IntoIterator<Item = ChatMessage>,
    has_more_primary: bool,
) -> Vec<ChatMessage> {
    let cutoff_ms = if has_more_primary {
        primary.iter().map(|m| m.date_ms).min()
    } else {
        None
    };
    let mut seen: BTreeSet<String> = primary.iter().map(|m| m.id.clone()).collect();
    for msg in extra {
        if seen.contains(&msg.id) {
            continue;
        }
        if cutoff_ms.is_some_and(|min_ms| msg.date_ms < min_ms) {
            continue;
        }
        seen.insert(msg.id.clone());
        primary.push(msg);
    }
    primary.sort_by(|a, b| b.date_ms.cmp(&a.date_ms).then_with(|| b.id.cmp(&a.id)));
    primary
}

/// Pure in-memory fallback for `SharedMedia` when no SQLite store is attached.
#[must_use]
pub fn shared_media_page_from_memory(
    messages: &[ChatMessage],
    kind: SharedMediaKind,
    after_cursor: Option<&str>,
    limit: i64,
) -> SharedMediaPage {
    let safe_limit = usize::try_from(limit.clamp(1, 200)).unwrap_or(1);
    let mut filtered: Vec<ChatMessage> = messages
        .iter()
        .filter(|m| kind.matches_message(m))
        .cloned()
        .collect();
    filtered.sort_by(|a, b| b.date_ms.cmp(&a.date_ms).then_with(|| b.id.cmp(&a.id)));

    if let Some(raw_cursor) = after_cursor
        && !raw_cursor.starts_with(MEDIA_STORE_CURSOR_PREFIX)
        && let Some((ts_str, id_str)) = raw_cursor.split_once('|')
        && let Ok(cursor_ts) = ts_str.parse::<i64>()
        && !id_str.is_empty()
    {
        filtered.retain(|m| m.date_ms < cursor_ts || (m.date_ms == cursor_ts && m.id.as_str() < id_str));
    }

    let more = filtered.len() > safe_limit;
    let items: Vec<ChatMessage> = filtered.into_iter().take(safe_limit).collect();
    let cursor = if more {
        items.last().map(|m| format!("{}|{}", m.date_ms, m.id))
    } else {
        None
    };
    SharedMediaPage {
        items,
        cursor,
        more,
        ok: true,
    }
}

/// Splits a zCloud item key (`"<convId>|<msgId>|<kind>"`) matching Swift
/// `key.split(separator: "|", maxSplits: 2)` (`omittingEmptySubsequences: true`).
#[must_use]
pub fn split_cloud_key(key: &str) -> Vec<&str> {
    let mut parts = Vec::with_capacity(3);
    let mut rest = key.trim_start_matches('|');
    while !rest.is_empty() && parts.len() < 2 {
        if let Some(pos) = rest.find('|') {
            parts.push(&rest[..pos]);
            rest = rest[pos + 1..].trim_start_matches('|');
        } else {
            parts.push(rest);
            rest = "";
        }
    }
    if !rest.is_empty() {
        parts.push(rest);
    }
    parts
}

/// Extracts the file extension matching Swift `URL(fileURLWithPath: name).pathExtension`.
#[must_use]
pub fn path_extension(path: &str) -> String {
    let trimmed = path.trim_end_matches('/');
    let file_name = trimmed.rsplit('/').next().unwrap_or(trimmed);
    if file_name.is_empty() || file_name == "." || file_name == ".." {
        return String::new();
    }
    match file_name.rfind('.') {
        Some(idx) if idx > 0 => file_name[idx + 1..].to_owned(),
        _ => String::new(),
    }
}

/// Display name helper matching Swift `ConversationSummary.displayName`.
#[must_use]
pub fn conversation_display_name(conv: &ConversationSummary) -> &str {
    if conv.name.is_empty() {
        if conv.is_group {
            "Nhóm"
        } else {
            "Người dùng Zalo"
        }
    } else {
        conv.name.as_str()
    }
}

/// Resolves conversation display metadata matching Swift `ZaloEngine.resolveCloudConversationMeta`.
#[must_use]
pub fn resolve_cloud_conversation_meta(
    state: &CoreState,
    conv_id: &str,
    fallback_name: &str,
    fallback_avatar: &str,
    fallback_is_group: Option<bool>,
) -> (String, Option<String>, bool) {
    if let Some(conv) = state
        .conversations
        .conversations
        .iter()
        .find(|c| c.id == conv_id)
    {
        return (
            conversation_display_name(conv).to_owned(),
            conv.avatar.clone(),
            conv.is_group,
        );
    }
    let self_id = state.session.self_conversation_id.as_deref();
    let (ident_name, ident_avatar, _members) =
        state
            .conversations
            .lookup_conversation_identity(&state.contacts, conv_id, self_id);
    let is_group = fallback_is_group.unwrap_or_else(|| is_group_id(conv_id));
    let resolved_name = if !ident_name.is_empty() && ident_name != conv_id {
        ident_name
    } else if !fallback_name.is_empty() {
        fallback_name.to_owned()
    } else if self_id == Some(conv_id) {
        "Cloud của tôi".to_owned()
    } else if is_group {
        "Nhóm".to_owned()
    } else if ident_name.is_empty() {
        conv_id.to_owned()
    } else {
        ident_name
    };
    let resolved_avatar = ident_avatar.or_else(|| {
        (!fallback_avatar.is_empty() && is_valid_url_str(fallback_avatar))
            .then(|| fallback_avatar.to_owned())
    });
    (resolved_name, resolved_avatar, is_group)
}

/// Returns whether a `ChatMessage` represents a zCloud media/file attachment and its `CloudItemKind`.
#[must_use]
pub fn message_cloud_kind(msg: &ChatMessage) -> Option<CloudItemKind> {
    match &msg.kind {
        Kind::Photo { .. } => Some(CloudItemKind::Photo),
        Kind::Video { .. } => Some(CloudItemKind::Video),
        Kind::Voice { .. } => Some(CloudItemKind::Voice),
        Kind::File { .. } => Some(CloudItemKind::File),
        _ => None,
    }
}

/// Converts an in-memory `ChatMessage` to a [`CloudItem`], matching Swift `cloudItem(from:ChatMessage)`.
#[must_use]
pub fn cloud_item_from_message(
    msg: &ChatMessage,
    conv_id: &str,
    conv_name: &str,
) -> Option<CloudItem> {
    let (kind, title, ext, size, duration, width, height) = match &msg.kind {
        Kind::Photo { width, height, .. } => (
            CloudItemKind::Photo,
            msg.text.clone(),
            "jpg".to_owned(),
            ESTIMATED_PHOTO_BYTES,
            0.0,
            *width,
            *height,
        ),
        Kind::Video { duration, .. } => (
            CloudItemKind::Video,
            msg.text.clone(),
            "mp4".to_owned(),
            ESTIMATED_VIDEO_BYTES,
            *duration as f64,
            0,
            0,
        ),
        Kind::Voice { duration, .. } => (
            CloudItemKind::Voice,
            msg.text.clone(),
            "m4a".to_owned(),
            ESTIMATED_VOICE_BYTES,
            *duration as f64,
            0,
            0,
        ),
        Kind::File { name, size, .. } => (
            CloudItemKind::File,
            name.clone(),
            path_extension(name),
            (*size).max(0),
            0.0,
            0,
            0,
        ),
        _ => return None,
    };
    Some(CloudItem {
        id: format!("{conv_id}|{}|{}", msg.id, kind.as_str()),
        kind,
        conversation_id: conv_id.to_owned(),
        conversation_name: conv_name.to_owned(),
        size,
        date_ms: Some(msg.date_ms),
        title,
        ext,
        duration,
        width,
        height,
    })
}

/// Converts a SQLite [`StoredCloudMediaItem`] to a [`CloudItem`], matching Swift
/// `cloudItem(from:StoredCloudMediaItem)`.
#[must_use]
pub fn cloud_item_from_stored(
    state: &CoreState,
    stored: &StoredCloudMediaItem,
) -> Option<CloudItem> {
    let kind = CloudItemKind::from_raw(&stored.kind_tag)?;
    let (conv_name, _, _) =
        resolve_cloud_conversation_meta(state, &stored.conv_id, &stored.conv_name, "", None);
    let (title, ext) = match kind {
        CloudItemKind::Photo => (stored.text.clone(), "jpg".to_owned()),
        CloudItemKind::Video => (stored.text.clone(), "mp4".to_owned()),
        CloudItemKind::Voice => (stored.text.clone(), "m4a".to_owned()),
        CloudItemKind::File => {
            let t = if stored.file_name.is_empty() {
                stored.text.clone()
            } else {
                stored.file_name.clone()
            };
            let ext = path_extension(&t);
            (t, ext)
        }
        CloudItemKind::Other => return None,
    };
    Some(CloudItem {
        id: format!("{}|{}|{}", stored.conv_id, stored.id, kind.as_str()),
        kind,
        conversation_id: stored.conv_id.clone(),
        conversation_name: conv_name,
        size: stored.size_bytes,
        date_ms: (stored.ts_ms > 0).then_some(stored.ts_ms),
        title,
        ext,
        duration: stored.duration_sec as f64,
        width: stored.width,
        height: stored.height,
    })
}

/// Sorts [`CloudItem`]s matching Swift `ZaloEngine.sortCloudItems(_:bySize:ascending:)`.
///
/// When `by_size` is true, tie-breaker `date_ms` is ALWAYS descending (matching Swift `ad > bd`),
/// followed by `id` in the requested `ascending` direction.
pub fn sort_cloud_items(items: &mut [CloudItem], by_size: bool, ascending: bool) {
    items.sort_by(|a, b| {
        if by_size && a.size != b.size {
            return if ascending {
                a.size.cmp(&b.size)
            } else {
                b.size.cmp(&a.size)
            };
        }
        let ad = a.date_ms.unwrap_or(i64::MIN);
        let bd = b.date_ms.unwrap_or(i64::MIN);
        if ad != bd {
            if by_size {
                return bd.cmp(&ad);
            }
            return if ascending { ad.cmp(&bd) } else { bd.cmp(&ad) };
        }
        if ascending {
            a.id.cmp(&b.id)
        } else {
            b.id.cmp(&a.id)
        }
    });
}

#[derive(Default)]
struct ConvAccumulator {
    photo: i64,
    video: i64,
    file: i64,
    voice: i64,
    last_activity_ms: Option<i64>,
    fallback_name: String,
    fallback_avatar: String,
    fallback_is_group: Option<bool>,
}

impl ConvAccumulator {
    const fn total(&self) -> i64 {
        self.photo + self.video + self.file + self.voice
    }
}

/// Pure aggregation + plan update matching Swift `ZaloEngine.applyCloudSnapshot`.
/// Returns `true` if `state.cloud.snapshot` changed.
pub fn apply_cloud_snapshot(
    state: &mut CoreState,
    sql_summaries: &[StoredCloudConversationSummary],
    existing_ids_by_conv: &BTreeMap<String, BTreeSet<String>>,
    server_snapshot: Option<&CloudServerSnapshot>,
) -> bool {
    let mut per_conv: BTreeMap<String, ConvAccumulator> = BTreeMap::new();
    for summary in sql_summaries {
        if summary.conv_id.is_empty() {
            continue;
        }
        per_conv.insert(
            summary.conv_id.clone(),
            ConvAccumulator {
                photo: summary.photo_bytes,
                video: summary.video_bytes,
                file: summary.file_bytes,
                voice: summary.voice_bytes,
                last_activity_ms: (summary.last_activity_ms > 0)
                    .then_some(summary.last_activity_ms),
                fallback_name: summary.conv_name.clone(),
                fallback_avatar: summary.conv_avatar.clone(),
                fallback_is_group: Some(summary.is_group),
            },
        );
    }

    for (cid, list) in &state.messages.windows {
        if cid.is_empty() {
            continue;
        }
        let persisted = existing_ids_by_conv.get(cid);
        for msg in list {
            if persisted.is_some_and(|set| set.contains(&msg.id)) {
                continue;
            }
            let (kind_bytes, is_media) = match &msg.kind {
                Kind::Photo { .. } => ((ESTIMATED_PHOTO_BYTES, 0, 0, 0), true),
                Kind::Video { .. } => ((0, ESTIMATED_VIDEO_BYTES, 0, 0), true),
                Kind::Voice { .. } => ((0, 0, 0, ESTIMATED_VOICE_BYTES), true),
                Kind::File { size, .. } => ((0, 0, (*size).max(0), 0), true),
                _ => ((0, 0, 0, 0), false),
            };
            if is_media {
                let acc = per_conv.entry(cid.clone()).or_default();
                acc.photo += kind_bytes.0;
                acc.video += kind_bytes.1;
                acc.file += kind_bytes.2;
                acc.voice += kind_bytes.3;
                acc.last_activity_ms = Some(
                    acc.last_activity_ms
                        .map_or(msg.date_ms, |prev| prev.max(msg.date_ms)),
                );
            }
        }
    }

    let mut next = state.cloud.snapshot.clone();
    next.loaded = true;
    next.self_id = state.session.self_conversation_id.clone();
    next.settings.offload_enabled = false;
    next.settings.offload_available = false;

    let mut media_breakdown = CloudBreakdown::default();
    let mut my_cloud_breakdown = CloudBreakdown::default();
    let mut conv_entries: Vec<CloudConversation> = Vec::new();
    let my_cloud_id = state.session.self_conversation_id.as_deref().unwrap_or("");

    for (cid, acc) in &per_conv {
        let conv_preview_ms = state
            .conversations
            .conversations
            .iter()
            .find(|c| c.id == *cid)
            .and_then(|c| c.preview.as_ref())
            .and_then(|p| p.date_ms);
        let latest = match (acc.last_activity_ms, conv_preview_ms) {
            (Some(a), Some(b)) => Some(a.max(b)),
            (Some(a), None) => Some(a),
            (None, Some(b)) => Some(b),
            (None, None) => None,
        };
        if !my_cloud_id.is_empty() && cid == my_cloud_id {
            my_cloud_breakdown.photo += acc.photo;
            my_cloud_breakdown.video += acc.video;
            my_cloud_breakdown.file += acc.file;
            my_cloud_breakdown.voice += acc.voice;
        } else {
            media_breakdown.photo += acc.photo;
            media_breakdown.video += acc.video;
            media_breakdown.file += acc.file;
            media_breakdown.voice += acc.voice;
        }
        if acc.total() > 0 {
            let (name, avatar, is_group) = resolve_cloud_conversation_meta(
                state,
                cid,
                &acc.fallback_name,
                &acc.fallback_avatar,
                acc.fallback_is_group,
            );
            conv_entries.push(CloudConversation {
                id: cid.clone(),
                name,
                avatar,
                is_group,
                total: acc.total(),
                last_activity_ms: latest,
            });
        }
    }

    // Approved fix (user-decisions item 12.1): equal totals tie-break by name, then id.
    conv_entries.sort_by(|a, b| {
        b.total
            .cmp(&a.total)
            .then_with(|| a.name.cmp(&b.name))
            .then_with(|| a.id.cmp(&b.id))
    });
    next.media = media_breakdown;
    next.my_cloud_types = my_cloud_breakdown;
    next.conversations = conv_entries;

    if let Some(server) = server_snapshot {
        let previous_has_key = next.plan.as_ref().is_none_or(|p| p.has_key);
        next.plan = Some(CloudPlan {
            kind: server.plan_kind,
            name: server.plan_name.clone(),
            quota: server.quota,
            usage: server.usage,
            family: server.family,
            cloud_media: server.cloud_media,
            message_backup: server.message_backup,
            my_cloud: server.my_cloud,
            expire_at_ms: server.expire_at_ms,
            auto_renew: server.auto_renew,
            months: server.months,
            has_key: previous_has_key,
            backup_media: server.backup_media,
            backup_my_cloud: server.backup_my_cloud,
            backup_messages: server.backup_messages,
            file_limit: server.file_limit,
        });
    } else if let Some(mut existing) = next.plan {
        if existing.is_paid() {
            existing.my_cloud = my_cloud_breakdown.total();
            existing.cloud_media = media_breakdown.total();
            existing.usage =
                my_cloud_breakdown.total() + media_breakdown.total() + existing.message_backup;
        } else {
            existing.my_cloud = my_cloud_breakdown.total();
            existing.cloud_media = 0;
            existing.message_backup = 0;
            existing.family = 0;
            existing.usage = my_cloud_breakdown.total();
            if existing.quota <= 0 {
                existing.quota = DEFAULT_FREE_CLOUD_QUOTA;
            }
        }
        next.plan = Some(existing);
    } else {
        next.plan = Some(CloudPlan::default_free(my_cloud_breakdown.total()));
    }

    if next != state.cloud.snapshot {
        state.cloud.snapshot = next;
        true
    } else {
        false
    }
}

/// Collects `(conv_id, media_message_ids)` across all non-empty memory windows (for `RefreshCloud`).
#[must_use]
pub fn collect_memory_media_ids(state: &CoreState) -> Vec<(String, Vec<String>)> {
    let mut out = Vec::new();
    for (cid, list) in &state.messages.windows {
        if list.is_empty() {
            continue;
        }
        let ids: Vec<String> = list
            .iter()
            .filter(|m| message_cloud_kind(m).is_some())
            .map(|m| m.id.clone())
            .collect();
        if !ids.is_empty() {
            out.push((cid.clone(), ids));
        }
    }
    out
}

/// Collects `(conv_id, all_media_ids, kind_matching_ids)` for `CloudList`.
#[must_use]
pub fn collect_list_memory_media_ids(
    state: &CoreState,
    conv_id: Option<&str>,
    excluding_self: Option<&str>,
    kind_filter: Option<CloudItemKind>,
) -> Vec<(String, Vec<String>, Vec<String>)> {
    let mut out = Vec::new();
    let convs: Vec<&str> = match conv_id {
        Some(cid) => vec![cid],
        None => state
            .messages
            .windows
            .keys()
            .filter(|cid| excluding_self != Some(cid.as_str()))
            .map(String::as_str)
            .collect(),
    };
    for cid in convs {
        let Some(list) = state.messages.windows.get(cid) else {
            continue;
        };
        if list.is_empty() {
            continue;
        }
        let mut all_ids = Vec::new();
        let mut kind_ids = Vec::new();
        for msg in list {
            let Some(k) = message_cloud_kind(msg) else {
                continue;
            };
            all_ids.push(msg.id.clone());
            if kind_filter.is_none() || kind_filter == Some(k) {
                kind_ids.push(msg.id.clone());
            }
        }
        if !all_ids.is_empty() {
            out.push((cid.to_owned(), all_ids, kind_ids));
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn split_cloud_key_matches_swift() {
        assert_eq!(
            split_cloud_key("3001161|ft_photo|photo"),
            vec!["3001161", "ft_photo", "photo"]
        );
        assert_eq!(
            split_cloud_key("3001161|ft_photo"),
            vec!["3001161", "ft_photo"]
        );
        assert_eq!(split_cloud_key("badkey"), vec!["badkey"]);
        assert_eq!(split_cloud_key("a|b|c|d"), vec!["a", "b", "c|d"]);
        assert_eq!(split_cloud_key("|a||b|c"), vec!["a", "b", "c"]);
        assert!(split_cloud_key("|||").is_empty());
    }

    #[test]
    fn path_extension_matches_swift_url() {
        assert_eq!(path_extension("report.pdf"), "pdf");
        assert_eq!(path_extension("/fake/cloud/clip1.mp4"), "mp4");
        assert_eq!(path_extension("archive.tar.gz"), "gz");
        assert_eq!(path_extension("README"), "");
        assert_eq!(path_extension(".hidden"), "");
        assert_eq!(path_extension("file."), "");
        assert_eq!(path_extension("dir.with.dot/noext"), "");
    }

    #[test]
    fn sort_cloud_items_size_tie_breaks_date_desc_even_when_ascending() {
        let mut items = vec![
            CloudItem {
                id: "a".to_owned(),
                kind: CloudItemKind::File,
                conversation_id: "c1".to_owned(),
                conversation_name: "C1".to_owned(),
                size: 150_000,
                date_ms: Some(1000),
                title: "old".to_owned(),
                ext: "pdf".to_owned(),
                duration: 0.0,
                width: 0,
                height: 0,
            },
            CloudItem {
                id: "b".to_owned(),
                kind: CloudItemKind::File,
                conversation_id: "c1".to_owned(),
                conversation_name: "C1".to_owned(),
                size: 150_000,
                date_ms: Some(3000),
                title: "new".to_owned(),
                ext: "zip".to_owned(),
                duration: 0.0,
                width: 0,
                height: 0,
            },
            CloudItem {
                id: "c".to_owned(),
                kind: CloudItemKind::Voice,
                conversation_id: "c1".to_owned(),
                conversation_name: "C1".to_owned(),
                size: 40_000,
                date_ms: Some(2000),
                title: "small".to_owned(),
                ext: "m4a".to_owned(),
                duration: 5.0,
                width: 0,
                height: 0,
            },
        ];
        sort_cloud_items(&mut items, true, true);
        let ids: Vec<&str> = items.iter().map(|i| i.id.as_str()).collect();
        assert_eq!(ids, vec!["c", "b", "a"]);
    }

    #[test]
    fn cloud_snapshot_default_has_hidden_lookup_true() {
        let snap = CloudSnapshotState::default();
        assert!(snap.hidden_lookup);
        assert!(!snap.loaded);
        assert!(snap.plan.is_none());
    }

    #[test]
    fn equal_totals_tie_break_by_name_item_12_1() {
        let summary =
            |conv_id: &str, name: &str, photo_bytes: i64| StoredCloudConversationSummary {
                conv_id: conv_id.to_owned(),
                conv_name: name.to_owned(),
                conv_avatar: String::new(),
                is_group: false,
                photo_bytes,
                video_bytes: 0,
                file_bytes: 0,
                voice_bytes: 0,
                item_count: 1,
                last_activity_ms: 1_700_000_000_000,
            };
        let mut state = CoreState::default();
        // Reverse ID order relative to name order so id-only sorting would disagree.
        let sql_summaries = vec![
            summary("3001", "Charlie", 150_000),
            summary("3002", "Alpha", 150_000),
            summary("3003", "Beta", 150_000),
            summary("3004", "Biggest", 300_000),
        ];
        let changed = apply_cloud_snapshot(&mut state, &sql_summaries, &BTreeMap::new(), None);
        assert!(changed);
        let names: Vec<&str> = state
            .cloud
            .snapshot
            .conversations
            .iter()
            .map(|c| c.name.as_str())
            .collect();
        assert_eq!(names, vec!["Biggest", "Alpha", "Beta", "Charlie"]);
    }
}
