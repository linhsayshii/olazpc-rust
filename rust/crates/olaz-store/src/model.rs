//! Row models the store reads and writes.
//!
//! These mirror the Swift `StoredConversation`, `StoredMessage`,
//! `StoredCloudConversationSummary` and `StoredCloudMediaItem` structs in
//! `ZaloSQLiteStore.swift`. The wire-parser crate defines its own models;
//! the duplication is intentional (ported by separate units).

/// One row of the `conversations` table.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct StoredConversation {
    pub id: String,
    pub is_group: bool,
    pub name: String,
    pub avatar: String,
    pub pinned: bool,
    pub members: i64,
    pub unread: i64,
    pub preview_text: String,
    pub preview_ts_ms: i64,
    pub preview_from_me: bool,
    pub updated_at_ms: i64,
}

/// One row of the `messages` table. `raw_json_data` is the UTF-8 bytes of the
/// `raw_json` TEXT column (a serialized Swift `ChatMessage` dictionary).
#[derive(Debug, Clone, PartialEq, Eq, Default)]
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

/// Per-conversation media totals (`cloud_media_aggregation`).
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct StoredCloudConversationSummary {
    pub conv_id: String,
    pub conv_name: String,
    pub conv_avatar: String,
    pub is_group: bool,
    pub photo_bytes: i64,
    pub video_bytes: i64,
    pub file_bytes: i64,
    pub voice_bytes: i64,
    pub item_count: i64,
    pub last_activity_ms: i64,
}

impl StoredCloudConversationSummary {
    /// Sum of all media byte counters.
    #[must_use]
    pub fn total_bytes(&self) -> i64 {
        self.photo_bytes + self.video_bytes + self.file_bytes + self.voice_bytes
    }
}

/// One media item (`cloud_media_items`).
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct StoredCloudMediaItem {
    pub id: String,
    pub client_id: String,
    pub conv_id: String,
    pub conv_name: String,
    pub kind_tag: String,
    pub text: String,
    pub ts_ms: i64,
    pub file_name: String,
    pub size_bytes: i64,
    pub duration_sec: i64,
    pub width: i64,
    pub height: i64,
    pub url: String,
}

/// Flags of Swift `saveMessages(_:skipTwinChecks:preserveExistingReactions:)`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct SaveOptions {
    /// Skip the E2EE locked/plain twin handling (bulk fast path).
    pub skip_twin_checks: bool,
    /// Keep `$.reactions` of the stored row when the incoming row has none.
    pub preserve_existing_reactions: bool,
}

/// Result of `messages_around`.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct MessagesAround {
    pub messages: Vec<StoredMessage>,
    pub has_more_older: bool,
}

/// Result of `shared_media_raw`: raw JSON blobs plus a keyset cursor.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct SharedMediaPage {
    pub rows: Vec<Vec<u8>>,
    pub cursor: Option<String>,
    pub more: bool,
}

/// Filters for `cloud_media_items` (Swift default arguments are in `Default`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CloudMediaQuery {
    pub conv_id: Option<String>,
    pub excluding_conv_id: Option<String>,
    pub kind_tags: Vec<String>,
    pub sort_by_size: bool,
    pub ascending: bool,
    pub offset: i64,
    pub limit: i64,
}

impl Default for CloudMediaQuery {
    fn default() -> Self {
        Self {
            conv_id: None,
            excluding_conv_id: None,
            kind_tags: ["photo", "video", "file", "voice"]
                .iter()
                .map(|s| (*s).to_owned())
                .collect(),
            sort_by_size: false,
            ascending: false,
            offset: 0,
            limit: 60,
        }
    }
}
