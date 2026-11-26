//! Message-actions domain state, pure helpers, and U4-independent reducer (U6).
//!
//! Covers:
//! - [`RemoteDeleteMatchPolicy`] & [`REMOTE_DELETE_MATCH_POLICY`] (approved item #5: `IdAndClientId`).
//! - [`find_server_msg_id`]: pure recursive parser matching Swift `ZaloEngine.findServerMsgId`.
//! - Reaction dedupe keys ([`reaction_dedupe_keys`], [`local_reaction_seen_keys`]),
//!   FIFO-capped persistent seen set ([`SeenReactionKeys`], cap 1000, pref `"seenReactionEventIds"`),
//!   and 20 s local echo suppression ([`PendingLocalReactions`]).
//! - Delete-for-me undo bar state & 5 s generation-checked expiry timer ([`DeleteUndoState`]).
//! - Auto-delete settings map (`Option<BTreeMap<String, i64>>`), load/set commands, and system
//!   notice helper ([`auto_delete_system_notice`]).
//! - Recall 24 h window guard and error card/log mapping ([`RecallFailure`],
//!   [`recall_error_card_text`], [`recall_error_log_line`]).
//!
//! No I/O and no wall clock live here (D9): timestamps (`now_ms`) enter as command fields and
//! timers / network calls execute as [`Effect`]s in [`crate::runner::SessionEffectRunner`].

use std::collections::{BTreeMap, BTreeSet, VecDeque};
use std::fmt;
use std::time::Duration;

use olaz_api::{ApiError, AutoDeleteFetchOutcome, auto_delete_label};
use olaz_json::{parse_any, string as json_string};
use olaz_net::NetError;
use olaz_wire::{
    ChatMessage, DeleteMode, Kind, MessageMenu, Reaction, StarMode, Status, UNKNOWN_NAME,
    encode_chat_message, is_group_id, reaction_client_msg_type, reaction_icon, reaction_spec,
    sanitize_profile_uid, strip_user_prefix,
};
use serde_json::{Value, json};

use crate::changes::DirtyKey;
use crate::conversations::{
    BatchApplyDelta, CachedProfile, ConvPreviewOverride, ConversationPreview, MessagePreviewInput,
};
use crate::effect::{Effect, HostCall, OpResult, StoreOp};
use crate::input::{Command, Input};
use crate::messages::{PendingWindowOp, WindowChange, to_db_stored};
use crate::reduce::ReduceOutput;
use crate::reduce::conversations::{apply_batch_delta, apply_message_preview_update};
use crate::state::CoreState;

/// SQLite preference key for persisted reaction dedupe keys (Swift `ZaloEngine.swift:528,1495`).
pub const PREF_SEEN_REACTION_EVENT_IDS: &str = "seenReactionEventIds";

/// FIFO cap on `seen_reaction_event_ids` (Swift `ZaloEngine.swift:529,1490`).
pub const SEEN_REACTION_CAP: usize = 1000;

/// Lifetime of a pending local reaction echo-suppression entry in ms (Swift `ZaloEngine.swift:1744`).
pub const PENDING_LOCAL_REACTION_TTL_MS: i64 = 20_000;

/// Delete-for-me undo bar display lifetime (Swift `ZaloEngine+MessageActions.swift:536`).
pub const DELETE_UNDO_DURATION: Duration = Duration::from_secs(5);

/// Delete-for-me undo bar lifetime in milliseconds.
pub const DELETE_UNDO_DURATION_MS: i64 = 5_000;

/// Card toast shown when the user clicks Undo on the delete bar.
pub const RESTORE_SUCCESS_CARD_TEXT: &str = "Khôi phục thành công";

/// Card toast shown when `updateAutoDeleteConvers` fails.
pub const AUTO_DELETE_FAILED_CARD_TEXT: &str = "Không thể cài đặt tin nhắn tự xóa";

/// Maximum age (24 h in ms) of a message that can be recalled (Swift `ZaloEngine+MessageActions.swift:433`).
pub const RECALL_WINDOW_MS: i64 = 86_400_000;

/// Card toast shown when attempting to recall a message older than 24 h.
pub const RECALL_OVER_24H_CARD_TEXT: &str =
    "Bạn chỉ có thể thu hồi tin nhắn đã gửi trong vòng 24 giờ.";

/// Card toast shown when `sendReactionAPI` fails after any retry.
pub const REACT_FAILED_CARD_TEXT: &str = "Không thể thả biểu cảm. Vui lòng thử lại.";

/// Card toast shown when starring a message in a forward-blocked conversation.
pub const STAR_BLOCKED_CARD_TEXT: &str = "Trò chuyện này đã bật Chặn chia sẻ";

/// Card toasts shown after starring / unstarring a message.
pub const STAR_ADDED_CARD_TEXT: &str = "Đã đánh dấu tin nhắn";
pub const STAR_REMOVED_CARD_TEXT: &str = "Đã bỏ đánh dấu tin nhắn";

/// SQLite preference key for starred message ids.
pub const PREF_STARRED_IDS: &str = "starredIds";

const PRIORITY_SEARCH_KEYS: [&str; 5] = ["data", "msgs", "groupMsgs", "messages", "list"];
const MAX_SERVER_ID_SEARCH_DEPTH: usize = 8;

/// Policy governing how remote delete-for-me events match in-memory and SQLite rows (item #5).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RemoteDeleteMatchPolicy {
    /// Legacy Swift behavior prior to PR #9: match `msg.id` only in memory and delete
    /// `globalDelMsgId` only in SQLite.
    LegacyIdOnly,
    /// Approved item #5 behavior: match `msg.id` or `msg.client_id` in memory, and delete both
    /// `globalDelMsgId` and `cliMsgId` in SQLite.
    IdAndClientId,
}

/// Active policy for remote delete matching (approved by user: item #5).
pub const REMOTE_DELETE_MATCH_POLICY: RemoteDeleteMatchPolicy =
    RemoteDeleteMatchPolicy::IdAndClientId;

/// Returns whether an in-memory message `(msg_id, msg_cli_id)` matches a remote delete event
/// carrying `(target_msg_id, target_cli_id)` under `policy`.
#[must_use]
pub fn remote_delete_matches(
    policy: RemoteDeleteMatchPolicy,
    msg_id: &str,
    msg_cli_id: &str,
    target_msg_id: &str,
    target_cli_id: &str,
) -> bool {
    let target_msg = target_msg_id.trim();
    let target_cli = target_cli_id.trim();
    let id_match = !msg_id.is_empty()
        && ((!target_msg.is_empty() && msg_id == target_msg)
            || (!target_cli.is_empty() && msg_id == target_cli));
    if id_match {
        return true;
    }
    match policy {
        RemoteDeleteMatchPolicy::LegacyIdOnly => false,
        RemoteDeleteMatchPolicy::IdAndClientId => {
            !msg_cli_id.is_empty()
                && ((!target_msg.is_empty() && msg_cli_id == target_msg)
                    || (!target_cli.is_empty() && msg_cli_id == target_cli))
        }
    }
}

/// Returns the SQLite message IDs to delete for a remote delete event under `policy`
/// (deduplicated, preserving order).
#[must_use]
pub fn remote_delete_store_ids(
    policy: RemoteDeleteMatchPolicy,
    target_msg_id: &str,
    target_cli_id: &str,
) -> Vec<String> {
    let target_msg = target_msg_id.trim();
    let target_cli = target_cli_id.trim();
    let mut ids = Vec::with_capacity(2);
    if !target_msg.is_empty() {
        ids.push(target_msg.to_owned());
    }
    if policy == RemoteDeleteMatchPolicy::IdAndClientId
        && !target_cli.is_empty()
        && target_cli != target_msg
    {
        ids.push(target_cli.to_owned());
    }
    ids
}

/// Pure port of Swift `ZaloEngine.findServerMsgId(in:matchingClientId:)`.
///
/// Recursively searches a JSON payload (including nested JSON strings starting with `{` or `[`,
/// up to depth 8) for an object whose `cliMsgId` / `clientId` equals `matching_client_id`, and
/// returns its non-empty, non-`"0"`, distinct `msgId` / `globalMsgId` / `minGlobalMsgId`.
#[must_use]
pub fn find_server_msg_id(payload: &Value, matching_client_id: &str) -> Option<String> {
    let target_cli = matching_client_id.trim();
    if target_cli.is_empty() {
        return None;
    }
    search_server_msg_id(payload, target_cli, 0)
}

fn search_server_msg_id(node: &Value, target_cli: &str, depth: usize) -> Option<String> {
    if depth >= MAX_SERVER_ID_SEARCH_DEPTH {
        return None;
    }
    match node {
        Value::String(s) => {
            let trimmed = s.trim();
            if (trimmed.starts_with('{') || trimmed.starts_with('['))
                && let Some(parsed) = parse_any(trimmed.as_bytes())
            {
                return search_server_msg_id(&parsed, target_cli, depth + 1);
            }
            None
        }
        Value::Array(arr) => {
            for item in arr {
                if let Some(found) = search_server_msg_id(item, target_cli, depth + 1) {
                    return Some(found);
                }
            }
            None
        }
        Value::Object(map) => {
            let cli_raw = map.get("cliMsgId").or_else(|| map.get("clientId"));
            let cli = json_string(cli_raw);
            if cli.trim() == target_cli {
                let msg_raw = map
                    .get("msgId")
                    .or_else(|| map.get("globalMsgId"))
                    .or_else(|| map.get("minGlobalMsgId"));
                let msg_id = json_string(msg_raw);
                let trimmed_msg = msg_id.trim();
                if !trimmed_msg.is_empty() && trimmed_msg != "0" && trimmed_msg != target_cli {
                    return Some(trimmed_msg.to_owned());
                }
            }
            for key in PRIORITY_SEARCH_KEYS {
                if let Some(sub) = map.get(key)
                    && let Some(found) = search_server_msg_id(sub, target_cli, depth + 1)
                {
                    return Some(found);
                }
            }
            for (k, v) in map {
                if PRIORITY_SEARCH_KEYS.contains(&k.as_str()) {
                    continue;
                }
                if matches!(v, Value::Object(_) | Value::Array(_) | Value::String(_))
                    && let Some(found) = search_server_msg_id(v, target_cli, depth + 1)
                {
                    return Some(found);
                }
            }
            None
        }
        Value::Null | Value::Bool(_) | Value::Number(_) => None,
    }
}

/// Normalizes a conversation id for reaction dedupe keys (Swift `ZaloEngine.swift:1703`).
#[must_use]
pub fn dedupe_conv_id(conv_id: &str) -> String {
    let trimmed = conv_id.trim();
    if is_group_id(trimmed) {
        trimmed.to_owned()
    } else {
        sanitize_profile_uid(trimmed).unwrap_or_else(|| trimmed.to_owned())
    }
}

/// Builds candidate reaction dedupe keys for an incoming remote reaction event
/// (Swift `ZaloEngine.swift:1704-1717`).
#[must_use]
pub fn reaction_dedupe_keys(
    conv_id: &str,
    msg_id: &str,
    cli_msg_id: &str,
    r_type: i32,
    event_id: &str,
    react_client_id: &str,
) -> Vec<String> {
    let dedup_conv = dedupe_conv_id(conv_id);
    let trimmed_msg = msg_id.trim();
    let trimmed_cli = cli_msg_id.trim();
    let target_key = if trimmed_msg.is_empty() {
        trimmed_cli
    } else {
        trimmed_msg
    };
    let ev = event_id.trim();
    let rcli = react_client_id.trim();
    let mut keys = Vec::with_capacity(3);
    if !ev.is_empty() {
        keys.push(format!("{dedup_conv}|{target_key}|{ev}|{r_type}"));
    }
    if !rcli.is_empty() {
        if !trimmed_msg.is_empty() {
            keys.push(format!("{dedup_conv}|{trimmed_msg}|cli:{rcli}|{r_type}"));
        }
        if !trimmed_cli.is_empty() && trimmed_cli != trimmed_msg {
            keys.push(format!("{dedup_conv}|{trimmed_cli}|cli:{rcli}|{r_type}"));
        }
    }
    keys
}

/// Builds seen keys recorded right after a local reaction API call succeeds
/// (Swift `ZaloEngine+Chat.swift:868-875`).
#[must_use]
pub fn local_reaction_seen_keys(
    conv_id: &str,
    effective_msg_id: &str,
    resolved_cli_id: &str,
    react_client_id: &str,
    effective_type: i32,
) -> Vec<String> {
    let dedup_conv = dedupe_conv_id(conv_id);
    let msg = effective_msg_id.trim();
    let cli = resolved_cli_id.trim();
    let rcli = react_client_id.trim();
    if msg.is_empty() || rcli.is_empty() {
        return Vec::new();
    }
    let mut keys = Vec::with_capacity(2);
    keys.push(format!("{dedup_conv}|{msg}|cli:{rcli}|{effective_type}"));
    if !cli.is_empty() && cli != msg {
        keys.push(format!("{dedup_conv}|{cli}|cli:{rcli}|{effective_type}"));
    }
    keys
}

/// FIFO-evicting seen reaction dedupe key set capped at [`SEEN_REACTION_CAP`] (1000),
/// matching Swift `ZaloEngine.seenReactionEventIds` / `seenReactionEventOrder`.
#[derive(Clone, Default, PartialEq, Eq)]
pub struct SeenReactionKeys {
    set: BTreeSet<String>,
    order: VecDeque<String>,
}

impl fmt::Debug for SeenReactionKeys {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("SeenReactionKeys")
            .field("count", &self.order.len())
            .finish()
    }
}

impl SeenReactionKeys {
    /// Hydrates from saved SQLite preference strings (`"seenReactionEventIds"`), keeping at most
    /// the latest [`SEEN_REACTION_CAP`] entries (matching Swift `.suffix(1000)`).
    pub fn hydrate_from_saved(&mut self, saved: &[String]) {
        self.clear();
        let start = saved.len().saturating_sub(SEEN_REACTION_CAP);
        for raw in &saved[start..] {
            let trimmed = raw.trim();
            if !trimmed.is_empty() && self.set.insert(trimmed.to_owned()) {
                self.order.push_back(trimmed.to_owned());
            }
        }
    }

    /// Returns `true` if any key in `keys` has already been seen.
    #[must_use]
    pub fn contains_any(&self, keys: &[String]) -> bool {
        keys.iter()
            .any(|k| !k.trim().is_empty() && self.set.contains(k.trim()))
    }

    /// Inserts all non-empty trimmed keys, evicting the oldest entries beyond [`SEEN_REACTION_CAP`].
    /// Returns `true` if at least one new key was added (caller should persist via
    /// [`crate::effect::StoreOp::SetPreferenceStrings`] under [`PREF_SEEN_REACTION_EVENT_IDS`]).
    pub fn record(&mut self, keys: &[String]) -> bool {
        let mut changed = false;
        for raw in keys {
            let trimmed = raw.trim();
            if trimmed.is_empty() {
                continue;
            }
            if self.set.insert(trimmed.to_owned()) {
                self.order.push_back(trimmed.to_owned());
                changed = true;
            }
        }
        while self.order.len() > SEEN_REACTION_CAP {
            if let Some(evicted) = self.order.pop_front() {
                self.set.remove(&evicted);
            }
        }
        changed
    }

    /// Snapshot in insertion order for SQLite persistence (`setPreferenceStrings`).
    #[must_use]
    pub fn ordered(&self) -> Vec<String> {
        self.order.iter().cloned().collect()
    }

