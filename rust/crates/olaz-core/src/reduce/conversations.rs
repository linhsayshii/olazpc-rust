//! Pure conversations & conversation-actions domain reducer (U3).
//!
//! No I/O, no clock, and no randomness live here (D9).

use std::collections::{BTreeMap, BTreeSet, HashMap};

use crate::changes::DirtyKey;
use crate::conversations::{
    BatchApplyDelta, ConversationActionResult, ConversationLabel, ConversationPreview,
    ConversationPrompt, PIN_LIMIT, parse_server_labels_response, serialize_labels_local_json,
    serialize_labels_server_json,
};
use crate::effect::{Effect, OpResult, StoreOp};
use crate::input::{Command, HiddenPinSyncKind, Input};
use crate::reduce::ReduceOutput;
use crate::state::CoreState;

const RESOLVE_NAMES_CHUNK_SIZE: usize = 50;

/// Applies a [`BatchApplyDelta`] computed by Swift's message-batch path to conversation state.
pub(crate) fn apply_batch_delta(
    state: &mut CoreState,
    delta: BatchApplyDelta,
    out: &mut ReduceOutput,
) {
    if delta.applied_count == 0 && delta.updates.is_empty() && delta.preview_overrides.is_empty() {
        return;
    }
    let override_ids: BTreeSet<String> = delta
        .preview_overrides
        .iter()
        .map(|ov| ov.conv_id.clone())
        .collect();
    let before_previews: HashMap<String, Option<ConversationPreview>> = if override_ids.is_empty() {
        HashMap::new()
    } else {
        state
            .conversations
            .conversations
            .iter()
            .filter(|c| override_ids.contains(&c.id))
            .map(|c| (c.id.clone(), c.preview.clone()))
            .collect()
    };

    let self_conv_id = state.session.self_conversation_id.clone();
    let (convs_changed, flags_changed, extras_changed) = state
        .conversations
        .apply_batch_delta(&delta, self_conv_id.as_deref());
    if convs_changed {
        out.dirty.insert(DirtyKey::Conversations);
    }
    if flags_changed {
        out.dirty.insert(DirtyKey::ConversationFlags);
    }
    if extras_changed {
        out.dirty.insert(DirtyKey::ConversationExtras);
    }
    if delta.persist_conversations {
        emit_save_conversations(state, out);
        for id in &override_ids {
            if let Some(conv) = state
                .conversations
                .conversations
                .iter()
                .find(|c| &c.id == id)
                && before_previews.get(id) != Some(&conv.preview)
            {
                out.effects
                    .push(Effect::Store(StoreOp::SetConversationPreview {
                        id: conv.id.clone(),
                        preview_text: conv
                            .preview
                            .as_ref()
                            .map_or_else(String::new, |p| p.text.clone()),
                        preview_ts_ms: conv.preview.as_ref().and_then(|p| p.date_ms).unwrap_or(0),
                        preview_from_me: conv.preview.as_ref().is_some_and(|p| p.from_me),
                    }));
            }
        }
    }
}

