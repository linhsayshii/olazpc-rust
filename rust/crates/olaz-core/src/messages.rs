//! Unit 4 message windows, history paging, freshness probing, and partial Unit 9 contacts state.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::fmt;

use olaz_store::StoredMessage as DbStoredMessage;
use olaz_wire::{
    ChatMessage, Kind, NameLookup, ParsedWireEvent, StoredMessage as WireStoredMessage,
    UNKNOWN_NAME, WireParseOptions, clean_group_id, decode_stored_message, encode_chat_message,
    extract_batch_events, group_conv_id, is_group_id, normalize_contact_uid, sanitize_profile_uid,
    strip_user_prefix,
};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};

use crate::conversations::{
    CachedGroup, CachedProfile, ConversationPreview, ConversationSummary, ConversationsState,
    FriendIdentity, GroupIdentity, IdentityTable, message_preview_label, sort_conversations,
};
use crate::groups::GroupsState;
use crate::input::SeenTarget;

/// 24-hour interval (in seconds) between full launch history refreshes.
pub const FULL_HISTORY_REFRESH_INTERVAL_SECS: f64 = 24.0 * 60.0 * 60.0;

/// Preference key storing the last full history refresh epoch seconds string.
pub const FULL_HISTORY_REFRESH_PREF_KEY: &str = "historyFullRefreshAt";

/// Formats an `f64` matching Swift's `String(Double)`: integral values end in `.0`, non-integral
/// values use Rust's shortest round-trip representation.
#[must_use]
pub fn format_swift_double(val: f64) -> String {
    if !val.is_finite() {
        return val.to_string();
    }
    let s = format!("{val}");
    if !s.contains('.') && !s.contains('e') && !s.contains('E') {
        format!("{s}.0")
    } else {
        s
    }
}

/// Per-conversation history freshness recorded during launch preload probing or recent fetches.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum HistoryFreshness {
    #[serde(rename = "up_to_date")]
    UpToDate,
    #[serde(rename = "stale")]
    Stale,
}

impl HistoryFreshness {
    #[must_use]
    pub fn as_str(self) -> &'static str {
        match self {
            Self::UpToDate => "up_to_date",
            Self::Stale => "stale",
        }
    }

    #[must_use]
    pub fn from_str_tag(s: &str) -> Option<Self> {
        match s {
            "up_to_date" => Some(Self::UpToDate),
            "stale" => Some(Self::Stale),
            _ => None,
        }
    }
}

/// Coalesced per-conversation message window delta shipped through [`crate::changes::ChangeHub`].
///
/// Exact rule:
/// - The first change a conversation's window ships in a mirror session is always [`Self::Reset`].
/// - [`Self::Append`] is shipped ONLY when, since the last pull, that window got nothing but tail
///   appends on top of a base already shipped.
/// - [`Self::Patch`] is shipped ONLY when, since the last pull, that window got in-place upserts
///   or removals with no reorder on top of a base already shipped.
/// - Anything else (including `Append + Patch`, `Patch + Append`, `Remove + Append`, or any sort /
///   page merge) coalesces to [`Self::Reset`].
#[derive(Clone, PartialEq)]
pub enum WindowDelta {
    Reset {
        conv_id: String,
        messages: Vec<ChatMessage>,
    },
    Append {
        conv_id: String,
        messages: Vec<ChatMessage>,
    },
    Patch {
        conv_id: String,
        upserts: Vec<ChatMessage>,
        removed_ids: Vec<String>,
    },
    Remove {
        conv_id: String,
    },
}

impl fmt::Debug for WindowDelta {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Reset { messages, .. } => f
                .debug_struct("WindowDelta::Reset")
                .field("count", &messages.len())
                .finish(),
            Self::Append { messages, .. } => f
                .debug_struct("WindowDelta::Append")
                .field("count", &messages.len())
                .finish(),
            Self::Patch {
                upserts,
                removed_ids,
                ..
            } => f
                .debug_struct("WindowDelta::Patch")
                .field("upserts", &upserts.len())
                .field("removed", &removed_ids.len())
                .finish(),
            Self::Remove { .. } => f.debug_struct("WindowDelta::Remove").finish(),
        }
    }
}

/// Internal per-conversation pending delta accumulator inside [`crate::changes::ChangeHub`].
#[derive(Clone, Debug, PartialEq)]
pub enum PendingWindowOp {
    Reset,
    Append(Vec<ChatMessage>),
    Patch {
        upserts: Vec<ChatMessage>,
        removed_ids: Vec<String>,
    },
    Remove,
}

/// Coalesces a new window operation onto an optional existing pending operation for a conversation
/// given `already_shipped` (whether a base `Reset` has been shipped in the current mirror session).
#[must_use]
pub fn coalesce_window_op(
    already_shipped: bool,
    existing: Option<PendingWindowOp>,
    incoming: PendingWindowOp,
) -> PendingWindowOp {
    if matches!(incoming, PendingWindowOp::Remove) {
        return PendingWindowOp::Remove;
    }
    if !already_shipped || matches!(existing, Some(PendingWindowOp::Remove)) {
        return PendingWindowOp::Reset;
    }
    match (existing, incoming) {
        (None, op) => op,
        (Some(PendingWindowOp::Remove), _) | (_, PendingWindowOp::Remove) => unreachable!(),
        (Some(PendingWindowOp::Reset), _) | (_, PendingWindowOp::Reset) => PendingWindowOp::Reset,
        (Some(PendingWindowOp::Append(mut prev)), PendingWindowOp::Append(next)) => {
            prev.extend(next);
            PendingWindowOp::Append(prev)
        }
        (
            Some(PendingWindowOp::Patch {
                mut upserts,
                mut removed_ids,
            }),
            PendingWindowOp::Patch {
                upserts: next_upserts,
                removed_ids: next_removed,
            },
        ) => {
            for r in next_removed {
                upserts.retain(|m| m.id != r);
                if !removed_ids.contains(&r) {
                    removed_ids.push(r);
                }
            }
            for u in next_upserts {
                removed_ids.retain(|id| id != &u.id);
                if let Some(pos) = upserts.iter().position(|m| m.id == u.id) {
                    upserts[pos] = u;
                } else {
                    upserts.push(u);
                }
            }
            PendingWindowOp::Patch {
                upserts,
                removed_ids,
            }
        }
        // Append + Patch or Patch + Append (including Remove + Append) coalesces to Reset.
        (Some(PendingWindowOp::Append(_)), PendingWindowOp::Patch { .. })
        | (Some(PendingWindowOp::Patch { .. }), PendingWindowOp::Append(_)) => {
            PendingWindowOp::Reset
        }
    }
}

/// One mute entry parsed from `/api/social/profile/getmute` during launch bootstrap.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct MuteEntry {
    pub conv_id: String,
    pub start: i64,
    pub duration: i64,
}

/// One friend row in [`ContactsState`] (partial U9 ownership).
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FriendEntry {
    pub id: String,
    pub name: String,
    pub zalo_name: String,
    pub avatar: Option<String>,
    /// Epoch milliseconds (`> 0`), or `None`.
    pub last_active_ms: Option<i64>,
    pub online: bool,
    pub section: String,
    pub sort_key: String,
}

impl fmt::Debug for FriendEntry {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("FriendEntry")
            .field("has_avatar", &self.avatar.is_some())
            .field("online", &self.online)
            .finish()
    }
}

/// One group row in [`ContactsState`] (partial U9 ownership).
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct GroupEntry {
    pub id: String,
    pub name: String,
    pub avatar: Option<String>,
    pub members: i64,
    pub sort_key: String,
}

impl fmt::Debug for GroupEntry {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("GroupEntry")
            .field("members", &self.members)
            .field("has_avatar", &self.avatar.is_some())
            .finish()
    }
}

/// One sent or received friend request row in [`ContactsState`].
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FriendRequestEntry {
    pub id: String,
    pub name: String,
    pub avatar: Option<String>,
    pub message: String,
    /// Epoch milliseconds (`> 0`), or `None`.
    pub time_ms: Option<i64>,
}

impl fmt::Debug for FriendRequestEntry {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("FriendRequestEntry")
            .field("has_time", &self.time_ms.is_some())
            .finish()
    }
}

/// Unified contacts & identity state owned by `olaz-core` and mirrored via `DirtyKey::Contacts`.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FoundUserEntry {
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

impl fmt::Debug for FoundUserEntry {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("FoundUserEntry")
            .field("is_friend", &self.is_friend)
            .field("is_self", &self.is_self)
            .field("requested", &self.requested)
            .field("requesting", &self.requesting)
            .finish()
    }
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ContactSearchStatus {
    #[default]
    Idle,
    Searching,
    Found,
    Error,
}

impl ContactSearchStatus {
    #[must_use]
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Idle => "idle",
            Self::Searching => "searching",
            Self::Found => "found",
            Self::Error => "error",
        }
    }

    #[must_use]
    pub fn parse(s: &str) -> Self {
        match s {
            "searching" => Self::Searching,
            "found" => Self::Found,
            "error" => Self::Error,
            _ => Self::Idle,
        }
    }
}

#[derive(Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ContactSearchState {
    pub status: ContactSearchStatus,
    pub error: Option<String>,
    pub user: Option<FoundUserEntry>,
}

impl fmt::Debug for ContactSearchState {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ContactSearchState")
            .field("status", &self.status)
            .field("has_error", &self.error.is_some())
            .field("has_user", &self.user.is_some())
            .finish()
    }
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ContactNotice {
    pub seq: i64,
    pub ok: bool,
    pub text: String,
}

impl fmt::Debug for ContactNotice {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ContactNotice")
            .field("seq", &self.seq)
            .field("ok", &self.ok)
            .finish()
    }
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BlockedUserState {
    pub id: String,
    pub name: String,
    pub avatar: Option<String>,
}

impl fmt::Debug for BlockedUserState {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("BlockedUserState")
            .field("has_avatar", &self.avatar.is_some())
            .finish()
    }
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SaveAliasOutcome {
    pub ok: bool,
    pub text: String,
}

impl fmt::Debug for SaveAliasOutcome {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("SaveAliasOutcome")
            .field("ok", &self.ok)
            .finish()
    }
}

#[derive(Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ContactsState {
    pub friends: Vec<FriendEntry>,
    pub groups: Vec<GroupEntry>,
    pub received: Vec<FriendRequestEntry>,
    pub sent: Vec<FriendRequestEntry>,
    pub friends_loaded: bool,
    pub groups_loaded: bool,
    pub pending_request_count: usize,
    pub loading_requests: bool,
    pub search: ContactSearchState,
    pub notice: Option<ContactNotice>,
    /// `None` before `loadBlockedUsers` / `setBlocked` runs; `Some(...)` once loaded or mutated.
    pub blocked_users: Option<Vec<BlockedUserState>>,
    /// Serialized JSON array string of raw received friend requests (`cachedReceivedRequestsRaw`).
    pub received_raw_json: Option<String>,
    /// Serialized JSON array string of raw sent friend requests (`cachedSentRequestsRaw`).
    pub sent_raw_json: Option<String>,
    /// UID -> globalId map discovered from friends list (`cachedFriendGlobalIds`).
    pub friend_global_ids: BTreeMap<String, String>,
    pub aliases: BTreeMap<String, String>,
    pub cached_profiles: BTreeMap<String, CachedProfile>,
    pub activity_ranks: BTreeMap<String, i64>,
    #[serde(skip)]
    pub search_gen: u64,
    #[serde(skip)]
    pub sync_in_flight: usize,
}

impl fmt::Debug for ContactsState {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ContactsState")
            .field("friends", &self.friends.len())
            .field("groups", &self.groups.len())
            .field("received", &self.received.len())
            .field("sent", &self.sent.len())
            .field("friends_loaded", &self.friends_loaded)
            .field("groups_loaded", &self.groups_loaded)
            .field("aliases", &self.aliases.len())
            .field("cached_profiles", &self.cached_profiles.len())
            .field("activity_ranks", &self.activity_ranks.len())
            .finish()
    }
}

