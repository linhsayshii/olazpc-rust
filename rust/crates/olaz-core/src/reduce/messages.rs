//! Pure messages-domain reducer (U4): conversation open/close, older history paging,
//! recent history fetch + sender profile resolution, live/batch message ingestion,
//! freshness probing, and write-through window hooks.
//!
//! No I/O, no clock, and no randomness live here (D9).

use std::collections::BTreeMap;

use olaz_wire::{
    ChatMessage, ParsedWireEvent, is_group_id, sanitize_profile_uid,
    sort_reaction_events_chronologically, strip_user_prefix,
};
use serde_json::{Map, Value};

use crate::changes::DirtyKey;
use crate::conversations::{
    BatchApplyDelta, CachedProfile, ConvMessageDelta, ConvPreviewOverride, MessagePreviewInput,
};
use crate::effect::{Effect, HostCall, OpResult, StoreOp};
use crate::input::{Command, Input};
use crate::messages::{
    SenderResolveFollowup, WindowChange, collect_missing_sender_uids, decode_db_stored,
    newest_message_ids, numeric_msg_cursor, parse_batch_events, preferred_contact_name,
    serialize_cached_profiles_json,
};
use crate::reduce::{ReduceOutput, conversations};
use crate::state::CoreState;

const SENDER_PROFILES_CHUNK_SIZE: usize = 50;