/// Reduces a U3 conversations / conversation_actions [`Input`].
pub(crate) fn reduce_conversations(state: &mut CoreState, input: Input, out: &mut ReduceOutput) {
    match input {
        Input::Command(cmd) => reduce_command(state, cmd, None, out),
        Input::OpRequest { op_id, cmd } => reduce_command(state, cmd, Some(op_id), out),
        Input::BatchDeltaApplied { delta } => apply_batch_delta(state, delta, out),

        Input::PinApiDone {
            id,
            pinned,
            ok,
            op_id,
        } => {
            if ok {
                if pinned {
                    state.conversations.pinned_ids.insert(id.clone());
                } else {
                    state.conversations.pinned_ids.remove(&id);
                }
                let self_conv_id = state.session.self_conversation_id.clone();
                state
                    .conversations
                    .apply_pin_status(&id, pinned, self_conv_id.as_deref());
                mark_list_flags_extras_dirty(out);
                out.effects
                    .push(Effect::Store(StoreOp::SetPreferenceStrings {
                        key: "pinnedIds".to_owned(),
                        values: sorted_set_vec(&state.conversations.pinned_ids),
                    }));
                out.effects
                    .push(Effect::Store(StoreOp::SetConversationPinned { id, pinned }));
                let text = if pinned {
                    "Đã ghim hội thoại"
                } else {
                    "Đã bỏ ghim hội thoại"
                };
                report_result(state, ConversationActionResult::ok(text), out);
                complete_op(op_id, OpResult::Unit, true, out);
            } else {
                let text = if pinned {
                    "Ghim hội thoại không thành công."
                } else {
                    "Bỏ ghim không thành công."
                };
                report_result(state, ConversationActionResult::fail(text), out);
                complete_op(op_id, OpResult::Unit, false, out);
            }
        }

        Input::PinReplacingStepDone {
            op_id,
            target_id,
            pinned,
            mut unpin_remaining,
            pin_id,
            ok,
        } => {
            if !ok {
                let res = ConversationActionResult::fail("Ghim hội thoại không thành công.");
                state.conversations.last_action_result = Some(res.clone());
                report_result(state, res.clone(), out);
                complete_op(op_id, OpResult::ActionResult(res), true, out);
                return;
            }
            let self_conv_id = state.session.self_conversation_id.clone();
            if !pinned {
                state.conversations.pinned_ids.remove(&target_id);
                state
                    .conversations
                    .apply_pin_status(&target_id, false, self_conv_id.as_deref());
                mark_list_flags_extras_dirty(out);
                out.effects
                    .push(Effect::Store(StoreOp::SetConversationPinned {
                        id: target_id,
                        pinned: false,
                    }));
                if !unpin_remaining.is_empty() {
                    let next = unpin_remaining.remove(0);
                    out.effects.push(Effect::PinReplacingApi {
                        op_id,
                        target_id: next,
                        pinned: false,
                        unpin_remaining,
                        pin_id,
                    });
                } else {
                    out.effects.push(Effect::PinReplacingApi {
                        op_id,
                        target_id: pin_id.clone(),
                        pinned: true,
                        unpin_remaining: Vec::new(),
                        pin_id,
                    });
                }
            } else {
                state.conversations.pinned_ids.insert(target_id.clone());
                state
                    .conversations
                    .apply_pin_status(&target_id, true, self_conv_id.as_deref());
                mark_list_flags_extras_dirty(out);
                out.effects
                    .push(Effect::Store(StoreOp::SetPreferenceStrings {
                        key: "pinnedIds".to_owned(),
                        values: sorted_set_vec(&state.conversations.pinned_ids),
                    }));
                out.effects
                    .push(Effect::Store(StoreOp::SetConversationPinned {
                        id: target_id,
                        pinned: true,
                    }));
                let res = ConversationActionResult::ok("Đã ghim hội thoại");
                state.conversations.last_action_result = Some(res.clone());
                report_result(state, res.clone(), out);
                complete_op(op_id, OpResult::ActionResult(res), true, out);
            }
        }

        Input::MoveApiDone {
            id,
            to_other,
            ok,
            op_id,
        } => {
            if ok {
                if to_other {
                    state.conversations.archived_ids.insert(id);
                } else {
                    state.conversations.archived_ids.remove(&id);
                }
                out.effects
                    .push(Effect::Store(StoreOp::SetPreferenceStrings {
                        key: "archivedIds".to_owned(),
                        values: sorted_set_vec(&state.conversations.archived_ids),
                    }));
                rebuild_flags_and_extras(state, out);
                let text = if to_other {
                    "Đã chuyển sang mục Khác"
                } else {
                    "Đã chuyển về Hộp thư đến"
                };
                report_result(
                    state,
                    ConversationActionResult::ok_neutral(text, to_other),
                    out,
                );
                complete_op(op_id, OpResult::Unit, true, out);
            } else {
                report_result(
                    state,
                    ConversationActionResult::fail("Không thể chuyển cuộc trò chuyện."),
                    out,
                );
                complete_op(op_id, OpResult::Unit, false, out);
            }
        }

        Input::DeleteApiDone { id, op_id } => {
            out.effects.push(Effect::Store(StoreOp::DeleteConversation {
                id: id.clone(),
            }));
            let prev_len = state.conversations.conversations.len();
            state.conversations.conversations.retain(|c| c.id != id);
            if state.conversations.conversations.len() != prev_len {
                out.dirty.insert(DirtyKey::Conversations);
            }
            if state.conversations.pinned_ids.remove(&id) {
                out.effects
                    .push(Effect::Store(StoreOp::SetPreferenceStrings {
                        key: "pinnedIds".to_owned(),
                        values: sorted_set_vec(&state.conversations.pinned_ids),
                    }));
            }
            if state.conversations.archived_ids.remove(&id) {
                out.effects
                    .push(Effect::Store(StoreOp::SetPreferenceStrings {
                        key: "archivedIds".to_owned(),
                        values: sorted_set_vec(&state.conversations.archived_ids),
                    }));
            }
            if state.conversations.unread_marks.remove(&id) {
                out.effects
                    .push(Effect::Store(StoreOp::SetPreferenceStrings {
                        key: "unreadMarks".to_owned(),
                        values: sorted_set_vec(&state.conversations.unread_marks),
                    }));
            }
            let (win_rm, meta_rm) = state.messages.remove_conversation_window(&id);
            if win_rm {
                out.dirty.insert(DirtyKey::Messages);
            }
            if meta_rm {
                out.dirty.insert(DirtyKey::MessageMeta);
            }
            state.conversations.ui.remove(BTreeSet::from([id]));
            out.dirty.insert(DirtyKey::ConversationUi);
            rebuild_flags_and_extras(state, out);
            report_result(state, ConversationActionResult::ok("Đã xóa hội thoại"), out);
            complete_op(op_id, OpResult::Unit, true, out);
        }

        Input::HiddenPinSyncDone {
            op_id,
            kind,
            ok,
            md5,
            sha256,
        } => {
            if !ok {
                let text = match kind {
                    HiddenPinSyncKind::HideNewPin { .. } => "Không thể cài mã PIN trò chuyện ẩn.",
                    HiddenPinSyncKind::SetPin { changed: true } => "Không thể đổi mã PIN.",
                    HiddenPinSyncKind::SetPin { changed: false } => "Không thể cài mã PIN.",
                };
                let res = ConversationActionResult::fail(text);
                state.conversations.last_action_result = Some(res.clone());
                complete_op(op_id, OpResult::ActionResult(res), false, out);
                return;
            }
            if let Some(md5_val) = md5 {
                state.conversations.hidden_pin_md5 = Some(md5_val.clone());
                out.effects
                    .push(Effect::Store(StoreOp::SetPreferenceString {
                        key: "hiddenPinMD5".to_owned(),
                        value: md5_val,
                    }));
            }
            state.conversations.hidden_pin_hash = Some(sha256.clone());
            out.effects
                .push(Effect::Store(StoreOp::SetPreferenceString {
                    key: "hiddenPinHash".to_owned(),
                    value: sha256,
                }));
            state.conversations.actions.has_hidden_pin = true;
            out.dirty.insert(DirtyKey::ConversationFlags);

            match kind {
                HiddenPinSyncKind::HideNewPin { conv_id } => {
                    state
                        .conversations
                        .actions
                        .hidden_ids
                        .insert(conv_id.clone());
                    out.effects
                        .push(Effect::Store(StoreOp::SetPreferenceStrings {
                            key: "hiddenIds".to_owned(),
                            values: sorted_set_vec(&state.conversations.actions.hidden_ids),
                        }));
                    state
                        .conversations
                        .ui
                        .remove(BTreeSet::from([conv_id.clone()]));
                    out.dirty.insert(DirtyKey::ConversationUi);
                    rebuild_flags_and_extras(state, out);
                    let res = ConversationActionResult::ok("Đã ẩn trò chuyện");
                    state.conversations.last_action_result = Some(res.clone());
                    out.effects.push(Effect::SetHiddenConversationApi {
                        conv_id,
                        hidden: true,
                        op_id,
                        result: Some(res),
                    });
                }
                HiddenPinSyncKind::SetPin { changed } => {
                    rebuild_flags_and_extras(state, out);
                    let text = if changed {
                        "Đã đổi mã PIN"
                    } else {
                        "Đã cài mã PIN"
                    };
                    let res = ConversationActionResult::ok(text);
                    state.conversations.last_action_result = Some(res.clone());
                    complete_op(op_id, OpResult::ActionResult(res), true, out);
                }
            }
        }

        Input::OpApiDone { op_id, result } => {
            complete_op(Some(op_id), result, true, out);
        }

        Input::OpStoreFlushed { op_id, result } => {
            complete_op(Some(op_id), result, false, out);
        }

        Input::ResetHiddenPinApiDone { op_id, ok } => {
            if !ok {
                let res = ConversationActionResult::fail("Không thể xóa mã PIN.");
                state.conversations.last_action_result = Some(res.clone());
                complete_op(op_id, OpResult::ActionResult(res), false, out);
                return;
            }
            let formerly_hidden = std::mem::take(&mut state.conversations.actions.hidden_ids);
            state.conversations.actions.has_hidden_pin = false;
            state.conversations.hidden_pin_hash = None;
            state.conversations.hidden_pin_md5 = None;
            out.effects.push(Effect::Store(StoreOp::DeletePreference {
                key: "hiddenPinHash".to_owned(),
            }));
            out.effects.push(Effect::Store(StoreOp::DeletePreference {
                key: "hiddenPinMD5".to_owned(),
            }));
            out.effects
                .push(Effect::Store(StoreOp::SetPreferenceStrings {
                    key: "hiddenIds".to_owned(),
                    values: Vec::new(),
                }));
            state.conversations.ui.remove(formerly_hidden);
            state.conversations.ui.relock();
            out.dirty.insert(DirtyKey::ConversationUi);
            out.dirty.insert(DirtyKey::ConversationFlags);
            rebuild_flags_and_extras(state, out);
            let res = ConversationActionResult::ok("Đã xóa mã PIN");
            state.conversations.last_action_result = Some(res.clone());
            complete_op(op_id, OpResult::ActionResult(res), true, out);
        }

        Input::SyncHiddenFetched { op_id, snapshot } => {
            if let Some(snap) = snapshot {
                apply_server_hidden(state, &snap.pin, &snap.thread_ids, op_id, out);
            } else {
                complete_op(op_id, OpResult::Unit, false, out);
            }
        }

        Input::ResolveNamesChunkDone {
            op_id,
            mut remaining_chunks,
            profiles_map,
            mut profiles_cache_changed,
        } => {
            let (cache_changed, convs_changed) =
                state.conversations.apply_resolved_profiles(&profiles_map);
            profiles_cache_changed |= cache_changed;
            if convs_changed {
                out.dirty.insert(DirtyKey::Conversations);
            }
            if !remaining_chunks.is_empty() {
                let next_chunk = remaining_chunks.remove(0);
                out.effects.push(Effect::FetchProfilesChunkApi {
                    op_id,
                    chunk: next_chunk,
                    remaining_chunks,
                    profiles_cache_changed,
                });
            } else {
                if profiles_cache_changed
                    && let Ok(bytes) =
                        serde_json::to_vec(&state.conversations.identities.cached_profiles)
                {
                    out.effects.push(Effect::Store(StoreOp::SetPreferenceData {
                        key: "cachedProfiles".to_owned(),
                        data: bytes,
                    }));
                }
                complete_op(op_id, OpResult::Unit, profiles_cache_changed, out);
            }
        }

        Input::MentionPreviewsLoaded { op_id, messages } => {
            let my_uid = state
                .session
                .profile
                .as_ref()
                .map(|p| p.user_id.clone())
                .unwrap_or_default();
            let my_avatar = state
                .session
                .profile
                .as_ref()
                .and_then(|p| p.avatar.clone());
            if state.conversations.apply_mention_preview_messages(
                &messages,
                &my_uid,
                my_avatar.as_deref(),
            ) {
                out.dirty.insert(DirtyKey::Conversations);
            }
            complete_op(op_id, OpResult::Unit, false, out);
        }

        Input::SyncLabelsFetched { op_id, payload } => {
            let Some(data) = payload else {
                complete_op(op_id, OpResult::Unit, false, out);
                return;
            };
            let parsed = parse_server_labels_response(&data);
            if parsed.is_empty() {
                complete_op(op_id, OpResult::Unit, false, out);
                return;
            }
            let local_bytes = serialize_labels_local_json(&parsed);
            state.conversations.set_labels_in_memory(parsed);
            let self_conv_id = state.session.self_conversation_id.clone();
            state
                .conversations
                .rebuild_conversation_extras(self_conv_id.as_deref());
            out.dirty.insert(DirtyKey::ConversationExtras);
            out.effects.push(Effect::Store(StoreOp::SetPreferenceData {
                key: "labels".to_owned(),
                data: local_bytes,
            }));
            complete_op(op_id, OpResult::Unit, true, out);
        }

        _ => {}
    }
}