impl ContactsState {
    pub fn reset(&mut self) {
        *self = Self::default();
    }

    /// Projects the [`IdentityTable`] view of this contacts state plus [`GroupsState`].
    #[must_use]
    pub fn to_identity_table(&self, groups: &GroupsState) -> IdentityTable {
        IdentityTable {
            friends: self
                .friends
                .iter()
                .map(|f| FriendIdentity {
                    id: f.id.clone(),
                    name: f.name.clone(),
                    avatar: f.avatar.clone(),
                })
                .collect(),
            groups: self
                .groups
                .iter()
                .map(|g| GroupIdentity {
                    id: g.id.clone(),
                    name: g.name.clone(),
                    avatar: g.avatar.clone(),
                    members: g.members,
                })
                .collect(),
            friends_loaded: self.friends_loaded,
            groups_loaded: self.groups_loaded,
            aliases: self.aliases.clone(),
            cached_profiles: self.cached_profiles.clone(),
            cached_groups: groups.cached_groups.clone(),
            friend_global_ids: self.friend_global_ids.clone(),
            activity_ranks: self.activity_ranks.clone(),
        }
    }

    /// Applies an [`IdentityTable`] pushed by Swift / tests onto this state while preserving
    /// contacts-specific fields (`received`, `sent`, `zalo_name`, `online`, `sort_key`, etc.)
    /// for matching friend/group ids.
    pub fn apply_identity_table(&mut self, table: IdentityTable, groups: &mut GroupsState) {
        let existing_friends: HashMap<String, FriendEntry> =
            self.friends.drain(..).map(|f| (f.id.clone(), f)).collect();
        self.friends = table
            .friends
            .into_iter()
            .map(|f| {
                if let Some(prev) = existing_friends.get(&f.id) {
                    let sort_key = if prev.name == f.name {
                        prev.sort_key.clone()
                    } else {
                        fold_contact_str(&f.name).trim().to_owned()
                    };
                    let section = if prev.name == f.name {
                        prev.section.clone()
                    } else {
                        sort_key
                            .chars()
                            .next()
                            .map(|c| c.to_ascii_uppercase())
                            .filter(char::is_ascii_uppercase)
                            .map_or_else(|| "#".to_owned(), |c| c.to_string())
                    };
                    FriendEntry {
                        id: f.id,
                        name: f.name,
                        zalo_name: prev.zalo_name.clone(),
                        avatar: f.avatar,
                        last_active_ms: prev.last_active_ms,
                        online: prev.online,
                        section,
                        sort_key,
                    }
                } else {
                    let sort_key = fold_contact_str(&f.name).trim().to_owned();
                    let section = sort_key
                        .chars()
                        .next()
                        .map(|c| c.to_ascii_uppercase())
                        .filter(char::is_ascii_uppercase)
                        .map_or_else(|| "#".to_owned(), |c| c.to_string());
                    FriendEntry {
                        id: f.id,
                        name: f.name.clone(),
                        zalo_name: f.name,
                        avatar: f.avatar,
                        last_active_ms: None,
                        online: false,
                        section,
                        sort_key,
                    }
                }
            })
            .collect();

        let existing_groups: HashMap<String, GroupEntry> =
            self.groups.drain(..).map(|g| (g.id.clone(), g)).collect();
        self.groups = table
            .groups
            .into_iter()
            .map(|g| {
                let sort_key = match existing_groups.get(&g.id) {
                    Some(prev) if prev.name == g.name => prev.sort_key.clone(),
                    _ => fold_contact_str(&g.name),
                };
                GroupEntry {
                    id: g.id,
                    name: g.name,
                    avatar: g.avatar,
                    members: g.members,
                    sort_key,
                }
            })
            .collect();

        self.friends_loaded = table.friends_loaded;
        self.groups_loaded = table.groups_loaded;
        self.aliases = table.aliases;
        self.cached_profiles = table.cached_profiles;
        groups.cached_groups = table.cached_groups;
        self.friend_global_ids = table.friend_global_ids;
        self.activity_ranks = table.activity_ranks;
    }

    /// Applies a seeded [`ContactsState`] (from `Command::SeedContacts`), preserving existing
    /// identity caches (`aliases`, `cached_profiles`, `cached_groups`, `activity_ranks`) when the
    /// incoming snapshot leaves them empty.
    pub fn apply_seeded_contacts(&mut self, mut next: ContactsState) {
        if next.aliases.is_empty() && !self.aliases.is_empty() {
            next.aliases = std::mem::take(&mut self.aliases);
        }
        if next.cached_profiles.is_empty() && !self.cached_profiles.is_empty() {
            next.cached_profiles = std::mem::take(&mut self.cached_profiles);
        }
        if next.activity_ranks.is_empty() && !self.activity_ranks.is_empty() {
            next.activity_ranks = std::mem::take(&mut self.activity_ranks);
        }
        if next.blocked_users.is_none() && self.blocked_users.is_some() {
            next.blocked_users = self.blocked_users.take();
        }
        next.search_gen = self.search_gen;
        next.sync_in_flight = self.sync_in_flight;
        *self = next;
    }
}

/// Lock-free / instant-clone identity snapshot exposed via `Mutex<Arc<IdentitySnapshot>>` on
/// `CoreHandle` so Swift's synchronous Frame 1 WAL decode (`withKnownSender`) never blocks `@MainActor`.
#[derive(Clone, Default)]
pub struct IdentitySnapshot {
    pub my_uid: String,
    pub my_avatar: Option<String>,
    pub identities: IdentityTable,
    /// Conversation fallback names/avatars (`conv.id -> (name, avatar)`).
    pub conversation_fallbacks: HashMap<String, (String, String)>,
    friends_by_id: HashMap<String, usize>,
    uid_by_global_id: HashMap<String, String>,
}

impl fmt::Debug for IdentitySnapshot {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("IdentitySnapshot")
            .field("friends", &self.identities.friends.len())
            .field("profiles", &self.identities.cached_profiles.len())
            .finish()
    }
}

impl IdentitySnapshot {
    #[must_use]
    pub fn build_conversation_fallbacks(
        conversations: &[crate::conversations::ConversationSummary],
    ) -> HashMap<String, (String, String)> {
        let mut conversation_fallbacks = HashMap::with_capacity(conversations.len());
        for c in conversations {
            let trimmed = c.name.trim();
            let valid_name = if !trimmed.is_empty() && trimmed != c.id && trimmed != UNKNOWN_NAME {
                trimmed.to_owned()
            } else {
                String::new()
            };
            let avt = c.avatar.clone().unwrap_or_default();
            if !valid_name.is_empty() || !avt.is_empty() {
                conversation_fallbacks.insert(c.id.clone(), (valid_name, avt));
            }
        }
        conversation_fallbacks
    }

    pub fn rebuild_identity_indexes(&mut self) {
        let mut friends_by_id = HashMap::with_capacity(self.identities.friends.len());
        for (idx, f) in self.identities.friends.iter().enumerate() {
            friends_by_id.entry(f.id.clone()).or_insert(idx);
        }
        let mut uid_by_global_id = HashMap::with_capacity(self.identities.friend_global_ids.len());
        for (u, g) in &self.identities.friend_global_ids {
            uid_by_global_id
                .entry(g.clone())
                .or_insert_with(|| u.clone());
        }
        self.friends_by_id = friends_by_id;
        self.uid_by_global_id = uid_by_global_id;
    }

    #[must_use]
    pub fn from_core(
        my_uid: &str,
        my_avatar: Option<&str>,
        convs: &ConversationsState,
        contacts: &ContactsState,
        groups: &GroupsState,
    ) -> Self {
        let mut snap = Self {
            my_uid: my_uid.to_owned(),
            my_avatar: my_avatar.map(str::to_owned),
            identities: contacts.to_identity_table(groups),
            conversation_fallbacks: Self::build_conversation_fallbacks(&convs.conversations),
            friends_by_id: HashMap::new(),
            uid_by_global_id: HashMap::new(),
        };
        snap.rebuild_identity_indexes();
        snap
    }

    /// Exact port of `ZaloEngine.lookupPersonInfo(_:)` (`conversations.rs:835`), using O(1) indexes.
    #[must_use]
    pub fn lookup_person(&self, raw_uid: &str) -> Option<NameLookup> {
        let clean = strip_user_prefix(raw_uid);
        if matches!(clean.as_str(), "" | "0" | "-1" | "__legacy__" | "unknown") {
            return None;
        }
        let mut candidates = vec![clean.clone()];
        let norm = normalize_contact_uid(&clean);
        if !norm.is_empty() && norm != clean {
            candidates.push(norm);
        }
        if let Some(sanitized) = sanitize_profile_uid(&clean)
            && !candidates.contains(&sanitized)
        {
            candidates.push(sanitized);
        }
        if let Some(mapped_uid) = candidates
            .iter()
            .find_map(|cand| self.uid_by_global_id.get(cand).cloned())
            && !candidates.contains(&mapped_uid)
        {
            candidates.push(mapped_uid);
        }

        let clean_my_uid = normalize_contact_uid(&self.my_uid);
        let sanitized_my_uid =
            sanitize_profile_uid(&clean_my_uid).unwrap_or_else(|| clean_my_uid.clone());
        if !clean_my_uid.is_empty()
            && candidates
                .iter()
                .any(|c| c == &clean_my_uid || c == &sanitized_my_uid)
        {
            return Some(NameLookup {
                name: "Bạn".to_owned(),
                avatar: self.my_avatar.clone().unwrap_or_default(),
            });
        }

        for candidate in &candidates {
            let alias = self.identities.aliases.get(candidate).map(String::as_str);
            if let Some(&idx) = self.friends_by_id.get(candidate)
                && let Some(f) = self.identities.friends.get(idx)
            {
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
                return Some(NameLookup { name, avatar: avt });
            }
            if let Some(p) = self.identities.cached_profiles.get(candidate) {
                let best = match alias {
                    Some(a) if !a.is_empty() => a,
                    _ => p.name.as_str(),
                };
                let valid_best = if best == UNKNOWN_NAME { "" } else { best };
                if !valid_best.is_empty() || !p.avatar.is_empty() {
                    return Some(NameLookup {
                        name: valid_best.to_owned(),
                        avatar: p.avatar.clone(),
                    });
                }
            }
            if let Some(a) = alias
                && !a.is_empty()
                && a != UNKNOWN_NAME
            {
                return Some(NameLookup {
                    name: a.to_owned(),
                    avatar: String::new(),
                });
            }
        }

        for candidate in &candidates {
            if let Some((name, avatar)) = self.conversation_fallbacks.get(candidate) {
                return Some(NameLookup {
                    name: name.clone(),
                    avatar: avatar.clone(),
                });
            }
        }
        None
    }

    /// Exact port of `ZaloEngine.mentionDisplayName(_:)` (`ZaloEngine+Contacts.swift:424`).
    #[must_use]
    pub fn mention_display_name(&self, raw_uid: &str) -> Option<String> {
        let clean = normalize_contact_uid(raw_uid);
        if clean.is_empty() || clean == "-1" {
            return None;
        }
        let clean_my = normalize_contact_uid(&self.my_uid);
        let sanitized_my = sanitize_profile_uid(&clean_my).unwrap_or_else(|| clean_my.clone());
        let sanitized_clean = sanitize_profile_uid(&clean).unwrap_or_else(|| clean.clone());
        if !clean_my.is_empty() && (clean == clean_my || sanitized_clean == sanitized_my) {
            return None;
        }
        let hit = self.lookup_person(&clean)?;
        let trimmed = hit.name.trim();
        if trimmed.is_empty() || trimmed == clean || trimmed == "Bạn" || trimmed == UNKNOWN_NAME {
            return None;
        }
        Some(trimmed.to_owned())
    }