/// Reduces a U4 messages-domain [`Input`].
pub(crate) fn reduce_messages(state: &mut CoreState, input: Input, out: &mut ReduceOutput) {
    match input {
        Input::Command(cmd) => reduce_message_command(state, cmd, None, out),
        Input::OpRequest { op_id, cmd } => reduce_message_command(state, cmd, Some(op_id), out),

        Input::OpenLocalMessagesLoaded {
            open_seq,
            conv_id,
            rows,
            op_id,
        } => {
            if state
                .messages
                .active_open
                .as_ref()
                .is_none_or(|f| f.open_seq != open_seq || f.conv_id != conv_id)
            {
                complete_op(op_id, out);
                return;
            }
            if state
                .messages
                .windows
                .get(&conv_id)
                .is_none_or(Vec::is_empty)
                && !rows.is_empty()
            {
                let snap = state.identity_snapshot();
                let mut decoded_count = 0usize;
                for row in &rows {
                    if let Some(msg) = decode_db_stored(row) {
                        decoded_count += 1;
                        let _ = state.messages.merge_message(msg, None, &snap);
                    }
                }
                if decoded_count > 0 {
                    out.dirty.insert(DirtyKey::Messages);
                }
                if decoded_count >= 45
                    && state
                        .messages
                        .has_more_history
                        .insert(conv_id.clone(), true)
                        != Some(true)
                {
                    out.dirty.insert(DirtyKey::MessageMeta);
                }
            }
            begin_open_step2(state, open_seq, &conv_id, op_id, out);
        }

        Input::OpenHistoryPageFetched {
            open_seq,
            conv_id,
            page,
            op_id,
        } => {
            if state
                .messages
                .active_open
                .as_ref()
                .is_none_or(|f| f.open_seq != open_seq || f.conv_id != conv_id)
            {
                complete_op(op_id, out);
                return;
            }
            let fetched_count = match page {
                None => {
                    if matches!(
                        state.messages.ensure_window_exists(&conv_id),
                        WindowChange::Changed(_)
                    ) {
                        out.dirty.insert(DirtyKey::Messages);
                    }
                    if state
                        .messages
                        .windows
                        .get(&conv_id)
                        .is_none_or(Vec::is_empty)
                        && state
                            .messages
                            .has_more_history
                            .insert(conv_id.clone(), false)
                            != Some(false)
                    {
                        out.dirty.insert(DirtyKey::MessageMeta);
                    }
                    0
                }
                Some(page_obj) => {
                    apply_fetched_history_page(state, &conv_id, page_obj, None, 50, out)
                }
            };
            if let Some(flow) = state.messages.active_open.as_mut() {
                flow.fetched_count = fetched_count;
            }
            begin_sender_profile_resolution(
                state,
                &conv_id,
                SenderResolveFollowup::Open {
                    open_seq,
                    conv_id: conv_id.clone(),
                    fetched_count,
                    op_id,
                },
                out,
            );
        }

        Input::LoadOlderStoreRead {
            load_seq,
            conv_id,
            rows,
            had_before_cursor,
            op_id,
        } => {
            if state
                .messages
                .active_load_older
                .as_ref()
                .is_none_or(|f| f.load_seq != load_seq || f.conv_id != conv_id)
            {
                complete_op(op_id, out);
                return;
            }
            let mut added_count = 0usize;
            if had_before_cursor && !rows.is_empty() {
                let snap = state.identity_snapshot();
                let mut decoded_count = 0usize;
                for row in &rows {
                    if let Some(msg) = decode_db_stored(row) {
                        decoded_count += 1;
                        let exists = state
                            .messages
                            .windows
                            .get(&conv_id)
                            .is_some_and(|l| l.iter().any(|m| m.id == msg.id));
                        if !exists {
                            added_count += 1;
                        }
                        if matches!(
                            state.messages.merge_message(msg, None, &snap),
                            WindowChange::Changed(_)
                        ) {
                            out.dirty.insert(DirtyKey::Messages);
                        }
                    }
                }
                let self_conv_id = state.session.self_conversation_id.as_deref();
                if decoded_count < 45
                    && !is_group_id(&conv_id)
                    && Some(conv_id.as_str()) != self_conv_id
                    && state
                        .messages
                        .has_more_history
                        .insert(conv_id.clone(), false)
                        != Some(false)
                {
                    out.dirty.insert(DirtyKey::MessageMeta);
                }
            }

            if added_count == 0 {
                let before_msg_id = state
                    .messages
                    .windows
                    .get(&conv_id)
                    .and_then(|l| l.first())
                    .and_then(|m| numeric_msg_cursor(&m.id));
                out.effects.push(Effect::FetchHistoryPageApi {
                    conv_id,
                    before_msg_id,
                    count: 50,
                    is_old: None,
                    purpose: crate::effect::HistoryFetchPurpose::LoadOlder { load_seq, op_id },
                });
            } else {
                begin_sender_profile_resolution(
                    state,
                    &conv_id,
                    SenderResolveFollowup::LoadOlder {
                        load_seq,
                        conv_id: conv_id.clone(),
                        op_id,
                    },
                    out,
                );
            }
        }

        Input::LoadOlderPageFetched {
            load_seq,
            conv_id,
            before_msg_id,
            page,
            op_id,
        } => {
            if state
                .messages
                .active_load_older
                .as_ref()
                .is_none_or(|f| f.load_seq != load_seq || f.conv_id != conv_id)
            {
                complete_op(op_id, out);
                return;
            }
            let fetched = match page {
                None => {
                    if before_msg_id.is_none() {
                        if matches!(
                            state.messages.ensure_window_exists(&conv_id),
                            WindowChange::Changed(_)
                        ) {
                            out.dirty.insert(DirtyKey::Messages);
                        }
                        if state
                            .messages
                            .windows
                            .get(&conv_id)
                            .is_none_or(Vec::is_empty)
                            && state
                                .messages
                                .has_more_history
                                .insert(conv_id.clone(), false)
                                != Some(false)
                        {
                            out.dirty.insert(DirtyKey::MessageMeta);
                        }
                    }
                    0
                }
                Some(page_obj) => apply_fetched_history_page(
                    state,
                    &conv_id,
                    page_obj,
                    before_msg_id.as_deref(),
                    50,
                    out,
                ),
            };
            if fetched == 0
                && state
                    .messages
                    .has_more_history
                    .insert(conv_id.clone(), false)
                    != Some(false)
            {
                out.dirty.insert(DirtyKey::MessageMeta);
            }
            begin_sender_profile_resolution(
                state,
                &conv_id,
                SenderResolveFollowup::LoadOlder {
                    load_seq,
                    conv_id: conv_id.clone(),
                    op_id,
                },
                out,
            );
        }

        Input::SenderProfilesChunkDone {
            resolve_id,
            conv_id,
            remaining_chunks,
            profiles_map,
            mut cache_updated,
        } => {
            for (uid, raw_row) in profiles_map {
                let Some(row) = raw_row.as_object() else {
                    continue;
                };
                let trimmed = strip_user_prefix(&uid);
                let clean = sanitize_profile_uid(&trimmed).unwrap_or(trimmed);
                let fetched_name = preferred_contact_name(row);
                let avt = olaz_wire::lossless::string(row.get("avatar").or_else(|| row.get("avt")));
                if !clean.is_empty() && (!fetched_name.is_empty() || !avt.is_empty()) {
                    state.conversations.identities.cached_profiles.insert(
                        clean,
                        CachedProfile {
                            name: fetched_name,
                            avatar: avt,
                        },
                    );
                    cache_updated = true;
                }
            }

            if !remaining_chunks.is_empty() {
                let mut rem = remaining_chunks;
                let next_chunk = rem.remove(0);
                out.effects.push(Effect::FetchSenderProfilesChunkApi {
                    resolve_id,
                    conv_id,
                    chunk: next_chunk,
                    remaining_chunks: rem,
                    cache_updated,
                });
                return;
            }

            if cache_updated {
                out.dirty.insert(DirtyKey::Conversations);
                if let Some(data) =
                    serialize_cached_profiles_json(&state.conversations.identities.cached_profiles)
                {
                    out.effects.push(Effect::Store(StoreOp::SetPreferenceData {
                        key: "cachedProfiles".to_owned(),
                        data,
                    }));
                }
                let snap = state.identity_snapshot();
                let (to_persist, win_changed) = state
                    .messages
                    .apply_resolved_sender_profiles(&conv_id, &snap);
                if win_changed {
                    out.dirty.insert(DirtyKey::Messages);
                }
                if !to_persist.is_empty() {
                    out.effects.push(Effect::Store(StoreOp::SaveMessages {
                        rows: to_persist,
                        preserve_existing_reactions: true,
                    }));
                }
            }

            let snap = state.identity_snapshot();
            let (react_rows, react_ops) =
                state.messages.refresh_reaction_names(Some(&conv_id), &snap);
            if !react_ops.is_empty() {
                out.dirty.insert(DirtyKey::Messages);
            }
            if !react_rows.is_empty() {
                out.effects.push(Effect::Store(StoreOp::SaveMessages {
                    rows: react_rows,
                    preserve_existing_reactions: true,
                }));
            }

            if let Some(followup) = state.messages.pending_sender_resolves.remove(&resolve_id) {
                finish_sender_resolve_followup(state, followup, out);
            }
        }

        Input::FreshnessProbed { probes, .. } => {
            if state.messages.record_freshness_probes(&probes) {
                out.dirty.insert(DirtyKey::MessageMeta);
            }
        }

        Input::TypedEnvelopeReady {
            increment_unread,
            notify_incoming,
            envelope,
            ..
        } => {
            let snap = state.identity_snapshot();
            let events = if !snap.my_uid.is_empty() {
                let mut names = Vec::with_capacity(envelope.uids.len());
                for uid in &envelope.uids {
                    if let Some(info) = snap.lookup_person(uid) {
                        names.push((uid.clone(), info));
                    }
                }
                envelope
                    .payload
                    .resolve(
                        &snap.my_uid,
                        state.session.self_conversation_id.as_deref(),
                        &names,
                    )
                    .unwrap_or(envelope.events)
            } else {
                envelope.events
            };
            let _ = ingest_parsed_events_in_core(
                state,
                &events,
                increment_unread,
                notify_incoming,
                true,
                false,
                out,
            );
            out.effects
                .push(Effect::Host(HostCall::TransportBatchSettled));
        }

        Input::DecryptedEnvelopeReady {
            payload,
            default_cmd,
            fallback_conv_id,
            is_group_hint,
            increment_unread,
            notify_incoming,
            persist_conversations,
            probe_freshness,
            poll_batch_done,
            op_id,
        } => {
            let applied = ingest_wire_batch_in_core(
                state,
                &Value::Object(payload),
                default_cmd,
                fallback_conv_id.as_deref(),
                is_group_hint,
                increment_unread,
                notify_incoming,
                persist_conversations,
                probe_freshness,
                out,
            );
            if let Some((lp_gen, drain_id)) = poll_batch_done {
                crate::reduce::transport::finish_poll_batch_in_core(
                    state, lp_gen, drain_id, applied, out,
                );
            }
            if let Some(id) = op_id {
                out.effects.push(Effect::CompleteOp {
                    op_id: id,
                    result: OpResult::Int(i64::from(applied)),
                    after_store: true,
                });
            } else {
                out.effects
                    .push(Effect::Host(HostCall::TransportBatchSettled));
            }
        }

        _ => {}
    }
}