fn reduce_command(state: &mut CoreState, cmd: Command, op_id: Option<u64>, out: &mut ReduceOutput) {
    match cmd {
        Command::UpdateIdentities(table) => {
            state.conversations.identities = table;
            complete_op(op_id, OpResult::Unit, false, out);
        }

        Command::ApplyBatchDelta(delta) => {
            let persist = delta.persist_conversations;
            apply_batch_delta(state, delta, out);
            complete_op(op_id, OpResult::Unit, persist, out);
        }

        Command::UpdateConversationOnMessage {
            msg,
            increment_unread,
        } => {
            let my_uid = state
                .session
                .profile
                .as_ref()
                .map(|p| p.user_id.clone())
                .unwrap_or_default();
            let my_avatar = state
                .session
                .profile
                .as_ref()
                .and_then(|p| p.avatar.clone());
            let self_conv_id = state.session.self_conversation_id.clone();
            let changed = state.conversations.update_conversation_on_message(
                &msg,
                increment_unread,
                &my_uid,
                my_avatar.as_deref(),
                self_conv_id.as_deref(),
            );
            if changed {
                mark_list_flags_extras_dirty(out);
                emit_save_conversations(state, out);
            }
            complete_op(op_id, OpResult::Unit, changed, out);
        }

        Command::EnsureKnownContacts => {
            let self_conv_id = state.session.self_conversation_id.clone();
            if state
                .conversations
                .ensure_known_contacts(self_conv_id.as_deref())
            {
                out.dirty.insert(DirtyKey::Conversations);
            }
            rebuild_flags_and_extras(state, out);
            complete_op(op_id, OpResult::Unit, false, out);
        }

        Command::ResolveMissingNames => {
            let self_conv_id = state.session.self_conversation_id.clone();
            let missing = state
                .conversations
                .missing_name_uids(self_conv_id.as_deref());
            if missing.is_empty() {
                complete_op(op_id, OpResult::Unit, false, out);
                return;
            }
            let mut chunks: Vec<Vec<String>> = missing
                .chunks(RESOLVE_NAMES_CHUNK_SIZE)
                .map(<[String]>::to_vec)
                .collect();
            let first = chunks.remove(0);
            out.effects.push(Effect::FetchProfilesChunkApi {
                op_id,
                chunk: first,
                remaining_chunks: chunks,
                profiles_cache_changed: false,
            });
        }

        Command::RefreshMentionPreviews => {
            let group_ids: Vec<String> = state
                .conversations
                .conversations
                .iter()
                .filter(|c| c.is_group && c.preview.as_ref().is_some_and(|p| p.text.contains('@')))
                .map(|c| c.id.clone())
                .collect();
            if group_ids.is_empty() {
                complete_op(op_id, OpResult::Unit, false, out);
                return;
            }
            let my_uid = state
                .session
                .profile
                .as_ref()
                .map(|p| p.user_id.clone())
                .unwrap_or_default();
            out.effects
                .push(Effect::Store(StoreOp::LoadMentionPreviewMessages {
                    op_id,
                    group_ids,
                    my_uid,
                }));
        }

        Command::SetOpenConversation { id } => {
            state.conversations.open_conversation_id = id;
            complete_op(op_id, OpResult::Unit, false, out);
        }

        Command::PinConversation { id } => {
            let pinned_count = state.conversations.pinned_ids.len();
            if !state.conversations.pinned_ids.contains(&id) && pinned_count >= PIN_LIMIT {
                state.conversations.prompt = Some(ConversationPrompt::PinBoard(id));
                out.dirty.insert(DirtyKey::ConversationPrompt);
                complete_op(op_id, OpResult::Unit, false, out);
                return;
            }
            out.effects.push(Effect::UpdatePinnedConversationApi {
                id,
                pinned: true,
                op_id,
            });
        }

        Command::UnpinConversation { id } => {
            out.effects.push(Effect::UpdatePinnedConversationApi {
                id,
                pinned: false,
                op_id,
            });
        }

        Command::RequestPinBoard { .. } => {
            let board = state.conversations.compute_pin_board();
            state.conversations.last_pin_board = Some(board.clone());
            complete_op(op_id, OpResult::PinBoard(Some(board)), false, out);
        }

        Command::PinReplacing {
            mut unpin_ids,
            pin_id,
        } => {
            if !unpin_ids.is_empty() {
                let first = unpin_ids.remove(0);
                out.effects.push(Effect::PinReplacingApi {
                    op_id,
                    target_id: first,
                    pinned: false,
                    unpin_remaining: unpin_ids,
                    pin_id,
                });
            } else {
                out.effects.push(Effect::PinReplacingApi {
                    op_id,
                    target_id: pin_id.clone(),
                    pinned: true,
                    unpin_remaining: Vec::new(),
                    pin_id,
                });
            }
        }

        Command::MoveConversation { id, to_other } => {
            out.effects.push(Effect::UpdateArchivedChatApi {
                id,
                archived: to_other,
                op_id,
            });
        }

        Command::RequestDeleteConversation { id } => {
            state.conversations.prompt = Some(ConversationPrompt::Delete(id));
            out.dirty.insert(DirtyKey::ConversationPrompt);
            complete_op(op_id, OpResult::Unit, false, out);
        }

        Command::ConfirmDeleteConversation {
            id,
            last_cli_msg_id,
        } => {
            out.effects.push(Effect::DeleteConversationApi {
                id,
                last_cli_msg_id,
                op_id,
            });
        }

        Command::DismissConversationPrompt => {
            if state.conversations.prompt.take().is_some() {
                out.dirty.insert(DirtyKey::ConversationPrompt);
            }
            complete_op(op_id, OpResult::Unit, false, out);
        }

        Command::SetConversationPrompt(prompt) => {
            if state.conversations.prompt != prompt {
                state.conversations.prompt = prompt;
                out.dirty.insert(DirtyKey::ConversationPrompt);
            }
            complete_op(op_id, OpResult::Unit, false, out);
        }

        Command::MarkConversationRead { id, seen_target } => {
            if id.is_empty() {
                complete_op(op_id, OpResult::Unit, false, out);
                return;
            }
            let self_conv_id = state.session.self_conversation_id.clone();
            let mut extras_changed = false;
            if let Some(conv) = state
                .conversations
                .conversations
                .iter_mut()
                .find(|c| c.id == id)
                && conv.unread > 0
            {
                conv.unread = 0;
                out.dirty.insert(DirtyKey::Conversations);
                extras_changed = true;
            }
            let had_unread_mark = state.conversations.unread_marks.remove(&id);
            if had_unread_mark {
                if state
                    .conversations
                    .rebuild_conversation_flags(self_conv_id.as_deref())
                {
                    out.dirty.insert(DirtyKey::ConversationFlags);
                }
                extras_changed = true;
                out.effects
                    .push(Effect::Store(StoreOp::SetPreferenceStrings {
                        key: "unreadMarks".to_owned(),
                        values: sorted_set_vec(&state.conversations.unread_marks),
                    }));
                out.effects.push(Effect::SetUnreadMarkApi {
                    conv_id: id.clone(),
                    unread: false,
                });
            }
            if extras_changed
                && state
                    .conversations
                    .rebuild_conversation_extras(self_conv_id.as_deref())
            {
                out.dirty.insert(DirtyKey::ConversationExtras);
            }
            out.effects
                .push(Effect::Store(StoreOp::SetConversationUnread {
                    id,
                    unread: 0,
                }));
            if let Some(target) = seen_target {
                out.effects.push(Effect::SendSeenApi(target));
            }
            complete_op(op_id, OpResult::Unit, true, out);
        }

        Command::MarkConversationUnread { id } => {
            state.conversations.unread_marks.insert(id.clone());
            rebuild_flags_and_extras(state, out);
            out.effects
                .push(Effect::Store(StoreOp::SetPreferenceStrings {
                    key: "unreadMarks".to_owned(),
                    values: sorted_set_vec(&state.conversations.unread_marks),
                }));
            out.effects.push(Effect::SetUnreadMarkApi {
                conv_id: id,
                unread: true,
            });
            complete_op(op_id, OpResult::Unit, true, out);
        }

        Command::HideConversation { id, pin } => {
            if !state.conversations.check_hidden_pin(&pin) {
                let res = ConversationActionResult::bad_pin("Mã PIN không đúng.");
                state.conversations.last_action_result = Some(res.clone());
                complete_op(op_id, OpResult::ActionResult(res), false, out);
                return;
            }
            state.conversations.actions.hidden_ids.insert(id.clone());
            out.effects
                .push(Effect::Store(StoreOp::SetPreferenceStrings {
                    key: "hiddenIds".to_owned(),
                    values: sorted_set_vec(&state.conversations.actions.hidden_ids),
                }));
            let (win_rm, meta_rm) = state.messages.remove_conversation_window(&id);
            if win_rm {
                out.dirty.insert(DirtyKey::Messages);
            }
            if meta_rm {
                out.dirty.insert(DirtyKey::MessageMeta);
            }
            state.conversations.ui.remove(BTreeSet::from([id.clone()]));
            out.dirty.insert(DirtyKey::ConversationUi);
            rebuild_flags_and_extras(state, out);
            let res = ConversationActionResult::ok("Đã ẩn trò chuyện");
            state.conversations.last_action_result = Some(res.clone());
            out.effects.push(Effect::SetHiddenConversationApi {
                conv_id: id,
                hidden: true,
                op_id,
                result: Some(res),
            });
        }

        Command::HideConversationNewPin { id, pin } => {
            let has_existing = state.conversations.actions.has_hidden_pin
                || state
                    .conversations
                    .hidden_pin_md5
                    .as_deref()
                    .is_some_and(|s| !s.is_empty())
                || state
                    .conversations
                    .hidden_pin_hash
                    .as_deref()
                    .is_some_and(|s| !s.is_empty());
            if has_existing {
                if !state.conversations.actions.has_hidden_pin {
                    state.conversations.actions.has_hidden_pin = true;
                    out.dirty.insert(DirtyKey::ConversationFlags);
                }
                let res =
                    ConversationActionResult::pin_exists("Mã PIN đã được thiết lập trước đó.");
                state.conversations.last_action_result = Some(res.clone());
                complete_op(op_id, OpResult::ActionResult(res), false, out);
                return;
            }
            out.effects.push(Effect::UpdateHiddenPinApi {
                pin,
                kind: HiddenPinSyncKind::HideNewPin { conv_id: id },
                op_id,
            });
        }

        Command::UnhideConversation { id, pin } => {
            if let Some(pin_text) = pin
                && !state.conversations.check_hidden_pin(&pin_text)
            {
                let res = ConversationActionResult::bad_pin("Mã PIN không đúng.");
                state.conversations.last_action_result = Some(res.clone());
                complete_op(op_id, OpResult::ActionResult(res), false, out);
                return;
            }
            state.conversations.actions.hidden_ids.remove(&id);
            out.effects
                .push(Effect::Store(StoreOp::SetPreferenceStrings {
                    key: "hiddenIds".to_owned(),
                    values: sorted_set_vec(&state.conversations.actions.hidden_ids),
                }));
            rebuild_flags_and_extras(state, out);
            let res = ConversationActionResult::ok("Đã bỏ ẩn trò chuyện");
            state.conversations.last_action_result = Some(res.clone());
            out.effects.push(Effect::SetHiddenConversationApi {
                conv_id: id,
                hidden: false,
                op_id,
                result: Some(res),
            });
        }

        Command::SetHiddenPin { pin, changed } => {
            out.effects.push(Effect::UpdateHiddenPinApi {
                pin,
                kind: HiddenPinSyncKind::SetPin { changed },
                op_id,
            });
        }

        Command::ResetHiddenPin => {
            out.effects.push(Effect::ResetHiddenPinApi { op_id });
        }

        Command::SyncHiddenConversations => {
            out.effects
                .push(Effect::FetchHiddenConversationsApi { op_id });
        }

        Command::ApplyServerHiddenConversations { pin, thread_ids } => {
            apply_server_hidden(state, &pin, &thread_ids, op_id, out);
        }

        Command::HiddenSearch { query } => {
            if state.conversations.actions.hidden_enabled
                && query.chars().count() == 4
                && state.conversations.check_hidden_pin(&query)
            {
                let ids: Vec<String> = state
                    .conversations
                    .actions
                    .hidden_ids
                    .iter()
                    .cloned()
                    .collect();
                if state.conversations.ui.pin_search_ids != ids {
                    state.conversations.ui.set_pin_search(ids.clone());
                    out.dirty.insert(DirtyKey::ConversationUi);
                }
                complete_op(op_id, OpResult::HiddenSearch(Some(ids)), false, out);
            } else {
                if !state.conversations.ui.pin_search_ids.is_empty() {
                    state.conversations.ui.set_pin_search(Vec::new());
                    out.dirty.insert(DirtyKey::ConversationUi);
                }
                complete_op(op_id, OpResult::HiddenSearch(None), false, out);
            }
        }

        Command::UnlockFromPinSearch { id } => {
            let ok = if state.conversations.ui.pin_search_ids.contains(&id) {
                state.conversations.ui.unlock(id);
                out.dirty.insert(DirtyKey::ConversationUi);
                true
            } else {
                false
            };
            complete_op(op_id, OpResult::Bool(ok), false, out);
        }

        Command::UnlockHiddenConversation { id } => {
            state.conversations.ui.unlock(id);
            out.dirty.insert(DirtyKey::ConversationUi);
            complete_op(op_id, OpResult::Unit, false, out);
        }

        Command::DropHiddenUnlock => {
            if state.conversations.ui.unlocked_id.is_some() {
                state.conversations.ui.drop_unlock();
                out.dirty.insert(DirtyKey::ConversationUi);
            }
            complete_op(op_id, OpResult::Unit, false, out);
        }

        Command::RelockHidden => {
            if state.conversations.ui.unlocked_id.is_some()
                || !state.conversations.ui.pin_search_ids.is_empty()
            {
                state.conversations.ui.relock();
                out.dirty.insert(DirtyKey::ConversationUi);
            }
            complete_op(op_id, OpResult::Unit, false, out);
        }

        Command::HandleConversationActions { state: raw } => {
            let (actions_changed, ui_changed) =
                state.conversations.handle_conversation_actions_json(&raw);
            if actions_changed {
                out.dirty.insert(DirtyKey::ConversationFlags);
            }
            if ui_changed {
                out.dirty.insert(DirtyKey::ConversationUi);
            }
            complete_op(op_id, OpResult::Unit, false, out);
        }

        Command::HandleConversationExtras { state: raw } => {
            let (extras_changed, new_self_id) =
                state.conversations.handle_conversation_extras_json(&raw);
            if let Some(self_id) = new_self_id
                && state.session.self_conversation_id.as_deref() != Some(self_id.as_str())
            {
                state.session.self_conversation_id = Some(self_id);
                out.dirty.insert(DirtyKey::Session);
            }
            if extras_changed {
                out.dirty.insert(DirtyKey::ConversationExtras);
            }
            complete_op(op_id, OpResult::Unit, false, out);
        }

        Command::SetConversationFilter {
            filter_type,
            label_ids,
        } => {
            let before = (
                state.conversations.extras.type_filter,
                state.conversations.extras.label_filter_ids.clone(),
            );
            state.conversations.extras.type_filter = filter_type;
            state.conversations.extras.label_filter_ids = label_ids;
            let self_conv_id = state.session.self_conversation_id.clone();
            let rebuilt = state
                .conversations
                .rebuild_conversation_extras(self_conv_id.as_deref());
            if rebuilt
                || before.0 != state.conversations.extras.type_filter
                || before.1 != state.conversations.extras.label_filter_ids
            {
                out.dirty.insert(DirtyKey::ConversationExtras);
            }
            complete_op(op_id, OpResult::Unit, false, out);
        }

        Command::SetConversationLabel {
            conversation_id,
            label_id,
        } => {
            let updated: Vec<ConversationLabel> = state
                .conversations
                .extras
                .labels
                .iter()
                .map(|existing| {
                    let mut ids: Vec<String> = existing
                        .conv_ids
                        .iter()
                        .filter(|id| *id != &conversation_id)
                        .cloned()
                        .collect();
                    if let Some(target_label) = label_id.as_deref()
                        && existing.id == target_label
                        && !ids.contains(&conversation_id)
                    {
                        ids.push(conversation_id.clone());
                    }
                    ConversationLabel {
                        id: existing.id.clone(),
                        name: existing.name.clone(),
                        color_hex: existing.color_hex.clone(),
                        conv_ids: ids,
                    }
                })
                .collect();
            state.conversations.set_labels_in_memory(updated);
            let self_conv_id = state.session.self_conversation_id.clone();
            state
                .conversations
                .rebuild_conversation_extras(self_conv_id.as_deref());
            out.dirty.insert(DirtyKey::ConversationExtras);
            emit_save_labels(state, op_id, out);
        }

        Command::CreateConversationLabel {
            name,
            color_hex,
            conversation_ids,
            now_ms,
            rand4,
        } => {
            let trimmed = name.trim();
            if trimmed.is_empty() {
                complete_op(op_id, OpResult::Unit, false, out);
                return;
            }
            let id = format!("lbl_{now_ms}_{rand4}");
            let label = ConversationLabel {
                id: id.clone(),
                name: trimmed.to_owned(),
                color_hex,
                conv_ids: conversation_ids.clone(),
            };
            state.conversations.extras.labels.push(label);
            for conv in conversation_ids {
                state
                    .conversations
                    .extras
                    .label_by_conversation
                    .insert(conv, id.clone());
            }
            let self_conv_id = state.session.self_conversation_id.clone();
            state
                .conversations
                .rebuild_conversation_extras(self_conv_id.as_deref());
            out.dirty.insert(DirtyKey::ConversationExtras);
            emit_save_labels(state, op_id, out);
        }

        Command::UpdateConversationLabel {
            id,
            name,
            color_hex,
        } => {
            let trimmed = name.trim();
            if trimmed.is_empty() {
                complete_op(op_id, OpResult::Unit, false, out);
                return;
            }
            if let Some(existing) = state
                .conversations
                .extras
                .labels
                .iter_mut()
                .find(|l| l.id == id)
            {
                existing.name = trimmed.to_owned();
                existing.color_hex = color_hex;
                let self_conv_id = state.session.self_conversation_id.clone();
                state
                    .conversations
                    .rebuild_conversation_extras(self_conv_id.as_deref());
                out.dirty.insert(DirtyKey::ConversationExtras);
                emit_save_labels(state, op_id, out);
            } else {
                complete_op(op_id, OpResult::Unit, false, out);
            }
        }

        Command::DeleteConversationLabel { id } => {
            state.conversations.extras.labels.retain(|l| l.id != id);
            let mut map = BTreeMap::new();
            for label in &state.conversations.extras.labels {
                for conv in &label.conv_ids {
                    map.insert(conv.clone(), label.id.clone());
                }
            }
            state.conversations.extras.label_by_conversation = map;
            state
                .conversations
                .extras
                .label_filter_ids
                .retain(|fid| fid != &id);
            let self_conv_id = state.session.self_conversation_id.clone();
            state
                .conversations
                .rebuild_conversation_extras(self_conv_id.as_deref());
            out.dirty.insert(DirtyKey::ConversationExtras);
            emit_save_labels(state, op_id, out);
        }

        Command::ReorderConversationLabels { ids } => {
            let mut by_id: BTreeMap<String, ConversationLabel> = state
                .conversations
                .extras
                .labels
                .iter()
                .map(|l| (l.id.clone(), l.clone()))
                .collect();
            let mut ordered = Vec::with_capacity(state.conversations.extras.labels.len());
            let mut seen = BTreeSet::new();
            for id in &ids {
                if let Some(lbl) = by_id.remove(id) {
                    seen.insert(lbl.id.clone());
                    ordered.push(lbl);
                }
            }
            for lbl in &state.conversations.extras.labels {
                if !seen.contains(&lbl.id) {
                    ordered.push(lbl.clone());
                }
            }
            state.conversations.extras.labels = ordered;
            out.dirty.insert(DirtyKey::ConversationExtras);
            emit_save_labels(state, op_id, out);
        }

        Command::SyncConversationLabels => {
            out.effects
                .push(Effect::FetchConversationLabelsApi { op_id });
        }

        Command::ReportConversationActionResult(res) => {
            report_result(state, res, out);
            complete_op(op_id, OpResult::Unit, false, out);
        }

        Command::CheckHiddenPin { pin } => {
            let ok = state.conversations.check_hidden_pin(&pin);
            complete_op(op_id, OpResult::Bool(ok), false, out);
        }

        Command::SyncConversationsSnapshot(list) => {
            state.conversations.conversations = list;
            complete_op(op_id, OpResult::Unit, false, out);
        }

        Command::RebuildConversationExtras => {
            let self_conv_id = state.session.self_conversation_id.clone();
            if state
                .conversations
                .rebuild_conversation_extras(self_conv_id.as_deref())
            {
                out.dirty.insert(DirtyKey::ConversationExtras);
            }
            complete_op(op_id, OpResult::Unit, false, out);
        }

        Command::RepublishConversationActions => {
            let self_conv_id = state.session.self_conversation_id.clone();
            if state
                .conversations
                .rebuild_conversation_flags(self_conv_id.as_deref())
            {
                out.dirty.insert(DirtyKey::ConversationFlags);
            }
            complete_op(op_id, OpResult::Unit, false, out);
        }

        Command::ResetConversationActions => {
            state.conversations.actions = Default::default();
            state.conversations.prompt = None;
            state.conversations.hidden_pin_hash = None;
            state.conversations.hidden_pin_md5 = None;
            state.conversations.ui.reset();
            out.dirty.insert(DirtyKey::ConversationFlags);
            out.dirty.insert(DirtyKey::ConversationUi);
            out.dirty.insert(DirtyKey::ConversationPrompt);
            complete_op(op_id, OpResult::Unit, false, out);
        }

        Command::PersistConversations => {
            emit_save_conversations(state, out);
            complete_op(op_id, OpResult::Unit, true, out);
        }

        Command::ApplyBootstrapPinArchive {
            pinned_ids,
            archived_ids,
        } => {
            let mut wrote_store = false;
            if let Some(pins) = pinned_ids {
                state.conversations.pinned_ids = pins.into_iter().collect();
                out.effects
                    .push(Effect::Store(StoreOp::SetPreferenceStrings {
                        key: "pinnedIds".to_owned(),
                        values: sorted_set_vec(&state.conversations.pinned_ids),
                    }));
                wrote_store = true;
            }
            if let Some(archived) = archived_ids {
                state.conversations.archived_ids = archived.into_iter().collect();
                out.effects
                    .push(Effect::Store(StoreOp::SetPreferenceStrings {
                        key: "archivedIds".to_owned(),
                        values: sorted_set_vec(&state.conversations.archived_ids),
                    }));
                wrote_store = true;
            }
            rebuild_flags_and_extras(state, out);
            complete_op(op_id, OpResult::Unit, wrote_store, out);
        }

        Command::RemoveLocalConversation { id } => {
            let prev_len = state.conversations.conversations.len();
            state.conversations.conversations.retain(|c| c.id != id);
            if state.conversations.conversations.len() != prev_len {
                out.dirty.insert(DirtyKey::Conversations);
            }
            state.conversations.pinned_ids.remove(&id);
            state.conversations.archived_ids.remove(&id);
            state.conversations.unread_marks.remove(&id);
            if state.conversations.open_conversation_id.as_deref() == Some(id.as_str()) {
                state.conversations.open_conversation_id = None;
            }
            state.conversations.ui.remove(BTreeSet::from([id.clone()]));
            out.dirty.insert(DirtyKey::ConversationUi);
            rebuild_flags_and_extras(state, out);
            out.effects
                .push(Effect::Store(StoreOp::DeleteConversation { id }));
            out.effects
                .push(Effect::Store(StoreOp::SetPreferenceStrings {
                    key: "pinnedIds".to_owned(),
                    values: sorted_set_vec(&state.conversations.pinned_ids),
                }));
            out.effects
                .push(Effect::Store(StoreOp::SetPreferenceStrings {
                    key: "archivedIds".to_owned(),
                    values: sorted_set_vec(&state.conversations.archived_ids),
                }));
            out.effects
                .push(Effect::Store(StoreOp::SetPreferenceStrings {
                    key: "unreadMarks".to_owned(),
                    values: sorted_set_vec(&state.conversations.unread_marks),
                }));
            complete_op(op_id, OpResult::Unit, true, out);
        }

        _ => {
            complete_op(op_id, OpResult::Unit, false, out);
        }
    }
}