    #[must_use]
    pub fn with_known_sender(&self, mut msg: ChatMessage) -> ChatMessage {
        if !msg.is_mine
            && !msg.sender_id.is_empty()
            && msg.sender_id != "0"
            && let Some(info) = self.lookup_person(&msg.sender_id)
        {
            if !info.name.is_empty() && info.name != msg.sender_id && info.name != UNKNOWN_NAME {
                msg.sender_name = info.name;
            }
            if msg.sender_avatar.is_none() && is_valid_url_str(&info.avatar) {
                msg.sender_avatar = Some(info.avatar);
            }
        }
        msg
    }
}

/// Checks whether a string would pass Swift's `URL(string:)` check (non-empty, no ASCII whitespace/control).
#[must_use]
pub fn is_valid_url_str(s: &str) -> bool {
    !s.is_empty() && !s.bytes().any(|b| b <= 0x20 || b == 0x7f)
}

/// Outcome of mutating a single conversation's message window.
#[derive(Clone, Debug, PartialEq)]
pub enum WindowChange {
    NoChange,
    Changed(PendingWindowOp),
}

/// Outcome of applying a remote recall to an in-memory message window.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RecallWindowOutcome {
    pub found_in_memory: bool,
    pub recalled_id: Option<String>,
    /// Set to `Some((date_ms, from_me))` when the recalled message was the newest in memory.
    pub recalled_last: Option<(i64, bool)>,
    pub window_changed: bool,
}

/// Outcome of applying a remote delete to an in-memory message window.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DeleteWindowOutcome {
    pub deleted_ts_ms: Option<i64>,
    pub mem_latest: Option<ConversationPreview>,
    pub window_changed: bool,
}

/// Outcome of Pass 1 message ingestion for a wire batch (`applyBatchResponse` / `applyParsedEvents`).
#[derive(Clone, Default)]
pub struct BatchPass1Outcome {
    pub stored_rows: Vec<DbStoredMessage>,
    pub e2ee_conv_ids: Vec<String>,
    pub incoming_for_notice: Vec<ChatMessage>,
    pub poll_messages: Vec<ChatMessage>,
    pub windows_changed: bool,
    pub conversations_changed: bool,
    pub flags_changed: bool,
    pub extras_changed: bool,
}

impl fmt::Debug for BatchPass1Outcome {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("BatchPass1Outcome")
            .field("stored_rows", &self.stored_rows.len())
            .field("e2ee_conv_ids", &self.e2ee_conv_ids.len())
            .field("incoming_for_notice", &self.incoming_for_notice.len())
            .field("windows_changed", &self.windows_changed)
            .field("conversations_changed", &self.conversations_changed)
            .finish()
    }
}

/// Outcome of Pass 1 message ingestion for `fetchAndMergeHistory` (`open` / `load_older`).
#[derive(Clone, Default)]
pub struct HistoryPagePass1Outcome {
    pub stored_rows: Vec<DbStoredMessage>,
    pub new_visible_count: usize,
    pub total_parsed_messages: usize,
    pub windows_changed: bool,
    pub meta_changed: bool,
}

impl fmt::Debug for HistoryPagePass1Outcome {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("HistoryPagePass1Outcome")
            .field("stored_rows", &self.stored_rows.len())
            .field("new_visible_count", &self.new_visible_count)
            .field("total_parsed_messages", &self.total_parsed_messages)
            .finish()
    }
}

/// Active state of an in-flight `openConversation` flow.
#[derive(Clone, Debug)]
pub struct OpenFlowState {
    pub open_seq: u64,
    pub conv_id: String,
    pub op_id: Option<u64>,
    pub fetched_count: usize,
}

/// Active state of an in-flight `loadOlderMessages` flow.
#[derive(Clone, Debug)]
pub struct LoadOlderFlowState {
    pub load_seq: u64,
    pub conv_id: String,
    pub op_id: Option<u64>,
}

/// Active state of an in-flight launch `bootstrap` flow.
#[derive(Clone, Debug)]
pub struct BootstrapFlowState {
    pub boot_gen: u64,
    pub now_ms: i64,
    pub op_id: Option<u64>,
    pub full_refresh: bool,
    pub lp_drain_done: bool,
    pub group_waves_done: bool,
    pub group_activity_rank: HashMap<String, i64>,
    pub ordered_groups: Vec<String>,
    pub preload_chunks: Vec<Vec<String>>,
    pub preload_chunk_idx: usize,
    pub group_wave_slices: Vec<Vec<String>>,
    pub group_wave_idx: usize,
    pub pam_done: bool,
    pub labels_done: bool,
    pub hidden_done: bool,
    pub contacts_done: bool,
}

/// Follow-up action once `SenderProfilesFetched` completes.
#[derive(Clone, Debug)]
pub enum SenderResolveFollowup {
    Open {
        open_seq: u64,
        conv_id: String,
        fetched_count: usize,
        op_id: Option<u64>,
    },
    LoadOlder {
        load_seq: u64,
        conv_id: String,
        op_id: Option<u64>,
    },
}

/// Unit 4 core-owned message windows, history cursors/ticks, freshness map, and active flows.
#[derive(Clone, Default)]
pub struct MessagesState {
    pub windows: HashMap<String, Vec<ChatMessage>>,
    pub has_more_history: HashMap<String, bool>,
    pub history_ticks: HashMap<String, u64>,
    pub history_freshness: HashMap<String, HistoryFreshness>,
    pub history_full_refresh_due: bool,
    pub bootstrap_logs: Vec<String>,
    pub open_seq: u64,
    pub load_older_seq: u64,
    pub boot_gen: u64,
    pub active_open: Option<OpenFlowState>,
    pub active_load_older: Option<LoadOlderFlowState>,
    pub active_bootstrap: Option<BootstrapFlowState>,
    pub pending_sender_resolves: HashMap<u64, SenderResolveFollowup>,
    /// Queued `(conv_id, PendingWindowOp)` mutations drained by the actor into `ChangeHub`.
    pub pending_window_ops: Vec<(String, PendingWindowOp)>,
}

impl fmt::Debug for MessagesState {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("MessagesState")
            .field("windows", &self.windows.len())
            .field("has_more_history", &self.has_more_history.len())
            .field("history_ticks", &self.history_ticks.len())
            .field("history_freshness", &self.history_freshness.len())
            .field("open_seq", &self.open_seq)
            .field("boot_gen", &self.boot_gen)
            .finish()
    }
}

impl MessagesState {
    pub fn reset(&mut self) {
        *self = Self::default();
    }

    /// Drains queued window operations for `ChangeHub` coalescing.
    pub fn take_pending_window_ops(&mut self) -> Vec<(String, PendingWindowOp)> {
        std::mem::take(&mut self.pending_window_ops)
    }

    /// Records a window operation for `conv_id` to be coalesced by `ChangeHub`.
    pub fn record_window_op(&mut self, conv_id: impl Into<String>, op: PendingWindowOp) {
        self.pending_window_ops.push((conv_id.into(), op));
    }

