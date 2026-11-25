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
use olaz_wire::{is_group_id, sanitize_profile_uid};
use serde_json::{Value, json};

use crate::changes::DirtyKey;
use crate::effect::{Effect, HostCall, OpResult};
use crate::input::{Command, Input};
use crate::reduce::ReduceOutput;
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
    entries: Vec<PendingLocalReaction>,
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
        self.entries.retain(|entry| {
            now_ms.saturating_sub(entry.created_at_ms) <= PENDING_LOCAL_REACTION_TTL_MS
        });
    }

    /// Prunes expired entries and appends a new pending local reaction.
    pub fn push(&mut self, entry: PendingLocalReaction, now_ms: i64) {
        self.prune(now_ms);
        self.entries.push(entry);
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

        let pos = self.entries.iter().position(|pending| {
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
#[derive(Clone, PartialEq, Eq)]
pub struct DeleteUndoItem {
    pub conv_id: String,
    pub msg_id: String,
    pub cli_msg_id: String,
    pub sender_id: String,
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

#[derive(Clone, PartialEq, Eq)]
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
#[derive(Clone, Default, PartialEq, Eq)]
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

/// Core-owned message-actions state (U6).
#[derive(Clone, Default, PartialEq, Eq)]
pub struct ActionsState {
    pub seen_reactions: SeenReactionKeys,
    pub pending_reactions: PendingLocalReactions,
    pub delete_undo: DeleteUndoState,
    /// Per-conversation auto-delete TTL in ms (`None` = not loaded yet, `Some(map)` = loaded).
    pub auto_delete: Option<BTreeMap<String, i64>>,
}

impl fmt::Debug for ActionsState {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ActionsState")
            .field("seen_reactions", &self.seen_reactions)
            .field("pending_reactions", &self.pending_reactions)
            .field("delete_undo", &self.delete_undo)
            .field(
                "auto_delete_count",
                &self.auto_delete.as_ref().map(BTreeMap::len),
            )
            .finish()
    }
}

impl ActionsState {
    /// Current auto-delete TTL (ms) for `conv_id`, or `0` if off / unloaded.
    #[must_use]
    pub fn auto_delete_ttl(&self, conv_id: &str) -> i64 {
        self.auto_delete
            .as_ref()
            .and_then(|m| m.get(conv_id))
            .copied()
            .unwrap_or(0)
    }

    /// Resets per-session actions state on logout / session expiry, preserving the monotonic
    /// delete-undo generation counter. Returns `(delete_undo_changed, auto_delete_changed)`.
    pub(crate) fn reset_session(&mut self) -> (bool, bool) {
        self.seen_reactions.clear();
        self.pending_reactions.clear();
        let undo_changed = self.delete_undo.reset_session();
        let auto_delete_changed = self.auto_delete.take().is_some();
        (undo_changed, auto_delete_changed)
    }
}

/// Pure reducer for U6 message-actions commands and async completions.
pub(crate) fn reduce_actions(state: &mut CoreState, input: Input, out: &mut ReduceOutput) {
    match input {
        Input::Command(cmd) => reduce_command(state, cmd, None, out),
        Input::OpRequest { op_id, cmd } => reduce_command(state, cmd, Some(op_id), out),
        Input::DeleteUndoExpired { undo_gen } => {
            state.actions.delete_undo.expire(undo_gen, out);
        }
        Input::AutoDeleteLoaded { outcome, op_id } => {
            apply_auto_delete_loaded(&mut state.actions, outcome, out);
            complete_unit(op_id, out);
        }
        Input::AutoDeleteUpdated {
            conv_id,
            ttl,
            now_ms,
            error_type,
            op_id,
        } => {
            apply_auto_delete_updated(&mut state.actions, &conv_id, ttl, now_ms, error_type, out);
            complete_unit(op_id, out);
        }
        _ => {}
    }
}

fn reduce_command(state: &mut CoreState, cmd: Command, op_id: Option<u64>, out: &mut ReduceOutput) {
    match cmd {
        Command::UndoDelete => {
            let _ = state.actions.delete_undo.undo(out);
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
        _ => {}
    }
}

fn apply_auto_delete_loaded(
    actions: &mut ActionsState,
    outcome: Option<AutoDeleteFetchOutcome>,
    out: &mut ReduceOutput,
) {
    match outcome {
        Some(fetched) => {
            out.effects.push(Effect::EngineLog(fetched.log_line()));
            actions.auto_delete = Some(fetched.settings);
            out.dirty.insert(DirtyKey::AutoDelete);
        }
        None => {
            if actions.auto_delete.is_none() {
                actions.auto_delete = Some(BTreeMap::new());
                out.dirty.insert(DirtyKey::AutoDelete);
            }
        }
    }
}

fn apply_auto_delete_updated(
    actions: &mut ActionsState,
    conv_id: &str,
    ttl: i64,
    now_ms: i64,
    error_type: Option<String>,
    out: &mut ReduceOutput,
) {
    if let Some(err_type) = error_type {
        out.effects.push(Effect::EngineLog(format!(
            "autodelete: update failed {err_type}"
        )));
        out.effects.push(Effect::Host(HostCall::ShowCard {
            conv_id: conv_id.to_owned(),
            text: AUTO_DELETE_FAILED_CARD_TEXT.to_owned(),
        }));
        return;
    }
    let map = actions.auto_delete.get_or_insert_with(BTreeMap::new);
    if ttl > 0 {
        map.insert(conv_id.to_owned(), ttl);
    } else {
        map.remove(conv_id);
    }
    out.dirty.insert(DirtyKey::AutoDelete);
    // System notice synthesis is verified now; once U4's `MessagesState` lands, this notice will
    // be merged into the message window, persisted, and routed to `update_conversation_on_message`.
    let _notice = auto_delete_system_notice(conv_id, ttl, now_ms);
}

fn complete_unit(op_id: Option<u64>, out: &mut ReduceOutput) {
    if let Some(id) = op_id {
        out.effects.push(Effect::CompleteOp {
            op_id: id,
            result: OpResult::Unit,
            after_store: false,
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
        };
        let item2 = DeleteUndoItem {
            conv_id: "3000622".to_owned(),
            msg_id: "m2".to_owned(),
            cli_msg_id: "c2".to_owned(),
            sender_id: "2000".to_owned(),
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