    #[must_use]
    pub fn len(&self) -> usize {
        self.order.len()
    }

    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.order.is_empty()
    }

    pub fn clear(&mut self) {
        self.set.clear();
        self.order.clear();
    }
}

/// One in-flight / recently-sent local reaction tracked for 20 s to suppress server echoes
/// (Swift `ZaloEngine.PendingLocalReaction`).
#[derive(Clone, PartialEq, Eq)]
pub struct PendingLocalReaction {
    pub conv_id: String,
    pub msg_id: String,
    pub cli_msg_id: String,
    pub r_type: i32,
    pub react_client_id: String,
    pub created_at_ms: i64,
}

impl fmt::Debug for PendingLocalReaction {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("PendingLocalReaction")
            .field("r_type", &self.r_type)
            .field("has_react_client_id", &!self.react_client_id.is_empty())
            .field("created_at_ms", &self.created_at_ms)
            .finish()
    }
}

/// Queue of recent local reactions used to suppress our own server echoes within 20 s.
#[derive(Clone, Default, PartialEq, Eq)]
pub struct PendingLocalReactions {
    entries: Vec<(u64, PendingLocalReaction)>,
}

impl fmt::Debug for PendingLocalReactions {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("PendingLocalReactions")
            .field("count", &self.entries.len())
            .finish()
    }
}

impl PendingLocalReactions {
    /// Drops entries older than [`PENDING_LOCAL_REACTION_TTL_MS`] relative to `now_ms`.
    pub fn prune(&mut self, now_ms: i64) {
        self.entries.retain(|(_, entry)| {
            now_ms.saturating_sub(entry.created_at_ms) <= PENDING_LOCAL_REACTION_TTL_MS
        });
    }

    /// Prunes expired entries and appends a new pending local reaction.
    pub fn push(&mut self, entry: PendingLocalReaction, now_ms: i64) {
        self.push_tagged(0, entry, now_ms);
    }

    /// Prunes expired entries and appends a tagged pending local reaction (for rollback / retry).
    pub fn push_tagged(&mut self, tag: u64, entry: PendingLocalReaction, now_ms: i64) {
        self.prune(now_ms);
        self.entries.push((tag, entry));
    }

    /// Updates `react_client_id` on the tagged pending entry (after API returns final client id).
    pub fn update_tag_client_id(&mut self, tag: u64, react_client_id: &str) {
        if tag == 0 {
            return;
        }
        if let Some((_, entry)) = self.entries.iter_mut().find(|(t, _)| *t == tag) {
            entry.react_client_id = react_client_id.to_owned();
        }
    }

    /// Removes the pending entry with `tag` (used when `sendReactionAPI` fails and rolls back).
    pub fn remove_by_tag(&mut self, tag: u64) {
        if tag == 0 {
            return;
        }
        self.entries.retain(|(t, _)| *t != tag);
    }

    /// Prunes expired entries and consumes the first entry matching the incoming echo
    /// (Swift `ZaloEngine.consumeMatchingPendingLocalReaction`).
    pub fn consume_matching(
        &mut self,
        now_ms: i64,
        conv_id: &str,
        msg_id: &str,
        cli_msg_id: &str,
        r_type: i32,
        react_client_id: &str,
    ) -> bool {
        self.prune(now_ms);
        let trimmed_conv = conv_id.trim();
        let sanitized_conv = sanitize_profile_uid(trimmed_conv).unwrap_or_default();
        let trimmed_msg = msg_id.trim();
        let trimmed_cli = cli_msg_id.trim();
        let trimmed_rcli = react_client_id.trim();

        let pos = self.entries.iter().position(|(_, pending)| {
            let conv_match = pending.conv_id == trimmed_conv
                || (!sanitized_conv.is_empty() && pending.conv_id == sanitized_conv);
            if !conv_match {
                return false;
            }
            let msg_match = (!trimmed_msg.is_empty()
                && (pending.msg_id == trimmed_msg || pending.cli_msg_id == trimmed_msg))
                || (!trimmed_cli.is_empty()
                    && (pending.msg_id == trimmed_cli || pending.cli_msg_id == trimmed_cli));
            if !msg_match {
                return false;
            }
            if !trimmed_rcli.is_empty() && pending.react_client_id == trimmed_rcli {
                return true;
            }
            pending.r_type == r_type
        });

        if let Some(idx) = pos {
            self.entries.remove(idx);
            true
        } else {
            false
        }
    }

    #[must_use]
    pub fn len(&self) -> usize {
        self.entries.len()
    }

    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    pub fn clear(&mut self) {
        self.entries.clear();
    }
}

/// Observable snapshot of the delete-for-me undo bar (Case format v1 & Swift UI).
#[derive(Clone, PartialEq, Eq)]
pub struct DeleteUndoSnapshot {
    pub conv_id: String,
    pub count: usize,
    pub deadline_ms: i64,
}

impl DeleteUndoSnapshot {
    /// Serializes to the Case format v1 JSON object (`{"conv_id", "count", "deadline_ms"}`).
    #[must_use]
    pub fn to_case_json(&self) -> Value {
        json!({
            "conv_id": self.conv_id,
            "count": self.count,
            "deadline_ms": self.deadline_ms,
        })
    }
}

impl fmt::Debug for DeleteUndoSnapshot {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("DeleteUndoSnapshot")
            .field("has_conv_id", &!self.conv_id.is_empty())
            .field("count", &self.count)
            .field("deadline_ms", &self.deadline_ms)
            .finish()
    }
}

/// One message queued for deferred delete-for-me commit (`deleteMessageForMeAPI` + SQLite delete).
#[derive(Clone, PartialEq)]
pub struct DeleteUndoItem {
    pub conv_id: String,
    pub msg_id: String,
    pub cli_msg_id: String,
    pub sender_id: String,
    /// Full message snapshot for restoring into the window if the user taps Undo.
    pub message: Option<ChatMessage>,
}

impl fmt::Debug for DeleteUndoItem {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("DeleteUndoItem")
            .field("has_conv_id", &!self.conv_id.is_empty())
            .field("has_msg_id", &!self.msg_id.is_empty())
            .field("has_cli_msg_id", &!self.cli_msg_id.is_empty())
            .field("has_sender_id", &!self.sender_id.is_empty())
            .finish()
    }
}

#[derive(Clone, PartialEq)]
struct ActiveDeleteUndo {
    conv_id: String,
    items: Vec<DeleteUndoItem>,
    deadline_ms: i64,
    undo_gen: u64,
}

impl fmt::Debug for ActiveDeleteUndo {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ActiveDeleteUndo")
            .field("count", &self.items.len())
            .field("deadline_ms", &self.deadline_ms)
            .field("undo_gen", &self.undo_gen)
            .finish()
    }
}

/// Core-owned delete-for-me undo bar state with monotonic generation guard (U6).
#[derive(Clone, Default, PartialEq)]
pub struct DeleteUndoState {
    active: Option<ActiveDeleteUndo>,
    /// Monotonic generation counter; never reset across logout/clear to prevent ABA collisions.
    next_undo_gen: u64,
}

impl fmt::Debug for DeleteUndoState {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("DeleteUndoState")
            .field("active", &self.active)
            .field("next_undo_gen", &self.next_undo_gen)
            .finish()
    }
}

impl DeleteUndoState {
    /// Current observable undo bar snapshot, or `None` when hidden.
    #[must_use]
    pub fn snapshot(&self) -> Option<DeleteUndoSnapshot> {
        self.active.as_ref().map(|a| DeleteUndoSnapshot {
            conv_id: a.conv_id.clone(),
            count: a.items.len(),
            deadline_ms: a.deadline_ms,
        })
    }

    /// Starts a new 5 s undo window for `items` in `conv_id` at `now_ms`.
    ///
    /// If another undo window is already open, commits the previous batch immediately (cancelling
    /// its timer and emitting [`Effect::CommitDeleteBatch`]) before arming the new timer.
    pub fn start_batch(
        &mut self,
        conv_id: String,
        items: Vec<DeleteUndoItem>,
        now_ms: i64,
        out: &mut ReduceOutput,
    ) {
        if items.is_empty() {
            return;
        }
        if let Some(prev) = self.active.take() {
            out.effects.push(Effect::CancelDeleteUndoExpiry);
            out.effects
                .push(Effect::CommitDeleteBatch { items: prev.items });
        }
        self.next_undo_gen = self.next_undo_gen.wrapping_add(1);
        let undo_gen = self.next_undo_gen;
        let deadline_ms = now_ms.saturating_add(DELETE_UNDO_DURATION_MS);
        self.active = Some(ActiveDeleteUndo {
            conv_id,
            items,
            deadline_ms,
            undo_gen,
        });
        out.dirty.insert(DirtyKey::DeleteUndo);
        out.effects.push(Effect::StartDeleteUndoExpiry {
            undo_gen,
            delay: DELETE_UNDO_DURATION,
        });
    }

    /// Undoes the active delete batch, emitting [`Effect::CancelDeleteUndoExpiry`] and
    /// [`HostCall::ShowCard`] with `"Khôi phục thành công"`. Returns the restored `(conv_id, items)`
    /// for window restoration once U4's `MessagesState` lands.
    pub fn undo(&mut self, out: &mut ReduceOutput) -> Option<(String, Vec<DeleteUndoItem>)> {
        let active = self.active.take()?;
        out.dirty.insert(DirtyKey::DeleteUndo);
        out.effects.push(Effect::CancelDeleteUndoExpiry);
        out.effects.push(Effect::Host(HostCall::ShowCard {
            conv_id: active.conv_id.clone(),
            text: RESTORE_SUCCESS_CARD_TEXT.to_owned(),
        }));
        Some((active.conv_id, active.items))
    }

    /// Dismisses the active delete bar and commits the pending delete batch immediately.
    pub fn dismiss(&mut self, out: &mut ReduceOutput) -> bool {
        let Some(active) = self.active.take() else {
            return false;
        };
        out.dirty.insert(DirtyKey::DeleteUndo);
        out.effects.push(Effect::CancelDeleteUndoExpiry);
        out.effects.push(Effect::CommitDeleteBatch {
            items: active.items,
        });
        true
    }

    /// Handles timer expiry for `undo_gen`; ignores stale generations, otherwise clears the bar
    /// and commits the batch.
    pub fn expire(&mut self, undo_gen: u64, out: &mut ReduceOutput) -> bool {
        if self.active.as_ref().map(|a| a.undo_gen) != Some(undo_gen) {
            return false;
        }
        let Some(active) = self.active.take() else {
            return false;
        };
        out.dirty.insert(DirtyKey::DeleteUndo);
        out.effects.push(Effect::CommitDeleteBatch {
            items: active.items,
        });
        true
    }

    /// Resets per-session undo state without touching `next_undo_gen`.
    /// Returns `true` if an active undo bar was cleared.
    pub(crate) fn reset_session(&mut self) -> bool {
        self.active.take().is_some()
    }
}

/// System info line synthesized after `updateAutoDeleteConvers` succeeds
/// (Swift `ZaloEngine+AutoDelete.swift:26-34`).
#[derive(Clone, PartialEq, Eq)]
pub struct AutoDeleteSystemNotice {
    pub id: String,
    pub conv_id: String,
    pub text: String,
    pub date_ms: i64,
}

impl fmt::Debug for AutoDeleteSystemNotice {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("AutoDeleteSystemNotice")
            .field("has_conv_id", &!self.conv_id.is_empty())
            .field("text_len", &self.text.len())
            .field("date_ms", &self.date_ms)
            .finish()
    }
}

/// Builds the official Vietnamese system notice message for an auto-delete change.
#[must_use]
pub fn auto_delete_system_notice(conv_id: &str, ttl: i64, now_ms: i64) -> AutoDeleteSystemNotice {
    let text = if ttl > 0 {
        format!(
            "Bạn đã đặt thời gian tự xóa cho tin nhắn là {}.",
            auto_delete_label(ttl)
        )
    } else {
        "Bạn đã tắt tin nhắn tự xóa.".to_owned()
    };
    AutoDeleteSystemNotice {
        id: format!("ttl-{conv_id}-{now_ms}"),
        conv_id: conv_id.to_owned(),
        text,
        date_ms: now_ms,
    }
}

/// Returns `true` when the message is at least 24 hours old and cannot be recalled
/// (Swift `ZaloEngine+MessageActions.swift:433`).
#[must_use]
pub fn is_over_recall_window(msg_date_ms: i64, now_ms: i64) -> bool {
    now_ms.saturating_sub(msg_date_ms) >= RECALL_WINDOW_MS
}

/// Classified failure from `recall_message` API (Swift `ZaloEngine+MessageActions.swift:472-486`).
#[derive(Clone, PartialEq, Eq)]
pub enum RecallFailure {
    Session { code: i64, message: String },
    Network,
    Other(String),
}

impl RecallFailure {
    /// Classifies an [`ApiError`] into the exact Swift recall failure buckets.
    #[must_use]
    pub fn from_api_error(err: &ApiError) -> Self {
        match err {
            ApiError::Net(NetError::Session(s)) => Self::Session {
                code: s.code,
                message: s.message.clone(),
            },
            ApiError::Net(NetError::Network { .. }) => Self::Network,
            other => Self::Other(other.to_string()),
        }
    }
}

impl fmt::Debug for RecallFailure {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Session { code, .. } => f.debug_struct("Session").field("code", code).finish(),
            Self::Network => f.write_str("Network"),
            Self::Other(s) => f.debug_struct("Other").field("len", &s.len()).finish(),
        }
    }
}

/// Maps a [`RecallFailure`] to the exact Vietnamese toast card shown to the user
/// (Swift `ZaloEngine+MessageActions.swift:477-486`).
#[must_use]
pub fn recall_error_card_text(err: &RecallFailure) -> String {
    match err {
        RecallFailure::Session { code: 211, .. } => "Tin nhắn đã quá thời hạn thu hồi.".to_owned(),
        RecallFailure::Session { code, .. } => {
            format!("Thu hồi tin nhắn không thành công (mã lỗi {code}).")
        }
        RecallFailure::Network => "Không có kết nối mạng. Vui lòng kiểm tra và thử lại.".to_owned(),
        RecallFailure::Other(_) => "Thu hồi tin nhắn không thành công.".to_owned(),
    }
}

/// Formats the exact `EngineLog` diagnostic line for a [`RecallFailure`]
/// (Swift `ZaloEngine+MessageActions.swift:473-485`).
#[must_use]
pub fn recall_error_log_line(
    err: &RecallFailure,
    primary_e2ee: bool,
    retried_alt: bool,
    effective_msg_id: &str,
    resolved_cli_id: &str,
) -> String {
    match err {
        RecallFailure::Session { code, message } => {
            let msg_note = if message.is_empty() {
                "-"
            } else {
                message.as_str()
            };
            let same_id = effective_msg_id == resolved_cli_id;
            format!(
                "recall failed: code={code} msg={msg_note} primaryE2EE={primary_e2ee} retriedAlt={retried_alt} sameId={same_id} msgId={effective_msg_id} cliId={resolved_cli_id}"
            )
        }
        RecallFailure::Network => "recall failed: network error".to_owned(),
        RecallFailure::Other(detail) => format!("recall failed: {detail}"),
    }
}