    /// Starts a launch history freshness pass (`ZaloEngine.beginHistoryFreshnessPass`).
    /// Clears `history_freshness` unconditionally and returns `full_refresh_due`.
    pub fn begin_freshness_pass(&mut self, last_refresh_pref: Option<&str>, now_ms: i64) -> bool {
        self.history_freshness.clear();
        let last = last_refresh_pref
            .and_then(|s| s.parse::<f64>().ok())
            .filter(|v| v.is_finite());
        #[expect(
            clippy::cast_precision_loss,
            reason = "Epoch ms fits comfortably in f64 precision matching Swift Date.timeIntervalSince1970"
        )]
        let now_secs = (now_ms as f64) / 1000.0;
        let due = last
            .is_none_or(|l| (now_secs - l) >= FULL_HISTORY_REFRESH_INTERVAL_SECS || l > now_secs);
        self.history_full_refresh_due = due;
        due
    }

    /// Records `(conv_id, exists_in_store)` probe outcomes (`ZaloEngine.probeHistoryFreshness`).
    /// Once a conversation is marked `Stale` in the current pass, it stays `Stale`.
    /// Returns `true` if `history_freshness` mutated.
    pub fn record_freshness_probes(&mut self, probes: &[(String, bool)]) -> bool {
        let mut changed = false;
        for (conv_id, exists_in_store) in probes {
            if self.history_freshness.get(conv_id) == Some(&HistoryFreshness::Stale) {
                continue;
            }
            let next = if *exists_in_store {
                HistoryFreshness::UpToDate
            } else {
                HistoryFreshness::Stale
            };
            if self.history_freshness.insert(conv_id.clone(), next) != Some(next) {
                changed = true;
            }
        }
        changed
    }

    /// Marks `conv_id` as `UpToDate` (e.g. after a `before_msg_id == None` history fetch).
    pub fn mark_history_up_to_date(&mut self, conv_id: &str) -> bool {
        self.history_freshness
            .insert(conv_id.to_owned(), HistoryFreshness::UpToDate)
            != Some(HistoryFreshness::UpToDate)
    }

    #[must_use]
    pub fn is_recent_history_up_to_date(&self, conv_id: &str) -> bool {
        self.history_freshness.get(conv_id) == Some(&HistoryFreshness::UpToDate)
    }

    #[must_use]
    pub fn up_to_date_count(&self) -> usize {
        self.history_freshness
            .values()
            .filter(|&&v| v == HistoryFreshness::UpToDate)
            .count()
    }

    /// Completes a full history refresh (`ZaloEngine.finishFullHistoryRefresh`).
    /// When `history_full_refresh_due` was true, clears it and returns `Some((pref_key, formatted_secs))`
    /// for `StoreOp::SetPreferenceString`.
    pub fn finish_full_history_refresh(&mut self, now_ms: i64) -> Option<(String, String)> {
        if !self.history_full_refresh_due {
            return None;
        }
        self.history_full_refresh_due = false;
        #[expect(
            clippy::cast_precision_loss,
            reason = "Epoch ms fits comfortably in f64 precision matching Swift Date.timeIntervalSince1970"
        )]
        let now_secs = (now_ms as f64) / 1000.0;
        Some((
            FULL_HISTORY_REFRESH_PREF_KEY.to_owned(),
            format_swift_double(now_secs),
        ))
    }

    /// Computes the `SeenTarget` from the window's final message (`ZaloEngine+Chat.swift:728`).
    #[must_use]
    pub fn seen_target_for(&self, conv_id: &str) -> Option<SeenTarget> {
        let list = self.windows.get(conv_id)?;
        let last = list.last().filter(|m| !m.is_mine)?;
        Some(SeenTarget {
            conv_id: conv_id.to_owned(),
            msg_id: last.id.clone(),
            cli_msg_id: last.id.clone(),
            sender_id: last.sender_id.clone(),
        })
    }

    #[must_use]
    pub fn last_message_id(&self, conv_id: &str) -> String {
        self.windows
            .get(conv_id)
            .and_then(|list| list.last())
            .map(|m| m.id.clone())
            .unwrap_or_default()
    }

    /// Removes `conv_id`'s window and paging cursor (called on conversation delete).
    pub fn remove_conversation_window(&mut self, conv_id: &str) -> (bool, bool) {
        let win_removed = self.windows.remove(conv_id).is_some();
        if win_removed {
            self.record_window_op(conv_id.to_owned(), PendingWindowOp::Remove);
        }
        let meta_removed = self.has_more_history.remove(conv_id).is_some();
        (win_removed, meta_removed)
    }

    /// Ensures `windows[conv_id]` exists (inserting `[]` if absent).
    pub fn ensure_window_exists(&mut self, conv_id: &str) -> WindowChange {
        if self.windows.contains_key(conv_id) {
            WindowChange::NoChange
        } else {
            self.windows.insert(conv_id.to_owned(), Vec::new());
            self.record_window_op(conv_id.to_owned(), PendingWindowOp::Reset);
            WindowChange::Changed(PendingWindowOp::Reset)
        }
    }

    /// Exact port of `ZaloEngine.mergeMessageIntoMemory(_:replacingClientId:)`.
    pub fn merge_message(
        &mut self,
        raw_msg: ChatMessage,
        replacing_client_id: Option<&str>,
        snap: &IdentitySnapshot,
    ) -> WindowChange {
        let mut msg = snap.with_known_sender(raw_msg);
        let conv_id = msg.conversation_id.clone();
        let had_window = self.windows.contains_key(&conv_id);
        let mut list = self.windows.remove(&conv_id).unwrap_or_default();
        let original_count = list.len();

        let incoming_is_locked_placeholder =
            matches!(msg.kind, Kind::Placeholder { .. }) && msg.is_e2ee;
        let resolved_client_id: Option<String> = replacing_client_id
            .filter(|s| !s.is_empty())
            .map(str::to_owned)
            .or_else(|| (!msg.client_id.is_empty()).then(|| msg.client_id.clone()));

        let mut preserved_reactions = Vec::new();
        if let Some(existing_by_id) = list.iter().find(|m| m.id == msg.id) {
            if !existing_by_id.reactions.is_empty() {
                preserved_reactions = existing_by_id.reactions.clone();
            }
            if msg.client_id.is_empty() && !existing_by_id.client_id.is_empty() {
                msg.client_id = existing_by_id.client_id.clone();
            }
        } else if let Some(cid) = resolved_client_id.as_deref()
            && let Some(existing_by_cli) = list.iter().find(|m| m.id == cid || m.client_id == cid)
        {
            if !existing_by_cli.reactions.is_empty() {
                preserved_reactions = existing_by_cli.reactions.clone();
            }
            if msg.client_id.is_empty() {
                msg.client_id = if existing_by_cli.client_id.is_empty() {
                    cid.to_owned()
                } else {
                    existing_by_cli.client_id.clone()
                };
            }
        }

        if msg.reactions.is_empty() && !preserved_reactions.is_empty() && msg.kind != Kind::Recalled
        {
            msg.reactions = preserved_reactions;
        }

        let mut removed_ids = Vec::new();
        if let Some(cid) = replacing_client_id
            && !cid.is_empty()
            && cid != msg.id
        {
            if incoming_is_locked_placeholder {
                if let Some(idx) = list.iter().position(|existing| {
                    existing.id == cid
                        && !(matches!(existing.kind, Kind::Placeholder { .. }) && existing.is_e2ee)
                }) {
                    list[idx].id = msg.id;
                    if list[idx].client_id.is_empty() {
                        list[idx].client_id = cid.to_owned();
                    }
                    let updated = list[idx].clone();
                    self.windows.insert(conv_id.clone(), list);
                    let op = PendingWindowOp::Patch {
                        upserts: vec![updated],
                        removed_ids: vec![cid.to_owned()],
                    };
                    self.record_window_op(conv_id, op.clone());
                    return WindowChange::Changed(op);
                }
                if list.iter().any(|existing| {
                    existing.client_id == cid
                        && existing.id != cid
                        && !(matches!(existing.kind, Kind::Placeholder { .. }) && existing.is_e2ee)
                }) {
                    if had_window {
                        self.windows.insert(conv_id, list);
                    }
                    return WindowChange::NoChange;
                }
            } else {
                let before = list.len();
                list.retain(|m| m.id != cid);
                if list.len() != before {
                    removed_ids.push(cid.to_owned());
                }
            }
        }

        let op = if let Some(idx) = list.iter().position(|m| m.id == msg.id) {
            let untouched = list.len() == original_count && removed_ids.is_empty();
            if untouched && list[idx] == msg {
                if had_window {
                    self.windows.insert(conv_id, list);
                }
                return WindowChange::NoChange;
            }
            if incoming_is_locked_placeholder {
                if matches!(list[idx].kind, Kind::Placeholder { .. }) && list[idx].is_e2ee {
                    list[idx] = msg.clone();
                } else if untouched {
                    if had_window {
                        self.windows.insert(conv_id, list);
                    }
                    return WindowChange::NoChange;
                }
            } else {
                list[idx] = msg.clone();
            }
            let order_ok = (idx == 0 || cmp_msg_stable(&list[idx - 1], &list[idx]).is_le())
                && (idx + 1 >= list.len() || cmp_msg_stable(&list[idx], &list[idx + 1]).is_le());
            if !order_ok {
                list.sort_by(cmp_msg_page);
                PendingWindowOp::Reset
            } else {
                PendingWindowOp::Patch {
                    upserts: vec![list[idx].clone()],
                    removed_ids,
                }
            }
        } else if let Some(last) = list.last()
            && (last.date_ms < msg.date_ms || (last.date_ms == msg.date_ms && last.id < msg.id))
        {
            list.push(msg.clone());
            if !had_window {
                PendingWindowOp::Reset
            } else if removed_ids.is_empty() {
                PendingWindowOp::Append(vec![msg])
            } else {
                PendingWindowOp::Patch {
                    upserts: vec![msg],
                    removed_ids,
                }
            }
        } else if list.is_empty() && removed_ids.is_empty() && had_window {
            list.push(msg.clone());
            PendingWindowOp::Append(vec![msg])
        } else {
            list.push(msg);
            list.sort_by(cmp_msg_page);
            PendingWindowOp::Reset
        };

        self.windows.insert(conv_id.clone(), list);
        self.record_window_op(conv_id, op.clone());
        WindowChange::Changed(op)
    }

    /// Bulk-merges a page of `(ChatMessage, Option<clientId>)` rows into `conv_id`'s window
    /// (exact port of `ZaloEngine.mergeMessagesIntoMemory(_:in:)`).
    pub fn merge_messages_page(
        &mut self,
        conv_id: &str,
        rows: Vec<(ChatMessage, Option<String>)>,
        snap: &IdentitySnapshot,
    ) -> Vec<(String, PendingWindowOp)> {
        let mut known = HashSet::new();
        if let Some(existing) = self.windows.get(conv_id) {
            for m in existing {
                known.insert(m.id.clone());
                if !m.client_id.is_empty() {
                    known.insert(m.client_id.clone());
                }
            }
        }
        let mut fresh = Vec::with_capacity(rows.len());
        let mut colliding = Vec::new();
        for (m, cid) in rows {
            let mut keys = Vec::with_capacity(3);
            if !m.id.is_empty() {
                keys.push(m.id.clone());
            }
            if !m.client_id.is_empty() {
                keys.push(m.client_id.clone());
            }
            if let Some(c) = &cid
                && !c.is_empty()
            {
                keys.push(c.clone());
            }
            if m.conversation_id != conv_id || keys.iter().any(|k| known.contains(k)) {
                colliding.push((m, cid));
                continue;
            }
            for k in keys {
                known.insert(k);
            }
            fresh.push(snap.with_known_sender(m));
        }

        let mut ops: Vec<(String, PendingWindowOp)> = Vec::new();
        if !fresh.is_empty() {
            let list = self.windows.entry(conv_id.to_owned()).or_default();
            list.extend(fresh);
            list.sort_by(cmp_msg_page);
            self.record_window_op(conv_id.to_owned(), PendingWindowOp::Reset);
            ops.push((conv_id.to_owned(), PendingWindowOp::Reset));
        }
        for (m, cid) in colliding {
            let target_conv = m.conversation_id.clone();
            if let WindowChange::Changed(op) = self.merge_message(m, cid.as_deref(), snap) {
                ops.push((target_conv, op));
            }
        }
        ops
    }

    /// Applies Pass 1 of `fetchAndMergeHistory` (`open` / `load_older`) into `conv_id`'s window,
    /// updating `history_freshness` (when `before_msg_id.is_none()`) and `has_more_history`.
    pub fn apply_history_page_pass1(
        &mut self,
        conv_id: &str,
        events: &[ParsedWireEvent],
        before_msg_id: Option<&str>,
        count: usize,
        self_conv_id: Option<&str>,
        snap: &IdentitySnapshot,
    ) -> HistoryPagePass1Outcome {
        let mut meta_changed = false;
        if before_msg_id.is_none() && self.mark_history_up_to_date(conv_id) {
            meta_changed = true;
        }

        let mut stored_rows = Vec::new();
        let mut new_visible_count = 0usize;
        let mut total_parsed_messages = 0usize;
        let mut windows_changed = false;

        for ev in events {
            if let ParsedWireEvent::Message(msg, stored) = ev {
                if msg.conversation_id == conv_id {
                    total_parsed_messages += 1;
                    let exists = self
                        .windows
                        .get(&msg.conversation_id)
                        .is_some_and(|l| l.iter().any(|m| m.id == msg.id));
                    if !exists {
                        new_visible_count += 1;
                    }
                }
                stored_rows.push(to_db_stored(stored));
                if matches!(
                    self.merge_message((**msg).clone(), Some(&stored.client_id), snap),
                    WindowChange::Changed(_)
                ) {
                    windows_changed = true;
                }
            }
        }
        if matches!(self.ensure_window_exists(conv_id), WindowChange::Changed(_)) {
            windows_changed = true;
        }

        let is_grp = is_group_id(conv_id);
        let is_self_cloud = Some(conv_id) == self_conv_id;
        let window_len = self.windows.get(conv_id).map_or(0, Vec::len);
        if is_grp || is_self_cloud {
            if total_parsed_threshold(total_parsed_messages, count) {
                if self.has_more_history.insert(conv_id.to_owned(), true) != Some(true) {
                    meta_changed = true;
                }
            } else if window_len < 45
                && self.has_more_history.insert(conv_id.to_owned(), false) != Some(false)
            {
                meta_changed = true;
            }
        } else if window_len < 45
            && self.has_more_history.insert(conv_id.to_owned(), false) != Some(false)
        {
            meta_changed = true;
        }

        HistoryPagePass1Outcome {
            stored_rows,
            new_visible_count,
            total_parsed_messages,
            windows_changed,
            meta_changed,
        }
    }

    /// Mutates the in-memory window for a remote recall (`ZaloEngine.applyRemoteRecall`).
    pub fn apply_recall_in_window(
        &mut self,
        conv_id: &str,
        msg_id: &str,
        cli_msg_id: &str,
    ) -> RecallWindowOutcome {
        let Some(list) = self.windows.get_mut(conv_id) else {
            return RecallWindowOutcome {
                found_in_memory: false,
                recalled_id: None,
                recalled_last: None,
                window_changed: false,
            };
        };
        let Some(idx) = list.iter().position(|m| {
            (!msg_id.is_empty() && (m.id == msg_id || m.client_id == msg_id))
                || (!cli_msg_id.is_empty() && (m.client_id == cli_msg_id || m.id == cli_msg_id))
        }) else {
            return RecallWindowOutcome {
                found_in_memory: false,
                recalled_id: None,
                recalled_last: None,
                window_changed: false,
            };
        };

        let recalled_id = list[idx].id.clone();
        let was_last = idx + 1 == list.len();
        let msg_date_ms = list[idx].date_ms;
        let msg_from_me = list[idx].is_mine;

        list[idx].kind = Kind::Recalled;
        list[idx].text.clear();
        list[idx].reactions.clear();
        list[idx].quote = None;
        list[idx].card_buttons.clear();
        list[idx].menu.recall = false;
        list[idx].menu.forward = olaz_wire::Availability::Hidden;
        list[idx].menu.pin = false;
        list[idx].menu.star = None;
        list[idx].menu.starred = false;

        let updated = list[idx].clone();
        self.record_window_op(
            conv_id.to_owned(),
            PendingWindowOp::Patch {
                upserts: vec![updated],
                removed_ids: Vec::new(),
            },
        );

        RecallWindowOutcome {
            found_in_memory: true,
            recalled_id: Some(recalled_id),
            recalled_last: was_last.then_some((msg_date_ms, msg_from_me)),
            window_changed: true,
        }
    }

    /// Mutates the in-memory window for a remote delete (`ZaloEngine.applyRemoteDelete`).
    pub fn apply_delete_in_window(
        &mut self,
        conv_id: &str,
        msg_id: &str,
        cli_msg_id: &str,
    ) -> DeleteWindowOutcome {
        let target_id = if !msg_id.is_empty() {
            msg_id
        } else {
            cli_msg_id
        };
        let Some(list) = self.windows.get_mut(conv_id) else {
            return DeleteWindowOutcome {
                deleted_ts_ms: None,
                mem_latest: None,
                window_changed: false,
            };
        };
        let mut deleted_ts_ms: Option<i64> = None;
        let mut removed_ids = Vec::new();
        list.retain(|m| {
            let matches_target = m.id == target_id
                || m.client_id == target_id
                || (!cli_msg_id.is_empty() && (m.id == cli_msg_id || m.client_id == cli_msg_id));
            if matches_target {
                deleted_ts_ms = Some(deleted_ts_ms.map_or(m.date_ms, |prev| prev.max(m.date_ms)));
                removed_ids.push(m.id.clone());
            }
            !matches_target
        });
        let mem_latest = list.last().map(|last| ConversationPreview {
            text: message_preview_label(last),
            date_ms: Some(last.date_ms),
            from_me: last.is_mine,
        });
        let window_changed = !removed_ids.is_empty();
        if window_changed {
            self.record_window_op(
                conv_id.to_owned(),
                PendingWindowOp::Patch {
                    upserts: Vec::new(),
                    removed_ids,
                },
            );
        }
        DeleteWindowOutcome {
            deleted_ts_ms,
            mem_latest,
            window_changed,
        }
    }

    /// Idempotent write-through upsert for unported Swift writers (U5/U6/U8/U14).
    pub fn write_through_upsert(
        &mut self,
        msg: ChatMessage,
        replacing_client_id: Option<&str>,
        snap: &IdentitySnapshot,
    ) -> WindowChange {
        self.merge_message(msg, replacing_client_id, snap)
    }

    /// Idempotent write-through removal of message IDs from `conv_id`'s window.
    pub fn write_through_remove(&mut self, conv_id: &str, ids: &[String]) -> WindowChange {
        if ids.is_empty() {
            return WindowChange::NoChange;
        }
        let Some(list) = self.windows.get_mut(conv_id) else {
            return WindowChange::NoChange;
        };
        let mut removed_ids = Vec::new();
        list.retain(|m| {
            let drop_it = ids.iter().any(|id| !id.is_empty() && m.id == *id);
            if drop_it {
                removed_ids.push(m.id.clone());
            }
            !drop_it
        });
        if removed_ids.is_empty() {
            WindowChange::NoChange
        } else {
            let op = PendingWindowOp::Patch {
                upserts: Vec::new(),
                removed_ids,
            };
            self.record_window_op(conv_id.to_owned(), op.clone());
            WindowChange::Changed(op)
        }
    }

    /// Replaces the entire window of `conv_id` (used for jump-to-message `messagesAround` / clear).
    pub fn write_through_replace_window(
        &mut self,
        conv_id: &str,
        mut list: Vec<ChatMessage>,
        _snap: &IdentitySnapshot,
    ) -> WindowChange {
        list.sort_by(cmp_msg_page);
        if self.windows.get(conv_id) == Some(&list) {
            return WindowChange::NoChange;
        }
        self.windows.insert(conv_id.to_owned(), list);
        self.record_window_op(conv_id.to_owned(), PendingWindowOp::Reset);
        WindowChange::Changed(PendingWindowOp::Reset)
    }

    /// Updates sender names/avatars in `conv_id`'s window after `fetch_profiles`, returning
    /// `(changed_stored_rows, window_changed)` (`ZaloEngine.resolveMissingSenderProfiles` tail).
    pub fn apply_resolved_sender_profiles(
        &mut self,
        conv_id: &str,
        snap: &IdentitySnapshot,
    ) -> (Vec<DbStoredMessage>, bool) {
        let Some(list) = self.windows.get_mut(conv_id) else {
            return (Vec::new(), false);
        };
        let mut to_persist = Vec::new();
        let mut upserts = Vec::new();
        for msg in list.iter_mut() {
            if msg.is_mine {
                continue;
            }
            let clean = strip_user_prefix(&msg.sender_id);
            let Some(info) = snap.lookup_person(&clean) else {
                continue;
            };
            let mut row_changed = false;
            if !info.name.is_empty()
                && info.name != clean
                && info.name != UNKNOWN_NAME
                && msg.sender_name != info.name
            {
                msg.sender_name = info.name;
                row_changed = true;
            }
            if msg.sender_avatar.is_none() && is_valid_url_str(&info.avatar) {
                msg.sender_avatar = Some(info.avatar);
                row_changed = true;
            }
            if row_changed {
                upserts.push(msg.clone());
                if let Some(stored) = encode_chat_message(msg, &msg.client_id) {
                    to_persist.push(to_db_stored(&stored));
                }
            }
        }
        let changed = !upserts.is_empty();
        if changed {
            self.record_window_op(
                conv_id.to_owned(),
                PendingWindowOp::Patch {
                    upserts,
                    removed_ids: Vec::new(),
                },
            );
        }
        (to_persist, changed)
    }

    /// Refreshes reaction display names in `target_conv_id` (or all windows when `None`) from `snap`,
    /// returning `(changed_stored_rows, window_patch_ops)`.
    pub fn refresh_reaction_names(
        &mut self,
        target_conv_id: Option<&str>,
        snap: &IdentitySnapshot,
    ) -> (Vec<DbStoredMessage>, Vec<(String, PendingWindowOp)>) {
        let stripped_my = strip_user_prefix(&snap.my_uid);
        let my_uid = sanitize_profile_uid(&stripped_my).unwrap_or(stripped_my);
        let conv_keys: Vec<String> = match target_conv_id {
            Some(c) => vec![c.to_owned()],
            None => self.windows.keys().cloned().collect(),
        };
        let mut changed_rows = Vec::new();
        let mut ops = Vec::new();

        for conv_id in conv_keys {
            let Some(list) = self.windows.get_mut(&conv_id) else {
                continue;
            };
            let mut upserts = Vec::new();
            for msg in list.iter_mut() {
                if msg.reactions.is_empty() {
                    continue;
                }
                let mut reactions_changed = false;
                for r in &mut msg.reactions {
                    let mut ordered_uids: Vec<String> = r
                        .user_counts
                        .iter()
                        .filter(|(k, v)| {
                            !k.is_empty()
                                && k.as_str() != "__legacy__"
                                && k.as_str() != "unknown"
                                && k.as_str() != "-1"
                                && **v > 0
                        })
                        .map(|(k, _)| k.clone())
                        .collect();
                    ordered_uids.sort();
                    if r.includes_me && !my_uid.is_empty() {
                        ordered_uids.retain(|u| u != &my_uid && u != "0" && u != "me");
                        ordered_uids.insert(0, my_uid.clone());
                    }
                    if ordered_uids.is_empty() {
                        continue;
                    }
                    let mut refreshed = Vec::new();
                    for uid in ordered_uids {
                        if refreshed.len() >= 3 {
                            break;
                        }
                        if uid == my_uid || uid == "0" || uid == "me" {
                            refreshed.push("Bạn".to_owned());
                        } else if let Some(info) = snap.lookup_person(&uid) {
                            let name = info.name.trim();
                            if !name.is_empty() && name != UNKNOWN_NAME && name != uid {
                                refreshed.push(name.to_owned());
                            }
                        }
                    }
                    if refreshed != r.names {
                        r.names = refreshed;
                        reactions_changed = true;
                    }
                }
                if reactions_changed {
                    upserts.push(msg.clone());
                    if let Some(stored) = encode_chat_message(msg, &msg.client_id) {
                        changed_rows.push(to_db_stored(&stored));
                    }
                }
            }
            if !upserts.is_empty() {
                let op = PendingWindowOp::Patch {
                    upserts,
                    removed_ids: Vec::new(),
                };
                self.pending_window_ops.push((conv_id.clone(), op.clone()));
                ops.push((conv_id, op));
            }
        }
        (changed_rows, ops)
    }

    /// Serializes U4 + bootstrap state fields into Case format v1 JSON (`MessageSnapshot.swift`).
    #[must_use]
    pub fn to_case_json_fields(&self, store: Option<&olaz_store::Store>) -> Map<String, Value> {
        let mut out = Map::new();

        let mut msgs_obj = Map::new();
        let mut sorted_convs: Vec<&String> = self.windows.keys().collect();
        sorted_convs.sort();
        for conv_id in sorted_convs {
            if let Some(list) = self.windows.get(conv_id) {
                let items: Vec<Value> = list
                    .iter()
                    .map(|m| {
                        let reactions_json: Vec<Value> = m
                            .reactions
                            .iter()
                            .map(|r| {
                                let icon = if !r.icon.emoji.is_empty() {
                                    &r.icon.emoji
                                } else if !r.icon.key.is_empty() {
                                    &r.icon.key
                                } else {
                                    &r.icon.r#type
                                };
                                json!({
                                    "icon": icon,
                                    "count": r.count,
                                    "includes_me": r.includes_me,
                                })
                            })
                            .collect();
                        let (_, kind_tag) = olaz_wire::serialize_kind(&m.kind);
                        json!({
                            "id": m.id,
                            "client_id": m.client_id,
                            "conv_id": m.conversation_id,
                            "sender_id": m.sender_id,
                            "sender_name": m.sender_name,
                            "sender_avatar": m.sender_avatar,
                            "date_ms": m.date_ms,
                            "is_mine": m.is_mine,
                            "kind_tag": kind_tag,
                            "text": m.text,
                            "is_e2ee": m.is_e2ee,
                            "reactions": reactions_json,
                        })
                    })
                    .collect();
                msgs_obj.insert(conv_id.clone(), Value::Array(items));
            }
        }
        out.insert("messages".to_owned(), Value::Object(msgs_obj));

        let mut has_more_obj = Map::new();
        for (k, v) in &self.has_more_history {
            has_more_obj.insert(k.clone(), Value::Bool(*v));
        }
        out.insert("has_more_history".to_owned(), Value::Object(has_more_obj));

        let mut ticks_obj = Map::new();
        for (k, v) in &self.history_ticks {
            ticks_obj.insert(k.clone(), Value::from(*v));
        }
        out.insert("history_ticks".to_owned(), Value::Object(ticks_obj));

        let mut fresh_obj = Map::new();
        for (k, v) in &self.history_freshness {
            fresh_obj.insert(k.clone(), Value::String(v.as_str().to_owned()));
        }
        out.insert("history_freshness".to_owned(), Value::Object(fresh_obj));

        out.insert(
            "bootstrap_logs".to_owned(),
            Value::Array(
                self.bootstrap_logs
                    .iter()
                    .map(|s| Value::String(s.clone()))
                    .collect(),
            ),
        );

        if let Some(st) = store {
            let mut stored_msgs = load_all_stored_messages_sorted(st);
            stored_msgs.sort_by(|a, b| {
                a.conv_id
                    .cmp(&b.conv_id)
                    .then_with(|| a.ts_ms.cmp(&b.ts_ms))
                    .then_with(|| a.id.cmp(&b.id))
            });
            let msg_rows_json: Vec<Value> = stored_msgs
                .into_iter()
                .map(|row| {
                    json!({
                        "id": row.id,
                        "conv_id": row.conv_id,
                        "client_id": row.client_id,
                        "sender_id": row.sender_id,
                        "sender_name": row.sender_name,
                        "sender_avatar": row.sender_avatar,
                        "is_mine": row.is_mine,
                        "text": row.text,
                        "kind_tag": row.kind_tag,
                        "ts_ms": row.ts_ms,
                        "status": row.status,
                    })
                })
                .collect();
            out.insert("__store_messages".to_owned(), Value::Array(msg_rows_json));

            let full_refresh_at = st
                .get_preference_string(FULL_HISTORY_REFRESH_PREF_KEY)
                .ok()
                .flatten()
                .filter(|s| !s.is_empty())
                .map_or(Value::Null, Value::String);
            let ranks_val = st
                .get_preference_data("activityRanks")
                .ok()
                .flatten()
                .and_then(|d| olaz_wire::lossless::parse_any(&d))
                .unwrap_or_else(|| json!({}));
            let aliases_val = st
                .get_preference_data("aliases")
                .ok()
                .flatten()
                .and_then(|d| olaz_wire::lossless::parse_any(&d))
                .unwrap_or_else(|| json!({}));
            out.insert(
                "__store_u4_prefs".to_owned(),
                json!({
                    "history_full_refresh_at": full_refresh_at,
                    "activity_ranks": ranks_val,
                    "aliases": aliases_val,
                }),
            );
        }

        out
    }
}