// U4-bootstrap
pub(crate) fn apply_server_hidden(
    state: &mut CoreState,
    pin: &str,
    thread_ids: &[String],
    op_id: Option<u64>,
    out: &mut ReduceOutput,
) {
    let server_pin = pin.trim().to_ascii_lowercase();
    let self_conv_id = state.session.self_conversation_id.as_deref();
    let server_hidden_ids: BTreeSet<String> = thread_ids
        .iter()
        .filter(|id| !id.is_empty() && self_conv_id != Some(id.as_str()))
        .cloned()
        .collect();
    let old_hidden_ids = state.conversations.actions.hidden_ids.clone();

    if !server_pin.is_empty() {
        let prev_md5 = state
            .conversations
            .hidden_pin_md5
            .as_deref()
            .map(str::to_ascii_lowercase);
        if prev_md5.as_deref() != Some(server_pin.as_str()) {
            state.conversations.hidden_pin_hash = None;
            out.effects.push(Effect::Store(StoreOp::DeletePreference {
                key: "hiddenPinHash".to_owned(),
            }));
        }
        state.conversations.hidden_pin_md5 = Some(server_pin.clone());
        out.effects
            .push(Effect::Store(StoreOp::SetPreferenceString {
                key: "hiddenPinMD5".to_owned(),
                value: server_pin.clone(),
            }));
    } else {
        state.conversations.hidden_pin_md5 = None;
        state.conversations.hidden_pin_hash = None;
        out.effects.push(Effect::Store(StoreOp::DeletePreference {
            key: "hiddenPinMD5".to_owned(),
        }));
        out.effects.push(Effect::Store(StoreOp::DeletePreference {
            key: "hiddenPinHash".to_owned(),
        }));
    }

    out.effects
        .push(Effect::Store(StoreOp::SetPreferenceStrings {
            key: "hiddenIds".to_owned(),
            values: sorted_set_vec(&server_hidden_ids),
        }));

    let mut next = state.conversations.actions.clone();
    next.hidden_known = true;
    next.hidden_enabled = true;
    next.has_hidden_pin = !server_pin.is_empty();
    next.hidden_ids = server_hidden_ids.clone();
    if next != state.conversations.actions {
        state.conversations.actions = next;
        out.dirty.insert(DirtyKey::ConversationFlags);
    }

    let newly_hidden: BTreeSet<String> = server_hidden_ids
        .difference(&old_hidden_ids)
        .cloned()
        .collect();
    if !newly_hidden.is_empty() {
        state.conversations.ui.remove(newly_hidden);
        out.dirty.insert(DirtyKey::ConversationUi);
    }
    rebuild_flags_and_extras(state, out);
    complete_op(op_id, OpResult::Unit, true, out);
}

