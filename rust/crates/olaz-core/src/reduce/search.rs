//! U14 Search, ensure-message-loaded, and load-quoted-message reducer.
//!
//! Incorporates approved U14 fixes 1–4:
//! 1. Cursor-paged store search (`page_size = max(limit * 2, 50)`) looping until `limit`
//!    post-filter results are secured or the store runs out.
//! 2. Store search matches the same fields as memory search (incl. `call.detail`,
//!    `ecard.reminderTitle`) via one shared fold function (`olaz_store::search_text`).
//! 3. Pending-delete and memory/store dedupe match both `id` and non-empty `client_id` in
//!    `search_messages` and `ensure_message_loaded` (window filter + fallback merge).
//! 4. `load_quoted_message` skips recalled (and pending-deleted) messages for id/client-id
//!    matches, and legacy quote-text fallback also searches the store before loading the window.

use std::cmp::Ordering;
use std::collections::{HashSet, VecDeque};

use olaz_store::{
    MessagesAround, StoredMessage as DbStoredMessage, fold_search_text, trim_search_query,
};
use olaz_wire::{ChatMessage, Kind};

use crate::changes::DirtyKey;
use crate::effect::{Effect, OpResult, StoreOp};
use crate::input::{Command, Input};
use crate::messages::decode_db_stored;
use crate::reduce::ReduceOutput;
use crate::search::{
    PendingEnsureLoaded, PendingLoadQuoted, PendingSearch, message_matches_folded_needle,
};
use crate::state::CoreState;

const SEARCH_MAX_LIMIT: usize = 500;
const SEARCH_MIN_PAGE_SIZE: usize = 50;
const LEGACY_QUOTED_STORE_LIMIT: i64 = 50;

fn cmp_search_result_desc(a: &ChatMessage, b: &ChatMessage) -> Ordering {
    b.date_ms.cmp(&a.date_ms).then_with(|| b.id.cmp(&a.id))
}

fn is_key_in(id: &str, client_id: &str, set: &HashSet<String>) -> bool {
    (!id.is_empty() && set.contains(id)) || (!client_id.is_empty() && set.contains(client_id))
}

fn is_msg_in(msg: &ChatMessage, set: &HashSet<String>) -> bool {
    is_key_in(&msg.id, &msg.client_id, set)
}

fn insert_keys(set: &mut HashSet<String>, id: &str, client_id: &str) {
    if !id.is_empty() {
        set.insert(id.to_owned());
    }
    if !client_id.is_empty() {
        set.insert(client_id.to_owned());
    }
}

fn collect_memory_keys(list: &[ChatMessage]) -> HashSet<String> {
    let mut keys = HashSet::with_capacity(list.len() * 2);
    for msg in list {
        insert_keys(&mut keys, &msg.id, &msg.client_id);
    }
    keys
}

pub(crate) fn reduce_search(state: &mut CoreState, input: Input, out: &mut ReduceOutput) {
    match input {
        Input::OpRequest { op_id, cmd } => match cmd {
            Command::SearchMessages {
                conv_id,
                query,
                limit,
            } => {
                start_search(state, op_id, conv_id, query, limit, out);
            }
            Command::EnsureMessageLoaded { conv_id, message } => {
                let pending_set = state.actions.delete_undo.pending_deleted_keys(&conv_id);
                start_ensure_message_loaded(
                    state,
                    op_id,
                    conv_id,
                    *message,
                    pending_set,
                    false,
                    out,
                );
            }
            Command::LoadQuotedMessage { conv_id, message } => {
                let pending_set = state.actions.delete_undo.pending_deleted_keys(&conv_id);
                start_load_quoted(state, op_id, conv_id, *message, pending_set, out);
            }
            _ => {}
        },
        Input::Command(
            Command::SearchMessages { .. }
            | Command::EnsureMessageLoaded { .. }
            | Command::LoadQuotedMessage { .. },
        ) => {
            // Request-reply commands are handled via OpRequest; fire-and-forget is a no-op.
        }
        Input::SearchMessagesPageLoaded {
            op_id,
            rows,
            page_limit,
        } => {
            on_search_page_loaded(state, op_id, rows, page_limit, out);
        }
        Input::EnsureMessageWindowLoaded { op_id, window } => {
            on_ensure_window_loaded(state, op_id, window, out);
        }
        Input::QuotedLookupDone { op_id, row } => {
            on_quoted_lookup_done(state, op_id, row, out);
        }
        Input::LegacyQuotedLookupDone { op_id, rows } => {
            on_legacy_quoted_lookup_done(state, op_id, rows, out);
        }
        _ => {}
    }
}

