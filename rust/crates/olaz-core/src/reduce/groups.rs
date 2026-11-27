//! Pure reducer for the groups domain (U10: `ZaloEngine+GroupCreate.swift`,
//! `ZaloEngine+GroupAdmin.swift`, `ZaloEngine+GroupEvents.swift`, and `mentionCandidates`).

use std::collections::BTreeSet;

use olaz_api::clean_group_member_ids;
use olaz_wire::{
    ChatMessage, Kind, MessageMenu, Status, clean_group_id, encode_chat_message, group_conv_id,
    group_event_notice, is_group_event_member_act, is_group_id, lossless, normalize_contact_uid,
    strip_user_prefix,
};
use serde_json::{Map, Value};

use crate::changes::DirtyKey;
use crate::conversations::{MessagePreviewInput, ToastKind};
use crate::effect::{Effect, HostCall, OpResult, StoreOp};
use crate::groups::{
    GROUP_CREATE_DEFAULT_FAILURE, GroupAdminAction, GroupCreateOutcome, GroupDetailPurpose,
    GroupMetadataPatch, MemberProfilesPurpose, MentionCandidate, MergedGroupMetadataPersistence,
    UNKNOWN_GROUP_MEMBER_NAME, admin_error_text, apply_group_metadata_update,
    contact_name_for_group_notice, filter_mention_candidates, group_member_ids,
    mention_member_fetch_ids, merge_fetched_group_metadata, not_added_text, preferred_profile_name,
};
use crate::input::{Command, Input};
use crate::messages::{is_valid_url_str, serialize_cached_groups_json, to_db_stored};
use crate::reduce::ReduceOutput;
use crate::reduce::contacts::{format_session_failure_localized, start_contacts_sync};
use crate::reduce::conversations;
use crate::state::CoreState;

const MENTION_PROFILE_FETCH_LIMIT: usize = 50;

fn complete_op(out: &mut ReduceOutput, op_id: Option<u64>, result: OpResult, after_store: bool) {
    if let Some(id) = op_id {
        out.effects.push(Effect::CompleteOp {
            op_id: id,
            result,
            after_store,
        });
    }
}

fn my_profile_info(state: &CoreState) -> (&str, Option<&str>) {
    let uid = state
        .session
        .profile
        .as_ref()
        .map_or("", |p| p.user_id.as_str());
    let avatar = state
        .session
        .profile
        .as_ref()
        .and_then(|p| p.avatar.as_deref());
    (uid, avatar)
}

fn mark_group_metadata_dirty(out: &mut ReduceOutput) {
    out.dirty.insert(DirtyKey::Groups);
    out.dirty.insert(DirtyKey::Contacts);
    out.dirty.insert(DirtyKey::Conversations);
    out.dirty.insert(DirtyKey::ConversationFlags);
    out.dirty.insert(DirtyKey::ConversationExtras);
    out.dirty.insert(DirtyKey::CachedGroups);
    out.refresh_identity_snapshot = true;
}

fn emit_persistence(persisted: MergedGroupMetadataPersistence, out: &mut ReduceOutput) -> bool {
    let mut had_store = false;
    if let Some(bytes) = persisted.cached_groups_json {
        out.effects.push(Effect::Store(StoreOp::SetPreferenceData {
            key: "cachedGroups".to_owned(),
            data: bytes,
        }));
        had_store = true;
    }
    if let Some(row) = persisted.stored_conversation {
        out.effects
            .push(Effect::Store(StoreOp::SaveConversations(vec![row])));
        had_store = true;
    }
    had_store
}

fn show_toast(
    state: &mut CoreState,
    kind: ToastKind,
    text: impl Into<String>,
    out: &mut ReduceOutput,
) {
    state.conversations.ui.show(kind, text);
    out.dirty.insert(DirtyKey::ConversationUi);
}

fn current_group_member_count(state: &CoreState, gid: &str, fallback: usize) -> i64 {
    state
        .conversations
        .conversations
        .iter()
        .find(|c| c.id == gid)
        .map(|c| c.members)
        .or_else(|| {
            state
                .contacts
                .groups
                .iter()
                .find(|g| g.id == gid)
                .map(|g| g.members)
        })
        .unwrap_or_else(|| i64::try_from(fallback).unwrap_or(0))
}

fn finish_load_group_members_fallback(
    state: &mut CoreState,
    gid: &str,
    op_id: Option<u64>,
    after_store: bool,
    out: &mut ReduceOutput,
) {
    let (my_uid_raw, my_avatar) = my_profile_info(state);
    let my_uid_owned = my_uid_raw.to_owned();
    let my_avatar_owned = my_avatar.map(str::to_owned);
    let my_norm = normalize_contact_uid(&my_uid_owned);
    let my_stripped = strip_user_prefix(&my_uid_owned);

    let known_ids: Vec<String> = group_member_ids(gid, &state.groups)
        .into_iter()
        .filter(|uid| {
            let norm = normalize_contact_uid(uid);
            uid != &my_stripped && (my_norm.is_empty() || norm != my_norm)
        })
        .collect();
    if known_ids.is_empty() {
        complete_op(
            out,
            op_id,
            OpResult::MentionCandidates(Vec::new()),
            after_store,
        );
        return;
    }

    let fallback: Vec<MentionCandidate> = known_ids
        .into_iter()
        .map(|uid| {
            let info = state.conversations.lookup_person_info(
                &state.contacts,
                &uid,
                &my_uid_owned,
                my_avatar_owned.as_deref(),
            );
            let name = info
                .as_ref()
                .map(|(n, _)| n.as_str())
                .filter(|n| !n.is_empty())
                .unwrap_or(UNKNOWN_GROUP_MEMBER_NAME)
                .to_owned();
            let avatar = info
                .map(|(_, a)| a)
                .filter(|a| !a.is_empty() && is_valid_url_str(a));
            MentionCandidate {
                id: uid,
                name,
                avatar,
                is_all: false,
            }
        })
        .collect();
    let mut cached = Vec::with_capacity(fallback.len() + 1);
    cached.push(MentionCandidate::all());
    cached.extend(fallback.iter().cloned());
    state.groups.member_cache.insert(gid.to_owned(), cached);
    out.dirty.insert(DirtyKey::Groups);
    complete_op(
        out,
        op_id,
        OpResult::MentionCandidates(fallback),
        after_store,
    );
}