fn emit_save_labels(state: &CoreState, op_id: Option<u64>, out: &mut ReduceOutput) {
    let local_bytes = serialize_labels_local_json(&state.conversations.extras.labels);
    out.effects.push(Effect::Store(StoreOp::SetPreferenceData {
        key: "labels".to_owned(),
        data: local_bytes,
    }));
    let server_json = serialize_labels_server_json(&state.conversations.extras.labels);
    out.effects.push(Effect::UpdateConversationLabelsApi {
        label_data_json: server_json,
        op_id,
    });
}

// U4-bootstrap
pub(crate) fn emit_save_conversations(state: &CoreState, out: &mut ReduceOutput) {
    // Timestamp is stamped by the store worker (`updated_at_ms`) when writing to SQLite so `reduce`
    // stays clock-free (D9).
    let rows = state.conversations.stored_conversation_rows(0);
    out.effects
        .push(Effect::Store(StoreOp::SaveConversations(rows)));
}

// U4-bootstrap
pub(crate) fn rebuild_flags_and_extras(state: &mut CoreState, out: &mut ReduceOutput) {
    let self_conv_id = state.session.self_conversation_id.clone();
    if state
        .conversations
        .rebuild_conversation_flags(self_conv_id.as_deref())
    {
        out.dirty.insert(DirtyKey::ConversationFlags);
    }
    if state
        .conversations
        .rebuild_conversation_extras(self_conv_id.as_deref())
    {
        out.dirty.insert(DirtyKey::ConversationExtras);
    }
}