fn reduce_message_command(
    state: &mut CoreState,
    cmd: Command,
    op_id: Option<u64>,
    out: &mut ReduceOutput,
) {
    match cmd {
        Command::OpenConversation {
            id,
            preloaded,
            skip_local_read,
        } => {
            if id.is_empty() {
                complete_op(op_id, out);
                return;
            }
            state.messages.open_seq = state.messages.open_seq.saturating_add(1);
            let open_seq = state.messages.open_seq;
            let changed = state.conversations.open_conversation_id.as_deref() != Some(id.as_str());
            state.conversations.open_conversation_id = Some(id.clone());

            if matches!(
                state.messages.ensure_window_exists(&id),
                WindowChange::Changed(_)
            ) {
                out.dirty.insert(DirtyKey::Messages);
            }

            if !preloaded.is_empty() {
                let snap = state.identity_snapshot();
                let count = preloaded.len();
                let rows: Vec<(ChatMessage, Option<String>)> =
                    preloaded.into_iter().map(|m| (m, None)).collect();
                let ops = state.messages.merge_messages_page(&id, rows, &snap);
                if !ops.is_empty() {
                    out.dirty.insert(DirtyKey::Messages);
                }
                if count >= 45
                    && state.messages.has_more_history.insert(id.clone(), true) != Some(true)
                {
                    out.dirty.insert(DirtyKey::MessageMeta);
                }
            }

            if changed && state.forward.clear_request() {
                out.dirty.insert(DirtyKey::ForwardRequest);
            }
            out.effects
                .push(Effect::Host(HostCall::OnOpenConversationSync {
                    conv_id: id.clone(),
                    changed,
                }));

            state.messages.active_open = Some(crate::messages::OpenFlowState {
                open_seq,
                conv_id: id.clone(),
                op_id,
                fetched_count: 0,
            });

            let window_empty = state.messages.windows.get(&id).is_none_or(Vec::is_empty);
            if window_empty && !skip_local_read {
                out.effects
                    .push(Effect::Store(StoreOp::LoadOpenLocalMessages {
                        open_seq,
                        conv_id: id,
                        limit: 50,
                        op_id,
                    }));
            } else {
                begin_open_step2(state, open_seq, &id, op_id, out);
            }
        }

        Command::CloseConversation => {
            state.messages.open_seq = state.messages.open_seq.saturating_add(1);
            state.messages.active_open = None;
            state.conversations.open_conversation_id = None;
            if state.forward.clear_request() {
                out.dirty.insert(DirtyKey::ForwardRequest);
            }
            out.effects
                .push(Effect::Host(HostCall::OnCloseConversation));
            complete_op(op_id, out);
        }

        Command::LoadOlderMessages { id } => {
            if id.is_empty() {
                complete_op(op_id, out);
                return;
            }
            state.messages.load_older_seq = state.messages.load_older_seq.saturating_add(1);
            let load_seq = state.messages.load_older_seq;
            state.messages.active_load_older = Some(crate::messages::LoadOlderFlowState {
                load_seq,
                conv_id: id.clone(),
                op_id,
            });
            let before_ts_ms = state
                .messages
                .windows
                .get(&id)
                .and_then(|l| l.first())
                .map(|m| m.date_ms);
            if let Some(ts_ms) = before_ts_ms {
                out.effects
                    .push(Effect::Store(StoreOp::LoadOlderStoreMessages {
                        load_seq,
                        conv_id: id,
                        before_ts_ms: ts_ms,
                        limit: 50,
                        op_id,
                    }));
            } else {
                out.effects.push(Effect::FetchHistoryPageApi {
                    conv_id: id,
                    before_msg_id: None,
                    count: 50,
                    is_old: None,
                    purpose: crate::effect::HistoryFetchPurpose::LoadOlder { load_seq, op_id },
                });
            }
        }

        Command::ApplyBatchDirect {
            payload,
            default_cmd,
            fallback_conv_id,
            is_group_hint,
            increment_unread,
            notify_incoming,
            persist_conversations,
            probe_freshness,
            now_ms,
        } => {
            let my_uid = state
                .session
                .profile
                .as_ref()
                .map_or("", |p| p.user_id.as_str())
                .to_owned();
            let root_val = Value::Object(payload.clone());
            if !my_uid.is_empty() && olaz_wire::envelope_contains_signal_cipher(&root_val) {
                out.effects.push(Effect::Host(HostCall::DecryptEnvelope {
                    payload,
                    default_cmd,
                    fallback_conv_id,
                    is_group_hint,
                    increment_unread,
                    notify_incoming,
                    persist_conversations,
                    probe_freshness,
                    poll_batch_done: None,
                    op_id,
                }));
                return;
            }
            let applied = ingest_wire_batch_with_now(
                state,
                &root_val,
                default_cmd,
                fallback_conv_id.as_deref(),
                is_group_hint,
                increment_unread,
                notify_incoming,
                persist_conversations,
                probe_freshness,
                now_ms,
                out,
            );
            if let Some(id) = op_id {
                out.effects.push(Effect::CompleteOp {
                    op_id: id,
                    result: OpResult::Int(i64::from(applied)),
                    after_store: true,
                });
            } else {
                out.effects
                    .push(Effect::Host(HostCall::TransportBatchSettled));
            }
        }

        Command::ApplyParsedEventsDirect {
            events,
            increment_unread,
            notify_incoming,
            persist_conversations,
        } => {
            let applied = ingest_parsed_events_in_core(
                state,
                &events,
                increment_unread,
                notify_incoming,
                persist_conversations,
                false,
                out,
            );
            if let Some(id) = op_id {
                out.effects.push(Effect::CompleteOp {
                    op_id: id,
                    result: OpResult::Int(i64::from(applied)),
                    after_store: true,
                });
            } else {
                out.effects
                    .push(Effect::Host(HostCall::TransportBatchSettled));
            }
        }

        Command::WriteThroughUpsertMessage {
            msg,
            replacing_client_id,
        } => {
            let snap = state.identity_snapshot();
            if matches!(
                state
                    .messages
                    .write_through_upsert(*msg, replacing_client_id.as_deref(), &snap),
                WindowChange::Changed(_)
            ) {
                out.dirty.insert(DirtyKey::Messages);
            }
            complete_op(op_id, out);
        }

        Command::WriteThroughRemoveMessages { conv_id, ids } => {
            if matches!(
                state.messages.write_through_remove(&conv_id, &ids),
                WindowChange::Changed(_)
            ) {
                out.dirty.insert(DirtyKey::Messages);
            }
            complete_op(op_id, out);
        }

        Command::WriteThroughReplaceWindow { conv_id, messages } => {
            let snap = state.identity_snapshot();
            if matches!(
                state
                    .messages
                    .write_through_replace_window(&conv_id, messages, &snap),
                WindowChange::Changed(_)
            ) {
                out.dirty.insert(DirtyKey::Messages);
            }
            complete_op(op_id, out);
        }

        Command::WriteThroughSetHasMore { conv_id, has_more } => {
            if state.messages.has_more_history.insert(conv_id, has_more) != Some(has_more) {
                out.dirty.insert(DirtyKey::MessageMeta);
            }
            complete_op(op_id, out);
        }

        Command::WriteThroughRemoveWindow { conv_id } => {
            let (win_removed, meta_removed) = state.messages.remove_conversation_window(&conv_id);
            if win_removed {
                out.dirty.insert(DirtyKey::Messages);
            }
            if meta_removed {
                out.dirty.insert(DirtyKey::MessageMeta);
            }
            complete_op(op_id, out);
        }

        Command::RefreshReactionNames { conv_id } => {
            let snap = state.identity_snapshot();
            let (rows, ops) = state
                .messages
                .refresh_reaction_names(conv_id.as_deref(), &snap);
            if !ops.is_empty() {
                out.dirty.insert(DirtyKey::Messages);
            }
            let wrote_store = !rows.is_empty();
            if wrote_store {
                out.effects.push(Effect::Store(StoreOp::SaveMessages {
                    rows,
                    preserve_existing_reactions: true,
                }));
            }
            complete_op_after_store(op_id, wrote_store, out);
        }

        Command::SeedHistoryFreshness(entries) => {
            state.messages.history_freshness = entries.into_iter().collect();
            out.dirty.insert(DirtyKey::MessageMeta);
            complete_op(op_id, out);
        }

        Command::SeedContacts(contacts) => {
            state.contacts = *contacts;
            out.dirty.insert(DirtyKey::Contacts);
            complete_op(op_id, out);
        }

        _ => {
            complete_op(op_id, out);
        }
    }
}