fn total_parsed_threshold(total_parsed_messages: usize, count: usize) -> bool {
    total_parsed_messages >= (count / 2).max(10)
}

fn cmp_msg_stable(a: &ChatMessage, b: &ChatMessage) -> std::cmp::Ordering {
    a.date_ms.cmp(&b.date_ms)
}

fn cmp_msg_page(a: &ChatMessage, b: &ChatMessage) -> std::cmp::Ordering {
    a.date_ms.cmp(&b.date_ms).then_with(|| a.id.cmp(&b.id))
}

fn load_all_stored_messages_sorted(store: &olaz_store::Store) -> Vec<DbStoredMessage> {
    store.load_all_messages().unwrap_or_default()
}

/// Parses a wire JSON batch or history page into `[ParsedWireEvent]` using `snap` for sender name lookup.
#[must_use]
pub fn parse_batch_events(
    root: &Value,
    my_uid: &str,
    self_conv_id: Option<&str>,
    default_cmd: u16,
    fallback_conv_id: Option<&str>,
    is_group_hint: Option<bool>,
    snap: &IdentitySnapshot,
) -> Vec<ParsedWireEvent> {
    let lookup_fn = |uid: &str| snap.lookup_person(uid);
    let opts = WireParseOptions {
        cmd: default_cmd,
        fallback_conv_id,
        is_group_hint,
        self_conv_id,
        name_lookup: Some(&lookup_fn),
    };
    extract_batch_events(root, my_uid, &opts)
}