fn mark_list_flags_extras_dirty(out: &mut ReduceOutput) {
    out.dirty.insert(DirtyKey::Conversations);
    out.dirty.insert(DirtyKey::ConversationFlags);
    out.dirty.insert(DirtyKey::ConversationExtras);
}

fn report_result(state: &mut CoreState, result: ConversationActionResult, out: &mut ReduceOutput) {
    if state.conversations.report(&result) {
        out.dirty.insert(DirtyKey::ConversationUi);
    }
}

fn complete_op(op_id: Option<u64>, result: OpResult, after_store: bool, out: &mut ReduceOutput) {
    if let Some(id) = op_id {
        out.effects.push(Effect::CompleteOp {
            op_id: id,
            result,
            after_store,
        });
    }
}

// U4-bootstrap
pub(crate) fn sorted_set_vec(set: &BTreeSet<String>) -> Vec<String> {
    set.iter().cloned().collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::conversations::ConversationSummary;

    #[test]
    fn delete_api_done_persists_removed_pin_archive_unread_prefs() {
        let mut state = CoreState::default();
        state.conversations.conversations.push(ConversationSummary {
            id: "c1".to_owned(),
            is_group: false,
            name: "Peer".to_owned(),
            avatar: None,
            pinned: true,
            members: 0,
            unread: 1,
            preview: None,
        });
        state.conversations.pinned_ids.insert("c1".to_owned());
        state.conversations.pinned_ids.insert("c2".to_owned());
        state.conversations.archived_ids.insert("c1".to_owned());
        state.conversations.unread_marks.insert("c1".to_owned());

        let out = crate::reduce::reduce(
            &mut state,
            Input::DeleteApiDone {
                id: "c1".to_owned(),
                op_id: Some(7),
            },
        );

        let pref_writes: Vec<(&str, &Vec<String>)> = out
            .effects
            .iter()
            .filter_map(|e| match e {
                Effect::Store(StoreOp::SetPreferenceStrings { key, values }) => {
                    Some((key.as_str(), values))
                }
                _ => None,
            })
            .collect();
        assert_eq!(
            pref_writes,
            vec![
                ("pinnedIds", &vec!["c2".to_owned()]),
                ("archivedIds", &vec![]),
                ("unreadMarks", &vec![]),
            ]
        );
    }

    #[test]
    fn delete_api_done_skips_unmodified_pref_writes() {
        let mut state = CoreState::default();
        state.conversations.conversations.push(ConversationSummary {
            id: "c1".to_owned(),
            is_group: false,
            name: "Peer".to_owned(),
            avatar: None,
            pinned: false,
            members: 0,
            unread: 0,
            preview: None,
        });
        state.conversations.pinned_ids.insert("c2".to_owned());

        let out = crate::reduce::reduce(
            &mut state,
            Input::DeleteApiDone {
                id: "c1".to_owned(),
                op_id: Some(8),
            },
        );

        let pref_keys: Vec<&str> = out
            .effects
            .iter()
            .filter_map(|e| match e {
                Effect::Store(StoreOp::SetPreferenceStrings { key, .. }) => Some(key.as_str()),
                _ => None,
            })
            .collect();
        assert!(pref_keys.is_empty());
    }
}