fn begin_open_step2(
    state: &mut CoreState,
    open_seq: u64,
    conv_id: &str,
    op_id: Option<u64>,
    out: &mut ReduceOutput,
) {
    if state.messages.is_recent_history_up_to_date(conv_id) {
        begin_sender_profile_resolution(
            state,
            conv_id,
            SenderResolveFollowup::Open {
                open_seq,
                conv_id: conv_id.to_owned(),
                fetched_count: 0,
                op_id,
            },
            out,
        );
    } else {
        out.effects.push(Effect::FetchHistoryPageApi {
            conv_id: conv_id.to_owned(),
            before_msg_id: None,
            count: 50,
            is_old: Some(false),
            purpose: crate::effect::HistoryFetchPurpose::Open { open_seq, op_id },
        });
    }
}

fn apply_fetched_history_page(
    state: &mut CoreState,
    conv_id: &str,
    page_obj: Map<String, Value>,
    before_msg_id: Option<&str>,
    count: usize,
    out: &mut ReduceOutput,
) -> usize {
    let my_uid = state
        .session
        .profile
        .as_ref()
        .map_or("", |p| p.user_id.as_str())
        .to_owned();
    let self_conv_id = state.session.self_conversation_id.clone();
    let is_grp = is_group_id(conv_id);
    let is_self = Some(conv_id) == self_conv_id.as_deref();
    let fallback_conv = (is_grp || is_self).then_some(conv_id);
    let is_group_hint = if is_grp {
        Some(true)
    } else if is_self {
        Some(false)
    } else {
        None
    };

    let snap = state.identity_snapshot();
    let events = parse_batch_events(
        &Value::Object(page_obj),
        &my_uid,
        self_conv_id.as_deref(),
        0,
        fallback_conv,
        is_group_hint,
        &snap,
    );

    let pass1 = state.messages.apply_history_page_pass1(
        conv_id,
        &events,
        before_msg_id,
        count,
        self_conv_id.as_deref(),
        &snap,
    );
    if pass1.windows_changed {
        out.dirty.insert(DirtyKey::Messages);
    }
    if pass1.meta_changed {
        out.dirty.insert(DirtyKey::MessageMeta);
    }
    if !pass1.stored_rows.is_empty() {
        out.effects.push(Effect::Store(StoreOp::SaveMessages {
            rows: pass1.stored_rows,
            preserve_existing_reactions: true,
        }));
    }

    // Pass 2 on history page: chronological reactions, then recalls & deletes (which update preview).
    emit_pass2_events(
        state,
        &events,
        Pass2Options {
            update_preview_immediately: true,
            emit_typing: false,
            persist_conversations: true,
            now_ms: None,
        },
        out,
    );

    pass1.new_visible_count
}