fn continue_load_group_members(
    state: &mut CoreState,
    gid: &str,
    op_id: Option<u64>,
    after_store: bool,
    out: &mut ReduceOutput,
) {
    if let Some(cached) = state.groups.member_cache.get(gid) {
        let via_mention: Vec<MentionCandidate> = cached
            .iter()
            .filter(|c| !c.is_all && c.id != "-1")
            .cloned()
            .collect();
        if !via_mention.is_empty() {
            complete_op(
                out,
                op_id,
                OpResult::MentionCandidates(via_mention),
                after_store,
            );
            return;
        }
        finish_load_group_members_fallback(state, gid, op_id, after_store, out);
        return;
    }

    if state.groups.detail_object(gid).is_some() {
        let my_uid = my_profile_info(state).0.to_owned();
        let clean_ids = mention_member_fetch_ids(gid, &my_uid, &state.groups);
        if !clean_ids.is_empty() {
            let fetch_ids: Vec<String> = clean_ids
                .into_iter()
                .take(MENTION_PROFILE_FETCH_LIMIT)
                .collect();
            out.effects.push(Effect::FetchGroupMemberProfilesApi {
                op_id,
                gid: gid.to_owned(),
                uids: fetch_ids,
                purpose: MemberProfilesPurpose::LoadMembers,
            });
            return;
        }
    }

    state
        .groups
        .member_cache
        .insert(gid.to_owned(), vec![MentionCandidate::all()]);
    out.dirty.insert(DirtyKey::Groups);
    finish_load_group_members_fallback(state, gid, op_id, after_store, out);
}

/// Applies a group control notice (`ZaloEngine+GroupEvents.swift: handleGroupEventNotice`).
///
/// Called both from `Command::HandleGroupEventNotice` (explicit/test path) and directly from
/// `reduce/transport.rs` on `Route::GroupNotice` (live WS/LP path).
pub(crate) fn handle_group_event_notice(
    state: &mut CoreState,
    act: &str,
    data: &Map<String, Value>,
    ts: i64,
    now_ms: i64,
    out: &mut ReduceOutput,
) -> bool {
    let raw_group_id = lossless::string(
        data.get("groupId")
            .or_else(|| data.get("group_id"))
            .or_else(|| data.get("grid")),
    );
    if raw_group_id.is_empty() || raw_group_id == "0" {
        return false;
    }
    let conv_id = group_conv_id(&raw_group_id);
    let clean_grid = clean_group_id(&raw_group_id);
    if conv_id.is_empty() || clean_grid.is_empty() {
        return false;
    }

    if is_group_event_member_act(act) {
        let removed_cache = state.groups.member_cache.remove(&conv_id).is_some();
        let removed_detail = state.groups.details_json.remove(&clean_grid).is_some();
        if removed_cache || removed_detail {
            out.dirty.insert(DirtyKey::Groups);
            out.dirty.insert(DirtyKey::Contacts);
        }
    }

    let (my_uid_raw, my_avatar) = my_profile_info(state);
    let my_uid = my_uid_raw.to_owned();
    let my_avatar_owned = my_avatar.map(str::to_owned);
    let Some(text) = group_event_notice(act, data, &my_uid, |uid| {
        state
            .conversations
            .lookup_person_info(&state.contacts, uid, &my_uid, my_avatar_owned.as_deref())
            .map(|(name, _)| name)
    }) else {
        return false;
    };

    let ms = if ts > 100_000_000_000 {
        ts
    } else if ts > 0 {
        ts.saturating_mul(1_000)
    } else {
        now_ms
    };
    let members = data
        .get("updateMembers")
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(Value::as_object)
                .map(|m| lossless::string(m.get("id")))
                .collect::<Vec<_>>()
                .join(",")
        })
        .unwrap_or_default();
    let id = format!("gevt-{clean_grid}-{act}-{ms}-{members}");

    if state
        .messages
        .windows
        .get(&conv_id)
        .is_some_and(|list| list.iter().any(|m| m.id == id))
    {
        return false;
    }

    let msg = ChatMessage {
        id: id.clone(),
        client_id: String::new(),
        conversation_id: conv_id,
        sender_id: String::new(),
        sender_name: String::new(),
        sender_avatar: None,
        is_mine: false,
        kind: Kind::System,
        text,
        date_ms: ms,
        status: Status::Sent,
        quote: None,
        reactions: Vec::new(),
        is_e2ee: false,
        mentions: Vec::new(),
        card_buttons: Vec::new(),
        suggests_stickers: false,
        menu: MessageMenu::default(),
        fallback_urls: Vec::new(),
        text_styles: Vec::new(),
        ttl_ms: 0,
        urgency: 0,
    };

    let snap = state.identity_snapshot();
    let _ = state.messages.merge_message(msg.clone(), None, &snap);
    out.dirty.insert(DirtyKey::Messages);

    let mut had_store = false;
    if let Some(wire_stored) = encode_chat_message(&msg, &id) {
        out.effects.push(Effect::Store(StoreOp::SaveMessages {
            rows: vec![to_db_stored(&wire_stored)],
            preserve_existing_reactions: false,
        }));
        had_store = true;
    }

    let preview_input = MessagePreviewInput::from_chat_message(&msg);
    let conv_changed =
        conversations::apply_message_preview_update(state, &preview_input, false, out);
    had_store || conv_changed
}