/// Maps an [`ApiError`] to the Swift `String(describing: type(of: error))` label used in
/// `autodelete: update failed <Type>` (Swift `ZaloEngine+AutoDelete.swift:20`).
#[must_use]
pub fn swift_error_type_name(err: &ApiError) -> &'static str {
    match err {
        ApiError::Net(NetError::Session(_)) => "ZaloSessionError",
        ApiError::Net(NetError::Network { .. }) => "URLError",
        ApiError::Net(NetError::Crypto(_)) => "CryptoError",
        ApiError::Net(NetError::Cancelled) => "CancellationError",
        ApiError::Net(
            NetError::Http { .. }
            | NetError::InvalidJson
            | NetError::NotAuthenticated
            | NetError::InvalidUrl(_)
            | NetError::QrTimeout
            | NetError::QrFailed(_),
        ) => "ZaloTransportError",
    }
}

/// Confirmation action carried by [`MessageConfirmState`] (`MessageActionConfirm.Action`).
#[derive(Clone, PartialEq, Eq)]
pub enum MessageConfirmAction {
    DeleteForMe {
        msg_id: String,
    },
    DeleteMany {
        msg_ids: Vec<String>,
    },
    RecallMany {
        msg_ids: Vec<String>,
    },
    Pin {
        msg_id: String,
        replacing_ref: Option<String>,
    },
    Unpin {
        topic_ref: String,
    },
}

impl MessageConfirmAction {
    #[must_use]
    pub fn kind_name(&self) -> &'static str {
        match self {
            Self::DeleteForMe { .. } => "delete_for_me",
            Self::DeleteMany { .. } => "delete_many",
            Self::RecallMany { .. } => "recall_many",
            Self::Pin { .. } => "pin",
            Self::Unpin { .. } => "unpin",
        }
    }
}

impl fmt::Debug for MessageConfirmAction {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::DeleteForMe { .. } => f.write_str("DeleteForMe"),
            Self::DeleteMany { msg_ids } => f
                .debug_struct("DeleteMany")
                .field("count", &msg_ids.len())
                .finish(),
            Self::RecallMany { msg_ids } => f
                .debug_struct("RecallMany")
                .field("count", &msg_ids.len())
                .finish(),
            Self::Pin { replacing_ref, .. } => f
                .debug_struct("Pin")
                .field("has_replacing", &replacing_ref.is_some())
                .finish(),
            Self::Unpin { .. } => f.write_str("Unpin"),
        }
    }
}

/// Active message-action confirmation prompt (`ZaloEngine.messageConfirm`).
#[derive(Clone, PartialEq, Eq)]
pub struct MessageConfirmState {
    pub id: u64,
    pub conv_id: String,
    pub action: MessageConfirmAction,
    pub title: String,
    pub message: String,
    pub ok: String,
    pub destructive: bool,
}

impl MessageConfirmState {
    #[must_use]
    pub fn to_case_json(&self) -> Value {
        json!({
            "conv_id": self.conv_id,
            "action": self.action.kind_name(),
            "title": self.title,
            "message": self.message,
            "ok": self.ok,
            "destructive": self.destructive,
        })
    }
}

impl fmt::Debug for MessageConfirmState {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("MessageConfirmState")
            .field("id", &self.id)
            .field("action", &self.action)
            .field("destructive", &self.destructive)
            .finish()
    }
}

/// Classified failure from `send_reaction` API (Swift `ZaloEngine+Chat.swift:1013-1026`).
#[derive(Clone, PartialEq, Eq)]
pub enum ReactFailure {
    Session { code: i64, message: String },
    Other(String),
}

impl ReactFailure {
    #[must_use]
    pub fn from_api_error(err: &ApiError) -> Self {
        match err {
            ApiError::Net(NetError::Session(se)) => Self::Session {
                code: se.code,
                message: se.message.clone(),
            },
            other => Self::Other(other.to_string()),
        }
    }

    #[must_use]
    pub fn log_line(&self, effective_msg_id: &str, resolved_cli_id: &str, msg_type: i64) -> String {
        match self {
            Self::Session { code, message } => {
                let msg_note = if message.is_empty() {
                    "-"
                } else {
                    message.as_str()
                };
                format!(
                    "react failed: code={code} msg={msg_note} msgId={effective_msg_id} cliId={resolved_cli_id} msgType={msg_type}"
                )
            }
            Self::Other(desc) => format!(
                "react failed: {desc} msgId={effective_msg_id} cliId={resolved_cli_id} msgType={msg_type}"
            ),
        }
    }
}

impl fmt::Debug for ReactFailure {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Session { code, .. } => f.debug_struct("Session").field("code", code).finish(),
            Self::Other(s) => f.debug_struct("Other").field("len", &s.len()).finish(),
        }
    }
}

/// Parameters for [`mutate_reactions`] (pure port of Swift `ZaloEngine.mutateReactions`).
pub struct ReactionMutation<'a> {
    pub actor_uid: &'a str,
    pub my_uid: &'a str,
    pub is_me: bool,
    pub r_type: &'a str,
    pub r_icon: &'a str,
    pub allow_duplicate_same_user: bool,
}

/// Pure port of Swift `ZaloEngine.mutateReactions`.
pub fn mutate_reactions<F>(
    reactions: &mut Vec<Reaction>,
    params: &ReactionMutation<'_>,
    name_lookup: F,
) where
    F: Fn(&str) -> String,
{
    let trimmed_type = params.r_type.trim();
    let trimmed_icon = params.r_icon.trim();
    if trimmed_type.is_empty() && trimmed_icon.is_empty() {
        return;
    }

    let clean_my_uid = sanitize_profile_uid(params.my_uid)
        .unwrap_or_else(|| strip_user_prefix(params.my_uid).to_owned());
    let my_key: &str = if clean_my_uid.is_empty() {
        "me"
    } else {
        clean_my_uid.as_str()
    };
    let clean_actor = strip_user_prefix(params.actor_uid);
    let normalized_actor: String = if params.is_me {
        my_key.to_owned()
    } else {
        sanitize_profile_uid(&clean_actor).unwrap_or_else(|| clean_actor.clone())
    };
    let is_sentinel = |k: &str| k.is_empty() || k == "__legacy__" || k == "unknown" || k == "-1";
    if !params.is_me && is_sentinel(&normalized_actor) {
        return;
    }

    let rebuild_derived_fields = |reaction: &mut Reaction| {
        reaction
            .user_counts
            .retain(|k, v| !is_sentinel(k) && *v > 0);
        let total_count: i64 = reaction.user_counts.values().copied().sum();
        reaction.count = total_count;
        reaction.includes_me = reaction.user_counts.get(my_key).copied().unwrap_or(0) > 0;
        reaction.people = reaction.user_counts.len() as i64;

        let mut ordered_uids: Vec<String> = reaction.user_counts.keys().cloned().collect();
        ordered_uids.sort();
        if reaction.includes_me {
            ordered_uids.retain(|u| u != my_key);
            ordered_uids.insert(0, my_key.to_owned());
        }
        let mut rebuilt_names = Vec::new();
        for uid in ordered_uids {
            if rebuilt_names.len() >= 3 {
                break;
            }
            if uid == my_key {
                rebuilt_names.push("Bạn".to_owned());
            } else {
                let resolved = name_lookup(&uid);
                let resolved = resolved.trim();
                if !resolved.is_empty() && resolved != UNKNOWN_NAME && resolved != uid {
                    rebuilt_names.push(resolved.to_owned());
                }
            }
        }
        reaction.names = rebuilt_names;
    };

    let is_removal = trimmed_type == "-1" || trimmed_type.parse::<i64>().is_ok_and(|n| n < 0);
    if is_removal {
        let existing_list = std::mem::take(reactions);
        let mut kept = Vec::with_capacity(existing_list.len());
        for existing in existing_list {
            let mut r = existing.clone();
            if !r.user_counts.is_empty() {
                r.user_counts.remove("__legacy__");
                r.user_counts.remove("unknown");
                if params.is_me {
                    r.user_counts.remove(my_key);
                    r.user_counts.remove("0");
                    r.user_counts.remove("me");
                } else {
                    r.user_counts.remove(&normalized_actor);
                    if clean_actor != normalized_actor {
                        r.user_counts.remove(&clean_actor);
                    }
                }
                rebuild_derived_fields(&mut r);
                if r.count > 0 {
                    kept.push(r);
                }
            } else {
                let had_known_people = existing.people > 0;
                if params.is_me {
                    if !r.includes_me {
                        kept.push(r);
                        continue;
                    }
                    r.includes_me = false;
                    r.names.retain(|n| n != "Bạn");
                    r.people = (existing.people - 1).max(0);
                    r.count = if had_known_people && r.people == 0 {
                        0
                    } else {
                        (existing.count - 1).max(0)
                    };
                } else {
                    let actor_name_owned = name_lookup(&normalized_actor);
                    let actor_name = actor_name_owned.trim();
                    let matched_name =
                        !actor_name.is_empty() && r.names.iter().any(|n| n == actor_name);
                    if matched_name || (!r.includes_me && r.people <= 1) {
                        if matched_name {
                            r.names.retain(|n| n != actor_name);
                        }
                        r.people = (existing.people - 1).max(0);
                        r.count = if had_known_people && r.people == 0 {
                            0
                        } else {
                            (existing.count - 1).max(0)
                        };
                    }
                }
                if r.count > 0 {
                    kept.push(r);
                }
            }
        }
        *reactions = kept;
        return;
    }

    let Some(icon) = reaction_icon(trimmed_type, trimmed_icon) else {
        return;
    };

    if let Some(r) = reactions
        .iter_mut()
        .find(|existing| existing.icon.r#type == icon.r#type)
    {
        if r.user_counts.is_empty() && r.count > 0 && r.includes_me {
            r.user_counts.insert(my_key.to_owned(), 1);
        }
        if params.allow_duplicate_same_user || !r.user_counts.contains_key(&normalized_actor) {
            *r.user_counts.entry(normalized_actor).or_insert(0) += 1;
        }
        rebuild_derived_fields(r);
    } else {
        let mut user_counts = BTreeMap::new();
        user_counts.insert(normalized_actor, 1);
        let mut created = Reaction {
            icon,
            count: 1,
            includes_me: params.is_me,
            names: Vec::new(),
            people: 1,
            user_counts,
        };
        rebuild_derived_fields(&mut created);
        reactions.push(created);
    }
}

#[derive(Clone)]
pub(crate) enum PendingIdResolution {
    React(ReactDispatchArgs),
    Recall(RecallDispatchArgs),
    // U7
    Pin {
        conv_id: String,
        initial_msg_id: String,
        pin_op_id: u64,
    },
}

#[derive(Clone)]
pub(crate) struct ReactDispatchArgs {
    pub(crate) conv_id: String,
    pub(crate) initial_msg_id: String,
    pub(crate) busy_key: String,
    pub(crate) effective_type: i64,
    pub(crate) effective_icon: String,
    pub(crate) msg_type: i64,
    pub(crate) now_ms: i64,
    pub(crate) op_id: Option<u64>,
}

#[derive(Clone)]
pub(crate) struct RecallDispatchArgs {
    pub(crate) conv_id: String,
    pub(crate) initial_msg_id: String,
    pub(crate) busy_key: String,
    pub(crate) primary_is_e2ee: bool,
    pub(crate) can_try_alt: bool,
    pub(crate) op_id: Option<u64>,
    pub(crate) recall_many_id: Option<u64>,
}

#[derive(Clone)]
pub(crate) struct InFlightReact {
    pub(crate) conv_id: String,
    pub(crate) initial_msg_id: String,
    pub(crate) busy_key: String,
    pub(crate) effective_msg_id: String,
    pub(crate) resolved_cli_id: String,
    pub(crate) effective_type: i64,
    pub(crate) msg_type: i64,
    pub(crate) previous_reactions: Vec<Reaction>,
    pub(crate) op_id: Option<u64>,
}

#[derive(Clone)]
pub(crate) struct InFlightRecall {
    pub(crate) conv_id: String,
    pub(crate) busy_key: String,
    pub(crate) effective_msg_id: String,
    pub(crate) resolved_cli_id: String,
    pub(crate) primary_is_e2ee: bool,
    pub(crate) op_id: Option<u64>,
    pub(crate) recall_many_id: Option<u64>,
}

#[derive(Clone)]
pub(crate) struct InFlightRecallMany {
    pub(crate) conv_id: String,
    pub(crate) remaining_msg_ids: VecDeque<String>,
    pub(crate) now_ms: i64,
    pub(crate) op_id: Option<u64>,
}

/// Core-owned message-actions state (U6).
#[derive(Clone, Default)]
pub struct ActionsState {
    pub seen_reactions: SeenReactionKeys,
    pub pending_reactions: PendingLocalReactions,
    pub delete_undo: DeleteUndoState,
    /// Active confirmation prompt (`ZaloEngine.messageConfirm`).
    pub message_confirm: Option<MessageConfirmState>,
    /// Per-conversation auto-delete TTL in ms (`None` = not loaded yet, `Some(map)` = loaded).
    pub auto_delete: Option<BTreeMap<String, i64>>,
    /// In-memory starred message id set (`ZaloEngine.cachedStarredIds`).
    pub starred_ids: BTreeSet<String>,
    /// Next expiry returned by the most recent `prune_expired_messages` call.
    pub last_prune_next_expiry_ms: Option<i64>,

    // Internal reducer bookkeeping (monotonic across session resets).
    pub(crate) next_seq: u64,
    pub(crate) reaction_busy_keys: BTreeSet<String>,
    pub(crate) recall_busy_keys: BTreeSet<String>,
    pub(crate) pending_id_resolutions: BTreeMap<u64, PendingIdResolution>,
    pub(crate) in_flight_reacts: BTreeMap<u64, InFlightReact>,
    pub(crate) in_flight_recalls: BTreeMap<u64, InFlightRecall>,
    pub(crate) in_flight_recall_many: BTreeMap<u64, InFlightRecallMany>,
}

impl fmt::Debug for ActionsState {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ActionsState")
            .field("seen_reactions", &self.seen_reactions)
            .field("pending_reactions", &self.pending_reactions)
            .field("delete_undo", &self.delete_undo)
            .field("message_confirm", &self.message_confirm)
            .field(
                "auto_delete_count",
                &self.auto_delete.as_ref().map(BTreeMap::len),
            )
            .field("starred_ids_count", &self.starred_ids.len())
            .field("last_prune_next_expiry_ms", &self.last_prune_next_expiry_ms)
            .field("in_flight_reacts", &self.in_flight_reacts.len())
            .field("in_flight_recalls", &self.in_flight_recalls.len())
            .finish()
    }
}

impl ActionsState {
    pub(crate) fn next_id(&mut self) -> u64 {
        self.next_seq = self.next_seq.wrapping_add(1);
        if self.next_seq == 0 {
            self.next_seq = 1;
        }
        self.next_seq
    }

    /// Current auto-delete TTL (ms) for `conv_id`, or `0` if off / unloaded.
    #[must_use]
    pub fn auto_delete_ttl(&self, conv_id: &str) -> i64 {
        self.auto_delete
            .as_ref()
            .and_then(|m| m.get(conv_id))
            .copied()
            .unwrap_or(0)
    }