fn begin_sender_profile_resolution(
    state: &mut CoreState,
    conv_id: &str,
    followup: SenderResolveFollowup,
    out: &mut ReduceOutput,
) {
    let my_uid = state
        .session
        .profile
        .as_ref()
        .map_or("", |p| p.user_id.as_str())
        .to_owned();
    let snap = state.identity_snapshot();
    let unknown_uids = state
        .messages
        .windows
        .get(conv_id)
        .map_or_else(Vec::new, |list| {
            collect_missing_sender_uids(list, &my_uid, &snap)
        });

    if unknown_uids.is_empty() {
        let (react_rows, react_ops) = state.messages.refresh_reaction_names(Some(conv_id), &snap);
        if !react_ops.is_empty() {
            out.dirty.insert(DirtyKey::Messages);
        }
        if !react_rows.is_empty() {
            out.effects.push(Effect::Store(StoreOp::SaveMessages {
                rows: react_rows,
                preserve_existing_reactions: true,
            }));
        }
        finish_sender_resolve_followup(state, followup, out);
        return;
    }

    let mut chunks: Vec<Vec<String>> = unknown_uids
        .chunks(SENDER_PROFILES_CHUNK_SIZE)
        .map(<[String]>::to_vec)
        .collect();
    let first_chunk = chunks.remove(0);

    let resolve_id = state
        .messages
        .open_seq
        .wrapping_add(state.messages.load_older_seq)
        .wrapping_add(u64::try_from(state.messages.pending_sender_resolves.len()).unwrap_or(0))
        .wrapping_add(1);
    state
        .messages
        .pending_sender_resolves
        .insert(resolve_id, followup);
    out.effects.push(Effect::FetchSenderProfilesChunkApi {
        resolve_id,
        conv_id: conv_id.to_owned(),
        chunk: first_chunk,
        remaining_chunks: chunks,
        cache_updated: false,
    });
}