fn start_search(
    state: &mut CoreState,
    op_id: u64,
    conv_id: String,
    query: String,
    limit: i64,
    out: &mut ReduceOutput,
) {
    let trimmed = trim_search_query(&query);
    if conv_id.is_empty() || trimmed.is_empty() || limit <= 0 {
        out.effects.push(Effect::CompleteOp {
            op_id,
            result: OpResult::SearchMessages(Vec::new()),
            after_store: false,
        });
        return;
    }

    let clamped_limit = usize::try_from(limit)
        .unwrap_or(SEARCH_MAX_LIMIT)
        .clamp(1, SEARCH_MAX_LIMIT);
    let page_size = (clamped_limit.saturating_mul(2)).max(SEARCH_MIN_PAGE_SIZE);
    let folded_needle = fold_search_text(trimmed);
    if folded_needle.is_empty() {
        out.effects.push(Effect::CompleteOp {
            op_id,
            result: OpResult::SearchMessages(Vec::new()),
            after_store: false,
        });
        return;
    }

    let pending_set = state.actions.delete_undo.pending_deleted_keys(&conv_id);

    let in_memory = state
        .messages
        .windows
        .get(&conv_id)
        .map(Vec::as_slice)
        .unwrap_or(&[]);
    let memory_keys = collect_memory_keys(in_memory);
    let mut seen_keys = HashSet::new();
    let mut memory_results = Vec::new();

    for msg in in_memory {
        if is_msg_in(msg, &pending_set) {
            continue;
        }
        if !message_matches_folded_needle(msg, &folded_needle) {
            continue;
        }
        if is_msg_in(msg, &seen_keys) {
            continue;
        }
        insert_keys(&mut seen_keys, &msg.id, &msg.client_id);
        memory_results.push(msg.clone());
    }

    let trimmed_owned = trimmed.to_owned();
    let pending = PendingSearch {
        conv_id: conv_id.clone(),
        trimmed_query: trimmed_owned.clone(),
        folded_needle,
        limit: clamped_limit,
        page_size,
        pending_deleted_keys: pending_set,
        memory_keys,
        seen_keys,
        memory_results,
        store_results: Vec::new(),
    };
    state.search.pending_searches.insert(op_id, pending);
    out.effects.push(Effect::Store(StoreOp::SearchMessagesPage {
        op_id,
        conv_id,
        query: trimmed_owned,
        before: None,
        limit: i64::try_from(page_size).unwrap_or(1000),
    }));
}