/// Pure reducer entry point for all U10 group commands and API completion inputs.
pub fn reduce_groups(state: &mut CoreState, input: Input, out: &mut ReduceOutput) {
    match input {
        Input::Command(cmd) => reduce_command(state, cmd, None, out),
        Input::OpRequest { op_id, cmd } => reduce_command(state, cmd, Some(op_id), out),

        Input::GroupCreatedApi {
            op_id,
            name,
            members,
            avatar,
            now_ms,
            result,
        } => match result {
            Err(failure) => {
                let desc = format_session_failure_localized(&failure);
                out.effects
                    .push(Effect::EngineLog(format!("group create failed: {desc}")));
                complete_op(
                    out,
                    op_id,
                    OpResult::GroupCreate(GroupCreateOutcome::Failed {
                        title: None,
                        message: GROUP_CREATE_DEFAULT_FAILURE.to_owned(),
                        closes: false,
                    }),
                    false,
                );
            }
            Ok(root) => {
                let d = root.get("data").and_then(Value::as_object);
                let raw_gid = d
                    .map(|obj| lossless::string(obj.get("groupId")))
                    .unwrap_or_default();
                let gid = group_conv_id(&raw_gid);
                if gid.is_empty() {
                    complete_op(
                        out,
                        op_id,
                        OpResult::GroupCreate(GroupCreateOutcome::Failed {
                            title: None,
                            message: GROUP_CREATE_DEFAULT_FAILURE.to_owned(),
                            closes: false,
                        }),
                        false,
                    );
                    return;
                }

                let failed: Vec<String> = d
                    .and_then(|obj| obj.get("rejectedMembers"))
                    .and_then(Value::as_array)
                    .map(|arr| {
                        arr.iter()
                            .map(|v| lossless::string(Some(v)))
                            .filter(|s| !s.is_empty())
                            .collect()
                    })
                    .unwrap_or_default();
                let failed_set: BTreeSet<String> =
                    clean_group_member_ids(&failed).into_iter().collect();

                let my_uid = strip_user_prefix(my_profile_info(state).0);
                let mut initial_ids: Vec<String> = clean_group_member_ids(&members)
                    .into_iter()
                    .filter(|id| !failed_set.contains(id))
                    .collect();
                if !my_uid.is_empty() && !initial_ids.iter().any(|id| id == &my_uid) {
                    initial_ids.insert(0, my_uid);
                }

                let trimmed_name = name.trim();
                let initial_name = if trimmed_name.is_empty() {
                    "Nhóm"
                } else {
                    trimmed_name
                };
                let initial_count = i64::try_from(initial_ids.len()).unwrap_or(1).max(1);
                let self_conv_id = state.session.self_conversation_id.clone();

                if let Some(persisted) = apply_group_metadata_update(
                    &gid,
                    GroupMetadataPatch {
                        name: Some(initial_name),
                        avatar: None,
                        member_count: Some(initial_count),
                        member_ids: Some(&initial_ids),
                        base_detail: None,
                    },
                    &mut state.groups,
                    &mut state.contacts,
                    &mut state.conversations,
                    self_conv_id.as_deref(),
                    now_ms,
                ) {
                    mark_group_metadata_dirty(out);
                    // Approved Fix (`user-decisions` item 7.1): persist immediately so created
                    // groups survive restart even when `/api/group/getmg-v2` returns empty.
                    let _ = emit_persistence(persisted, out);
                }

                if let Some(avt) = avatar {
                    out.effects.push(Effect::UploadGroupAvatarApi {
                        op_id,
                        gid,
                        avatar: avt,
                        failed,
                        now_ms,
                    });
                } else {
                    out.effects.push(Effect::FetchGroupDetailApi {
                        gid,
                        purpose: GroupDetailPurpose::CreateFollowup {
                            op_id,
                            failed,
                            avatar_upload_failed: false,
                            now_ms,
                        },
                    });
                }
            }
        },

        Input::GroupAvatarUploadedApi {
            op_id,
            gid,
            failed,
            now_ms,
            result,
        } => {
            let avatar_upload_failed = match result {
                Ok(root) => {
                    if let Some(up_data) = root.get("data").and_then(Value::as_object) {
                        let avt_str = lossless::string(
                            up_data
                                .get("avatar")
                                .or_else(|| up_data.get("avt"))
                                .or_else(|| up_data.get("fullAvt"))
                                .or_else(|| up_data.get("url")),
                        );
                        if !avt_str.is_empty() && is_valid_url_str(&avt_str) {
                            let self_conv_id = state.session.self_conversation_id.clone();
                            if let Some(persisted) = apply_group_metadata_update(
                                &gid,
                                GroupMetadataPatch {
                                    name: None,
                                    avatar: Some(&avt_str),
                                    member_count: None,
                                    member_ids: None,
                                    base_detail: None,
                                },
                                &mut state.groups,
                                &mut state.contacts,
                                &mut state.conversations,
                                self_conv_id.as_deref(),
                                now_ms,
                            ) {
                                mark_group_metadata_dirty(out);
                                // Approved Fix (item 7.1): persist updated avatar immediately.
                                let _ = emit_persistence(persisted, out);
                            }
                        }
                    }
                    false
                }
                Err(failure) => {
                    let desc = format_session_failure_localized(&failure);
                    out.effects.push(Effect::EngineLog(format!(
                        "group avatar upload failed: {desc}"
                    )));
                    true
                }
            };

            out.effects.push(Effect::FetchGroupDetailApi {
                gid,
                purpose: GroupDetailPurpose::CreateFollowup {
                    op_id,
                    failed,
                    avatar_upload_failed,
                    now_ms,
                },
            });
        }

        Input::GroupRenamedApi {
            op_id,
            gid,
            name,
            now_ms,
            result,
        } => match result {
            Ok(()) => {
                let self_conv_id = state.session.self_conversation_id.clone();
                let mut had_store = false;
                if let Some(persisted) = apply_group_metadata_update(
                    &gid,
                    GroupMetadataPatch {
                        name: Some(&name),
                        avatar: None,
                        member_count: None,
                        member_ids: None,
                        base_detail: None,
                    },
                    &mut state.groups,
                    &mut state.contacts,
                    &mut state.conversations,
                    self_conv_id.as_deref(),
                    now_ms,
                ) {
                    mark_group_metadata_dirty(out);
                    had_store = emit_persistence(persisted, out);
                }
                show_toast(state, ToastKind::Success, "Đã đổi tên nhóm", out);
                complete_op(out, op_id, OpResult::Bool(true), had_store);
            }
            Err(failure) => {
                let desc = format_session_failure_localized(&failure);
                out.effects
                    .push(Effect::EngineLog(format!("rename group failed: {desc}")));
                show_toast(state, ToastKind::Failure, "Không thể đổi tên nhóm.", out);
                complete_op(out, op_id, OpResult::Bool(false), false);
            }
        },

        Input::GroupMembersInvitedApi {
            op_id,
            gid,
            clean_ids,
            now_ms,
            result,
        } => match result {
            Err(failure) => {
                let desc = format_session_failure_localized(&failure);
                out.effects.push(Effect::EngineLog(format!(
                    "invite group members failed: {desc}"
                )));
                show_toast(
                    state,
                    ToastKind::Failure,
                    "Không thể thêm thành viên vào nhóm.",
                    out,
                );
                complete_op(out, op_id, OpResult::Bool(false), false);
            }
            Ok(root) => {
                let d = root.get("data").and_then(Value::as_object);
                let raw_rejected: Vec<String> = d
                    .and_then(|obj| {
                        obj.get("errorMem")
                            .or_else(|| obj.get("errorMembers"))
                            .or_else(|| obj.get("rejectedMembers"))
                    })
                    .and_then(Value::as_array)
                    .map(|arr| arr.iter().map(|v| lossless::string(Some(v))).collect())
                    .unwrap_or_default();
                // Approved Fix (`user-decisions` item 7.2): preserve invite/response order
                // (deduplicated) rather than unordered `Set` iteration.
                let rejected_ordered = clean_group_member_ids(&raw_rejected);
                let rejected_set: BTreeSet<&str> =
                    rejected_ordered.iter().map(String::as_str).collect();
                let added: Vec<String> = clean_ids
                    .into_iter()
                    .filter(|id| !rejected_set.contains(id.as_str()))
                    .collect();
                if added.is_empty() {
                    show_toast(
                        state,
                        ToastKind::Failure,
                        "Không thể thêm thành viên vào nhóm.",
                        out,
                    );
                    complete_op(out, op_id, OpResult::Bool(false), false);
                    return;
                }

                let existing_ids = group_member_ids(&gid, &state.groups);
                let mut merged_ids = existing_ids.clone();
                let mut newly_added = 0i64;
                for uid in &added {
                    if !merged_ids.iter().any(|x| x == uid) {
                        merged_ids.push(uid.clone());
                        newly_added += 1;
                    }
                }
                let current_count = current_group_member_count(state, &gid, existing_ids.len());
                let merged_len = i64::try_from(merged_ids.len()).unwrap_or(0);
                let next_count = merged_len.max(current_count.saturating_add(newly_added));

                state.groups.member_cache.remove(&gid);
                let self_conv_id = state.session.self_conversation_id.clone();
                if let Some(persisted) = apply_group_metadata_update(
                    &gid,
                    GroupMetadataPatch {
                        name: None,
                        avatar: None,
                        member_count: Some(next_count),
                        member_ids: Some(&merged_ids),
                        base_detail: None,
                    },
                    &mut state.groups,
                    &mut state.contacts,
                    &mut state.conversations,
                    self_conv_id.as_deref(),
                    now_ms,
                ) {
                    mark_group_metadata_dirty(out);
                    let _ = emit_persistence(persisted, out);
                }

                out.effects.push(Effect::FetchGroupDetailApi {
                    gid,
                    purpose: GroupDetailPurpose::InviteFollowup {
                        op_id,
                        rejected_ordered,
                        now_ms,
                    },
                });
            }
        },

        Input::GroupMemberKickedApi {
            op_id,
            gid,
            member_id,
            now_ms,
            result,
        } => match result {
            Err(failure) => {
                let desc = format_session_failure_localized(&failure);
                out.effects.push(Effect::EngineLog(format!(
                    "kick group member failed: {desc}"
                )));
                show_toast(state, ToastKind::Failure, "Không thể xóa thành viên.", out);
                complete_op(out, op_id, OpResult::Bool(false), false);
            }
            Ok(()) => {
                if let Some(cached) = state.groups.member_cache.get_mut(&gid) {
                    cached.retain(|c| c.id != member_id);
                }
                let current_ids = group_member_ids(&gid, &state.groups);
                let had_member = current_ids.iter().any(|x| x == &member_id);
                let updated_ids: Vec<String> = current_ids
                    .iter()
                    .filter(|x| *x != &member_id)
                    .cloned()
                    .collect();
                let current_count = current_group_member_count(state, &gid, current_ids.len());
                let next_count = if had_member || current_ids.is_empty() {
                    current_count.saturating_sub(1).max(1)
                } else {
                    i64::try_from(updated_ids.len()).unwrap_or(1).max(1)
                };

                let self_conv_id = state.session.self_conversation_id.clone();
                if let Some(persisted) = apply_group_metadata_update(
                    &gid,
                    GroupMetadataPatch {
                        name: None,
                        avatar: None,
                        member_count: Some(next_count),
                        member_ids: (!current_ids.is_empty()).then_some(updated_ids.as_slice()),
                        base_detail: None,
                    },
                    &mut state.groups,
                    &mut state.contacts,
                    &mut state.conversations,
                    self_conv_id.as_deref(),
                    now_ms,
                ) {
                    mark_group_metadata_dirty(out);
                    let _ = emit_persistence(persisted, out);
                }

                out.effects.push(Effect::FetchGroupDetailApi {
                    gid,
                    purpose: GroupDetailPurpose::KickFollowup { op_id, now_ms },
                });
            }
        },

        Input::GroupLeftApi { op_id, gid, result } => match result {
            Err(failure) => {
                let desc = format_session_failure_localized(&failure);
                out.effects
                    .push(Effect::EngineLog(format!("leave group failed: {desc}")));
                show_toast(state, ToastKind::Failure, "Không thể rời nhóm.", out);
                complete_op(out, op_id, OpResult::Bool(false), false);
            }
            Ok(()) => {
                let clean_grid = clean_group_id(&gid);
                state.contacts.groups.retain(|g| g.id != gid);
                state.groups.details_json.remove(&clean_grid);
                state.groups.member_cache.remove(&gid);
                state.groups.cached_groups.remove(&gid);

                let (win_removed, meta_removed) = state.messages.remove_conversation_window(&gid);
                if win_removed {
                    out.dirty.insert(DirtyKey::Messages);
                }
                if meta_removed {
                    out.dirty.insert(DirtyKey::MessageMeta);
                }
                if state.typing.active.remove(&gid).is_some() {
                    out.dirty.insert(DirtyKey::Typing);
                }
                if state.pins.lists.remove(&gid).is_some()
                    || state.pins.raw_topics.remove(&gid).is_some()
                {
                    out.dirty.insert(DirtyKey::Pins);
                }

                if state.conversations.open_conversation_id.as_deref() == Some(gid.as_str()) {
                    state.conversations.open_conversation_id = None;
                    if state.forward.clear_request() {
                        out.dirty.insert(DirtyKey::ForwardRequest);
                    }
                    if state.actions.message_confirm.take().is_some() {
                        out.dirty.insert(DirtyKey::MessageConfirm);
                    }
                }

                // Local conversation removal (matches `Command::RemoveLocalConversation`).
                state.conversations.conversations.retain(|c| c.id != gid);
                state.conversations.pinned_ids.remove(&gid);
                state.conversations.archived_ids.remove(&gid);
                state.conversations.unread_marks.remove(&gid);
                state.conversations.ui.remove(BTreeSet::from([gid.clone()]));
                conversations::rebuild_flags_and_extras(state, out);

                out.effects.push(Effect::Store(StoreOp::DeleteConversation {
                    id: gid.clone(),
                }));
                out.effects
                    .push(Effect::Store(StoreOp::SetPreferenceStrings {
                        key: "pinnedIds".to_owned(),
                        values: state.conversations.pinned_ids.iter().cloned().collect(),
                    }));
                out.effects
                    .push(Effect::Store(StoreOp::SetPreferenceStrings {
                        key: "archivedIds".to_owned(),
                        values: state.conversations.archived_ids.iter().cloned().collect(),
                    }));
                out.effects
                    .push(Effect::Store(StoreOp::SetPreferenceStrings {
                        key: "unreadMarks".to_owned(),
                        values: state.conversations.unread_marks.iter().cloned().collect(),
                    }));

                if let Some(bytes) = serialize_cached_groups_json(&state.groups.cached_groups) {
                    out.effects.push(Effect::Store(StoreOp::SetPreferenceData {
                        key: "cachedGroups".to_owned(),
                        data: bytes,
                    }));
                }

                mark_group_metadata_dirty(out);
                show_toast(state, ToastKind::Success, "Đã rời nhóm", out);
                complete_op(out, op_id, OpResult::Bool(true), true);
            }
        },

        Input::GroupDetailFetched {
            gid,
            purpose,
            group_info,
        } => {
            let now_ms = match &purpose {
                GroupDetailPurpose::Refresh { now_ms, .. }
                | GroupDetailPurpose::CreateFollowup { now_ms, .. }
                | GroupDetailPurpose::InviteFollowup { now_ms, .. }
                | GroupDetailPurpose::KickFollowup { now_ms, .. }
                | GroupDetailPurpose::AdminFollowup { now_ms, .. }
                | GroupDetailPurpose::LoadMembers { now_ms, .. } => *now_ms,
            };

            let mut had_store = false;
            if let Some(info) = group_info
                && !info.is_empty()
            {
                state.groups.member_cache.remove(&gid);
                let self_conv_id = state.session.self_conversation_id.clone();
                if let Some(persisted) = merge_fetched_group_metadata(
                    &gid,
                    &info,
                    &mut state.groups,
                    &mut state.contacts,
                    &mut state.conversations,
                    self_conv_id.as_deref(),
                    now_ms,
                ) {
                    mark_group_metadata_dirty(out);
                    had_store = emit_persistence(persisted, out);
                }
            }

            match purpose {
                GroupDetailPurpose::Refresh { op_id, .. } => {
                    complete_op(out, op_id, OpResult::Unit, had_store);
                }
                GroupDetailPurpose::CreateFollowup {
                    op_id,
                    failed,
                    avatar_upload_failed,
                    ..
                } => {
                    start_contacts_sync(state, None, out);
                    state.groups.navigation_request = Some(gid.clone());
                    out.dirty.insert(DirtyKey::Groups);

                    if !failed.is_empty() && avatar_upload_failed {
                        let names: Vec<String> = failed
                            .iter()
                            .map(|uid| contact_name_for_group_notice(uid, &state.contacts))
                            .collect();
                        show_toast(
                            state,
                            ToastKind::Neutral,
                            format!("{} Chưa tải lên được ảnh đại diện.", not_added_text(&names)),
                            out,
                        );
                    } else if !failed.is_empty() {
                        let names: Vec<String> = failed
                            .iter()
                            .map(|uid| contact_name_for_group_notice(uid, &state.contacts))
                            .collect();
                        show_toast(state, ToastKind::Neutral, not_added_text(&names), out);
                    } else if avatar_upload_failed {
                        show_toast(
                            state,
                            ToastKind::Neutral,
                            "Đã tạo nhóm nhưng chưa tải lên được ảnh đại diện.",
                            out,
                        );
                    }

                    complete_op(
                        out,
                        op_id,
                        OpResult::GroupCreate(GroupCreateOutcome::Created { id: gid, failed }),
                        true,
                    );
                }
                GroupDetailPurpose::InviteFollowup {
                    op_id,
                    rejected_ordered,
                    ..
                } => {
                    if !rejected_ordered.is_empty() {
                        let names: Vec<String> = rejected_ordered
                            .iter()
                            .map(|uid| contact_name_for_group_notice(uid, &state.contacts))
                            .collect();
                        show_toast(state, ToastKind::Neutral, not_added_text(&names), out);
                    } else {
                        show_toast(
                            state,
                            ToastKind::Success,
                            "Đã thêm thành viên vào nhóm",
                            out,
                        );
                    }
                    complete_op(out, op_id, OpResult::Bool(true), true);
                }
                GroupDetailPurpose::KickFollowup { op_id, .. } => {
                    show_toast(
                        state,
                        ToastKind::Success,
                        "Đã xóa thành viên khỏi nhóm",
                        out,
                    );
                    complete_op(out, op_id, OpResult::Bool(true), true);
                }
                GroupDetailPurpose::AdminFollowup { op_id, ok_text, .. } => {
                    if !ok_text.is_empty() {
                        out.effects.push(Effect::Host(HostCall::ShowCard {
                            conv_id: Some(gid),
                            text: ok_text,
                        }));
                    }
                    complete_op(out, op_id, OpResult::Bool(true), had_store);
                }
                GroupDetailPurpose::LoadMembers { op_id, .. } => {
                    continue_load_group_members(state, &gid, op_id, had_store, out);
                }
            }
        }

        Input::GroupMemberProfilesFetched {
            op_id,
            gid,
            uids,
            purpose,
            profiles_map,
        } => {
            let mut candidates = Vec::with_capacity(uids.len() + 1);
            candidates.push(MentionCandidate::all());
            if let Some(map) = profiles_map {
                // Approved Fix (`user-decisions` item 7.3): iterate in member-list order (`uids`).
                for uid in &uids {
                    let Some(row) = map.get(uid).and_then(Value::as_object) else {
                        continue;
                    };
                    let name = preferred_profile_name(row);
                    if name.is_empty() {
                        continue;
                    }
                    let avt = lossless::string(row.get("avatar").or_else(|| row.get("avt")));
                    let avatar = (!avt.is_empty() && is_valid_url_str(&avt)).then_some(avt);
                    candidates.push(MentionCandidate {
                        id: uid.clone(),
                        name,
                        avatar,
                        is_all: false,
                    });
                }
            }
            state
                .groups
                .member_cache
                .insert(gid.clone(), candidates.clone());
            out.dirty.insert(DirtyKey::Groups);

            match purpose {
                MemberProfilesPurpose::Mention { query, excluding } => {
                    let filtered = filter_mention_candidates(&candidates, &query, &excluding);
                    complete_op(out, op_id, OpResult::MentionCandidates(filtered), false);
                }
                MemberProfilesPurpose::LoadMembers => {
                    let via_mention: Vec<MentionCandidate> = candidates
                        .into_iter()
                        .filter(|c| !c.is_all && c.id != "-1")
                        .collect();
                    if !via_mention.is_empty() {
                        complete_op(out, op_id, OpResult::MentionCandidates(via_mention), false);
                    } else {
                        finish_load_group_members_fallback(state, &gid, op_id, false, out);
                    }
                }
            }
        }

        Input::GroupAdminApiDone {
            op_id,
            gid,
            action,
            now_ms,
            result,
        } => match result {
            Ok(()) => {
                state.groups.member_cache.remove(&gid);
                out.dirty.insert(DirtyKey::Groups);
                out.effects.push(Effect::FetchGroupDetailApi {
                    gid,
                    purpose: GroupDetailPurpose::AdminFollowup {
                        op_id,
                        ok_text: action.ok_text().to_owned(),
                        now_ms,
                    },
                });
            }
            Err(code) => {
                let code_str = code.map_or_else(|| "-".to_owned(), |c| c.to_string());
                out.effects.push(Effect::EngineLog(format!(
                    "group admin: failed code={code_str}"
                )));
                out.effects.push(Effect::Host(HostCall::ShowCard {
                    conv_id: Some(gid),
                    text: admin_error_text(code, action.fail_text()),
                }));
                complete_op(out, op_id, OpResult::Bool(false), false);
            }
        },

        Input::GroupPendingFetched { op_id, members } => {
            complete_op(out, op_id, OpResult::GroupPending(members), false);
        }

        Input::GroupLinkFetched {
            op_id,
            gid,
            is_mutation,
            link,
        } => {
            if is_mutation && link.is_none() {
                out.effects.push(Effect::Host(HostCall::ShowCard {
                    conv_id: Some(gid),
                    text: "Không thể thực hiện, vui lòng thử lại".to_owned(),
                }));
            }
            complete_op(out, op_id, OpResult::GroupLink(link), false);
        }

        _ => {}
    }
}