fn finish_sender_resolve_followup(
    state: &mut CoreState,
    followup: SenderResolveFollowup,
    out: &mut ReduceOutput,
) {
    match followup {
        SenderResolveFollowup::Open {
            open_seq,
            conv_id,
            fetched_count,
            op_id,
        } => {
            if state
                .messages
                .active_open
                .as_ref()
                .is_none_or(|f| f.open_seq != open_seq || f.conv_id != conv_id)
            {
                complete_op(op_id, out);
                return;
            }
            state.messages.active_open = None;

            let missing_preview = state
                .conversations
                .conversations
                .iter()
                .find(|c| c.id == conv_id)
                .is_none_or(|c| c.preview.is_none());
            if (fetched_count > 0 || missing_preview)
                && let Some(latest) = state
                    .messages
                    .windows
                    .get(&conv_id)
                    .and_then(|l| l.last())
                    .cloned()
            {
                conversations::reduce_conversations(
                    state,
                    Input::Command(Command::UpdateConversationOnMessage {
                        msg: MessagePreviewInput::from_chat_message(&latest),
                        increment_unread: false,
                    }),
                    out,
                );
            }

            let is_grp = is_group_id(&conv_id);
            let is_friend = state
                .conversations
                .identities
                .friends
                .iter()
                .any(|f| f.id == conv_id)
                || state.contacts.friends.iter().any(|f| f.id == conv_id);
            let seen_target = state.messages.seen_target_for(&conv_id);
            if is_grp || is_friend {
                let req_gen = state.pins.current_gen(&conv_id);
                out.effects.push(Effect::RefreshBoardPins {
                    conv_id: conv_id.clone(),
                    req_gen,
                    followup: crate::pins::RefreshBoardFollowup::OpenConversation {
                        conv_id,
                        seen_target,
                        op_id,
                    },
                });
            } else {
                out.effects.push(Effect::EngineLog(
                    "pins: list skipped (1-1 not in friends)".to_owned(),
                ));
                out.effects.push(Effect::Host(HostCall::MarkReadBoundary {
                    conv_id,
                    seen_target,
                }));
                complete_op_after_store(op_id, true, out);
            }
        }

        SenderResolveFollowup::LoadOlder {
            load_seq,
            conv_id,
            op_id,
        } => {
            if state
                .messages
                .active_load_older
                .as_ref()
                .is_none_or(|f| f.load_seq != load_seq || f.conv_id != conv_id)
            {
                complete_op(op_id, out);
                return;
            }
            state.messages.active_load_older = None;
            let next_tick = state
                .messages
                .history_ticks
                .get(&conv_id)
                .copied()
                .unwrap_or(0)
                .saturating_add(1);
            state.messages.history_ticks.insert(conv_id, next_tick);
            out.dirty.insert(DirtyKey::MessageMeta);
            complete_op_after_store(op_id, true, out);
        }
    }
}

/// Ingests a raw wire JSON batch inside `olaz-core` (Pass 1 + Pass 2 + conversation delta).
#[expect(
    clippy::too_many_arguments,
    reason = "Matches ZaloEngine.applyBatchResponse parameter list 1-for-1"
)]
pub(crate) fn ingest_wire_batch_in_core(
    state: &mut CoreState,
    root: &Value,
    default_cmd: u16,
    fallback_conv_id: Option<&str>,
    is_group_hint: Option<bool>,
    increment_unread: bool,
    notify_incoming: bool,
    persist_conversations: bool,
    probe_freshness: bool,
    out: &mut ReduceOutput,
) -> u32 {
    ingest_wire_batch_with_now(
        state,
        root,
        default_cmd,
        fallback_conv_id,
        is_group_hint,
        increment_unread,
        notify_incoming,
        persist_conversations,
        probe_freshness,
        None,
        out,
    )
}

#[expect(
    clippy::too_many_arguments,
    reason = "Matches ZaloEngine.applyBatchResponse parameter list 1-for-1"
)]
fn ingest_wire_batch_with_now(
    state: &mut CoreState,
    root: &Value,
    default_cmd: u16,
    fallback_conv_id: Option<&str>,
    is_group_hint: Option<bool>,
    increment_unread: bool,
    notify_incoming: bool,
    persist_conversations: bool,
    probe_freshness: bool,
    now_ms: Option<i64>,
    out: &mut ReduceOutput,
) -> u32 {
    let my_uid = state
        .session
        .profile
        .as_ref()
        .map_or("", |p| p.user_id.as_str())
        .to_owned();
    let self_conv_id = state.session.self_conversation_id.clone();
    let snap = state.identity_snapshot();
    let events = parse_batch_events(
        root,
        &my_uid,
        self_conv_id.as_deref(),
        default_cmd,
        fallback_conv_id,
        is_group_hint,
        &snap,
    );
    ingest_parsed_events_with_now(
        state,
        &events,
        increment_unread,
        notify_incoming,
        persist_conversations,
        probe_freshness,
        now_ms,
        out,
    )
}