/// Applies Pass 1 of `applyBatchResponse` / `applyParsedEvents` across `MessagesState` and
/// `ConversationsState` (used by bootstrap preload/self/group history, LP drain, and WS pushes).
#[expect(
    clippy::too_many_arguments,
    reason = "pure batch projection over explicit core state slices"
)]
pub fn apply_batch_pass1(
    messages: &mut MessagesState,
    conversations: &mut ConversationsState,
    contacts: &ContactsState,
    groups: &GroupsState,
    events: &[ParsedWireEvent],
    increment_unread: bool,
    self_conv_id: Option<&str>,
    snap: &IdentitySnapshot,
) -> BatchPass1Outcome {
    if events.is_empty() {
        return BatchPass1Outcome::default();
    }

    let mut stored_rows = Vec::new();
    let mut e2ee_conv_ids = Vec::new();
    let mut e2ee_seen = HashSet::new();
    let mut unread_delta_by_conv: HashMap<String, i64> = HashMap::new();
    let mut latest_by_conv: HashMap<String, ChatMessage> = HashMap::new();
    let mut incoming_for_notice = Vec::new();
    let mut windows_changed = false;

    for ev in events {
        if let ParsedWireEvent::Message(msg, stored) = ev {
            if msg.is_e2ee
                && !is_group_id(&msg.conversation_id)
                && Some(msg.conversation_id.as_str()) != self_conv_id
                && e2ee_seen.insert(msg.conversation_id.clone())
            {
                e2ee_conv_ids.push(msg.conversation_id.clone());
            }
            let is_locked_e2ee = stored.status == "e2ee_locked";
            if is_locked_e2ee
                && let Some(mem_list) = messages.windows.get(&msg.conversation_id)
                && let Some(readable) = mem_list.iter().find(|existing| {
                    (existing.id == msg.id
                        || (!stored.client_id.is_empty() && existing.id == stored.client_id))
                        && !(matches!(existing.kind, Kind::Placeholder { .. }) && existing.is_e2ee)
                })
            {
                let readable_id = readable.id.clone();
                if readable_id != msg.id && !msg.id.is_empty() && readable_id == stored.client_id {
                    if matches!(
                        messages.merge_message((**msg).clone(), Some(&stored.client_id), snap),
                        WindowChange::Changed(_)
                    ) {
                        windows_changed = true;
                    }
                    stored_rows.push(to_db_stored(stored));
                }
                continue;
            }

            let already_known = messages
                .windows
                .get(&msg.conversation_id)
                .is_some_and(|l| l.iter().any(|m| m.id == msg.id));
            stored_rows.push(to_db_stored(stored));
            if matches!(
                messages.merge_message((**msg).clone(), Some(&stored.client_id), snap),
                WindowChange::Changed(_)
            ) {
                windows_changed = true;
            }
            if latest_by_conv
                .get(&msg.conversation_id)
                .is_none_or(|prev| msg.date_ms >= prev.date_ms)
            {
                latest_by_conv.insert(msg.conversation_id.clone(), (**msg).clone());
            }
            if increment_unread
                && !already_known
                && !msg.is_mine
                && conversations.open_conversation_id.as_deref()
                    != Some(msg.conversation_id.as_str())
            {
                *unread_delta_by_conv
                    .entry(msg.conversation_id.clone())
                    .or_insert(0) += 1;
                incoming_for_notice.push((**msg).clone());
            }
        }
    }

    let mut poll_messages = Vec::with_capacity(latest_by_conv.len());
    let mut by_id: HashMap<String, ConversationSummary> = conversations
        .conversations
        .iter()
        .cloned()
        .map(|c| (c.id.clone(), c))
        .collect();

    for (conv_id, latest) in latest_by_conv {
        poll_messages.push(latest.clone());
        let is_grp = is_group_id(&conv_id);
        let info =
            conversations.lookup_conversation_identity(contacts, groups, &conv_id, self_conv_id);
        let prev = ConversationPreview {
            text: message_preview_label(&latest),
            date_ms: Some(latest.date_ms),
            from_me: latest.is_mine,
        };
        let existing = by_id.get(&conv_id);
        let best_name = if !info.0.is_empty() {
            info.0
        } else if !latest.is_mine && !is_grp {
            latest.sender_name.clone()
        } else {
            existing.map_or_else(|| conv_id.clone(), |e| e.name.clone())
        };
        let effective_prev = match existing.and_then(|e| e.preview.as_ref()) {
            Some(ep) if ep.date_ms.unwrap_or(i64::MIN) > latest.date_ms => ep.clone(),
            _ => prev,
        };
        let avatar = info
            .1
            .or_else(|| existing.and_then(|e| e.avatar.clone()))
            .or_else(|| {
                (!is_grp && !latest.is_mine)
                    .then(|| latest.sender_avatar.clone())
                    .flatten()
            });
        let members = if info.2 > 0 {
            info.2
        } else {
            existing.map_or(0, |e| e.members)
        };
        let unread = existing.map_or(0, |e| e.unread)
            + unread_delta_by_conv.get(&conv_id).copied().unwrap_or(0);
        by_id.insert(
            conv_id.clone(),
            ConversationSummary {
                id: conv_id.clone(),
                is_group: is_grp,
                name: if best_name.is_empty() {
                    conv_id
                } else {
                    best_name
                },
                avatar,
                pinned: conversations.pinned_ids.contains(&latest.conversation_id),
                members,
                unread,
                preview: Some(effective_prev),
            },
        );
    }

    let mut list: Vec<ConversationSummary> = by_id.into_values().collect();
    sort_conversations(&mut list, &contacts.activity_ranks);
    let conversations_changed = if list != conversations.conversations {
        conversations.conversations = list;
        true
    } else {
        false
    };
    let flags_changed = conversations.rebuild_conversation_flags(self_conv_id);
    let extras_changed = conversations.rebuild_conversation_extras(contacts, self_conv_id);

    BatchPass1Outcome {
        stored_rows,
        e2ee_conv_ids,
        incoming_for_notice,
        poll_messages,
        windows_changed,
        conversations_changed,
        flags_changed,
        extras_changed,
    }
}

/// Converts a wire `StoredMessage` to an `olaz-store` `StoredMessage`.
#[must_use]
pub fn to_db_stored(w: &WireStoredMessage) -> DbStoredMessage {
    DbStoredMessage {
        id: w.id.clone(),
        conv_id: w.conv_id.clone(),
        client_id: w.client_id.clone(),
        sender_id: w.sender_id.clone(),
        sender_name: w.sender_name.clone(),
        sender_avatar: w.sender_avatar.clone(),
        is_mine: w.is_mine,
        text: w.text.clone(),
        kind_tag: w.kind_tag.clone(),
        ts_ms: w.ts_ms,
        status: w.status.clone(),
        raw_json_data: w.raw_json_data.clone(),
    }
}

/// Converts an `olaz-store` `StoredMessage` to a wire `StoredMessage` and decodes it.
#[must_use]
pub fn decode_db_stored(row: &DbStoredMessage) -> Option<ChatMessage> {
    let w = WireStoredMessage {
        id: row.id.clone(),
        conv_id: row.conv_id.clone(),
        client_id: row.client_id.clone(),
        sender_id: row.sender_id.clone(),
        sender_name: row.sender_name.clone(),
        sender_avatar: row.sender_avatar.clone(),
        is_mine: row.is_mine,
        text: row.text.clone(),
        kind_tag: row.kind_tag.clone(),
        ts_ms: row.ts_ms,
        status: row.status.clone(),
        raw_json_data: row.raw_json_data.clone(),
    };
    decode_stored_message(&w)
}

/// Computes the newest message id per conversation (by `date_ms`, then `id`) in `events`,
/// matching `ZaloEngine.newestMessageIds(in:)`.
#[must_use]
pub fn newest_message_ids(events: &[ParsedWireEvent]) -> BTreeMap<String, String> {
    let mut newest: BTreeMap<String, (i64, String)> = BTreeMap::new();
    for ev in events {
        let ParsedWireEvent::Message(msg, _) = ev else {
            continue;
        };
        if msg.id.is_empty() || msg.conversation_id.is_empty() {
            continue;
        }
        if let Some((cur_ts, cur_id)) = newest.get(&msg.conversation_id)
            && (*cur_ts > msg.date_ms
                || (*cur_ts == msg.date_ms && cur_id.as_str() >= msg.id.as_str()))
        {
            continue;
        }
        newest.insert(msg.conversation_id.clone(), (msg.date_ms, msg.id.clone()));
    }
    newest.into_iter().map(|(k, (_, id))| (k, id)).collect()
}