    /// Resets per-session actions state on logout / session expiry, preserving monotonic counters.
    pub(crate) fn reset_session(&mut self) -> (bool, bool, bool, bool) {
        self.seen_reactions.clear();
        self.pending_reactions.clear();
        let undo_changed = self.delete_undo.reset_session();
        let confirm_changed = self.message_confirm.take().is_some();
        let auto_delete_changed = self.auto_delete.take().is_some();
        let starred_changed = !self.starred_ids.is_empty();
        self.starred_ids.clear();
        self.last_prune_next_expiry_ms = None;
        self.reaction_busy_keys.clear();
        self.recall_busy_keys.clear();
        self.pending_id_resolutions.clear();
        self.in_flight_reacts.clear();
        self.in_flight_recalls.clear();
        self.in_flight_recall_many.clear();
        (
            undo_changed,
            confirm_changed,
            auto_delete_changed,
            starred_changed,
        )
    }
}

fn is_selectable_message(msg: &ChatMessage) -> bool {
    !matches!(
        msg.kind,
        Kind::System | Kind::Notice { .. } | Kind::Ecard(_) | Kind::Poll(_)
    ) && msg.status != Status::Sending
}

fn selection_can_recall(list: &[ChatMessage], now_ms: i64) -> bool {
    !list.is_empty()
        && list.iter().all(|m| {
            m.is_mine
                && m.menu.recall
                && m.kind != Kind::Recalled
                && now_ms.saturating_sub(m.date_ms) < RECALL_WINDOW_MS
        })
}

fn select_messages_in_window_order(
    state: &CoreState,
    conv_id: &str,
    msg_ids: &[String],
) -> Vec<ChatMessage> {
    let Some(list) = state.messages.windows.get(conv_id) else {
        return Vec::new();
    };
    let mut selected_ids: BTreeSet<&str> = BTreeSet::new();
    for raw_id in msg_ids {
        if let Some(m) = list
            .iter()
            .find(|m| m.id == *raw_id || (!m.client_id.is_empty() && m.client_id == *raw_id))
            && is_selectable_message(m)
            && selected_ids.len() < 100
        {
            selected_ids.insert(m.id.as_str());
        }
    }
    list.iter()
        .filter(|m| selected_ids.contains(m.id.as_str()))
        .cloned()
        .collect()
}

struct RemoteReactionInput<'a> {
    conv_id: &'a str,
    msg_id: &'a str,
    cli_msg_id: &'a str,
    sender_id: &'a str,
    r_type: &'a str,
    r_icon: &'a str,
    event_id: &'a str,
    react_client_id: &'a str,
    sender_name: &'a str,
    now_ms: i64,
}

struct RemoteRecallInput {
    conv_id: String,
    msg_id: String,
    cli_msg_id: String,
    update_conversation_preview: bool,
    persist_conversations: bool,
    op_id: Option<u64>,
    recall_many_id: Option<u64>,
}

struct RemoteRecallStoreInput {
    conv_id: String,
    recalled_last: Option<(i64, bool)>,
    update_conversation_preview: bool,
    persist_conversations: bool,
    op_id: Option<u64>,
    recall_many_id: Option<u64>,
}

struct RemoteDeleteStoreInput {
    conv_id: String,
    deleted_ts_ms: Option<i64>,
    mem_latest: Option<ConversationPreview>,
    store_latest: Option<ConversationPreview>,
    update_conversation_preview: bool,
    persist_conversations: bool,
}

/// Pure reducer for U6 message-actions commands and async completions.
pub(crate) fn reduce_actions(state: &mut CoreState, input: Input, out: &mut ReduceOutput) {
    match input {
        Input::Command(cmd) => reduce_command(state, cmd, None, out),
        Input::OpRequest { op_id, cmd } => reduce_command(state, cmd, Some(op_id), out),
        Input::MessageIdsResolved {
            resolve_id,
            effective_msg_id,
            resolved_cli_id,
            upgraded_from_history: _,
        } => {
            handle_ids_resolved(state, resolve_id, effective_msg_id, resolved_cli_id, out);
        }
        Input::ReactDone {
            react_id,
            final_react_client_id,
            error,
        } => {
            handle_react_done(state, react_id, final_react_client_id, error, out);
        }
        Input::RecallDone {
            recall_id,
            retried_alt,
            error,
        } => {
            handle_recall_done(state, recall_id, retried_alt, error, out);
        }
        Input::RemoteReactionApproved {
            conv_id,
            msg_id,
            cli_msg_id,
            sender_id,
            r_type,
            r_icon,
            event_id,
            react_client_id,
            sender_name,
            now_ms,
        } => {
            handle_remote_reaction(
                state,
                &RemoteReactionInput {
                    conv_id: &conv_id,
                    msg_id: &msg_id,
                    cli_msg_id: &cli_msg_id,
                    sender_id: &sender_id,
                    r_type: &r_type,
                    r_icon: &r_icon,
                    event_id: &event_id,
                    react_client_id: &react_client_id,
                    sender_name: &sender_name,
                    now_ms,
                },
                out,
            );
        }
        Input::RemoteRecallApproved {
            conv_id,
            msg_id,
            cli_msg_id,
            update_conversation_preview,
            persist_conversations,
            op_id,
            recall_many_id,
        } => {
            handle_remote_recall_approved(
                state,
                RemoteRecallInput {
                    conv_id,
                    msg_id,
                    cli_msg_id,
                    update_conversation_preview,
                    persist_conversations,
                    op_id,
                    recall_many_id,
                },
                out,
            );
        }
        Input::RemoteRecallSkipped {
            op_id,
            recall_many_id,
        } => {
            finish_recall_step(state, op_id, recall_many_id, false, out);
        }
        Input::RemoteRecallStoreDone {
            conv_id,
            recalled_last,
            update_conversation_preview,
            persist_conversations,
            op_id,
            recall_many_id,
        } => {
            handle_remote_recall_store_done(
                state,
                RemoteRecallStoreInput {
                    conv_id,
                    recalled_last,
                    update_conversation_preview,
                    persist_conversations,
                    op_id,
                    recall_many_id,
                },
                out,
            );
        }
        Input::RemoteDeleteApproved {
            conv_id,
            msg_id,
            cli_msg_id,
            update_conversation_preview,
            persist_conversations,
        } => {
            handle_remote_delete_approved(
                state,
                conv_id,
                msg_id,
                cli_msg_id,
                update_conversation_preview,
                persist_conversations,
                out,
            );
        }
        Input::RemoteDeleteStoreDone {
            conv_id,
            deleted_ts_ms,
            mem_latest,
            store_latest,
            update_conversation_preview,
            persist_conversations,
        } => {
            handle_remote_delete_store_done(
                state,
                RemoteDeleteStoreInput {
                    conv_id,
                    deleted_ts_ms,
                    mem_latest,
                    store_latest,
                    update_conversation_preview,
                    persist_conversations,
                },
                out,
            );
        }
        Input::DeleteUndoExpired { undo_gen } => {
            state.actions.delete_undo.expire(undo_gen, out);
        }
        Input::AutoDeleteLoaded { outcome, op_id } => {
            apply_auto_delete_loaded(state, outcome, out);
            complete_unit(op_id, out);
        }
        Input::AutoDeleteUpdated {
            conv_id,
            ttl,
            now_ms,
            error_type,
            op_id,
        } => {
            let persisted =
                apply_auto_delete_updated(state, &conv_id, ttl, now_ms, error_type, out);
            complete_unit_after(op_id, persisted, out);
        }
        _ => {}
    }
}

struct ReactStartArgs {
    conv_id: String,
    msg_id: String,
    emoji: String,
    remove_all: bool,
    now_ms: i64,
    op_id: Option<u64>,
}

struct RecallStartArgs {
    conv_id: String,
    msg_id: String,
    is_e2ee_thread: Option<bool>,
    now_ms: i64,
    op_id: Option<u64>,
    recall_many_id: Option<u64>,
}

fn reduce_command(state: &mut CoreState, cmd: Command, op_id: Option<u64>, out: &mut ReduceOutput) {
    match cmd {
        Command::React {
            conv_id,
            msg_id,
            emoji,
            remove_all,
            now_ms,
        } => {
            start_react(
                state,
                ReactStartArgs {
                    conv_id,
                    msg_id,
                    emoji,
                    remove_all,
                    now_ms,
                    op_id,
                },
                out,
            );
        }
        Command::Recall {
            conv_id,
            msg_id,
            is_e2ee_thread,
            now_ms,
        } => {
            start_recall(
                state,
                RecallStartArgs {
                    conv_id,
                    msg_id,
                    is_e2ee_thread,
                    now_ms,
                    op_id,
                    recall_many_id: None,
                },
                out,
            );
        }
        Command::RecallMany {
            conv_id,
            msg_ids,
            confirm,
            now_ms,
        } => {
            if confirm {
                let list = select_messages_in_window_order(state, &conv_id, &msg_ids);
                if let Some(first) = list.first()
                    && selection_can_recall(&list, now_ms)
                {
                    let confirm_id = state.actions.next_id();
                    ask_message_confirm(
                        state,
                        MessageConfirmState {
                            id: confirm_id,
                            conv_id: first.conversation_id.clone(),
                            action: MessageConfirmAction::RecallMany {
                                msg_ids: list.into_iter().map(|m| m.id).collect(),
                            },
                            title: "Thu hồi tin nhắn".to_owned(),
                            message: "Thu hồi các tin nhắn đã chọn cho tất cả mọi người?"
                                .to_owned(),
                            ok: "Thu hồi".to_owned(),
                            destructive: true,
                        },
                        out,
                    );
                }
                complete_unit(op_id, out);
            } else {
                start_recall_many(state, conv_id, msg_ids, now_ms, op_id, out);
            }
        }
        Command::DeleteForMe {
            conv_id,
            msg_id,
            confirmed,
            now_ms,
        } => {
            start_delete_for_me(state, &conv_id, &msg_id, confirmed, now_ms, out);
            complete_unit(op_id, out);
        }
        Command::DeleteMany {
            conv_id,
            msg_ids,
            confirm,
            now_ms,
        } => {
            let list = select_messages_in_window_order(state, &conv_id, &msg_ids);
            if confirm {
                if let Some(first) = list.first() {
                    let confirm_id = state.actions.next_id();
                    ask_message_confirm(
                        state,
                        MessageConfirmState {
                            id: confirm_id,
                            conv_id: first.conversation_id.clone(),
                            action: MessageConfirmAction::DeleteMany {
                                msg_ids: list.into_iter().map(|m| m.id).collect(),
                            },
                            title: "Xóa tin nhắn".to_owned(),
                            message: "Xóa các tin nhắn đã chọn chỉ ở phía bạn?".to_owned(),
                            ok: "Xóa chỉ ở phía tôi".to_owned(),
                            destructive: true,
                        },
                        out,
                    );
                }
            } else {
                start_delete_messages(state, &conv_id, list, now_ms, out);
            }
            complete_unit(op_id, out);
        }
        Command::AnswerMessageConfirm { ok, now_ms } => {
            let Some(confirm) = state.actions.message_confirm.take() else {
                complete_unit(op_id, out);
                return;
            };
            out.dirty.insert(DirtyKey::MessageConfirm);
            if !ok {
                complete_unit(op_id, out);
                return;
            }
            match confirm.action {
                MessageConfirmAction::DeleteForMe { msg_id } => {
                    start_delete_for_me(state, &confirm.conv_id, &msg_id, true, now_ms, out);
                    complete_unit(op_id, out);
                }
                MessageConfirmAction::DeleteMany { msg_ids } => {
                    let list = select_messages_in_window_order(state, &confirm.conv_id, &msg_ids);
                    start_delete_messages(state, &confirm.conv_id, list, now_ms, out);
                    complete_unit(op_id, out);
                }
                MessageConfirmAction::RecallMany { msg_ids } => {
                    start_recall_many(state, confirm.conv_id, msg_ids, now_ms, op_id, out);
                }
                // U7
                MessageConfirmAction::Pin {
                    msg_id,
                    replacing_ref,
                } => {
                    crate::reduce::pins::start_pin(
                        state,
                        &confirm.conv_id,
                        &msg_id,
                        replacing_ref,
                        op_id,
                        out,
                    );
                }
                MessageConfirmAction::Unpin { topic_ref } => {
                    crate::reduce::pins::start_unpin(
                        state,
                        &confirm.conv_id,
                        &topic_ref,
                        op_id,
                        out,
                    );
                }
            }
        }
        Command::AskMessageConfirm { confirm } => {
            ask_message_confirm(state, *confirm, out);
            complete_unit(op_id, out);
        }
        Command::SetStarred {
            conv_id,
            msg_id,
            on,
        } => {
            let persisted = handle_set_starred(state, &conv_id, &msg_id, on, out);
            complete_unit_after(op_id, persisted, out);
        }
        Command::UndoDelete => {
            if let Some((_conv_id, restored)) = state.actions.delete_undo.undo(out) {
                let snap = state.identity_snapshot();
                let mut changed = false;
                for item in restored {
                    if let Some(msg) = item.message
                        && matches!(
                            state.messages.merge_message(msg, None, &snap),
                            WindowChange::Changed(_)
                        )
                    {
                        changed = true;
                    }
                }
                if changed {
                    out.dirty.insert(DirtyKey::Messages);
                }
            }
            complete_unit(op_id, out);
        }
        Command::DismissDeleteUndo => {
            state.actions.delete_undo.dismiss(out);
            complete_unit(op_id, out);
        }
        Command::LoadAutoDelete => {
            out.effects.push(Effect::FetchAutoDeleteApi { op_id });
        }
        Command::SetAutoDelete {
            conv_id,
            ttl,
            now_ms,
        } => {
            if conv_id.is_empty() || state.actions.auto_delete_ttl(&conv_id) == ttl {
                complete_unit(op_id, out);
                return;
            }
            out.effects.push(Effect::UpdateAutoDeleteApi {
                conv_id,
                ttl,
                now_ms,
                op_id,
            });
        }
        Command::PruneExpiredMessages { conv_id, now_ms } => {
            let (next_expiry, deleted_any) = handle_prune_expired(state, &conv_id, now_ms, out);
            if let Some(id) = op_id {
                out.effects.push(Effect::CompleteOp {
                    op_id: id,
                    result: OpResult::OptI64(next_expiry),
                    after_store: deleted_any,
                });
            }
        }
        Command::RecordSeenReactionKeys { keys, persist } => {
            let persisted = state.actions.seen_reactions.record(&keys) && persist;
            if persisted {
                out.effects
                    .push(Effect::Store(StoreOp::SetPreferenceStrings {
                        key: PREF_SEEN_REACTION_EVENT_IDS.to_owned(),
                        values: state.actions.seen_reactions.ordered(),
                    }));
            }
            complete_unit_after(op_id, persisted, out);
        }
        _ => {}
    }
}

fn ask_message_confirm(
    state: &mut CoreState,
    confirm: MessageConfirmState,
    out: &mut ReduceOutput,
) {
    if state.conversations.open_conversation_id.as_deref() != Some(confirm.conv_id.as_str())
        || state.actions.message_confirm.is_some()
    {
        return;
    }
    state.actions.message_confirm = Some(confirm);
    out.dirty.insert(DirtyKey::MessageConfirm);
}