fn reduce_command(state: &mut CoreState, cmd: Command, op_id: Option<u64>, out: &mut ReduceOutput) {
    match cmd {
        Command::CreateGroup {
            name,
            members,
            avatar,
            now_ms,
        } => {
            out.effects.push(Effect::CreateGroupApi {
                op_id,
                name,
                members,
                avatar,
                now_ms,
            });
        }

        Command::RenameGroup {
            group_id,
            name,
            now_ms,
        } => {
            let gid = group_conv_id(&group_id);
            let clean_grid = clean_group_id(&group_id);
            let trimmed = name.trim().to_owned();
            if gid.is_empty() || clean_grid.is_empty() || clean_grid == "0" || trimmed.is_empty() {
                complete_op(out, op_id, OpResult::Bool(false), false);
                return;
            }
            out.effects.push(Effect::RenameGroupApi {
                op_id,
                gid,
                name: trimmed,
                now_ms,
            });
        }

        Command::InviteGroupMembers {
            group_id,
            member_ids,
            now_ms,
        } => {
            let gid = group_conv_id(&group_id);
            let clean_grid = clean_group_id(&group_id);
            let my_uid = strip_user_prefix(my_profile_info(state).0);
            let clean_ids: Vec<String> = clean_group_member_ids(&member_ids)
                .into_iter()
                .filter(|id| id != &my_uid)
                .collect();
            if gid.is_empty() || clean_grid.is_empty() || clean_grid == "0" || clean_ids.is_empty()
            {
                complete_op(out, op_id, OpResult::Bool(false), false);
                return;
            }
            out.effects.push(Effect::InviteGroupMembersApi {
                op_id,
                gid,
                member_ids: clean_ids,
                now_ms,
            });
        }

        Command::KickGroupMember {
            group_id,
            member_id,
            now_ms,
        } => {
            let gid = group_conv_id(&group_id);
            let clean_grid = clean_group_id(&group_id);
            let Some(clean_member) = clean_group_member_ids(&[member_id]).into_iter().next() else {
                complete_op(out, op_id, OpResult::Bool(false), false);
                return;
            };
            if gid.is_empty() || clean_grid.is_empty() || clean_grid == "0" {
                complete_op(out, op_id, OpResult::Bool(false), false);
                return;
            }
            let my_raw = my_profile_info(state).0;
            if !my_raw.is_empty() && clean_member == strip_user_prefix(my_raw) {
                complete_op(out, op_id, OpResult::Bool(false), false);
                return;
            }
            out.effects.push(Effect::KickGroupMemberApi {
                op_id,
                gid,
                member_id: clean_member,
                now_ms,
            });
        }

        Command::LeaveGroup { group_id, silent } => {
            let gid = group_conv_id(&group_id);
            let clean_grid = clean_group_id(&group_id);
            if gid.is_empty() || clean_grid.is_empty() || clean_grid == "0" {
                complete_op(out, op_id, OpResult::Bool(false), false);
                return;
            }
            out.effects
                .push(Effect::LeaveGroupApi { op_id, gid, silent });
        }

        Command::RefreshGroupMetadata { group_id, now_ms } => {
            let gid = group_conv_id(&group_id);
            let clean_grid = clean_group_id(&group_id);
            if gid.is_empty() || clean_grid.is_empty() {
                complete_op(out, op_id, OpResult::Unit, false);
                return;
            }
            out.effects.push(Effect::FetchGroupDetailApi {
                gid,
                purpose: GroupDetailPurpose::Refresh { op_id, now_ms },
            });
        }

        Command::MentionCandidates {
            group_id,
            query,
            excluding,
        } => {
            if !is_group_id(&group_id) {
                complete_op(out, op_id, OpResult::MentionCandidates(Vec::new()), false);
                return;
            }
            if let Some(cached) = state.groups.member_cache.get(&group_id) {
                let filtered = filter_mention_candidates(cached, &query, &excluding);
                complete_op(out, op_id, OpResult::MentionCandidates(filtered), false);
                return;
            }
            if state.groups.detail_object(&group_id).is_some() {
                let my_uid = my_profile_info(state).0.to_owned();
                let clean_ids = mention_member_fetch_ids(&group_id, &my_uid, &state.groups);
                if !clean_ids.is_empty() {
                    let fetch_ids: Vec<String> = clean_ids
                        .into_iter()
                        .take(MENTION_PROFILE_FETCH_LIMIT)
                        .collect();
                    out.effects.push(Effect::FetchGroupMemberProfilesApi {
                        op_id,
                        gid: group_id,
                        uids: fetch_ids,
                        purpose: MemberProfilesPurpose::Mention { query, excluding },
                    });
                    return;
                }
            }
            let cached = vec![MentionCandidate::all()];
            let filtered = filter_mention_candidates(&cached, &query, &excluding);
            state.groups.member_cache.insert(group_id, cached);
            out.dirty.insert(DirtyKey::Groups);
            complete_op(out, op_id, OpResult::MentionCandidates(filtered), false);
        }

        Command::LoadGroupMembers { group_id, now_ms } => {
            let gid = group_conv_id(&group_id);
            let clean_grid = clean_group_id(&group_id);
            if gid.is_empty() {
                complete_op(out, op_id, OpResult::MentionCandidates(Vec::new()), false);
                return;
            }
            if !state.groups.details_json.contains_key(&clean_grid) {
                out.effects.push(Effect::FetchGroupDetailApi {
                    gid,
                    purpose: GroupDetailPurpose::LoadMembers { op_id, now_ms },
                });
                return;
            }
            continue_load_group_members(state, &gid, op_id, false, out);
        }

        Command::SetGroupAdmin {
            group_id,
            uid,
            admin,
            now_ms,
        } => {
            let gid = group_conv_id(&group_id);
            out.effects.push(Effect::GroupAdminApi {
                op_id,
                gid,
                action: GroupAdminAction::SetAdmin { uid, admin },
                now_ms,
            });
        }

        Command::ChangeGroupOwner {
            group_id,
            uid,
            now_ms,
        } => {
            let gid = group_conv_id(&group_id);
            out.effects.push(Effect::GroupAdminApi {
                op_id,
                gid,
                action: GroupAdminAction::ChangeOwner { uid },
                now_ms,
            });
        }

        Command::BlockGroupMember {
            group_id,
            uid,
            now_ms,
        } => {
            let gid = group_conv_id(&group_id);
            out.effects.push(Effect::GroupAdminApi {
                op_id,
                gid,
                action: GroupAdminAction::BlockMember { uid },
                now_ms,
            });
        }

        Command::FetchGroupPending { group_id } => {
            out.effects
                .push(Effect::FetchGroupPendingApi { op_id, group_id });
        }

        Command::ReviewGroupPending {
            group_id,
            uids,
            approve,
            now_ms,
        } => {
            let gid = group_conv_id(&group_id);
            out.effects.push(Effect::GroupAdminApi {
                op_id,
                gid,
                action: GroupAdminAction::ReviewPending { uids, approve },
                now_ms,
            });
        }

        Command::SetGroupJoinApproval {
            group_id,
            on,
            now_ms,
        } => {
            let gid = group_conv_id(&group_id);
            let mut settings = state
                .groups
                .detail_object(&group_id)
                .and_then(|d| d.get("setting").and_then(Value::as_object).cloned())
                .unwrap_or_default();
            settings.insert("joinAppr".to_owned(), Value::from(if on { 1 } else { 0 }));
            out.effects.push(Effect::GroupAdminApi {
                op_id,
                gid,
                action: GroupAdminAction::SetJoinApproval { settings },
                now_ms,
            });
        }

        Command::FetchGroupLink { group_id } => {
            let gid = group_conv_id(&group_id);
            out.effects.push(Effect::FetchGroupLinkApi { op_id, gid });
        }

        Command::SetGroupLink { group_id, renew } => {
            let gid = group_conv_id(&group_id);
            out.effects
                .push(Effect::SetGroupLinkApi { op_id, gid, renew });
        }

        Command::HandleGroupEventNotice {
            act,
            data,
            ts,
            now_ms,
        } => {
            let had_store = handle_group_event_notice(state, &act, &data, ts, now_ms, out);
            complete_op(out, op_id, OpResult::Unit, had_store);
        }

        Command::ClearGroupNavigationRequest => {
            if state.groups.navigation_request.take().is_some() {
                out.dirty.insert(DirtyKey::Groups);
            }
            complete_op(out, op_id, OpResult::Unit, false);
        }

        Command::SeedGroups(groups) => {
            state.groups.apply_seeded_groups(*groups);
            out.dirty.insert(DirtyKey::Groups);
            out.dirty.insert(DirtyKey::CachedGroups);
            out.refresh_identity_snapshot = true;
            complete_op(out, op_id, OpResult::Unit, false);
        }

        _ => {}
    }
}