/// Collects unknown sender/reactor UIDs in `conv_id`'s window needing profile resolution
/// (`ZaloEngine.resolveMissingSenderProfiles(in:)`).
#[must_use]
pub fn collect_missing_sender_uids(
    list: &[ChatMessage],
    my_uid: &str,
    snap: &IdentitySnapshot,
) -> Vec<String> {
    let clean_my = strip_user_prefix(my_uid);
    let sanitized_my = sanitize_profile_uid(&clean_my).unwrap_or_else(|| clean_my.clone());
    let mut unknown_uids = Vec::new();
    let mut seen = HashSet::new();

    let mut consider = |raw: &str, existing_name: &str, has_avatar: bool| {
        let trimmed = strip_user_prefix(raw);
        let clean = sanitize_profile_uid(&trimmed).unwrap_or(trimmed);
        if matches!(
            clean.as_str(),
            "" | "0" | "me" | "__legacy__" | "unknown" | "-1"
        ) || clean == clean_my
            || clean == sanitized_my
            || !seen.insert(clean.clone())
        {
            return;
        }
        let person = snap.lookup_person(&clean);
        let best_name =
            if !existing_name.is_empty() && existing_name != clean && existing_name != UNKNOWN_NAME
            {
                existing_name
            } else {
                person.as_ref().map_or("", |p| p.name.as_str())
            };
        let needs_name = best_name.is_empty() || best_name == clean || best_name == UNKNOWN_NAME;
        let person_avt_empty = person.as_ref().is_none_or(|p| p.avatar.is_empty());
        let cached_avt_empty = snap
            .identities
            .cached_profiles
            .get(&clean)
            .is_none_or(|p| p.avatar.is_empty());
        let needs_avatar = !has_avatar && person_avt_empty && cached_avt_empty;
        if needs_name || needs_avatar {
            unknown_uids.push(clean);
        }
    };

    for msg in list {
        if !msg.is_mine
            && !msg.sender_id.is_empty()
            && msg.sender_id != "0"
            && msg.sender_id != clean_my
        {
            consider(
                &msg.sender_id,
                &msg.sender_name,
                msg.sender_avatar.is_some(),
            );
        }
        for react in &msg.reactions {
            for raw_uid in react.user_counts.keys() {
                consider(raw_uid, "", false);
            }
        }
    }
    unknown_uids
}

// ---------------------------------------------------------------------------
// Contacts folding, sorting, and parsing (`ZaloEngine+Contacts.swift`)
// ---------------------------------------------------------------------------

static CONTACT_COLLATOR: std::sync::LazyLock<icu_collator::CollatorBorrowed<'static>> =
    std::sync::LazyLock::new(|| {
        let mut prefs = icu_collator::CollatorPreferences::default();
        prefs.numeric_ordering = Some(icu_collator::preferences::CollationNumericOrdering::True);
        let mut opts = icu_collator::options::CollatorOptions::default();
        opts.strength = Some(icu_collator::options::Strength::Tertiary);
        let res = icu_collator::Collator::try_new(prefs, opts);
        #[expect(
            clippy::expect_used,
            reason = "compiled-in ICU root collation data is infallible"
        )]
        // INFALLIBLE: compiled-in ICU root collation data (`icu_collator` `compiled_data` feature).
        res.expect("ICU root collator")
    });

fn is_latin_diacritic_mark(u: u32) -> bool {
    matches!(
        u,
        0x0300..=0x036F
            | 0x0483..=0x0489
            | 0x1AB0..=0x1AFF
            | 0x1DC0..=0x1DFF
            | 0x20D0..=0x20FF
            | 0xFE20..=0xFE2F
    )
}

fn fold_special_pre_nfd(ch: char) -> Option<&'static str> {
    match ch {
        'đ' | 'Đ' => Some("d"),
        'ß' | 'ẞ' => Some("ss"),
        '\u{017F}' | '\u{1E9B}' => Some("s"),
        '\u{0149}' => Some("\u{02BC}n"),
        '\u{1E9A}' => Some("a\u{02BE}"),
        '\u{00B5}' => Some("\u{03BC}"),
        '\u{0345}' => Some("\u{03B9}"),
        '\u{03C2}' => Some("\u{03C3}"),
        '\u{03D0}' => Some("\u{03B2}"),
        '\u{03D1}' => Some("\u{03B8}"),
        '\u{03D5}' => Some("\u{03C6}"),
        '\u{03D6}' => Some("\u{03C0}"),
        '\u{03F0}' => Some("\u{03BA}"),
        '\u{03F1}' => Some("\u{03C1}"),
        '\u{03F5}' => Some("\u{03B5}"),
        '\u{0587}' => Some("\u{0565}\u{0582}"),
        '\u{212B}' => Some("a"),
        '\u{FB00}' => Some("ff"),
        '\u{FB01}' => Some("fi"),
        '\u{FB02}' => Some("fl"),
        '\u{FB03}' => Some("ffi"),
        '\u{FB04}' => Some("ffl"),
        '\u{FB05}' | '\u{FB06}' => Some("st"),
        '\u{FB13}' => Some("\u{0574}\u{0576}"),
        '\u{FB14}' => Some("\u{0574}\u{0565}"),
        '\u{FB15}' => Some("\u{0574}\u{056B}"),
        '\u{FB16}' => Some("\u{057E}\u{0576}"),
        '\u{FB17}' => Some("\u{0574}\u{056D}"),
        // Turkish capital I with dot above -> plain ASCII 'i' (without combining dot).
        '\u{0130}' => Some("i"),
        _ => None,
    }
}

fn preserves_precomposed_form(ch: char) -> bool {
    let u = u32::from(ch);
    // Hangul syllables, Greek prosgegrammeni/breathings, and negated math operators
    // are not decomposed by CFStringFold(diacriticInsensitive).
    (0xAC00..=0xD7A3).contains(&u)
        || matches!(u, 0x1FCD..=0x1FCF | 0x1FDD..=0x1FDF)
        || matches!(
            u,
            0x219A
                | 0x219B
                | 0x21AE
                | 0x21CD..=0x21CF
                | 0x2204
                | 0x2209
                | 0x220C
                | 0x2224
                | 0x2226
                | 0x2241
                | 0x2244
                | 0x2247
                | 0x2249
                | 0x2262
                | 0x226D
                | 0x2270
                | 0x2271
                | 0x2274
                | 0x2275
                | 0x2278
                | 0x2279
                | 0x2280
                | 0x2281
                | 0x2284
                | 0x2285
                | 0x2288
                | 0x2289
                | 0x22AC..=0x22AF
                | 0x22E0..=0x22E3
                | 0x22EA..=0x22ED
                | 0x2ADC
        )
}

/// Lower-cased, diacritic- and width-folded text (Vietnamese `đ`/`Đ` included) matching Swift's
/// `ZaloEngine.contactFold`:
/// `replacingOccurrences("đ"->"d", "Đ"->"D").folding([.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: "vi").lowercased()`.
#[must_use]
pub fn contact_fold(text: &str) -> String {
    fold_contact_str(text)
}

/// Exact ICU-backed port of `ZaloEngine.contactFold` (NFD + width folding + diacritic stripping + case folding).
#[must_use]
pub fn fold_contact_str(text: &str) -> String {
    let nfd = icu_normalizer::DecomposingNormalizerBorrowed::new_nfd();
    let nfkd = icu_normalizer::DecomposingNormalizerBorrowed::new_nfkd();
    let nfc = icu_normalizer::ComposingNormalizerBorrowed::new_nfc();

    let mut out = String::with_capacity(text.len());
    let mut prev_was_base = false;
    let mut scratch = String::new();

    for ch in text.chars() {
        let u = u32::from(ch);
        if is_latin_diacritic_mark(u) {
            if !prev_was_base {
                out.push(ch);
            }
            continue;
        }
        if let Some(mapped) = fold_special_pre_nfd(ch) {
            out.push_str(mapped);
            prev_was_base = true;
            continue;
        }
        // Halfwidth & Fullwidth Forms (U+FF01..=U+FFEE, excluding U+FFE3, U+FF9E, U+FF9F).
        if (0xFF01..=0xFFEE).contains(&u) && !matches!(u, 0xFFE3 | 0xFF9E | 0xFF9F) {
            scratch.clear();
            scratch.push(ch);
            let compat_decomposed = nfkd.normalize(&scratch);
            let compat = nfc.normalize(&compat_decomposed);
            for c in compat.chars() {
                for lc in c.to_lowercase() {
                    out.push(lc);
                }
            }
            prev_was_base = true;
            continue;
        }
        if preserves_precomposed_form(ch) {
            for lc in ch.to_lowercase() {
                out.push(lc);
            }
            prev_was_base = true;
            continue;
        }

        scratch.clear();
        scratch.push(ch);
        let decomposed = nfd.normalize(&scratch);
        let mut stripped_any = false;
        let mut temp = String::new();
        for (idx, dc) in decomposed.chars().enumerate() {
            let du = u32::from(dc);
            if idx > 0 && is_latin_diacritic_mark(du) {
                stripped_any = true;
                continue;
            }
            if let Some(mapped) = fold_special_pre_nfd(dc) {
                stripped_any = true;
                temp.push_str(mapped);
            } else {
                temp.push(dc);
            }
        }
        if stripped_any {
            let recomposed = nfc.normalize(&temp);
            for c in recomposed.chars() {
                for lc in c.to_lowercase() {
                    out.push(lc);
                }
            }
        } else {
            for lc in ch.to_lowercase() {
                out.push(lc);
            }
        }
        prev_was_base = true;
    }
    out
}

fn leading_zero_numeric_tiebreak(a: &str, b: &str) -> std::cmp::Ordering {
    let mut ia = a.chars().peekable();
    let mut ib = b.chars().peekable();
    loop {
        match (ia.peek(), ib.peek()) {
            (None, None) => return std::cmp::Ordering::Equal,
            (None, Some(_)) => return std::cmp::Ordering::Less,
            (Some(_), None) => return std::cmp::Ordering::Greater,
            (Some(&ca), Some(&cb)) if ca.is_ascii_digit() && cb.is_ascii_digit() => {
                let mut len_a = 0usize;
                while let Some(&d) = ia.peek()
                    && d.is_ascii_digit()
                {
                    len_a += 1;
                    let _ = ia.next();
                }
                let mut len_b = 0usize;
                while let Some(&d) = ib.peek()
                    && d.is_ascii_digit()
                {
                    len_b += 1;
                    let _ = ib.next();
                }
                match len_a.cmp(&len_b) {
                    std::cmp::Ordering::Equal => {}
                    ord => return ord,
                }
            }
            (Some(_), Some(_)) => {
                let _ = ia.next();
                let _ = ib.next();
            }
        }
    }
}

/// ICU UCA collation with numeric ordering (`kn=true`), matching Foundation's
/// `localizedStandardCompare` across Latin/Vietnamese, emoji/symbols, numbers, CJK, Kana, Hangul,
/// Cyrillic, and Greek, with Foundation's `forcedOrdering` tie-breaker (`"2" < "02"` and deterministic
/// UTF-8 tie-break).
#[must_use]
pub fn localized_standard_cmp(a: &str, b: &str) -> std::cmp::Ordering {
    if a == b {
        return std::cmp::Ordering::Equal;
    }
    match CONTACT_COLLATOR.compare(a, b) {
        std::cmp::Ordering::Equal => match leading_zero_numeric_tiebreak(a, b) {
            std::cmp::Ordering::Equal => a.cmp(b),
            ord => ord,
        },
        ord => ord,
    }
}