/// Ingests parsed `[ParsedWireEvent]` inside `olaz-core` (Pass 1 + Pass 2 + conversation delta + notifications).
pub(crate) fn ingest_parsed_events_in_core(
    state: &mut CoreState,
    events: &[ParsedWireEvent],
    increment_unread: bool,
    notify_incoming: bool,
    persist_conversations: bool,
    probe_freshness: bool,
    out: &mut ReduceOutput,
) -> u32 {
    ingest_parsed_events_with_now(
        state,
        events,
        increment_unread,
        notify_incoming,
        persist_conversations,
        probe_freshness,
        None,
        out,
    )
}

#[expect(
    clippy::too_many_arguments,
    reason = "Internal wrapper threading optional deterministic now_ms for batch replay"
)]
fn ingest_parsed_events_with_now(
    state: &mut CoreState,
    events: &[ParsedWireEvent],
    increment_unread: bool,
    notify_incoming: bool,
    persist_conversations: bool,
    probe_freshness: bool,
    now_ms: Option<i64>,
    out: &mut ReduceOutput,
) -> u32 {
    if events.is_empty() {
        return 0;
    }

    let probe_targets: BTreeMap<String, String> = if probe_freshness {
        newest_message_ids(events)
    } else {
        BTreeMap::new()
    };

    let self_conv_id = state.session.self_conversation_id.clone();
    let snap = state.identity_snapshot();
    let my_uid = snap.my_uid.clone();

    let mut stored_rows = Vec::new();
    let mut e2ee_conv_ids = Vec::new();
    let mut e2ee_seen = std::collections::HashSet::new();
    let mut unread_delta_by_conv: BTreeMap<String, i64> = BTreeMap::new();
    let mut latest_by_conv: BTreeMap<String, ChatMessage> = BTreeMap::new();
    let mut incoming_for_notice = Vec::new();

    for ev in events {
        if let ParsedWireEvent::Message(msg, stored) = ev {
            if msg.is_e2ee
                && !is_group_id(&msg.conversation_id)
                && Some(msg.conversation_id.as_str()) != self_conv_id.as_deref()
                && e2ee_seen.insert(msg.conversation_id.clone())
            {
                e2ee_conv_ids.push(msg.conversation_id.clone());
            }
            let is_locked_e2ee = stored.status == "e2ee_locked";
            if is_locked_e2ee
                && let Some(mem_list) = state.messages.windows.get(&msg.conversation_id)
                && let Some(readable) = mem_list.iter().find(|existing| {
                    (existing.id == msg.id
                        || (!stored.client_id.is_empty() && existing.id == stored.client_id))
                        && !(matches!(existing.kind, olaz_wire::Kind::Placeholder { .. })
                            && existing.is_e2ee)
                })
            {
                let readable_id = readable.id.clone();
                if readable_id != msg.id && !msg.id.is_empty() && readable_id == stored.client_id {
                    if matches!(
                        state.messages.merge_message(
                            (**msg).clone(),
                            Some(&stored.client_id),
                            &snap
                        ),
                        WindowChange::Changed(_)
                    ) {
                        out.dirty.insert(DirtyKey::Messages);
                    }
                    stored_rows.push(crate::messages::to_db_stored(stored));
                }
                continue;
            }

            let already_known = state
                .messages
                .windows
                .get(&msg.conversation_id)
                .is_some_and(|l| l.iter().any(|m| m.id == msg.id));
            stored_rows.push(crate::messages::to_db_stored(stored));
            if matches!(
                state
                    .messages
                    .merge_message((**msg).clone(), Some(&stored.client_id), &snap),
                WindowChange::Changed(_)
            ) {
                out.dirty.insert(DirtyKey::Messages);
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
                && state.conversations.open_conversation_id.as_deref()
                    != Some(msg.conversation_id.as_str())
            {
                *unread_delta_by_conv
                    .entry(msg.conversation_id.clone())
                    .or_insert(0) += 1;
                incoming_for_notice.push((**msg).clone());
            }
        }
    }

    if !e2ee_conv_ids.is_empty() {
        out.effects
            .push(Effect::Host(HostCall::MarkE2eeConversations {
                conv_ids: e2ee_conv_ids,
            }));
    }

    if !probe_targets.is_empty() {
        out.effects
            .push(Effect::Store(StoreOp::ProbeAndSaveMessages {
                probe_targets,
                rows: stored_rows,
                preserve_existing_reactions: true,
                reply_boot_gen: None,
            }));
    } else if !stored_rows.is_empty() {
        out.effects.push(Effect::Store(StoreOp::SaveMessages {
            rows: stored_rows,
            preserve_existing_reactions: true,
        }));
    }

    // Pass 2: chronological reactions, recalls, deletes, typing.
    let preview_overrides = emit_pass2_events(
        state,
        events,
        Pass2Options {
            update_preview_immediately: false,
            emit_typing: true,
            persist_conversations,
            now_ms,
        },
        out,
    );

    let mut updates = Vec::with_capacity(latest_by_conv.len());
    let mut poll_msgs = Vec::with_capacity(latest_by_conv.len());
    for (conv_id, latest) in latest_by_conv {
        if matches!(latest.kind, olaz_wire::Kind::Poll(_)) {
            poll_msgs.push(latest.clone());
        }
        updates.push(ConvMessageDelta {
            conv_id: conv_id.clone(),
            preview_text: crate::conversations::message_preview_label(&latest),
            preview_date_ms: latest.date_ms,
            preview_from_me: latest.is_mine,
            is_mine: latest.is_mine,
            sender_name: latest.sender_name,
            sender_avatar: latest.sender_avatar,
            unread_delta: unread_delta_by_conv.get(&conv_id).copied().unwrap_or(0),
        });
    }
    if !poll_msgs.is_empty() {
        out.effects.push(Effect::Host(HostCall::NotePollMessages {
            messages: poll_msgs,
        }));
    }

    let applied_count = u32::try_from(events.len()).unwrap_or(u32::MAX);
    let delta = BatchApplyDelta {
        applied_count,
        updates,
        preview_overrides,
        persist_conversations,
    };
    conversations::apply_batch_delta(state, delta, out);

    if notify_incoming && !incoming_for_notice.is_empty() {
        out.effects
            .push(Effect::Host(HostCall::NotifyIncomingMessages {
                messages: incoming_for_notice,
            }));
    }

    let _ = my_uid;
    applied_count
}

struct Pass2Options {
    update_preview_immediately: bool,
    emit_typing: bool,
    persist_conversations: bool,
    now_ms: Option<i64>,
}

fn emit_pass2_events(
    state: &mut CoreState,
    events: &[ParsedWireEvent],
    opts: Pass2Options,
    out: &mut ReduceOutput,
) -> Vec<ConvPreviewOverride> {
    let has_messages = events
        .iter()
        .any(|e| matches!(e, ParsedWireEvent::Message(..)));
    let update_preview = opts.update_preview_immediately || !has_messages;
    for ev in sort_reaction_events_chronologically(events) {
        if let ParsedWireEvent::Reaction {
            conv_id,
            msg_id,
            cli_msg_id,
            sender_id,
            r_type,
            r_icon,
            event_id,
            react_client_id,
            sender_name,
            ..
        } = ev
        {
            out.effects
                .push(Effect::Host(HostCall::ApplyRemoteReaction {
                    conv_id,
                    msg_id,
                    cli_msg_id,
                    sender_id,
                    r_type,
                    r_icon,
                    event_id,
                    react_client_id,
                    sender_name,
                    now_ms: opts.now_ms.unwrap_or(0),
                }));
        }
    }

    let my_uid = state
        .session
        .profile
        .as_ref()
        .map_or("", |p| p.user_id.as_str())
        .to_owned();
    let preview_overrides = Vec::new();
    for ev in events {
        match ev {
            ParsedWireEvent::Undo {
                conv_id,
                msg_id,
                cli_msg_id,
            } => {
                out.effects.push(Effect::Host(HostCall::ApplyRemoteRecall {
                    conv_id: conv_id.clone(),
                    msg_id: msg_id.clone(),
                    cli_msg_id: cli_msg_id.clone(),
                    update_conversation_preview: update_preview,
                    persist_conversations: opts.persist_conversations,
                    op_id: None,
                    recall_many_id: None,
                }));
            }
            ParsedWireEvent::Delete {
                conv_id,
                msg_id,
                cli_msg_id,
            } => {
                out.effects.push(Effect::Host(HostCall::ApplyRemoteDelete {
                    conv_id: conv_id.clone(),
                    msg_id: msg_id.clone(),
                    cli_msg_id: cli_msg_id.clone(),
                    update_conversation_preview: update_preview,
                    persist_conversations: opts.persist_conversations,
                    cloud_delete_op_id: None,
                }));
            }
            ParsedWireEvent::Typing {
                conv_id, sender_id, ..
            } if opts.emit_typing && sender_id != &my_uid => {
                out.effects.push(Effect::Host(HostCall::ShowBatchTyping {
                    conv_id: conv_id.clone(),
                    sender_id: sender_id.clone(),
                }));
            }
            _ => {}
        }
    }
    preview_overrides
}

fn complete_op(op_id: Option<u64>, out: &mut ReduceOutput) {
    if let Some(id) = op_id {
        out.effects.push(Effect::CompleteOp {
            op_id: id,
            result: OpResult::Unit,
            after_store: false,
        });
    }
}

fn complete_op_after_store(op_id: Option<u64>, after_store: bool, out: &mut ReduceOutput) {
    if let Some(id) = op_id {
        out.effects.push(Effect::CompleteOp {
            op_id: id,
            result: OpResult::Unit,
            after_store,
        });
    }
}