fn on_search_page_loaded(
    state: &mut CoreState,
    op_id: u64,
    rows: Vec<DbStoredMessage>,
    page_limit: usize,
    out: &mut ReduceOutput,
) {
    let Some(mut pending) = state.search.pending_searches.remove(&op_id) else {
        return;
    };

    let raw_count = rows.len();
    let last_cursor = rows.last().map(|r| (r.ts_ms, r.id.clone()));

    for row in rows {
        if is_key_in(&row.id, &row.client_id, &pending.pending_deleted_keys) {
            continue;
        }
        if is_key_in(&row.id, &row.client_id, &pending.seen_keys) {
            continue;
        }
        if is_key_in(&row.id, &row.client_id, &pending.memory_keys) {
            insert_keys(&mut pending.seen_keys, &row.id, &row.client_id);
            continue;
        }
        let Some(decoded) = decode_db_stored(&row) else {
            continue;
        };
        if is_msg_in(&decoded, &pending.pending_deleted_keys) {
            continue;
        }
        if is_msg_in(&decoded, &pending.seen_keys) {
            continue;
        }
        if is_msg_in(&decoded, &pending.memory_keys) {
            insert_keys(&mut pending.seen_keys, &row.id, &row.client_id);
            insert_keys(&mut pending.seen_keys, &decoded.id, &decoded.client_id);
            continue;
        }
        if !message_matches_folded_needle(&decoded, &pending.folded_needle) {
            continue;
        }

        insert_keys(&mut pending.seen_keys, &row.id, &row.client_id);
        insert_keys(&mut pending.seen_keys, &decoded.id, &decoded.client_id);
        pending.store_results.push(decoded);
    }

    let exhausted = raw_count < page_limit || last_cursor.is_none();
    let enough_from_store = pending.store_results.len() >= pending.limit;
    let cursor_past_cutoff = if !exhausted && !enough_from_store {
        if let Some((cursor_ts, ref cursor_id)) = last_cursor {
            let total = pending.memory_results.len() + pending.store_results.len();
            if total >= pending.limit {
                // Check whether at least `limit` collected results strictly beat `(cursor_ts, cursor_id)`
                // in `(date_ms DESC, id DESC)` order. If so, no older store row can enter top `limit`.
                let beats_cursor = |m: &ChatMessage| {
                    m.date_ms > cursor_ts
                        || (m.date_ms == cursor_ts && m.id.as_str() > cursor_id.as_str())
                };
                let strictly_newer = pending
                    .memory_results
                    .iter()
                    .filter(|m| beats_cursor(m))
                    .count()
                    + pending
                        .store_results
                        .iter()
                        .filter(|m| beats_cursor(m))
                        .count();
                strictly_newer >= pending.limit
            } else {
                false
            }
        } else {
            true
        }
    } else {
        true
    };

    if !exhausted && !enough_from_store && !cursor_past_cutoff {
        let conv_id = pending.conv_id.clone();
        let query = pending.trimmed_query.clone();
        let page_size = pending.page_size;
        state.search.pending_searches.insert(op_id, pending);
        out.effects.push(Effect::Store(StoreOp::SearchMessagesPage {
            op_id,
            conv_id,
            query,
            before: last_cursor,
            limit: i64::try_from(page_size).unwrap_or(1000),
        }));
        return;
    }

    let mut combined = pending.memory_results;
    combined.extend(pending.store_results);
    combined.sort_by(cmp_search_result_desc);
    combined.truncate(pending.limit);

    out.effects.push(Effect::CompleteOp {
        op_id,
        result: OpResult::SearchMessages(combined),
        after_store: false,
    });
}

fn start_ensure_message_loaded(
    state: &mut CoreState,
    op_id: u64,
    conv_id: String,
    message: ChatMessage,
    pending_deleted_keys: HashSet<String>,
    for_quote: bool,
    out: &mut ReduceOutput,
) {
    let finish = |loaded: bool, msg_id: &str, out: &mut ReduceOutput| {
        let result = if for_quote {
            OpResult::OptionalString(loaded.then(|| msg_id.to_owned()))
        } else {
            OpResult::Bool(loaded)
        };
        out.effects.push(Effect::CompleteOp {
            op_id,
            result,
            after_store: false,
        });
    };

    if conv_id.is_empty() {
        finish(false, &message.id, out);
        return;
    }
    if state
        .messages
        .windows
        .get(&conv_id)
        .is_some_and(|list| list.iter().any(|m| m.id == message.id))
    {
        finish(true, &message.id, out);
        return;
    }

    let target_ts_ms = message.date_ms;
    let before_oldest_ts_ms = state
        .messages
        .windows
        .get(&conv_id)
        .and_then(|list| list.first())
        .map(|m| m.date_ms);

    state.search.pending_ensures.insert(
        op_id,
        PendingEnsureLoaded {
            conv_id: conv_id.clone(),
            message,
            pending_deleted_keys,
            for_quote,
        },
    );
    out.effects.push(Effect::Store(StoreOp::LoadMessagesAround {
        op_id,
        conv_id,
        target_ts_ms,
        before_oldest_ts_ms,
    }));
}