fn start_delete_for_me(
    state: &mut CoreState,
    conv_id: &str,
    msg_id: &str,
    confirmed: bool,
    now_ms: i64,
    out: &mut ReduceOutput,
) {
    let Some(msg) = state
        .messages
        .windows
        .get(conv_id)
        .and_then(|list| {
            list.iter()
                .find(|m| m.id == msg_id || (!m.client_id.is_empty() && m.client_id == msg_id))
        })
        .cloned()
    else {
        return;
    };
    if !confirmed && msg.menu.delete == Some(DeleteMode::ForMe) {
        let confirm_id = state.actions.next_id();
        ask_message_confirm(
            state,
            MessageConfirmState {
                id: confirm_id,
                conv_id: msg.conversation_id.clone(),
                action: MessageConfirmAction::DeleteForMe {
                    msg_id: msg.id.clone(),
                },
                title: "Xóa tin nhắn".to_owned(),
                message: "Tin nhắn sẽ chỉ bị xóa ở phía bạn.".to_owned(),
                ok: "Xóa".to_owned(),
                destructive: true,
            },
            out,
        );
        return;
    }
    start_delete_messages(state, &msg.conversation_id.clone(), vec![msg], now_ms, out);
}

fn start_delete_messages(
    state: &mut CoreState,
    conv_id: &str,
    list: Vec<ChatMessage>,
    now_ms: i64,
    out: &mut ReduceOutput,
) {
    if list.is_empty() || conv_id.is_empty() {
        return;
    }
    let ids: Vec<String> = list.iter().map(|m| m.id.clone()).collect();
    if matches!(
        state.messages.write_through_remove(conv_id, &ids),
        WindowChange::Changed(_)
    ) {
        out.dirty.insert(DirtyKey::Messages);
    }
    let items: Vec<DeleteUndoItem> = list
        .into_iter()
        .map(|m| DeleteUndoItem {
            conv_id: m.conversation_id.clone(),
            msg_id: m.id.clone(),
            cli_msg_id: m.client_id.clone(),
            sender_id: m.sender_id.clone(),
            message: Some(m),
        })
        .collect();
    state
        .actions
        .delete_undo
        .start_batch(conv_id.to_owned(), items, now_ms, out);
}