#[cfg(test)]
#[expect(
    clippy::unwrap_used,
    reason = "unit tests assert invariants on synthetic fixtures"
)]
mod tests {
    use serde_json::json;

    use super::*;
    use crate::messages::FriendEntry;
    use crate::reduce::reduce;
    use crate::state::Profile;

    fn state_with_profile(uid: &str) -> CoreState {
        let mut s = CoreState::default();
        s.session.profile = Some(Profile {
            user_id: uid.to_owned(),
            display_name: "Me".to_owned(),
            avatar: None,
            phone: None,
        });
        s
    }

    #[test]
    fn fix_7_1_create_group_persists_even_when_getmg_returns_empty() {
        let mut state = state_with_profile("2001001");
        let root = json!({
            "error_code": 0,
            "data": { "groupId": "500999" }
        })
        .as_object()
        .cloned()
        .unwrap();

        let out = reduce(
            &mut state,
            Input::GroupCreatedApi {
                op_id: Some(1),
                name: "   ".to_owned(),
                members: vec!["3001001".to_owned()],
                avatar: None,
                now_ms: 1_700_000_000_000,
                result: Ok(root),
            },
        );
        // Persisted immediately to SQLite (cachedGroups + conversation row)
        assert!(out.effects.iter().any(|e| matches!(
            e,
            Effect::Store(StoreOp::SetPreferenceData { key, .. }) if key == "cachedGroups"
        )));
        assert!(out.effects.iter().any(|e| matches!(
            e,
            Effect::Store(StoreOp::SaveConversations(rows)) if rows.iter().any(|r| r.id == "g500999" && r.name == "Nhóm")
        )));

        // Follow-up getmg-v2 returns empty -> group stays persisted and navigation_request is set
        let followup_out = reduce(
            &mut state,
            Input::GroupDetailFetched {
                gid: "g500999".to_owned(),
                purpose: GroupDetailPurpose::CreateFollowup {
                    op_id: Some(1),
                    failed: Vec::new(),
                    avatar_upload_failed: false,
                    now_ms: 1_700_000_000_000,
                },
                group_info: None,
            },
        );
        assert_eq!(state.groups.navigation_request.as_deref(), Some("g500999"));
        assert!(state.groups.cached_groups.contains_key("g500999"));
        assert!(followup_out.effects.iter().any(|e| matches!(
            e,
            Effect::CompleteOp {
                op_id: 1,
                result: OpResult::GroupCreate(GroupCreateOutcome::Created { id, .. }),
                after_store: true,
            } if id == "g500999"
        )));
    }