fn on_ensure_window_loaded(
    state: &mut CoreState,
    op_id: u64,
    window: Option<MessagesAround>,
    out: &mut ReduceOutput,
) {
    let Some(pending) = state.search.pending_ensures.remove(&op_id) else {
        return;
    };

    let snap = state.identity_snapshot();
    let mut dirty = false;

    if let Some(window) = window {
        let mut to_merge: Vec<(ChatMessage, Option<String>)> =
            Vec::with_capacity(window.messages.len());
        for row in window.messages {
            if is_key_in(&row.id, &row.client_id, &pending.pending_deleted_keys) {
                continue;
            }
            let Some(decoded) = decode_db_stored(&row) else {
                continue;
            };
            if is_msg_in(&decoded, &pending.pending_deleted_keys) {
                continue;
            }
            let row_client = (!row.client_id.is_empty()).then_some(row.client_id);
            to_merge.push((decoded, row_client));
        }
        if !to_merge.is_empty() {
            let ops = state
                .messages
                .merge_messages_page(&pending.conv_id, to_merge, &snap);
            if !ops.is_empty() {
                dirty = true;
            }
        }
        if window.has_more_older {
            let prev = state
                .messages
                .has_more_history
                .insert(pending.conv_id.clone(), true);
            if prev != Some(true) {
                out.dirty.insert(DirtyKey::MessageMeta);
            }
        }
    }

    let already_loaded = state
        .messages
        .windows
        .get(&pending.conv_id)
        .is_some_and(|list| list.iter().any(|m| m.id == pending.message.id));

    if !already_loaded
        && (pending.message.conversation_id == pending.conv_id
            || pending.message.conversation_id.is_empty())
        && !is_msg_in(&pending.message, &pending.pending_deleted_keys)
        && matches!(
            state
                .messages
                .merge_message(pending.message.clone(), None, &snap),
            crate::messages::WindowChange::Changed(_)
        )
    {
        dirty = true;
    }

    if dirty {
        out.dirty.insert(DirtyKey::Messages);
    }

    let loaded = state
        .messages
        .windows
        .get(&pending.conv_id)
        .is_some_and(|list| list.iter().any(|m| m.id == pending.message.id));

    let result = if pending.for_quote {
        OpResult::OptionalString(loaded.then_some(pending.message.id))
    } else {
        OpResult::Bool(loaded)
    };
    out.effects.push(Effect::CompleteOp {
        op_id,
        result,
        after_store: false,
    });
}

fn start_load_quoted(
    state: &mut CoreState,
    op_id: u64,
    conv_id: String,
    message: ChatMessage,
    pending_deleted_keys: HashSet<String>,
    out: &mut ReduceOutput,
) {
    let Some(quote) = message.quote.as_ref() else {
        out.effects.push(Effect::CompleteOp {
            op_id,
            result: OpResult::OptionalString(None),
            after_store: false,
        });
        return;
    };

    let keys: Vec<String> = [quote.msg_id.as_str(), quote.cli_msg_id.as_str()]
        .into_iter()
        .filter(|k| !k.is_empty() && *k != "0")
        .map(str::to_owned)
        .collect();

    let list = state
        .messages
        .windows
        .get(&conv_id)
        .map(Vec::as_slice)
        .unwrap_or(&[]);

    if !keys.is_empty() {
        let mut memory_shadow_keys = HashSet::new();
        for m in list {
            if matches!(m.kind, Kind::Recalled) || is_msg_in(m, &pending_deleted_keys) {
                insert_keys(&mut memory_shadow_keys, &m.id, &m.client_id);
            }
        }
        for key in &keys {
            if let Some(hit) = list
                .iter()
                .find(|m| m.id == *key || (!m.client_id.is_empty() && m.client_id == *key))
            {
                if matches!(hit.kind, Kind::Recalled) || is_msg_in(hit, &pending_deleted_keys) {
                    // Fix 4: recalled / pending-deleted message in memory is skipped and shadows store.
                    insert_keys(&mut memory_shadow_keys, &hit.id, &hit.client_id);
                    continue;
                }
                out.effects.push(Effect::CompleteOp {
                    op_id,
                    result: OpResult::OptionalString(Some(hit.id.clone())),
                    after_store: false,
                });
                return;
            }
        }

        let mut remaining: VecDeque<String> = keys
            .into_iter()
            .filter(|k| !memory_shadow_keys.contains(k) && !pending_deleted_keys.contains(k))
            .collect();
        let Some(first_key) = remaining.pop_front() else {
            out.effects.push(Effect::CompleteOp {
                op_id,
                result: OpResult::OptionalString(None),
                after_store: false,
            });
            return;
        };

        state.search.pending_quotes.insert(
            op_id,
            PendingLoadQuoted {
                conv_id: conv_id.clone(),
                remaining_keys: remaining,
                legacy_text: None,
                mine_only: false,
                pending_deleted_keys,
                memory_shadow_keys,
            },
        );
        out.effects.push(Effect::Store(StoreOp::LookupMessage {
            op_id,
            conv_id,
            key: first_key,
        }));
        return;
    }

    // Legacy fallback: quotes without ids match newest earlier message by trimmed text.
    let trimmed = trim_search_query(&quote.text);
    if trimmed.is_empty() {
        out.effects.push(Effect::CompleteOp {
            op_id,
            result: OpResult::OptionalString(None),
            after_store: false,
        });
        return;
    }
    let mine_only = quote.sender_name == "Bạn";

    if let Some(hit) = list.iter().rev().find(|m| {
        m.id != message.id
            && m.date_ms <= message.date_ms
            && !matches!(m.kind, Kind::Recalled)
            && !is_msg_in(m, &pending_deleted_keys)
            && trim_search_query(&m.text) == trimmed
            && (!mine_only || m.is_mine)
    }) {
        out.effects.push(Effect::CompleteOp {
            op_id,
            result: OpResult::OptionalString(Some(hit.id.clone())),
            after_store: false,
        });
        return;
    }

    // Fix 4: legacy fallback also checks the store when not found in memory.
    let memory_shadow_keys = collect_memory_keys(list);
    let trimmed_owned = trimmed.to_owned();
    state.search.pending_quotes.insert(
        op_id,
        PendingLoadQuoted {
            conv_id: conv_id.clone(),
            remaining_keys: VecDeque::new(),
            legacy_text: Some(trimmed_owned.clone()),
            mine_only,
            pending_deleted_keys,
            memory_shadow_keys,
        },
    );
    out.effects.push(Effect::Store(StoreOp::FindLegacyQuoted {
        op_id,
        conv_id,
        exclude_id: message.id,
        max_ts_ms: message.date_ms,
        trimmed_text: trimmed_owned,
        mine_only,
        limit: LEGACY_QUOTED_STORE_LIMIT,
    }));
}