fn start_react(state: &mut CoreState, args: ReactStartArgs, out: &mut ReduceOutput) {
    if args.conv_id.is_empty() || args.msg_id.is_empty() {
        complete_unit(args.op_id, out);
        return;
    }
    let Some(initial_msg) = state
        .messages
        .windows
        .get(&args.conv_id)
        .and_then(|list| {
            list.iter().find(|m| {
                m.id == args.msg_id || (!m.client_id.is_empty() && m.client_id == args.msg_id)
            })
        })
        .cloned()
    else {
        complete_unit(args.op_id, out);
        return;
    };
    if initial_msg.kind == Kind::Recalled
        || initial_msg.status == Status::Sending
        || initial_msg.status == Status::Failed
    {
        complete_unit(args.op_id, out);
        return;
    }
    let busy_key = format!("{}|{}", args.conv_id, initial_msg.id);
    if !state.actions.reaction_busy_keys.insert(busy_key.clone()) {
        complete_unit(args.op_id, out);
        return;
    }
    let (spec_icon, spec_type) = reaction_spec(&args.emoji);
    if args.remove_all && !initial_msg.reactions.iter().any(|r| r.includes_me) {
        state.actions.reaction_busy_keys.remove(&busy_key);
        complete_unit(args.op_id, out);
        return;
    }
    let spec_type_str = spec_type.to_string();
    let already_mine = args.remove_all
        || initial_msg
            .reactions
            .iter()
            .any(|r| r.includes_me && r.icon.r#type == spec_type_str);
    let effective_type = if already_mine { -1 } else { spec_type };
    let effective_icon = if already_mine {
        String::new()
    } else {
        spec_icon.to_owned()
    };
    let msg_type = reaction_client_msg_type(&initial_msg.kind);

    let dispatch_args = ReactDispatchArgs {
        conv_id: args.conv_id.clone(),
        initial_msg_id: initial_msg.id.clone(),
        busy_key,
        effective_type,
        effective_icon,
        msg_type,
        now_ms: args.now_ms,
        op_id: args.op_id,
    };

    let trimmed_id = initial_msg.id.trim().to_owned();
    let trimmed_cli = initial_msg.client_id.trim().to_owned();
    if !trimmed_cli.is_empty() && !trimmed_id.is_empty() && trimmed_id != trimmed_cli {
        dispatch_react_after_id_resolution(state, dispatch_args, trimmed_id, trimmed_cli, out);
    } else {
        let resolve_id = state.actions.next_id();
        state
            .actions
            .pending_id_resolutions
            .insert(resolve_id, PendingIdResolution::React(dispatch_args));
        out.effects.push(Effect::ResolveMessageIds {
            resolve_id,
            conv_id: args.conv_id,
            msg_id: initial_msg.id,
            cli_msg_id: initial_msg.client_id,
        });
    }
}

fn dispatch_react_after_id_resolution(
    state: &mut CoreState,
    args: ReactDispatchArgs,
    effective_msg_id: String,
    resolved_cli_id: String,
    out: &mut ReduceOutput,
) {
    let my_uid = state
        .session
        .profile
        .as_ref()
        .map_or("", |p| p.user_id.as_str())
        .to_owned();
    let mut previous_reactions = Vec::new();
    let eff_type_str = args.effective_type.to_string();
    if let Some(list) = state.messages.windows.get_mut(&args.conv_id)
        && let Some(idx) = list.iter().position(|m| {
            m.id == args.initial_msg_id
                || m.id == effective_msg_id
                || (!resolved_cli_id.is_empty() && m.client_id == resolved_cli_id)
        })
    {
        previous_reactions = list[idx].reactions.clone();
        mutate_reactions(
            &mut list[idx].reactions,
            &ReactionMutation {
                actor_uid: &my_uid,
                my_uid: &my_uid,
                is_me: true,
                r_type: &eff_type_str,
                r_icon: &args.effective_icon,
                allow_duplicate_same_user: true,
            },
            |_| "Bạn".to_owned(),
        );
        let updated = list[idx].clone();
        state.messages.record_window_op(
            args.conv_id.clone(),
            PendingWindowOp::Patch {
                upserts: vec![updated],
                removed_ids: Vec::new(),
            },
        );
        out.dirty.insert(DirtyKey::Messages);
    }

    let react_id = state.actions.next_id();
    state.actions.pending_reactions.push_tagged(
        react_id,
        PendingLocalReaction {
            conv_id: args.conv_id.clone(),
            msg_id: effective_msg_id.clone(),
            cli_msg_id: resolved_cli_id.clone(),
            r_type: args.effective_type as i32,
            react_client_id: String::new(),
            created_at_ms: args.now_ms,
        },
        args.now_ms,
    );
    state.actions.in_flight_reacts.insert(
        react_id,
        InFlightReact {
            conv_id: args.conv_id.clone(),
            initial_msg_id: args.initial_msg_id,
            busy_key: args.busy_key,
            effective_msg_id: effective_msg_id.clone(),
            resolved_cli_id: resolved_cli_id.clone(),
            effective_type: args.effective_type,
            msg_type: args.msg_type,
            previous_reactions,
            op_id: args.op_id,
        },
    );
    out.effects.push(Effect::SendReactionApi {
        react_id,
        conv_id: args.conv_id,
        msg_id: effective_msg_id,
        cli_msg_id: resolved_cli_id,
        r_icon: args.effective_icon,
        r_type: args.effective_type,
        msg_type: args.msg_type,
    });
}

fn handle_react_done(
    state: &mut CoreState,
    react_id: u64,
    final_react_client_id: String,
    error: Option<ReactFailure>,
    out: &mut ReduceOutput,
) {
    let Some(flight) = state.actions.in_flight_reacts.remove(&react_id) else {
        return;
    };
    state.actions.reaction_busy_keys.remove(&flight.busy_key);
    match error {
        None => {
            state
                .actions
                .pending_reactions
                .update_tag_client_id(react_id, &final_react_client_id);
            let seen_keys = local_reaction_seen_keys(
                &flight.conv_id,
                &flight.effective_msg_id,
                &flight.resolved_cli_id,
                &final_react_client_id,
                flight.effective_type as i32,
            );
            let mut store_written = false;
            if state.actions.seen_reactions.record(&seen_keys) {
                out.effects
                    .push(Effect::Store(StoreOp::SetPreferenceStrings {
                        key: PREF_SEEN_REACTION_EVENT_IDS.to_owned(),
                        values: state.actions.seen_reactions.ordered(),
                    }));
                store_written = true;
            }
            if let Some(current) = state
                .messages
                .windows
                .get(&flight.conv_id)
                .and_then(|list| {
                    list.iter().find(|m| {
                        m.id == flight.effective_msg_id
                            || m.id == flight.initial_msg_id
                            || (!flight.resolved_cli_id.is_empty()
                                && m.client_id == flight.resolved_cli_id)
                    })
                })
                && let Some(wire_stored) = encode_chat_message(current, &current.client_id)
            {
                out.effects.push(Effect::Store(StoreOp::SaveMessages {
                    rows: vec![to_db_stored(&wire_stored)],
                    preserve_existing_reactions: false,
                }));
                store_written = true;
            }
            complete_unit_after(flight.op_id, store_written, out);
        }
        Some(err) => {
            state.actions.pending_reactions.remove_by_tag(react_id);
            if let Some(list) = state.messages.windows.get_mut(&flight.conv_id)
                && let Some(idx) = list.iter().position(|m| {
                    m.id == flight.effective_msg_id
                        || m.id == flight.initial_msg_id
                        || (!flight.resolved_cli_id.is_empty()
                            && m.client_id == flight.resolved_cli_id)
                })
            {
                list[idx].reactions = flight.previous_reactions;
                let restored = list[idx].clone();
                state.messages.record_window_op(
                    flight.conv_id.clone(),
                    PendingWindowOp::Patch {
                        upserts: vec![restored],
                        removed_ids: Vec::new(),
                    },
                );
                out.dirty.insert(DirtyKey::Messages);
            }
            out.effects.push(Effect::EngineLog(err.log_line(
                &flight.effective_msg_id,
                &flight.resolved_cli_id,
                flight.msg_type,
            )));
            out.effects.push(Effect::Host(HostCall::ShowCard {
                conv_id: flight.conv_id,
                text: REACT_FAILED_CARD_TEXT.to_owned(),
            }));
            complete_unit(flight.op_id, out);
        }
    }
}

fn start_recall(state: &mut CoreState, args: RecallStartArgs, out: &mut ReduceOutput) {
    if args.conv_id.is_empty()
        || state.session.self_conversation_id.as_deref() == Some(args.conv_id.as_str())
    {
        finish_recall_step(state, args.op_id, args.recall_many_id, false, out);
        return;
    }
    let Some(msg) = state
        .messages
        .windows
        .get(&args.conv_id)
        .and_then(|list| {
            list.iter().find(|m| {
                m.id == args.msg_id || (!m.client_id.is_empty() && m.client_id == args.msg_id)
            })
        })
        .cloned()
    else {
        finish_recall_step(state, args.op_id, args.recall_many_id, false, out);
        return;
    };
    if !msg.is_mine
        || msg.kind == Kind::Recalled
        || msg.status == Status::Sending
        || msg.status == Status::Failed
    {
        finish_recall_step(state, args.op_id, args.recall_many_id, false, out);
        return;
    }
    if is_over_recall_window(msg.date_ms, args.now_ms) {
        out.effects.push(Effect::Host(HostCall::ShowCard {
            conv_id: args.conv_id,
            text: RECALL_OVER_24H_CARD_TEXT.to_owned(),
        }));
        finish_recall_step(state, args.op_id, args.recall_many_id, false, out);
        return;
    }
    let busy_key = format!("{}|{}|recall", args.conv_id, msg.id);
    if !state.actions.recall_busy_keys.insert(busy_key.clone()) {
        finish_recall_step(state, args.op_id, args.recall_many_id, false, out);
        return;
    }
    let primary_is_e2ee = msg.is_e2ee;
    let can_try_alt = primary_is_e2ee
        || is_group_id(&args.conv_id)
        || args
            .is_e2ee_thread
            .unwrap_or_else(|| state.send.e2ee_threads.contains(&args.conv_id));

    let dispatch_args = RecallDispatchArgs {
        conv_id: args.conv_id.clone(),
        initial_msg_id: msg.id.clone(),
        busy_key,
        primary_is_e2ee,
        can_try_alt,
        op_id: args.op_id,
        recall_many_id: args.recall_many_id,
    };

    let trimmed_id = msg.id.trim().to_owned();
    let trimmed_cli = msg.client_id.trim().to_owned();
    if !trimmed_cli.is_empty() && !trimmed_id.is_empty() && trimmed_id != trimmed_cli {
        dispatch_recall_after_id_resolution(state, dispatch_args, trimmed_id, trimmed_cli, out);
    } else {
        let resolve_id = state.actions.next_id();
        state
            .actions
            .pending_id_resolutions
            .insert(resolve_id, PendingIdResolution::Recall(dispatch_args));
        out.effects.push(Effect::ResolveMessageIds {
            resolve_id,
            conv_id: args.conv_id,
            msg_id: msg.id,
            cli_msg_id: msg.client_id,
        });
    }
}

fn dispatch_recall_after_id_resolution(
    state: &mut CoreState,
    args: RecallDispatchArgs,
    effective_msg_id: String,
    resolved_cli_id: String,
    out: &mut ReduceOutput,
) {
    let recall_id = state.actions.next_id();
    state.actions.in_flight_recalls.insert(
        recall_id,
        InFlightRecall {
            conv_id: args.conv_id.clone(),
            busy_key: args.busy_key,
            effective_msg_id: effective_msg_id.clone(),
            resolved_cli_id: resolved_cli_id.clone(),
            primary_is_e2ee: args.primary_is_e2ee,
            op_id: args.op_id,
            recall_many_id: args.recall_many_id,
        },
    );
    out.effects.push(Effect::RecallMessageApi {
        recall_id,
        conv_id: args.conv_id,
        msg_id: effective_msg_id,
        cli_msg_id: resolved_cli_id,
        primary_is_e2ee: args.primary_is_e2ee,
        can_try_alt: args.can_try_alt,
    });
}

fn handle_recall_done(
    state: &mut CoreState,
    recall_id: u64,
    retried_alt: bool,
    error: Option<RecallFailure>,
    out: &mut ReduceOutput,
) {
    let Some(flight) = state.actions.in_flight_recalls.remove(&recall_id) else {
        return;
    };
    state.actions.recall_busy_keys.remove(&flight.busy_key);
    match error {
        None => {
            out.effects.push(Effect::Host(HostCall::ApplyRemoteRecall {
                conv_id: flight.conv_id,
                msg_id: flight.effective_msg_id,
                cli_msg_id: flight.resolved_cli_id,
                update_conversation_preview: true,
                persist_conversations: true,
                op_id: flight.op_id,
                recall_many_id: flight.recall_many_id,
            }));
        }
        Some(failure) => {
            out.effects.push(Effect::EngineLog(recall_error_log_line(
                &failure,
                flight.primary_is_e2ee,
                retried_alt,
                &flight.effective_msg_id,
                &flight.resolved_cli_id,
            )));
            out.effects.push(Effect::Host(HostCall::ShowCard {
                conv_id: flight.conv_id,
                text: recall_error_card_text(&failure),
            }));
            finish_recall_step(state, flight.op_id, flight.recall_many_id, false, out);
        }
    }
}

fn start_recall_many(
    state: &mut CoreState,
    conv_id: String,
    msg_ids: Vec<String>,
    now_ms: i64,
    op_id: Option<u64>,
    out: &mut ReduceOutput,
) {
    let mut queue: VecDeque<String> = msg_ids.into_iter().collect();
    let Some(first_id) = queue.pop_front() else {
        complete_unit(op_id, out);
        return;
    };
    let batch_id = state.actions.next_id();
    state.actions.in_flight_recall_many.insert(
        batch_id,
        InFlightRecallMany {
            conv_id: conv_id.clone(),
            remaining_msg_ids: queue,
            now_ms,
            op_id,
        },
    );
    start_recall(
        state,
        RecallStartArgs {
            conv_id,
            msg_id: first_id,
            is_e2ee_thread: None,
            now_ms,
            op_id: None,
            recall_many_id: Some(batch_id),
        },
        out,
    );
}

fn finish_recall_step(
    state: &mut CoreState,
    op_id: Option<u64>,
    recall_many_id: Option<u64>,
    after_store: bool,
    out: &mut ReduceOutput,
) {
    if let Some(batch_id) = recall_many_id {
        let next_step = state
            .actions
            .in_flight_recall_many
            .get_mut(&batch_id)
            .and_then(|b| {
                b.remaining_msg_ids
                    .pop_front()
                    .map(|mid| (b.conv_id.clone(), mid, b.now_ms))
            });
        if let Some((conv_id, msg_id, now_ms)) = next_step {
            start_recall(
                state,
                RecallStartArgs {
                    conv_id,
                    msg_id,
                    is_e2ee_thread: None,
                    now_ms,
                    op_id: None,
                    recall_many_id: Some(batch_id),
                },
                out,
            );
        } else if let Some(done) = state.actions.in_flight_recall_many.remove(&batch_id) {
            complete_unit_after(done.op_id, after_store, out);
        }
    } else {
        complete_unit_after(op_id, after_store, out);
    }
}

fn handle_ids_resolved(
    state: &mut CoreState,
    resolve_id: u64,
    effective_msg_id: String,
    resolved_cli_id: String,
    out: &mut ReduceOutput,
) {
    let Some(pending) = state.actions.pending_id_resolutions.remove(&resolve_id) else {
        return;
    };
    let (conv_id, initial_msg_id) = match &pending {
        PendingIdResolution::React(a) => (a.conv_id.clone(), a.initial_msg_id.clone()),
        PendingIdResolution::Recall(a) => (a.conv_id.clone(), a.initial_msg_id.clone()),
        PendingIdResolution::Pin {
            conv_id,
            initial_msg_id,
            ..
        } => (conv_id.clone(), initial_msg_id.clone()),
    };

    if !effective_msg_id.is_empty()
        && let Some(list) = state.messages.windows.get_mut(&conv_id)
        && let Some(idx) = list.iter().position(|m| {
            m.id == initial_msg_id
                || (!resolved_cli_id.is_empty() && m.client_id == resolved_cli_id)
        })
    {
        let old_id = list[idx].id.clone();
        if old_id != effective_msg_id || list[idx].client_id.is_empty() {
            list[idx].id = effective_msg_id.clone();
            if list[idx].client_id.is_empty() && !resolved_cli_id.is_empty() {
                list[idx].client_id = resolved_cli_id.clone();
            }
            let updated = list[idx].clone();
            let removed = if old_id != effective_msg_id {
                vec![old_id]
            } else {
                Vec::new()
            };
            state.messages.record_window_op(
                conv_id,
                PendingWindowOp::Patch {
                    upserts: vec![updated],
                    removed_ids: removed,
                },
            );
            out.dirty.insert(DirtyKey::Messages);
        }
    }

    match pending {
        PendingIdResolution::React(args) => {
            dispatch_react_after_id_resolution(state, args, effective_msg_id, resolved_cli_id, out);
        }
        PendingIdResolution::Recall(args) => {
            dispatch_recall_after_id_resolution(
                state,
                args,
                effective_msg_id,
                resolved_cli_id,
                out,
            );
        }
        PendingIdResolution::Pin { pin_op_id, .. } => {
            crate::reduce::pins::on_pin_ids_resolved(
                state,
                pin_op_id,
                effective_msg_id,
                resolved_cli_id,
                out,
            );
        }
    }
}

fn handle_set_starred(
    state: &mut CoreState,
    conv_id: &str,
    msg_id: &str,
    on: bool,
    out: &mut ReduceOutput,
) -> bool {
    let existing_star = state
        .messages
        .windows
        .get(conv_id)
        .and_then(|list| list.iter().find(|m| m.id == msg_id))
        .and_then(|m| m.menu.star);
    if on && existing_star == Some(StarMode::Blocked) {
        out.effects.push(Effect::Host(HostCall::ShowCard {
            conv_id: conv_id.to_owned(),
            text: STAR_BLOCKED_CARD_TEXT.to_owned(),
        }));
        return false;
    }

    let mut persisted = false;
    if let Some(list) = state.messages.windows.get_mut(conv_id)
        && let Some(idx) = list.iter().position(|m| m.id == msg_id)
    {
        list[idx].menu.starred = on;
        list[idx].menu.star = Some(if on { StarMode::Unstar } else { StarMode::Star });
        let updated = list[idx].clone();
        state.messages.record_window_op(
            conv_id.to_owned(),
            PendingWindowOp::Patch {
                upserts: vec![updated.clone()],
                removed_ids: Vec::new(),
            },
        );
        out.dirty.insert(DirtyKey::Messages);

        let set_changed = if on {
            state.actions.starred_ids.insert(msg_id.to_owned())
        } else {
            state.actions.starred_ids.remove(msg_id)
        };
        if set_changed {
            out.dirty.insert(DirtyKey::StarredIds);
        }
        out.effects
            .push(Effect::Store(StoreOp::SetPreferenceStrings {
                key: PREF_STARRED_IDS.to_owned(),
                values: state.actions.starred_ids.iter().cloned().collect(),
            }));
        if let Some(wire_stored) = encode_chat_message(&updated, &updated.client_id) {
            out.effects.push(Effect::Store(StoreOp::SaveMessages {
                rows: vec![to_db_stored(&wire_stored)],
                preserve_existing_reactions: true,
            }));
        }
        persisted = true;
    }
    out.effects.push(Effect::Host(HostCall::ShowCard {
        conv_id: conv_id.to_owned(),
        text: if on {
            STAR_ADDED_CARD_TEXT.to_owned()
        } else {
            STAR_REMOVED_CARD_TEXT.to_owned()
        },
    }));
    persisted
}

fn handle_remote_reaction(
    state: &mut CoreState,
    req: &RemoteReactionInput<'_>,
    out: &mut ReduceOutput,
) {
    let trimmed_conv = req.conv_id.trim();
    let trimmed_msg = req.msg_id.trim();
    let trimmed_cli = req.cli_msg_id.trim();
    let trimmed_type = req.r_type.trim();
    let trimmed_icon = req.r_icon.trim();
    let trimmed_event_id = req.event_id.trim();
    let trimmed_react_cli = req.react_client_id.trim();
    let trimmed_wire_sender_name = req.sender_name.trim();

    if trimmed_conv.is_empty()
        || (trimmed_msg.is_empty() && trimmed_cli.is_empty())
        || (trimmed_type.is_empty() && trimmed_icon.is_empty())
    {
        return;
    }

    let sanitized_conv = dedupe_conv_id(trimmed_conv);
    let r_type_num = trimmed_type.parse::<i32>().unwrap_or(0);
    let candidate_keys = reaction_dedupe_keys(
        trimmed_conv,
        trimmed_msg,
        trimmed_cli,
        r_type_num,
        trimmed_event_id,
        trimmed_react_cli,
    );
    if state.actions.seen_reactions.contains_any(&candidate_keys) {
        return;
    }
    if state.actions.seen_reactions.record(&candidate_keys) {
        out.effects
            .push(Effect::Store(StoreOp::SetPreferenceStrings {
                key: PREF_SEEN_REACTION_EVENT_IDS.to_owned(),
                values: state.actions.seen_reactions.ordered(),
            }));
    }

    let my_uid = state
        .session
        .profile
        .as_ref()
        .map_or("", |p| p.user_id.as_str())
        .to_owned();
    let sanitized_my_uid =
        sanitize_profile_uid(&my_uid).unwrap_or_else(|| strip_user_prefix(&my_uid).to_owned());
    let clean_sender = strip_user_prefix(req.sender_id);
    if clean_sender == "-1" {
        return;
    }
    let sanitized_sender = sanitize_profile_uid(&clean_sender);
    let is_me = (!my_uid.is_empty()
        && (clean_sender == my_uid
            || sanitized_sender.as_deref() == Some(sanitized_my_uid.as_str())))
        || clean_sender == "0"
        || clean_sender.is_empty();

    if !is_me {
        let canonical_actor = sanitized_sender.as_deref().unwrap_or(&clean_sender);
        if !canonical_actor.is_empty()
            && !trimmed_wire_sender_name.is_empty()
            && trimmed_wire_sender_name != UNKNOWN_NAME
            && trimmed_wire_sender_name != canonical_actor
        {
            let snap = state.identity_snapshot();
            let existing = snap.lookup_person(canonical_actor);
            let should_cache = match &existing {
                None => true,
                Some(e) => e.name.is_empty() || e.name == canonical_actor,
            };
            if should_cache {
                let existing_avatar = existing
                    .map(|e| e.avatar)
                    .or_else(|| {
                        state
                            .conversations
                            .identities
                            .cached_profiles
                            .get(canonical_actor)
                            .map(|p| p.avatar.clone())
                    })
                    .unwrap_or_default();
                state.conversations.identities.cached_profiles.insert(
                    canonical_actor.to_owned(),
                    CachedProfile {
                        name: trimmed_wire_sender_name.to_owned(),
                        avatar: existing_avatar,
                    },
                );
                out.dirty.insert(DirtyKey::CachedProfiles);
            }
        }
    }

    let r_type_i32 = trimmed_type.parse::<i32>().unwrap_or(0);
    if is_me
        && state.actions.pending_reactions.consume_matching(
            req.now_ms,
            trimmed_conv,
            trimmed_msg,
            trimmed_cli,
            r_type_i32,
            trimmed_react_cli,
        )
    {
        return;
    } else {
        state.actions.pending_reactions.prune(req.now_ms);
    }

    let matches_msg = |m: &ChatMessage| -> bool {
        (!trimmed_msg.is_empty() && (m.id == trimmed_msg || m.client_id == trimmed_msg))
            || (!trimmed_cli.is_empty() && (m.id == trimmed_cli || m.client_id == trimmed_cli))
    };

    let memory_conv_key: Option<String> = if state
        .messages
        .windows
        .get(trimmed_conv)
        .is_some_and(|list| list.iter().any(matches_msg))
    {
        Some(trimmed_conv.to_owned())
    } else if sanitized_conv != trimmed_conv
        && state
            .messages
            .windows
            .get(&sanitized_conv)
            .is_some_and(|list| list.iter().any(matches_msg))
    {
        Some(sanitized_conv.clone())
    } else {
        None
    };

    let snap = state.identity_snapshot();
    if let Some(conv_key) = memory_conv_key {
        if let Some(list) = state.messages.windows.get_mut(&conv_key)
            && let Some(idx) = list.iter().position(matches_msg)
        {
            mutate_reactions(
                &mut list[idx].reactions,
                &ReactionMutation {
                    actor_uid: &clean_sender,
                    my_uid: &my_uid,
                    is_me,
                    r_type: trimmed_type,
                    r_icon: trimmed_icon,
                    allow_duplicate_same_user: !trimmed_event_id.is_empty(),
                },
                |uid| snap.lookup_person(uid).map(|p| p.name).unwrap_or_default(),
            );
            let updated = list[idx].clone();
            state.messages.record_window_op(
                conv_key,
                PendingWindowOp::Patch {
                    upserts: vec![updated.clone()],
                    removed_ids: Vec::new(),
                },
            );
            out.dirty.insert(DirtyKey::Messages);
            if let Some(wire_stored) = encode_chat_message(&updated, &updated.client_id) {
                out.effects.push(Effect::Store(StoreOp::SaveMessages {
                    rows: vec![to_db_stored(&wire_stored)],
                    preserve_existing_reactions: false,
                }));
            }
        }
        return;
    }

    let conv_candidates = if sanitized_conv == trimmed_conv {
        vec![trimmed_conv.to_owned()]
    } else {
        vec![trimmed_conv.to_owned(), sanitized_conv]
    };
    out.effects
        .push(Effect::Store(StoreOp::ApplyRemoteReactionInStore {
            conv_candidates,
            msg_id: trimmed_msg.to_owned(),
            cli_msg_id: trimmed_cli.to_owned(),
            actor_uid: clean_sender.to_owned(),
            my_uid,
            is_me,
            r_type: trimmed_type.to_owned(),
            r_icon: trimmed_icon.to_owned(),
            allow_duplicate_same_user: !trimmed_event_id.is_empty(),
            snap: Box::new(snap),
        }));
}

fn handle_remote_recall_approved(
    state: &mut CoreState,
    req: RemoteRecallInput,
    out: &mut ReduceOutput,
) {
    let target_id = if !req.msg_id.is_empty() {
        req.msg_id.clone()
    } else {
        req.cli_msg_id.clone()
    };
    if req.conv_id.is_empty() || target_id.is_empty() {
        finish_recall_step(state, req.op_id, req.recall_many_id, false, out);
        return;
    }

    let outcome = state
        .messages
        .apply_recall_in_window(&req.conv_id, &req.msg_id, &req.cli_msg_id);
    if outcome.window_changed {
        out.dirty.insert(DirtyKey::Messages);
    }
    if let Some(recalled_id) = &outcome.recalled_id
        && state.actions.starred_ids.remove(recalled_id)
    {
        out.dirty.insert(DirtyKey::StarredIds);
        out.effects
            .push(Effect::Store(StoreOp::SetPreferenceStrings {
                key: PREF_STARRED_IDS.to_owned(),
                values: state.actions.starred_ids.iter().cloned().collect(),
            }));
    }

    out.effects
        .push(Effect::Store(StoreOp::MarkRecalledAndCheckLatest {
            conv_id: req.conv_id,
            target_id,
            cli_msg_id: req.cli_msg_id,
            found_in_memory: outcome.found_in_memory,
            recalled_last: outcome.recalled_last,
            update_conversation_preview: req.update_conversation_preview,
            persist_conversations: req.persist_conversations,
            op_id: req.op_id,
            recall_many_id: req.recall_many_id,
        }));
}

fn handle_remote_recall_store_done(
    state: &mut CoreState,
    req: RemoteRecallStoreInput,
    out: &mut ReduceOutput,
) {
    let mut persisted_conv = false;
    if req.update_conversation_preview
        && let Some((target_date_ms, from_me)) = req.recalled_last
    {
        let ov = ConvPreviewOverride {
            conv_id: req.conv_id,
            target_date_ms,
            preview: Some(ConversationPreview {
                text: "Tin nhắn đã được thu hồi".to_owned(),
                date_ms: Some(target_date_ms),
                from_me,
            }),
        };
        apply_batch_delta(
            state,
            BatchApplyDelta {
                applied_count: 0,
                updates: Vec::new(),
                preview_overrides: vec![ov],
                persist_conversations: req.persist_conversations,
            },
            out,
        );
        persisted_conv = req.persist_conversations;
    }
    finish_recall_step(state, req.op_id, req.recall_many_id, persisted_conv, out);
}

fn handle_remote_delete_approved(
    state: &mut CoreState,
    conv_id: String,
    msg_id: String,
    cli_msg_id: String,
    update_conversation_preview: bool,
    persist_conversations: bool,
    out: &mut ReduceOutput,
) {
    let target_id = if !msg_id.is_empty() {
        msg_id.as_str()
    } else {
        cli_msg_id.as_str()
    };
    if conv_id.is_empty() || target_id.is_empty() {
        return;
    }

    let outcome = state
        .messages
        .apply_delete_in_window(&conv_id, &msg_id, &cli_msg_id);
    if outcome.window_changed {
        out.dirty.insert(DirtyKey::Messages);
    }

    out.effects
        .push(Effect::Store(StoreOp::DeleteMessageAndCheckLatest {
            conv_id,
            msg_id,
            cli_msg_id,
            deleted_ts_ms: outcome.deleted_ts_ms,
            mem_latest: outcome.mem_latest,
            update_conversation_preview,
            persist_conversations,
        }));
}

fn handle_remote_delete_store_done(
    state: &mut CoreState,
    req: RemoteDeleteStoreInput,
    out: &mut ReduceOutput,
) {
    let Some(target_ms) = req.deleted_ts_ms else {
        return;
    };
    let best_remaining = match (req.mem_latest, req.store_latest) {
        (Some(a), Some(b)) => {
            if a.date_ms.unwrap_or(0) >= b.date_ms.unwrap_or(0) {
                Some(a)
            } else {
                Some(b)
            }
        }
        (Some(a), None) => Some(a),
        (None, Some(b)) => Some(b),
        (None, None) => None,
    };
    if best_remaining
        .as_ref()
        .and_then(|p| p.date_ms)
        .is_some_and(|d| d > target_ms)
    {
        return;
    }
    if req.update_conversation_preview {
        let ov = ConvPreviewOverride {
            conv_id: req.conv_id,
            target_date_ms: target_ms,
            preview: best_remaining,
        };
        apply_batch_delta(
            state,
            BatchApplyDelta {
                applied_count: 0,
                updates: Vec::new(),
                preview_overrides: vec![ov],
                persist_conversations: req.persist_conversations,
            },
            out,
        );
    }
}

fn handle_prune_expired(
    state: &mut CoreState,
    conv_id: &str,
    now_ms: i64,
    out: &mut ReduceOutput,
) -> (Option<i64>, bool) {
    let Some(list) = state.messages.windows.get(conv_id) else {
        state.actions.last_prune_next_expiry_ms = None;
        return (None, false);
    };
    if !list.iter().any(|m| m.ttl_ms > 0) {
        state.actions.last_prune_next_expiry_ms = None;
        return (None, false);
    }
    let expired_ids: Vec<String> = list
        .iter()
        .filter(|m| m.ttl_ms > 0 && m.date_ms.saturating_add(m.ttl_ms) <= now_ms)
        .map(|m| m.id.clone())
        .collect();
    let deleted_any = !expired_ids.is_empty();
    if deleted_any {
        if matches!(
            state.messages.write_through_remove(conv_id, &expired_ids),
            WindowChange::Changed(_)
        ) {
            out.dirty.insert(DirtyKey::Messages);
        }
        for id in expired_ids {
            out.effects.push(Effect::Store(StoreOp::DeleteMessage {
                conv_id: conv_id.to_owned(),
                id,
            }));
        }
    }
    let next_expiry = state.messages.windows.get(conv_id).and_then(|remaining| {
        remaining
            .iter()
            .filter(|m| m.ttl_ms > 0)
            .map(|m| m.date_ms.saturating_add(m.ttl_ms))
            .min()
    });
    state.actions.last_prune_next_expiry_ms = next_expiry;
    (next_expiry, deleted_any)
}

fn apply_auto_delete_loaded(
    state: &mut CoreState,
    outcome: Option<AutoDeleteFetchOutcome>,
    out: &mut ReduceOutput,
) {
    match outcome {
        Some(fetched) => {
            out.effects.push(Effect::EngineLog(fetched.log_line()));
            state.send.auto_delete_ttl_ms = fetched.settings.clone();
            state.actions.auto_delete = Some(fetched.settings);
            out.dirty.insert(DirtyKey::AutoDelete);
        }
        None => {
            if state.actions.auto_delete.is_none() {
                state.actions.auto_delete = Some(BTreeMap::new());
                out.dirty.insert(DirtyKey::AutoDelete);
            }
        }
    }
}

fn apply_auto_delete_updated(
    state: &mut CoreState,
    conv_id: &str,
    ttl: i64,
    now_ms: i64,
    error_type: Option<String>,
    out: &mut ReduceOutput,
) -> bool {
    if let Some(err_type) = error_type {
        out.effects.push(Effect::EngineLog(format!(
            "autodelete: update failed {err_type}"
        )));
        out.effects.push(Effect::Host(HostCall::ShowCard {
            conv_id: conv_id.to_owned(),
            text: AUTO_DELETE_FAILED_CARD_TEXT.to_owned(),
        }));
        return false;
    }
    let map = state.actions.auto_delete.get_or_insert_with(BTreeMap::new);
    if ttl > 0 {
        map.insert(conv_id.to_owned(), ttl);
        state
            .send
            .auto_delete_ttl_ms
            .insert(conv_id.to_owned(), ttl);
    } else {
        map.remove(conv_id);
        state.send.auto_delete_ttl_ms.remove(conv_id);
    }
    out.dirty.insert(DirtyKey::AutoDelete);

    let notice = auto_delete_system_notice(conv_id, ttl, now_ms);
    let msg = ChatMessage {
        id: notice.id.clone(),
        conversation_id: conv_id.to_owned(),
        sender_id: String::new(),
        sender_name: String::new(),
        sender_avatar: None,
        is_mine: false,
        kind: Kind::System,
        text: notice.text.clone(),
        date_ms: now_ms,
        status: Status::Sent,
        quote: None,
        reactions: Vec::new(),
        is_e2ee: false,
        client_id: String::new(),
        mentions: Vec::new(),
        text_styles: Vec::new(),
        ttl_ms: 0,
        urgency: 0,
        card_buttons: Vec::new(),
        suggests_stickers: false,
        fallback_urls: Vec::new(),
        menu: MessageMenu::default(),
    };
    let snap = state.identity_snapshot();
    if matches!(
        state.messages.merge_message(msg.clone(), None, &snap),
        WindowChange::Changed(_)
    ) {
        out.dirty.insert(DirtyKey::Messages);
    }
    if let Some(wire_stored) = encode_chat_message(&msg, &msg.id) {
        out.effects.push(Effect::Store(StoreOp::SaveMessages {
            rows: vec![to_db_stored(&wire_stored)],
            preserve_existing_reactions: true,
        }));
    }
    let preview_input = MessagePreviewInput::from_chat_message(&msg);
    let _ = apply_message_preview_update(state, &preview_input, false, out);
    true
}

fn complete_unit(op_id: Option<u64>, out: &mut ReduceOutput) {
    complete_unit_after(op_id, false, out);
}

fn complete_unit_after(op_id: Option<u64>, after_store: bool, out: &mut ReduceOutput) {
    if let Some(id) = op_id {
        out.effects.push(Effect::CompleteOp {
            op_id: id,
            result: OpResult::Unit,
            after_store,
        });
    }
}

#[cfg(test)]
mod tests {
    use olaz_net::{NetworkErrorKind, ZaloSessionError};
    use serde_json::json;

    use super::*;
    use crate::reduce::reduce;
    use crate::state::CoreState;

    #[test]
    fn remote_delete_match_policy_defaults_to_approved_id_and_client_id() {
        assert_eq!(
            REMOTE_DELETE_MATCH_POLICY,
            RemoteDeleteMatchPolicy::IdAndClientId
        );

        // Matches by msg.id under both policies.
        assert!(remote_delete_matches(
            RemoteDeleteMatchPolicy::LegacyIdOnly,
            "9001",
            "c9001",
            "9001",
            "c9001",
        ));
        assert!(remote_delete_matches(
            RemoteDeleteMatchPolicy::IdAndClientId,
            "9001",
            "c9001",
            "9001",
            "c9001",
        ));

        // Message stored under provisional clientId, deleted by server globalDelMsgId + cliMsgId:
        // LegacyIdOnly misses when msg.id is different and only msg.client_id matches target_cli.
        assert!(!remote_delete_matches(
            RemoteDeleteMatchPolicy::LegacyIdOnly,
            "local-99",
            "c9002",
            "9002",
            "c9002",
        ));
        assert!(remote_delete_matches(
            RemoteDeleteMatchPolicy::IdAndClientId,
            "local-99",
            "c9002",
            "9002",
            "c9002",
        ));

        // SQLite delete ids under both policies.
        assert_eq!(
            remote_delete_store_ids(RemoteDeleteMatchPolicy::LegacyIdOnly, "9002", "c9002"),
            vec!["9002".to_owned()]
        );
        assert_eq!(
            remote_delete_store_ids(RemoteDeleteMatchPolicy::IdAndClientId, "9002", "c9002"),
            vec!["9002".to_owned(), "c9002".to_owned()]
        );
        // Deduplicates when target_msg == target_cli.
        assert_eq!(
            remote_delete_store_ids(RemoteDeleteMatchPolicy::IdAndClientId, "9002", "9002"),
            vec!["9002".to_owned()]
        );
    }

    #[test]
    fn find_server_msg_id_handles_nested_strings_lists_priority_keys_and_guards() {
        // Empty target returns None.
        assert_eq!(
            find_server_msg_id(&json!({"cliMsgId": "1", "msgId": "2"}), "  "),
            None
        );

        // Direct object match with integer/string ids and globalMsgId / minGlobalMsgId fallbacks.
        let direct = json!({
            "data": {
                "msgs": [
                    {"cliMsgId": "c1", "msgId": 0},
                    {"cliMsgId": "c1", "globalMsgId": "c1"},
                    {"clientId": "c1", "minGlobalMsgId": 9007001}
                ]
            }
        });
        assert_eq!(
            find_server_msg_id(&direct, " c1 "),
            Some("9007001".to_owned())
        );

        // Nested JSON string inside `"data"` -> `"groupMsgs"` array -> stringified item.
        let nested_str = json!({
            "data": "{\"groupMsgs\": [\"{\\\"cliMsgId\\\": \\\"c900\\\", \\\"msgId\\\": \\\"8888777766665555444\\\"}\"]}"
        });
        assert_eq!(
            find_server_msg_id(&nested_str, "c900"),
            Some("8888777766665555444".to_owned())
        );

        // Non-priority custom key recursion.
        let custom_key = json!({
            "extra_wrapper": {
                "entries": [
                    {"cliMsgId": "c42", "globalMsgId": "77742"}
                ]
            }
        });
        assert_eq!(
            find_server_msg_id(&custom_key, "c42"),
            Some("77742".to_owned())
        );

        // Priority key `"msgs"` checked before arbitrary key `"aaa"`.
        let priority = json!({
            "aaa": {"cliMsgId": "c1", "msgId": "wrong"},
            "msgs": [{"cliMsgId": "c1", "msgId": "right"}]
        });
        assert_eq!(
            find_server_msg_id(&priority, "c1"),
            Some("right".to_owned())
        );

        // Depth limit (depth >= 8 stops recursion).
        let mut deep = json!({"cliMsgId": "c_deep", "msgId": "99999"});
        for _ in 0..8 {
            deep = json!({"data": deep});
        }
        assert_eq!(find_server_msg_id(&deep, "c_deep"), None);
    }

    #[test]
    fn reaction_dedupe_keys_and_local_keys_match_golden_cases() {
        // Matches `remote_reaction_dedupe` and `remote_reaction_conv_sanitize`.
        assert_eq!(
            reaction_dedupe_keys(
                "u3000608",
                "9008001",
                "c9008001",
                5,
                "evt_8001",
                "rcli_8001a"
            ),
            vec![
                "3000608|9008001|evt_8001|5".to_owned(),
                "3000608|9008001|cli:rcli_8001a|5".to_owned(),
                "3000608|c9008001|cli:rcli_8001a|5".to_owned(),
            ]
        );
        // Group id stays `g...` untouched.
        assert_eq!(
            reaction_dedupe_keys("g610", "9010001", "", 5, "sn1", ""),
            vec!["g610|9010001|sn1|5".to_owned()]
        );
        // When msg_id is empty, target_key falls back to cli_msg_id.
        assert_eq!(
            reaction_dedupe_keys("3000608", "", "c9008", 3, "evt_x", "rcli_x"),
            vec![
                "3000608|c9008|evt_x|3".to_owned(),
                "3000608|c9008|cli:rcli_x|3".to_owned(),
            ]
        );
        // Matches `react_add` local keys.
        assert_eq!(
            local_reaction_seen_keys("3000601", "9001001", "c9001001", "6000000000001", 5),
            vec![
                "3000601|9001001|cli:6000000000001|5".to_owned(),
                "3000601|c9001001|cli:6000000000001|5".to_owned(),
            ]
        );
        // When resolved_cli_id == effective_msg_id, emits only one key.
        assert_eq!(
            local_reaction_seen_keys("3000601", "9001001", "9001001", "6000000000001", -1),
            vec!["3000601|9001001|cli:6000000000001|-1".to_owned()]
        );
    }

    #[test]
    fn seen_reaction_keys_caps_at_1000_fifo_and_hydrates_suffix() {
        let mut seen = SeenReactionKeys::default();
        let initial: Vec<String> = (0..1050).map(|i| format!("k{i}")).collect();
        seen.hydrate_from_saved(&initial);
        assert_eq!(seen.len(), SEEN_REACTION_CAP);
        assert!(!seen.contains_any(&["k0".to_owned(), "k49".to_owned()]));
        assert!(seen.contains_any(&["k50".to_owned()]));
        assert!(seen.contains_any(&["k1049".to_owned()]));

        // Duplicate key does not report change or alter length.
        assert!(!seen.record(&["k500".to_owned(), "  ".to_owned()]));
        assert_eq!(seen.len(), SEEN_REACTION_CAP);

        // Inserting 2 new keys evicts the 2 oldest (`k50`, `k51`).
        assert!(seen.record(&["new1".to_owned(), "new2".to_owned()]));
        assert_eq!(seen.len(), SEEN_REACTION_CAP);
        assert!(!seen.contains_any(&["k50".to_owned(), "k51".to_owned()]));
        assert!(seen.contains_any(&["k52".to_owned()]));
        assert_eq!(seen.ordered().last().map(String::as_str), Some("new2"));
    }

    #[test]
    fn pending_local_reactions_match_and_expire_at_20s() {
        let mut pending = PendingLocalReactions::default();
        let t0 = 1_700_000_000_000_i64;
        pending.push(
            PendingLocalReaction {
                conv_id: "3000609".to_owned(),
                msg_id: "9009001".to_owned(),
                cli_msg_id: "c9009001".to_owned(),
                r_type: 5,
                react_client_id: "6000000000070".to_owned(),
                created_at_ms: t0,
            },
            t0,
        );
        // Matches sanitized `u3000609` and consumes entry (second call returns false).
        assert!(pending.consume_matching(
            t0 + 5_000,
            "u3000609",
            "9009001",
            "c9009001",
            5,
            "srv_echo_1",
        ));
        assert!(!pending.consume_matching(
            t0 + 5_000,
            "3000609",
            "9009001",
            "c9009001",
            5,
            "srv_echo_1",
        ));

        // Entry older than 20 s is pruned and does not match.
        pending.push(
            PendingLocalReaction {
                conv_id: "3000609".to_owned(),
                msg_id: "9009002".to_owned(),
                cli_msg_id: "c9009002".to_owned(),
                r_type: 3,
                react_client_id: "6000000000071".to_owned(),
                created_at_ms: t0,
            },
            t0,
        );
        assert!(!pending.consume_matching(
            t0 + 20_001,
            "3000609",
            "9009002",
            "c9009002",
            3,
            "6000000000071",
        ));
        assert!(pending.is_empty());
    }

    #[test]
    fn delete_undo_bar_handles_undo_second_batch_dismiss_expiry_and_logout() {
        let mut state = CoreState::default();
        let t0 = 1_700_000_010_000_i64;
        let item1 = DeleteUndoItem {
            conv_id: "3000622".to_owned(),
            msg_id: "m1".to_owned(),
            cli_msg_id: "c1".to_owned(),
            sender_id: "2000".to_owned(),
            message: None,
        };
        let item2 = DeleteUndoItem {
            conv_id: "3000622".to_owned(),
            msg_id: "m2".to_owned(),
            cli_msg_id: "c2".to_owned(),
            sender_id: "2000".to_owned(),
            message: None,
        };

        // Start batch 1.
        let mut out1 = ReduceOutput::default();
        state.actions.delete_undo.start_batch(
            "3000622".to_owned(),
            vec![item1.clone()],
            t0,
            &mut out1,
        );
        assert!(out1.dirty.contains(&DirtyKey::DeleteUndo));
        assert_eq!(
            state.actions.delete_undo.snapshot(),
            Some(DeleteUndoSnapshot {
                conv_id: "3000622".to_owned(),
                count: 1,
                deadline_ms: t0 + 5_000,
            })
        );
        let gen1 = match &out1.effects[0] {
            Effect::StartDeleteUndoExpiry { undo_gen, delay } => {
                assert_eq!(*delay, DELETE_UNDO_DURATION);
                *undo_gen
            }
            other => panic!("expected StartDeleteUndoExpiry, got {other:?}"),
        };

        // Second delete immediately cancels timer + commits batch 1 + starts batch 2.
        let mut out2 = ReduceOutput::default();
        state.actions.delete_undo.start_batch(
            "3000622".to_owned(),
            vec![item2.clone()],
            t0 + 2_000,
            &mut out2,
        );
        assert!(matches!(out2.effects[0], Effect::CancelDeleteUndoExpiry));
        assert!(matches!(
            &out2.effects[1],
            Effect::CommitDeleteBatch { items } if items == &vec![item1]
        ));
        let gen2 = match &out2.effects[2] {
            Effect::StartDeleteUndoExpiry { undo_gen, .. } => *undo_gen,
            other => panic!("expected StartDeleteUndoExpiry, got {other:?}"),
        };
        assert!(gen2 > gen1);
        assert_eq!(
            state
                .actions
                .delete_undo
                .snapshot()
                .map(|s| s.to_case_json()),
            Some(json!({
                "conv_id": "3000622",
                "count": 1,
                "deadline_ms": t0 + 7_000,
            }))
        );

        // Stale expiry from gen1 is ignored.
        let stale = reduce(&mut state, Input::DeleteUndoExpired { undo_gen: gen1 });
        assert!(stale.dirty.is_empty());
        assert!(stale.effects.is_empty());
        assert!(state.actions.delete_undo.snapshot().is_some());

        // Matching expiry from gen2 clears bar and commits batch 2.
        let expired = reduce(&mut state, Input::DeleteUndoExpired { undo_gen: gen2 });
        assert!(expired.dirty.contains(&DirtyKey::DeleteUndo));
        assert!(state.actions.delete_undo.snapshot().is_none());
        assert!(matches!(
            expired.effects.as_slice(),
            [Effect::CommitDeleteBatch { items }] if items == &vec![item2.clone()]
        ));

        // UndoDelete cancels timer and shows restore card.
        let mut out3 = ReduceOutput::default();
        state.actions.delete_undo.start_batch(
            "3000620".to_owned(),
            vec![item2.clone()],
            t0 + 10_000,
            &mut out3,
        );
        let undo_out = reduce(&mut state, Input::Command(Command::UndoDelete));
        assert!(undo_out.dirty.contains(&DirtyKey::DeleteUndo));
        assert!(state.actions.delete_undo.snapshot().is_none());
        assert!(matches!(
            undo_out.effects.as_slice(),
            [
                Effect::CancelDeleteUndoExpiry,
                Effect::Host(HostCall::ShowCard { conv_id, text })
            ] if conv_id == "3000620" && text == RESTORE_SUCCESS_CARD_TEXT
        ));

        // DismissDeleteUndo commits batch immediately.
        let mut out4 = ReduceOutput::default();
        state.actions.delete_undo.start_batch(
            "3000620".to_owned(),
            vec![item2.clone()],
            t0 + 20_000,
            &mut out4,
        );
        let dismiss_out = reduce(&mut state, Input::Command(Command::DismissDeleteUndo));
        assert!(dismiss_out.dirty.contains(&DirtyKey::DeleteUndo));
        assert!(matches!(
            dismiss_out.effects.as_slice(),
            [
                Effect::CancelDeleteUndoExpiry,
                Effect::CommitDeleteBatch { items }
            ] if items == &vec![item2.clone()]
        ));

        // LogOut clears active undo bar and auto_delete while keeping generation monotonic.
        let mut out5 = ReduceOutput::default();
        state.actions.delete_undo.start_batch(
            "3000620".to_owned(),
            vec![item2.clone()],
            t0 + 30_000,
            &mut out5,
        );
        let gen_before_logout = match &out5.effects[0] {
            Effect::StartDeleteUndoExpiry { undo_gen, .. } => *undo_gen,
            other => panic!("unexpected {other:?}"),
        };
        state.actions.auto_delete = Some(BTreeMap::from([("3000620".to_owned(), 3_600_000)]));
        let logout_out = reduce(&mut state, Input::Command(Command::LogOut));
        assert!(logout_out.dirty.contains(&DirtyKey::DeleteUndo));
        assert!(logout_out.dirty.contains(&DirtyKey::AutoDelete));
        assert!(state.actions.delete_undo.snapshot().is_none());
        assert!(state.actions.auto_delete.is_none());

        let mut out6 = ReduceOutput::default();
        state.actions.delete_undo.start_batch(
            "3000620".to_owned(),
            vec![item2],
            t0 + 40_000,
            &mut out6,
        );
        let gen_after_logout = match &out6.effects[0] {
            Effect::StartDeleteUndoExpiry { undo_gen, .. } => *undo_gen,
            other => panic!("unexpected {other:?}"),
        };
        assert!(gen_after_logout > gen_before_logout);
    }

    #[test]
    fn auto_delete_load_and_set_match_swift_behavior() {
        let mut state = CoreState::default();
        assert_eq!(state.actions.auto_delete, None);
        assert_eq!(state.actions.auto_delete_ttl("3000628"), 0);

        // Load error when None initializes empty map (`auto_delete_load` failed_when_nil).
        let load_cmd = reduce(&mut state, Input::Command(Command::LoadAutoDelete));
        assert!(matches!(
            load_cmd.effects.as_slice(),
            [Effect::FetchAutoDeleteApi { op_id: None }]
        ));
        let fail_nil = reduce(
            &mut state,
            Input::AutoDeleteLoaded {
                outcome: None,
                op_id: None,
            },
        );
        assert!(fail_nil.dirty.contains(&DirtyKey::AutoDelete));
        assert_eq!(state.actions.auto_delete, Some(BTreeMap::new()));

        // Successful load replaces map and emits `EngineLog`.
        let loaded = reduce(
            &mut state,
            Input::AutoDeleteLoaded {
                outcome: Some(AutoDeleteFetchOutcome {
                    settings: BTreeMap::from([("g627".to_owned(), 86_400_000)]),
                    data_keys: vec!["convers".to_owned()],
                    convers_count: 1,
                }),
                op_id: None,
            },
        );
        assert!(loaded.dirty.contains(&DirtyKey::AutoDelete));
        assert_eq!(state.actions.auto_delete_ttl("g627"), 86_400_000);
        assert!(matches!(
            loaded.effects.as_slice(),
            [Effect::EngineLog(line)] if line == r#"autodelete: list keys=["convers"] convers=1"#
        ));

        // Subsequent load error preserves existing map without dirtying.
        let fail_existing = reduce(
            &mut state,
            Input::AutoDeleteLoaded {
                outcome: None,
                op_id: None,
            },
        );
        assert!(fail_existing.dirty.is_empty());
        assert_eq!(state.actions.auto_delete_ttl("g627"), 86_400_000);

        // SetAutoDelete guards: empty conv_id or unchanged TTL are no-ops.
        let empty = reduce(
            &mut state,
            Input::Command(Command::SetAutoDelete {
                conv_id: String::new(),
                ttl: 3_600_000,
                now_ms: 1000,
            }),
        );
        assert!(empty.effects.is_empty());
        let same = reduce(
            &mut state,
            Input::Command(Command::SetAutoDelete {
                conv_id: "g627".to_owned(),
                ttl: 86_400_000,
                now_ms: 1000,
            }),
        );
        assert!(same.effects.is_empty());

        // SetAutoDelete failure logs and emits `ShowCard`.
        let upd_fail = reduce(
            &mut state,
            Input::AutoDeleteUpdated {
                conv_id: "3000628".to_owned(),
                ttl: 3_600_000,
                now_ms: 2000,
                error_type: Some("ZaloSessionError".to_owned()),
                op_id: None,
            },
        );
        assert!(upd_fail.dirty.is_empty());
        assert!(matches!(
            upd_fail.effects.as_slice(),
            [
                Effect::EngineLog(line),
                Effect::Host(HostCall::ShowCard { conv_id, text })
            ] if line == "autodelete: update failed ZaloSessionError"
                && conv_id == "3000628"
                && text == AUTO_DELETE_FAILED_CARD_TEXT
        ));

        // SetAutoDelete success updates map (insert >0, remove <=0).
        let upd_on = reduce(
            &mut state,
            Input::AutoDeleteUpdated {
                conv_id: "3000628".to_owned(),
                ttl: 3_600_000,
                now_ms: 3000,
                error_type: None,
                op_id: None,
            },
        );
        assert!(upd_on.dirty.contains(&DirtyKey::AutoDelete));
        assert_eq!(state.actions.auto_delete_ttl("3000628"), 3_600_000);

        let upd_off = reduce(
            &mut state,
            Input::AutoDeleteUpdated {
                conv_id: "3000628".to_owned(),
                ttl: 0,
                now_ms: 4000,
                error_type: None,
                op_id: None,
            },
        );
        assert!(upd_off.dirty.contains(&DirtyKey::AutoDelete));
        assert_eq!(state.actions.auto_delete_ttl("3000628"), 0);
        assert!(
            !state
                .actions
                .auto_delete
                .as_ref()
                .is_some_and(|m| m.contains_key("3000628"))
        );

        // Notice text matches Swift `ZaloEngine+AutoDelete.swift`.
        let notice_on = auto_delete_system_notice("3000628", 3_600_000, 3000);
        assert_eq!(notice_on.id, "ttl-3000628-3000");
        assert_eq!(
            notice_on.text,
            "Bạn đã đặt thời gian tự xóa cho tin nhắn là 1 giờ."
        );
        let notice_off = auto_delete_system_notice("3000628", 0, 4000);
        assert_eq!(notice_off.id, "ttl-3000628-4000");
        assert_eq!(notice_off.text, "Bạn đã tắt tin nhắn tự xóa.");
    }

    #[test]
    fn recall_error_mapping_and_24h_guard_match_swift() {
        assert!(!is_over_recall_window(
            1_000_000,
            1_000_000 + RECALL_WINDOW_MS - 1
        ));
        assert!(is_over_recall_window(
            1_000_000,
            1_000_000 + RECALL_WINDOW_MS
        ));

        let err_211 =
            RecallFailure::from_api_error(&ApiError::Net(NetError::Session(ZaloSessionError {
                code: 211,
                message: "expired".to_owned(),
                url: "/api/message/undo".to_owned(),
            })));
        assert_eq!(
            recall_error_card_text(&err_211),
            "Tin nhắn đã quá thời hạn thu hồi."
        );
        assert_eq!(
            recall_error_log_line(&err_211, false, false, "9016001", "c9016001"),
            "recall failed: code=211 msg=expired primaryE2EE=false retriedAlt=false sameId=false msgId=9016001 cliId=c9016001"
        );

        let err_500 = RecallFailure::Session {
            code: 500,
            message: String::new(),
        };
        assert_eq!(
            recall_error_card_text(&err_500),
            "Thu hồi tin nhắn không thành công (mã lỗi 500)."
        );
        assert_eq!(
            recall_error_log_line(&err_500, true, true, "9016002", "9016002"),
            "recall failed: code=500 msg=- primaryE2EE=true retriedAlt=true sameId=true msgId=9016002 cliId=9016002"
        );

        let err_net = RecallFailure::from_api_error(&ApiError::Net(NetError::network(
            NetworkErrorKind::Timeout,
            "timed out",
        )));
        assert_eq!(
            recall_error_card_text(&err_net),
            "Không có kết nối mạng. Vui lòng kiểm tra và thử lại."
        );
        assert_eq!(
            recall_error_log_line(&err_net, false, false, "1", "2"),
            "recall failed: network error"
        );

        let err_other = RecallFailure::Other("oops".to_owned());
        assert_eq!(
            recall_error_card_text(&err_other),
            "Thu hồi tin nhắn không thành công."
        );
        assert_eq!(
            recall_error_log_line(&err_other, false, false, "1", "2"),
            "recall failed: oops"
        );
    }

    #[test]
    fn debug_output_redacts_ids_and_user_text() {
        let snap = DeleteUndoSnapshot {
            conv_id: "SECRET_CONV_42".to_owned(),
            count: 2,
            deadline_ms: 12345,
        };
        let item = DeleteUndoItem {
            conv_id: "SECRET_CONV_42".to_owned(),
            msg_id: "SECRET_MSG_1".to_owned(),
            cli_msg_id: "SECRET_CLI_1".to_owned(),
            sender_id: "SECRET_SENDER_1".to_owned(),
            message: None,
        };
        let pending = PendingLocalReaction {
            conv_id: "SECRET_CONV_42".to_owned(),
            msg_id: "SECRET_MSG_1".to_owned(),
            cli_msg_id: "SECRET_CLI_1".to_owned(),
            r_type: 5,
            react_client_id: "SECRET_RCLI_1".to_owned(),
            created_at_ms: 99,
        };
        let notice = auto_delete_system_notice("SECRET_CONV_42", 3_600_000, 99);
        let failure = RecallFailure::Session {
            code: 500,
            message: "SECRET_SERVER_MSG".to_owned(),
        };

        for dbg in [
            format!("{snap:?}"),
            format!("{item:?}"),
            format!("{pending:?}"),
            format!("{notice:?}"),
            format!("{failure:?}"),
        ] {
            assert!(!dbg.contains("SECRET_"), "leaked secret in {dbg}");
        }
    }
}