    #[test]
    fn fix_7_2_invite_rejected_notice_preserves_deterministic_order() {
        let mut state = state_with_profile("2001001");
        for (id, name) in [
            ("3001001", "Dũng"),
            ("3001002", "An"),
            ("3001003", "Chi"),
            ("3001004", "Bình"),
        ] {
            state.contacts.friends.push(FriendEntry {
                id: id.to_owned(),
                name: name.to_owned(),
                zalo_name: name.to_owned(),
                avatar: None,
                last_active_ms: None,
                online: false,
                section: String::new(),
                sort_key: String::new(),
            });
        }
        let root = json!({
            "error_code": 0,
            "data": {
                // Deliberately non-sorted order with duplicate to prove order-preserving dedup
                "errorMem": ["3001001", "3001004", "3001001", "3001003", "3001002"]
            }
        })
        .as_object()
        .cloned()
        .unwrap();

        let out = reduce(
            &mut state,
            Input::GroupMembersInvitedApi {
                op_id: Some(2),
                gid: "g500501".to_owned(),
                clean_ids: vec![
                    "3001001".to_owned(),
                    "3001002".to_owned(),
                    "3001003".to_owned(),
                    "3001004".to_owned(),
                    "3001099".to_owned(),
                ],
                now_ms: 1_700_000_000_000,
                result: Ok(root),
            },
        );
        let purpose = out
            .effects
            .into_iter()
            .find_map(|e| match e {
                Effect::FetchGroupDetailApi { purpose, .. } => Some(purpose),
                _ => None,
            })
            .unwrap();
        let _ = reduce(
            &mut state,
            Input::GroupDetailFetched {
                gid: "g500501".to_owned(),
                purpose,
                group_info: None,
            },
        );
        let toast = state.conversations.ui.toast.as_ref().unwrap();
        assert_eq!(
            toast.text,
            "Chưa thêm được Dũng, Bình, Chi và 1 người khác vào nhóm."
        );
    }