fn on_quoted_lookup_done(
    state: &mut CoreState,
    op_id: u64,
    row: Option<DbStoredMessage>,
    out: &mut ReduceOutput,
) {
    let Some(mut pending) = state.search.pending_quotes.remove(&op_id) else {
        return;
    };

    if let Some(row) = row {
        let row_blocked = is_key_in(&row.id, &row.client_id, &pending.pending_deleted_keys)
            || is_key_in(&row.id, &row.client_id, &pending.memory_shadow_keys);
        if !row_blocked
            && let Some(decoded) = decode_db_stored(&row)
            && !matches!(decoded.kind, Kind::Recalled)
            && !is_msg_in(&decoded, &pending.pending_deleted_keys)
            && !is_msg_in(&decoded, &pending.memory_shadow_keys)
        {
            start_ensure_message_loaded(
                state,
                op_id,
                pending.conv_id,
                decoded,
                pending.pending_deleted_keys,
                true,
                out,
            );
            return;
        }
    }

    if let Some(next_key) = pending.remaining_keys.pop_front() {
        let conv_id = pending.conv_id.clone();
        state.search.pending_quotes.insert(op_id, pending);
        out.effects.push(Effect::Store(StoreOp::LookupMessage {
            op_id,
            conv_id,
            key: next_key,
        }));
        return;
    }

    out.effects.push(Effect::CompleteOp {
        op_id,
        result: OpResult::OptionalString(None),
        after_store: false,
    });
}

fn on_legacy_quoted_lookup_done(
    state: &mut CoreState,
    op_id: u64,
    rows: Vec<DbStoredMessage>,
    out: &mut ReduceOutput,
) {
    let Some(pending) = state.search.pending_quotes.remove(&op_id) else {
        return;
    };
    let Some(expected_text) = pending.legacy_text.as_deref() else {
        out.effects.push(Effect::CompleteOp {
            op_id,
            result: OpResult::OptionalString(None),
            after_store: false,
        });
        return;
    };

    for row in rows {
        if is_key_in(&row.id, &row.client_id, &pending.pending_deleted_keys)
            || is_key_in(&row.id, &row.client_id, &pending.memory_shadow_keys)
        {
            continue;
        }
        let Some(decoded) = decode_db_stored(&row) else {
            continue;
        };
        if matches!(decoded.kind, Kind::Recalled)
            || is_msg_in(&decoded, &pending.pending_deleted_keys)
            || is_msg_in(&decoded, &pending.memory_shadow_keys)
        {
            continue;
        }
        if pending.mine_only && !decoded.is_mine {
            continue;
        }
        if trim_search_query(&decoded.text) != expected_text {
            continue;
        }
        start_ensure_message_loaded(
            state,
            op_id,
            pending.conv_id,
            decoded,
            pending.pending_deleted_keys,
            true,
            out,
        );
        return;
    }

    out.effects.push(Effect::CompleteOp {
        op_id,
        result: OpResult::OptionalString(None),
        after_store: false,
    });
}