/// Parses raw responses from the 4 contact endpoints into unified `ContactsState` and `GroupsState`.
pub fn apply_fetched_contacts(
    contacts: &mut ContactsState,
    groups: &mut GroupsState,
    friends_rows: Option<Vec<Map<String, Value>>>,
    groups_dict: Option<Map<String, Value>>,
    sent_rows: Option<Vec<Map<String, Value>>>,
    received_rows: Option<Vec<Map<String, Value>>>,
) {
    if let Some(rows) = friends_rows {
        let mut mapped_friends = Vec::with_capacity(rows.len());
        let mut friend_global_map = BTreeMap::new();
        for row in &rows {
            let uid_raw = row
                .get("userId")
                .or_else(|| row.get("uid"))
                .or_else(|| row.get("id"));
            let uid = normalize_contact_uid(&olaz_wire::lossless::string(uid_raw));
            if uid.is_empty() {
                continue;
            }
            let global_id = olaz_wire::lossless::string(row.get("globalId"));
            if !global_id.is_empty() {
                friend_global_map.insert(uid.clone(), global_id);
            }
            let display = preferred_contact_name(row);
            let zalo_name = olaz_wire::lossless::string(row.get("zaloName"));
            let name = if display.is_empty() {
                zalo_name.clone()
            } else {
                display
            };
            let avt = olaz_wire::lossless::string(row.get("avatar").or_else(|| row.get("avt")));
            let avatar = is_valid_url_str(&avt).then_some(avt);
            let last_act = olaz_wire::lossless::int64(row.get("lastActionTime")).unwrap_or(0);
            let online = olaz_wire::lossless::int64(row.get("isActivePC")) == Some(1)
                || row.get("online").and_then(Value::as_bool) == Some(true);
            let sort_key = fold_contact_str(&name).trim().to_owned();
            let first = sort_key
                .chars()
                .next()
                .map(|c| c.to_ascii_uppercase())
                .filter(char::is_ascii_uppercase);
            let section = first.map_or_else(|| "#".to_owned(), |c| c.to_string());
            mapped_friends.push(FriendEntry {
                id: uid,
                name,
                zalo_name,
                avatar,
                last_active_ms: (last_act > 0).then_some(last_act),
                online,
                section,
                sort_key,
            });
        }
        // Fix #1: replace friend_global_ids atomically so stale globalId mappings do not linger.
        contacts.friend_global_ids = friend_global_map;
        mapped_friends.sort_by(|a, b| {
            if a.section != b.section {
                if a.section == "#" {
                    return std::cmp::Ordering::Greater;
                }
                if b.section == "#" {
                    return std::cmp::Ordering::Less;
                }
                return a.section.cmp(&b.section);
            }
            localized_standard_cmp(&a.sort_key, &b.sort_key)
        });
        contacts.friends = mapped_friends;
        contacts.friends_loaded = true;
    }

    if let Some(g_dict) = groups_dict {
        let info_map = g_dict
            .get("gridInfoMap")
            .and_then(Value::as_object)
            .cloned()
            .unwrap_or_default();
        let mut mapped_groups = Vec::with_capacity(info_map.len());
        let mut detail_cache = BTreeMap::new();
        for (raw_id, raw_info) in info_map {
            let Some(info) = raw_info.as_object() else {
                continue;
            };
            let clean_id = clean_group_id(&raw_id);
            if clean_id.is_empty() {
                continue;
            }
            if let Ok(json_str) = serde_json::to_string(&Value::Object(info.clone())) {
                detail_cache.insert(clean_id.clone(), json_str);
            }
            let conv_id = group_conv_id(&clean_id);
            let name = olaz_wire::lossless::string(info.get("name"));
            let avt = olaz_wire::lossless::string(info.get("avt").or_else(|| info.get("fullAvt")));
            let avatar = is_valid_url_str(&avt).then_some(avt);
            let members =
                olaz_wire::lossless::int64(info.get("totalMember").or_else(|| info.get("total")))
                    .unwrap_or_else(|| {
                        info.get("memVerList")
                            .and_then(Value::as_array)
                            .or_else(|| info.get("memIds").and_then(Value::as_array))
                            .map_or(0, |a| i64::try_from(a.len()).unwrap_or(0))
                    });
            let sort_key = fold_contact_str(&name);
            mapped_groups.push(GroupEntry {
                id: conv_id,
                name,
                avatar,
                members,
                sort_key,
            });
        }
        mapped_groups.sort_by(|a, b| localized_standard_cmp(&a.sort_key, &b.sort_key));
        groups.details_json = detail_cache;
        contacts.groups = mapped_groups;
        contacts.groups_loaded = true;
    }

    if let Some(r_rows) = received_rows {
        contacts.received_raw_json = serde_json::to_string(&Value::Array(
            r_rows.iter().cloned().map(Value::Object).collect(),
        ))
        .ok();
        let mapped: Vec<FriendRequestEntry> = r_rows
            .iter()
            .filter_map(|row| parse_friend_request_row(row, "fromUid"))
            .collect();
        contacts.pending_request_count = mapped.len();
        contacts.received = mapped;
    }

    if let Some(s_rows) = sent_rows {
        contacts.sent_raw_json = serde_json::to_string(&Value::Array(
            s_rows.iter().cloned().map(Value::Object).collect(),
        ))
        .ok();
        contacts.sent = s_rows
            .iter()
            .filter_map(|row| parse_friend_request_row(row, "toUid"))
            .collect();
    }
}

fn parse_friend_request_row(
    row: &Map<String, Value>,
    alt_uid_key: &str,
) -> Option<FriendRequestEntry> {
    let uid = normalize_contact_uid(&olaz_wire::lossless::string(
        row.get("userId")
            .or_else(|| row.get("uid"))
            .or_else(|| row.get(alt_uid_key)),
    ));
    if uid.is_empty() {
        return None;
    }
    let name = olaz_wire::lossless::string(row.get("displayName").or_else(|| row.get("zaloName")));
    let avt = olaz_wire::lossless::string(row.get("avatar").or_else(|| row.get("avt")));
    let avatar = is_valid_url_str(&avt).then_some(avt);
    let message = olaz_wire::lossless::string(row.get("message").or_else(|| row.get("msg")));
    let time = olaz_wire::lossless::int64(row.get("time").or_else(|| row.get("ts"))).unwrap_or(0);
    Some(FriendRequestEntry {
        id: uid,
        name,
        avatar,
        message,
        time_ms: (time > 0).then_some(time),
    })
}

/// Port of `ZaloWireParser.preferredName(_:)`.
#[must_use]
pub fn preferred_contact_name(row: &Map<String, Value>) -> String {
    for key in [
        "zaloName",
        "zalo_name",
        "displayName",
        "display_name",
        "dName",
        "name",
    ] {
        let s = olaz_wire::lossless::string(row.get(key));
        let trimmed = s.trim();
        if !trimmed.is_empty() {
            return trimmed.to_owned();
        }
    }
    String::new()
}

/// Serializes `cachedProfiles` JSON bytes for SQLite persistence.
#[must_use]
pub fn serialize_cached_profiles_json(
    profiles: &BTreeMap<String, CachedProfile>,
) -> Option<Vec<u8>> {
    let mut obj = Map::new();
    for (k, v) in profiles {
        obj.insert(
            k.clone(),
            json!({
                "name": v.name,
                "avatar": v.avatar,
            }),
        );
    }
    serde_json::to_vec(&Value::Object(obj)).ok()
}

/// Serializes `cachedGroups` JSON bytes for SQLite persistence.
#[must_use]
pub fn serialize_cached_groups_json(groups: &BTreeMap<String, CachedGroup>) -> Option<Vec<u8>> {
    let mut obj = Map::new();
    for (k, v) in groups {
        obj.insert(
            k.clone(),
            json!({
                "name": v.name,
                "avatar": v.avatar,
                "members": v.members,
            }),
        );
    }
    serde_json::to_vec(&Value::Object(obj)).ok()
}

/// Parses an integer cursor string if `msg_id` parses as `i64` (matching `Int64(msg.id).map(String.init)`).
#[must_use]
pub fn numeric_msg_cursor(msg_id: &str) -> Option<String> {
    msg_id.parse::<i64>().ok().map(|n| n.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use olaz_wire::{MessageMenu, Status};

    fn sample_msg(id: &str, conv_id: &str, date_ms: i64, text: &str) -> ChatMessage {
        ChatMessage {
            id: id.to_owned(),
            conversation_id: conv_id.to_owned(),
            sender_id: conv_id.to_owned(),
            sender_name: "Peer".to_owned(),
            sender_avatar: None,
            is_mine: false,
            kind: Kind::Text,
            text: text.to_owned(),
            date_ms,
            status: Status::Sent,
            quote: None,
            reactions: Vec::new(),
            is_e2ee: false,
            mentions: Vec::new(),
            card_buttons: Vec::new(),
            suggests_stickers: false,
            menu: MessageMenu::default(),
            fallback_urls: Vec::new(),
            client_id: format!("cli_{id}"),
            text_styles: Vec::new(),
            ttl_ms: 0,
            urgency: 0,
        }
    }

    #[test]
    fn format_swift_double_handles_integral_and_fractional_values() {
        assert_eq!(format_swift_double(1_700_100_000.0), "1700100000.0");
        assert_eq!(format_swift_double(0.0), "0.0");
        assert_eq!(format_swift_double(-42.0), "-42.0");
        assert_eq!(format_swift_double(1_700_100_000.25), "1700100000.25");
        assert_eq!(format_swift_double(1_700_000_200.123), "1700000200.123");
    }

    #[test]
    fn window_delta_coalescing_rules() {
        let m1 = sample_msg("1", "c1", 1000, "one");
        let m2 = sample_msg("2", "c1", 2000, "two");
        let m3 = sample_msg("3", "c1", 3000, "three");

        // 1. First change on an unshipped conversation is ALWAYS Reset.
        assert_eq!(
            coalesce_window_op(false, None, PendingWindowOp::Append(vec![m1.clone()])),
            PendingWindowOp::Reset
        );
        assert_eq!(
            coalesce_window_op(
                false,
                None,
                PendingWindowOp::Patch {
                    upserts: vec![m1.clone()],
                    removed_ids: Vec::new(),
                }
            ),
            PendingWindowOp::Reset
        );

        // 2. Append + Append on already-shipped base stays Append.
        let ap = coalesce_window_op(true, None, PendingWindowOp::Append(vec![m1.clone()]));
        let ap2 = coalesce_window_op(true, Some(ap), PendingWindowOp::Append(vec![m2.clone()]));
        assert_eq!(ap2, PendingWindowOp::Append(vec![m1.clone(), m2.clone()]));

        // 3. Append + Reset -> Reset.
        assert_eq!(
            coalesce_window_op(true, Some(ap2), PendingWindowOp::Reset),
            PendingWindowOp::Reset
        );

        // 4. Patch + Append -> Reset.
        let patch = coalesce_window_op(
            true,
            None,
            PendingWindowOp::Patch {
                upserts: vec![m1],
                removed_ids: Vec::new(),
            },
        );
        assert_eq!(
            coalesce_window_op(true, Some(patch), PendingWindowOp::Append(vec![m3.clone()])),
            PendingWindowOp::Reset
        );

        // 5. Remove + Append -> Reset.
        let remove = coalesce_window_op(
            true,
            None,
            PendingWindowOp::Patch {
                upserts: Vec::new(),
                removed_ids: vec!["1".to_owned()],
            },
        );
        assert_eq!(
            coalesce_window_op(true, Some(remove), PendingWindowOp::Append(vec![m3])),
            PendingWindowOp::Reset
        );
    }

    #[test]
    fn contact_fold_and_numeric_sort_match_swift() {
        assert_eq!(fold_contact_str("Đặng Thị Ánh"), "dang thi anh");
        assert_eq!(
            localized_standard_cmp("group 2", "group 10"),
            std::cmp::Ordering::Less
        );
    }

    #[test]
    fn freshness_pass_and_sticky_stale_behavior() {
        let mut ms = MessagesState::default();
        assert!(ms.begin_freshness_pass(None, 1_700_100_000_000));
        assert!(!ms.begin_freshness_pass(Some("1700099900.0"), 1_700_100_000_000));

        assert!(ms.record_freshness_probes(&[("g1".to_owned(), true), ("g2".to_owned(), false),]));
        assert!(ms.is_recent_history_up_to_date("g1"));
        assert!(!ms.is_recent_history_up_to_date("g2"));

        // Once Stale in a pass, a subsequent probe does not flip g2 back to UpToDate.
        assert!(!ms.record_freshness_probes(&[("g2".to_owned(), true)]));
        assert_eq!(
            ms.history_freshness.get("g2"),
            Some(&HistoryFreshness::Stale)
        );
    }
}