    #[test]
    fn fix_7_3_mention_candidates_preserve_order_and_exclude_normalized_self() {
        let mut state = state_with_profile("u2001001_0");
        state.groups.details_json.insert(
            "500777".to_owned(),
            json!({
                "groupId": "500777",
                "memVerList": [
                    "3001003_0",
                    "2001001_0",
                    "3001001_0",
                    "u3001003_1",
                    "3001002_0"
                ]
            })
            .to_string(),
        );

        let ids = mention_member_fetch_ids("g500777", "u2001001_0", &state.groups);
        assert_eq!(ids, vec!["3001003", "3001001", "3001002"]);

        let profiles_map = json!({
            "3001001": { "displayName": "An" },
            "3001002": { "displayName": "Bình" },
            "3001003": { "displayName": "Chi" },
        })
        .as_object()
        .cloned()
        .unwrap();

        let _ = reduce(
            &mut state,
            Input::GroupMemberProfilesFetched {
                op_id: Some(3),
                gid: "g500777".to_owned(),
                uids: ids,
                purpose: MemberProfilesPurpose::Mention {
                    query: String::new(),
                    excluding: Vec::new(),
                },
                profiles_map: Some(profiles_map),
            },
        );
        let cached = state.groups.member_cache.get("g500777").unwrap();
        let cached_ids: Vec<&str> = cached.iter().map(|c| c.id.as_str()).collect();
        assert_eq!(cached_ids, vec!["-1", "3001003", "3001001", "3001002"]);
    }
}
