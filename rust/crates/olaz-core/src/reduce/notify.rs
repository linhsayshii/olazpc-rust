//! Reducer for notifications, mutes, incoming banner decisions, reminders, and card actions (U16).

use std::collections::HashSet;
use std::time::Duration;

use olaz_wire::lossless::string;
use olaz_wire::{
    ChatMessage, ECard, ECardStyle, Kind, UNKNOWN_NAME, is_group_id, strip_user_prefix,
    web_link_sanitized,
};
use serde_json::{Map, Value};

use crate::changes::DirtyKey;
use crate::conversations::{CachedProfile, message_preview_label, preferred_profile_name};
use crate::effect::{Effect, HostCall, OpResult, StoreOp};
use crate::input::{Command, Input};
use crate::notify::{
    CARD_DEFAULT_FAILED, CARD_DEFAULT_UNSUPPORTED, CardActionOutcomeData, ContactCardStateResult,
    ContactProfileResult, FriendRequestPrepResult, IncomingBatchInFlight, MUTE_ERROR_TOAST_TEXT,
    MuteInFlight, MuteInfo, NotifAuthorization, NotifyBannerPayload, ReminderSnapshotData,
    ReminderWatchWaiter, RespondReminderResult, SaveAliasResult, SubmitFriendRequestResult,
    build_reminder_responders, extract_responder_buckets, map_join_group_outcome,
    map_suggested_stickers, normalize_reminder_snapshot, parse_group_invite_preview,
};
use crate::reduce::ReduceOutput;
use crate::state::CoreState;

const REMINDER_WATCH_TIMEOUT: Duration = Duration::from_secs(15);

#[must_use]
pub(crate) fn is_notify_command(cmd: &Command) -> bool {
    matches!(
        cmd,
        Command::SetNotificationsEnabled { .. }
            | Command::SetNotificationSound { .. }
            | Command::SetMessagePreview { .. }
            | Command::SetNotifAuthorization { .. }
            | Command::MuteConversation { .. }
            | Command::UnmuteConversation { .. }
            | Command::IsConversationMuted { .. }
            | Command::HandleNotificationSettingsPayload { .. }
            | Command::LoadNotificationPreferences
            | Command::NotifyIncomingBatch { .. }
            | Command::PerformCardAction { .. }
            | Command::SuggestedStickers { .. }
            | Command::ContactCardState { .. }
            | Command::ContactProfile { .. }
            | Command::PrepareFriendRequest { .. }
            | Command::SubmitFriendRequest { .. }
            | Command::SaveAlias { .. }
            | Command::GroupInvitePreview { .. }
            | Command::JoinGroup { .. }
            | Command::ReminderWatch { .. }
            | Command::RespondReminder { .. }
            | Command::ReminderResponders { .. }
            | Command::ResetCardState
            | Command::SyncPinReminderRefs { .. }
    )
}

pub(crate) fn persist_notification_preferences(state: &CoreState, out: &mut ReduceOutput) {
    out.effects.push(Effect::Store(StoreOp::SetPreferenceBool {
        key: "notifEnabled".to_owned(),
        value: state.notify.settings.enabled,
    }));
    out.effects.push(Effect::Store(StoreOp::SetPreferenceBool {
        key: "notifSound".to_owned(),
        value: state.notify.settings.sound,
    }));
    out.effects.push(Effect::Store(StoreOp::SetPreferenceData {
        key: "mutedThreads".to_owned(),
        data: state.notify.settings.serialize_muted_threads_json(),
    }));
}

fn persist_aliases(state: &CoreState, out: &mut ReduceOutput) {
    if let Ok(bytes) = serde_json::to_vec(&state.conversations.identities.aliases) {
        out.effects.push(Effect::Store(StoreOp::SetPreferenceData {
            key: "aliases".to_owned(),
            data: bytes,
        }));
    }
}

fn complete_unit(op_id: Option<u64>, out: &mut ReduceOutput) {
    if let Some(id) = op_id {
        out.effects.push(Effect::CompleteOp {
            op_id: id,
            result: OpResult::Unit,
            after_store: true,
        });
    }
}

fn resolve_reminder_id(state: &CoreState, conv_id: &str, msg_id: &str) -> String {
    if let Some(refs) = state.notify.pin_reminder_refs.get(conv_id)
        && let Some(found) = refs
            .iter()
            .find(|r| r.msg_id == msg_id || r.cli_msg_id == msg_id)
        && !found.reminder_ref.is_empty()
    {
        return found.reminder_ref.clone();
    }
    msg_id.to_owned()
}

fn reminder_card_context(state: &CoreState, conv_id: &str, msg_id: &str) -> Option<ECard> {
    let list = state.messages.windows.get(conv_id)?;
    let msg = list.iter().find(|m| m.id == msg_id)?;
    match &msg.kind {
        Kind::Ecard(card) => Some(card.clone()),
        _ => None,
    }
}

fn normalize_reminder_in_state(
    state: &CoreState,
    resp: &Map<String, Value>,
    conv_id: &str,
    reminder_id: &str,
    msg_id: &str,
) -> Option<ReminderSnapshotData> {
    let fallback = reminder_card_context(state, conv_id, msg_id);
    let snap = state.identity_snapshot();
    let my_uid = state
        .session
        .profile
        .as_ref()
        .map(|p| p.user_id.as_str())
        .unwrap_or("");
    normalize_reminder_snapshot(
        resp,
        conv_id,
        reminder_id,
        fallback.as_ref(),
        my_uid,
        &|uid| snap.lookup_person(uid).map(|info| info.name),
    )
}

fn wake_reminder_waiters_for_key(state: &mut CoreState, key: &str, out: &mut ReduceOutput) {
    let Some(waiters) = state.notify.reminder_waiters.remove(key) else {
        return;
    };
    for w in waiters {
        out.effects
            .push(Effect::CancelReminderWatchTimer { waiter_id: w.waiter_id });
        out.effects.push(Effect::FetchReminderDetailApi {
            op_id: w.op_id,
            conv_id: w.conv_id,
            msg_id: w.msg_id,
            event_id: w.event_id,
        });
    }
}

/// Evaluates incoming notification banners for `messages` at `now_ms`.
///
/// When all sender avatars are already resolved locally (or `settings.enabled == false`),
/// emits `HostCall::NotifyBanner` synchronously without any async hop. When any unmuted
/// message lacks a local avatar and has a valid `sender_id`, fetches missing profiles first
/// via `Effect::FetchNotifyProfilesApi` and completes in `Input::NotifyProfilesFetched`.
pub(crate) fn start_notify_incoming_batch(
    state: &mut CoreState,
    messages: Vec<ChatMessage>,
    now_ms: i64,
    op_id: Option<u64>,
    out: &mut ReduceOutput,
) {
    step_incoming_batch(
        state,
        IncomingBatchInFlight {
            messages,
            cursor: 0,
            now_ms,
            op_id,
        },
        false,
        out,
    );
}

fn step_incoming_batch(
    state: &mut CoreState,
    mut flight: IncomingBatchInFlight,
    mut already_fetched_current: bool,
    out: &mut ReduceOutput,
) {
    while flight.cursor < flight.messages.len() {
        if !state.notify.settings.enabled {
            flight.cursor += 1;
            already_fetched_current = false;
            continue;
        }
        let msg = &flight.messages[flight.cursor];
        let conv_id = &msg.conversation_id;
        if conv_id.is_empty()
            || msg.is_mine
            || state.notify.settings.is_muted(conv_id, flight.now_ms)
        {
            flight.cursor += 1;
            already_fetched_current = false;
            continue;
        }
        let snap = state.identity_snapshot();
        let is_group = is_group_id(conv_id);
        let conv = state
            .conversations
            .conversations
            .iter()
            .find(|c| &c.id == conv_id);
        let clean_sender_id = strip_user_prefix(&msg.sender_id);
        let person = (!clean_sender_id.is_empty() && clean_sender_id != "0")
            .then(|| snap.lookup_person(&clean_sender_id))
            .flatten();
        let local_avatar_url = resolve_local_avatar_url(msg, person.as_ref(), conv, is_group);

        if !already_fetched_current
            && local_avatar_url.is_none()
            && !clean_sender_id.is_empty()
            && clean_sender_id != "0"
        {
            state.notify.next_incoming_id = state.notify.next_incoming_id.wrapping_add(1);
            let batch_id = state.notify.next_incoming_id;
            state.notify.incoming_in_flight.insert(batch_id, flight);
            out.effects.push(Effect::FetchNotifyProfilesApi {
                batch_id,
                uids: vec![clean_sender_id],
            });
            return;
        }

        emit_banner_for_single_message(state, msg, &snap, out);
        flight.cursor += 1;
        already_fetched_current = false;
    }
    complete_unit(flight.op_id, out);
}

fn resolve_local_avatar_url(
    msg: &ChatMessage,
    person: Option<&olaz_wire::NameLookup>,
    conv: Option<&crate::conversations::ConversationSummary>,
    is_group: bool,
) -> Option<String> {
    if let Some(avt) = msg.sender_avatar.as_deref()
        && let Some(u) = non_empty_url(avt)
    {
        return Some(u);
    }
    if let Some(p) = person
        && let Some(u) = non_empty_url(&p.avatar)
    {
        return Some(u);
    }
    if !is_group
        && let Some(c) = conv
        && let Some(avt) = c.avatar.as_deref()
        && let Some(u) = non_empty_url(avt)
    {
        return Some(u);
    }
    None
}

fn non_empty_url(raw: &str) -> Option<String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return None;
    }
    // Swift `URL(string:)` accepts valid URLs; `web_link_sanitized` or scheme-bearing URLs.
    if web_link_sanitized(Some(trimmed.to_owned())).is_some() || trimmed.contains("://") {
        Some(trimmed.to_owned())
    } else {
        None
    }
}

fn emit_banner_for_single_message(
    state: &CoreState,
    msg: &ChatMessage,
    snap: &crate::messages::IdentitySnapshot,
    out: &mut ReduceOutput,
) {
    let conv_id = &msg.conversation_id;
    let is_group = is_group_id(conv_id);
    let conv = state
        .conversations
        .conversations
        .iter()
        .find(|c| &c.id == conv_id);
    let clean_sender_id = strip_user_prefix(&msg.sender_id);
    let person = (!clean_sender_id.is_empty() && clean_sender_id != "0")
        .then(|| snap.lookup_person(&clean_sender_id))
        .flatten();

    let resolved_avatar_url = resolve_local_avatar_url(msg, person.as_ref(), conv, is_group);

    let title = if let Some(c) = conv
        && !c.name.is_empty()
        && c.name != *conv_id
    {
        c.name.clone()
    } else if let Some(p) = person.as_ref()
        && !p.name.is_empty()
        && p.name != clean_sender_id
    {
        p.name.clone()
    } else if msg.sender_name.is_empty() {
        conv_id.clone()
    } else {
        msg.sender_name.clone()
    };

    let sender_name = if !is_group {
        title.clone()
    } else if let Some(p) = person.as_ref()
        && !p.name.is_empty()
        && p.name != clean_sender_id
        && p.name != UNKNOWN_NAME
    {
        p.name.clone()
    } else {
        msg.sender_name.clone()
    };

    let raw_preview = message_preview_label(msg);
    let body = crate::notify::policy::body(&raw_preview, state.notify.settings.shows_preview);
    let silent = !state.notify.settings.sound;

    out.effects.push(Effect::Host(HostCall::NotifyBanner(
        NotifyBannerPayload {
            title,
            body,
            conv_id: conv_id.clone(),
            sender_id: clean_sender_id,
            sender_name,
            is_group,
            avatar_url: resolved_avatar_url,
            silent,
        },
    )));
}

pub(crate) fn reduce_notify(state: &mut CoreState, input: Input, out: &mut ReduceOutput) {
    match input {
        Input::Command(cmd) => handle_command(state, cmd, None, out),
        Input::OpRequest { op_id, cmd } => handle_command(state, cmd, Some(op_id), out),

        Input::NotificationPrefsLoaded {
            enabled,
            sound,
            mutes,
            op_id,
        } => {
            state.notify.settings.is_loaded = true;
            state.notify.settings.enabled = enabled;
            state.notify.settings.sound = sound;
            state.notify.settings.has_sound_setting = true;
            if let Some(m) = mutes {
                state.notify.settings.mutes = m;
            }
            out.dirty.insert(DirtyKey::NotificationSettings);
            complete_unit(op_id, out);
        }

        Input::NotifAuthResolved { auth, op_id } => {
            if state.notify.settings.authorization != auth {
                state.notify.settings.authorization = auth;
                out.dirty.insert(DirtyKey::NotificationSettings);
            }
            complete_unit(op_id, out);
        }

        Input::SetMuteApiDone { req_id, ok } => {
            let Some(flight) = state.notify.mute_in_flight.remove(&req_id) else {
                return;
            };
            if ok {
                if flight.unmute {
                    state.notify.settings.mutes.remove(&flight.conv_id);
                } else {
                    state.notify.settings.mutes.insert(
                        flight.conv_id.clone(),
                        MuteInfo {
                            start_time: flight.start_time_sec as f64,
                            duration: if flight.duration_secs < 0 {
                                -1.0
                            } else {
                                flight.duration_secs as f64
                            },
                        },
                    );
                }
                out.dirty.insert(DirtyKey::NotificationSettings);
                persist_notification_preferences(state, out);
            } else {
                // Approved fix 16.1: keep previous mute state, skip SQLite write, show error toast.
                out.effects.push(Effect::Host(HostCall::ShowCard {
                    conv_id: flight.conv_id,
                    text: MUTE_ERROR_TOAST_TEXT.to_owned(),
                }));
            }
            complete_unit(flight.op_id, out);
        }

        Input::NotifyProfilesFetched { batch_id, profiles } => {
            let Some(flight) = state.notify.incoming_in_flight.remove(&batch_id) else {
                return;
            };
            let mut updated_any = false;
            for (uid, val) in profiles {
                let Some(row) = val.as_object() else { continue; };
                let clean = strip_user_prefix(&uid);
                let name = preferred_profile_name(row);
                let avatar = string(row.get("avatar").or_else(|| row.get("avt")));
                if !clean.is_empty() && (!name.is_empty() || !avatar.is_empty()) {
                    state
                        .conversations
                        .identities
                        .cached_profiles
                        .insert(clean, CachedProfile { name, avatar });
                    updated_any = true;
                }
            }
            if updated_any {
                out.dirty.insert(DirtyKey::CachedProfiles);
                if let Ok(bytes) =
                    serde_json::to_vec(&state.conversations.identities.cached_profiles)
                {
                    out.effects.push(Effect::Store(StoreOp::SetPreferenceData {
                        key: "cachedProfiles".to_owned(),
                        data: bytes,
                    }));
                }
            }
            step_incoming_batch(state, flight, true, out);
        }

        Input::SuggestedStickersFetched { op_id, rows } => {
            let items = rows
                .as_deref()
                .map(map_suggested_stickers)
                .unwrap_or_default();
            out.effects.push(Effect::CompleteOp {
                op_id,
                result: OpResult::SuggestedStickers(items),
                after_store: false,
            });
        }

        Input::ContactProfileFetched { op_id, uid, row } => {
            let prof = row.map(|r| {
                let name = preferred_profile_name(&r);
                let zalo_name = string(r.get("zaloName"));
                let avt = string(r.get("avatar").or_else(|| r.get("avt")));
                ContactProfileResult {
                    uid,
                    name,
                    zalo_name,
                    avatar: non_empty_url(&avt),
                    bio: String::new(),
                    is_self: false,
                    is_friend: false,
                    is_oa: false,
                }
            });
            out.effects.push(Effect::CompleteOp {
                op_id,
                result: OpResult::ContactProfile(prof),
                after_store: false,
            });
        }

        Input::SubmitFriendDone { op_id, ok } => {
            if ok {
                // U9: refresh contacts via host until U9 merges.
                out.effects.push(Effect::Host(HostCall::RefreshContacts {
                    op_id: Some(op_id),
                    result: OpResult::SubmitFriend(SubmitFriendRequestResult {
                        ok: true,
                        text: "Đã gửi lời mời kết bạn.".to_owned(),
                        pending: false,
                    }),
                }));
            } else {
                out.effects.push(Effect::CompleteOp {
                    op_id,
                    result: OpResult::SubmitFriend(SubmitFriendRequestResult {
                        ok: false,
                        text: "Không thể gửi lời mời kết bạn.".to_owned(),
                        pending: false,
                    }),
                    after_store: false,
                });
            }
        }

        Input::SaveAliasDone {
            op_id,
            uid,
            trimmed_name,
            ok,
        } => {
            let res = if ok {
                if trimmed_name.is_empty() {
                    state.conversations.identities.aliases.remove(&uid);
                } else {
                    state
                        .conversations
                        .identities
                        .aliases
                        .insert(uid, trimmed_name.clone());
                }
                out.dirty.insert(DirtyKey::Aliases);
                persist_aliases(state, out);
                SaveAliasResult {
                    ok: true,
                    text: if trimmed_name.is_empty() {
                        "Đã xóa tên gợi nhớ.".to_owned()
                    } else {
                        "Đã lưu tên gợi nhớ.".to_owned()
                    },
                }
            } else {
                SaveAliasResult {
                    ok: false,
                    text: "Không lưu được tên gợi nhớ.".to_owned(),
                }
            };
            out.effects.push(Effect::CompleteOp {
                op_id,
                result: OpResult::SaveAlias(res),
                after_store: true,
            });
        }

        Input::GroupInvitePreviewDone { op_id, url, resp } => {
            let preview = match resp {
                Some(r) => {
                    let member_ids: HashSet<&str> = state
                        .contacts
                        .groups
                        .iter()
                        .map(|g| g.id.as_str())
                        .collect();
                    parse_group_invite_preview(&r, &member_ids)
                }
                None => crate::notify::GroupInvitePreviewResult::default(),
            };
            if !preview.group_id.is_empty() {
                state
                    .notify
                    .invite_preview_groups
                    .insert(url, preview.group_id.clone());
            }
            out.effects.push(Effect::CompleteOp {
                op_id,
                result: OpResult::GroupInvitePreview(preview),
                after_store: false,
            });
        }

        Input::JoinGroupDone {
            op_id,
            fallback_group_id,
            result,
        } => {
            let (mapped, should_refresh) = map_join_group_outcome(
                result.as_ref(),
                fallback_group_id.as_deref(),
            );
            if should_refresh {
                // U9: refresh contacts via host until U9 merges.
                out.effects.push(Effect::Host(HostCall::RefreshContacts {
                    op_id: Some(op_id),
                    result: OpResult::JoinGroup(mapped),
                }));
            } else {
                out.effects.push(Effect::CompleteOp {
                    op_id,
                    result: OpResult::JoinGroup(mapped),
                    after_store: false,
                });
            }
        }

        Input::ReminderWatchTimeout { waiter_id } => {
            let mut found: Option<ReminderWatchWaiter> = None;
            let mut empty_key: Option<String> = None;
            for (key, list) in &mut state.notify.reminder_waiters {
                if let Some(pos) = list.iter().position(|w| w.waiter_id == waiter_id) {
                    found = Some(list.remove(pos));
                    if list.is_empty() {
                        empty_key = Some(key.clone());
                    }
                    break;
                }
            }
            if let Some(k) = empty_key {
                state.notify.reminder_waiters.remove(&k);
            }
            if let Some(w) = found {
                out.effects.push(Effect::FetchReminderDetailApi {
                    op_id: w.op_id,
                    conv_id: w.conv_id,
                    msg_id: w.msg_id,
                    event_id: w.event_id,
                });
            }
        }

        Input::ReminderDetailFetched {
            op_id,
            conv_id,
            msg_id,
            event_id,
            resp,
        } => {
            let snap = resp.and_then(|r| {
                normalize_reminder_in_state(state, &r, &conv_id, &event_id, &msg_id)
            });
            if let Some(ref s) = snap {
                state
                    .notify
                    .reminder_watch_cache
                    .insert(format!("{conv_id}|{msg_id}"), s.clone());
            }
            out.effects.push(Effect::CompleteOp {
                op_id,
                result: OpResult::ReminderSnapshot(snap),
                after_store: false,
            });
        }

        Input::RespondReminderDone {
            op_id,
            conv_id,
            msg_id,
            event_id,
            accept,
            ok,
            detail_resp,
        } => {
            let res = if ok {
                let key = format!("{conv_id}|{msg_id}");
                let updated = detail_resp.and_then(|r| {
                    normalize_reminder_in_state(state, &r, &conv_id, &event_id, &msg_id)
                });
                if let Some(ref u) = updated {
                    state.notify.reminder_watch_cache.insert(key.clone(), u.clone());
                } else {
                    state.notify.reminder_watch_cache.remove(&key);
                }
                wake_reminder_waiters_for_key(state, &key, out);
                RespondReminderResult {
                    ok: true,
                    text: if accept {
                        "Đã xác nhận tham gia.".to_owned()
                    } else {
                        "Đã từ chối.".to_owned()
                    },
                    snapshot: updated,
                }
            } else {
                RespondReminderResult {
                    ok: false,
                    text: CARD_DEFAULT_FAILED.to_owned(),
                    snapshot: None,
                }
            };
            out.effects.push(Effect::CompleteOp {
                op_id,
                result: OpResult::RespondReminder(res),
                after_store: false,
            });
        }

        Input::ReminderRespondersFetched { op_id, resp } => {
            let Some(resp_obj) = resp else {
                out.effects.push(Effect::CompleteOp {
                    op_id,
                    result: OpResult::ReminderResponders(None),
                    after_store: false,
                });
                return;
            };
            let Some(buckets) = extract_responder_buckets(&resp_obj) else {
                out.effects.push(Effect::CompleteOp {
                    op_id,
                    result: OpResult::ReminderResponders(None),
                    after_store: false,
                });
                return;
            };
            let snap = state.identity_snapshot();
            let mut missing_set: HashSet<String> = HashSet::new();
            for entry in buckets.accept.iter().chain(buckets.reject.iter()) {
                if snap.lookup_person(&entry.uid).is_none() && entry.name.is_empty() {
                    missing_set.insert(entry.uid.clone());
                }
            }
            let mut missing_uids: Vec<String> = missing_set.into_iter().collect();
            missing_uids.sort();
            missing_uids.truncate(50);

            if missing_uids.is_empty() {
                let my_uid = state
                    .session
                    .profile
                    .as_ref()
                    .map(|p| p.user_id.as_str())
                    .unwrap_or("");
                let built = build_reminder_responders(&buckets, my_uid, &|uid| {
                    snap.lookup_person(uid).map(|i| (i.name, i.avatar))
                });
                out.effects.push(Effect::CompleteOp {
                    op_id,
                    result: OpResult::ReminderResponders(Some(built)),
                    after_store: false,
                });
            } else {
                out.effects.push(Effect::FetchResponderProfilesApi {
                    op_id,
                    buckets,
                    uids: missing_uids,
                });
            }
        }

        Input::ReminderResponderProfilesFetched {
            op_id,
            buckets,
            profiles,
        } => {
            let mut updated_any = false;
            for (uid, val) in profiles {
                let Some(row) = val.as_object() else { continue; };
                let clean = strip_user_prefix(&uid);
                let name = preferred_profile_name(row);
                let avatar = string(row.get("avatar").or_else(|| row.get("avt")));
                if !clean.is_empty() && (!name.is_empty() || !avatar.is_empty()) {
                    state
                        .conversations
                        .identities
                        .cached_profiles
                        .insert(clean, CachedProfile { name, avatar });
                    updated_any = true;
                }
            }
            if updated_any {
                // Quirk preserved as recorded: updates in-memory `cachedProfiles` without persisting SQLite.
                out.dirty.insert(DirtyKey::CachedProfiles);
            }
            let snap = state.identity_snapshot();
            let my_uid = state
                .session
                .profile
                .as_ref()
                .map(|p| p.user_id.as_str())
                .unwrap_or("");
            let built = build_reminder_responders(&buckets, my_uid, &|uid| {
                snap.lookup_person(uid).map(|i| (i.name, i.avatar))
            });
            out.effects.push(Effect::CompleteOp {
                op_id,
                result: OpResult::ReminderResponders(Some(built)),
                after_store: false,
            });
        }

        Input::CategoryStickerSent { op_id, outcome } => {
            out.effects.push(Effect::CompleteOp {
                op_id,
                result: OpResult::CardAction(outcome),
                after_store: false,
            });
        }

        _ => {}
    }
}

fn handle_command(
    state: &mut CoreState,
    cmd: Command,
    op_id: Option<u64>,
    out: &mut ReduceOutput,
) {
    match cmd {
        Command::SetNotificationsEnabled { enabled } => {
            state.notify.settings.enabled = enabled;
            state.notify.settings.sound = enabled;
            state.notify.settings.has_sound_setting = true;
            out.dirty.insert(DirtyKey::NotificationSettings);
            persist_notification_preferences(state, out);
            if enabled {
                out.effects
                    .push(Effect::Host(HostCall::RequestNotifAuth { op_id }));
            } else {
                complete_unit(op_id, out);
            }
        }

        Command::SetNotificationSound { enabled } => {
            state.notify.settings.sound = enabled;
            state.notify.settings.has_sound_setting = true;
            out.dirty.insert(DirtyKey::NotificationSettings);
            persist_notification_preferences(state, out);
            complete_unit(op_id, out);
        }

        Command::SetMessagePreview { shown } => {
            if state.notify.settings.shows_preview != shown {
                state.notify.settings.shows_preview = shown;
                out.dirty.insert(DirtyKey::NotificationSettings);
            }
            complete_unit(op_id, out);
        }

        Command::SetNotifAuthorization { auth } => {
            if state.notify.settings.authorization != auth {
                state.notify.settings.authorization = auth;
                out.dirty.insert(DirtyKey::NotificationSettings);
            }
            complete_unit(op_id, out);
        }

        Command::MuteConversation {
            conv_id,
            duration_secs,
            now_ms,
        } => {
            if conv_id.is_empty() {
                complete_unit(op_id, out);
                return;
            }
            let start_time_sec = now_ms / 1000;
            let is_group = is_group_id(&conv_id);
            state.notify.next_mute_req_id = state.notify.next_mute_req_id.wrapping_add(1);
            let req_id = state.notify.next_mute_req_id;
            state.notify.mute_in_flight.insert(
                req_id,
                MuteInFlight {
                    conv_id: conv_id.clone(),
                    unmute: false,
                    start_time_sec,
                    duration_secs,
                    op_id,
                },
            );
            out.effects.push(Effect::SetMuteApi {
                req_id,
                conv_id,
                is_group,
                duration_secs,
                unmute: false,
                start_time_sec,
            });
        }

        Command::UnmuteConversation { conv_id, now_ms } => {
            if conv_id.is_empty() {
                complete_unit(op_id, out);
                return;
            }
            let start_time_sec = now_ms / 1000;
            let is_group = is_group_id(&conv_id);
            state.notify.next_mute_req_id = state.notify.next_mute_req_id.wrapping_add(1);
            let req_id = state.notify.next_mute_req_id;
            state.notify.mute_in_flight.insert(
                req_id,
                MuteInFlight {
                    conv_id: conv_id.clone(),
                    unmute: true,
                    start_time_sec,
                    duration_secs: 0,
                    op_id,
                },
            );
            out.effects.push(Effect::SetMuteApi {
                req_id,
                conv_id,
                is_group,
                duration_secs: 0,
                unmute: true,
                start_time_sec,
            });
        }

        Command::IsConversationMuted { conv_id, now_ms } => {
            let muted = state.notify.settings.is_muted(&conv_id, now_ms);
            if let Some(id) = op_id {
                out.effects.push(Effect::CompleteOp {
                    op_id: id,
                    result: OpResult::Bool(muted),
                    after_store: false,
                });
            }
        }

        Command::HandleNotificationSettingsPayload { payload } => {
            if payload.get("kind").and_then(Value::as_str) == Some("settings") {
                let mut next = state.notify.settings.clone();
                next.apply_settings_payload(&payload);
                if next != state.notify.settings {
                    state.notify.settings = next;
                    out.dirty.insert(DirtyKey::NotificationSettings);
                }
            }
            complete_unit(op_id, out);
        }

        Command::LoadNotificationPreferences => {
            out.effects
                .push(Effect::Store(StoreOp::LoadNotificationPrefs { op_id }));
        }

        Command::NotifyIncomingBatch { messages, now_ms } => {
            start_notify_incoming_batch(state, messages, now_ms, op_id, out);
        }

        Command::PerformCardAction {
            conv_id,
            msg_id,
            action_ref,
        } => {
            let Some(op_id) = op_id else {
                return;
            };
            if action_ref == "call:back" {
                let is_video = state
                    .messages
                    .windows
                    .get(&conv_id)
                    .and_then(|list| list.iter().find(|m| m.id == msg_id))
                    .is_some_and(|m| matches!(m.kind, Kind::Call { video: true, .. }));
                out.effects.push(Effect::Host(HostCall::StartCall {
                    uid: conv_id,
                    video: is_video,
                }));
                out.effects.push(Effect::CompleteOp {
                    op_id,
                    result: OpResult::CardAction(CardActionOutcomeData::Done),
                    after_store: false,
                });
                return;
            }

            // Swift `ref.split(separator: "_")` omits empty subsequences; replicate exact behavior:
            let parts: Vec<&str> = action_ref.split('_').filter(|s| !s.is_empty()).collect();
            if parts.len() == 2
                && let (Ok(cate_id), Ok(sticker_id)) = (parts[0].parse::<i32>(), parts[1].parse::<i32>())
                && sticker_id > 0
            {
                // U13: send category sticker via host until U13 merges.
                out.effects.push(Effect::Host(HostCall::SendCategorySticker {
                    op_id,
                    conv_id,
                    cate_id,
                    sticker_id,
                }));
                return;
            }

            out.effects.push(Effect::CompleteOp {
                op_id,
                result: OpResult::CardAction(CardActionOutcomeData::Unsupported(
                    CARD_DEFAULT_UNSUPPORTED.to_owned(),
                )),
                after_store: false,
            });
        }

        Command::SuggestedStickers { conv_id, msg_id } => {
            let Some(op_id) = op_id else {
                return;
            };
            let is_birthday = state
                .messages
                .windows
                .get(&conv_id)
                .and_then(|list| list.iter().find(|m| m.id == msg_id))
                .is_some_and(|m| matches!(&m.kind, Kind::Ecard(c) if c.style == ECardStyle::Birthday));
            let keyword = if is_birthday {
                "chúc mừng sinh nhật".to_owned()
            } else {
                "xin chào".to_owned()
            };
            out.effects
                .push(Effect::SuggestStickersApi { op_id, keyword });
        }

        Command::ContactCardState { uid } => {
            let Some(op_id) = op_id else {
                return;
            };
            let clean = strip_user_prefix(&uid);
            let my_uid = state
                .session
                .profile
                .as_ref()
                .map(|p| p.user_id.as_str())
                .unwrap_or("");
            let is_self = !my_uid.is_empty() && clean == my_uid;
            let is_friend = state.contacts.friends.iter().any(|f| f.id == clean)
                || state
                    .conversations
                    .identities
                    .friends
                    .iter()
                    .any(|f| f.id == clean);
            out.effects.push(Effect::CompleteOp {
                op_id,
                result: OpResult::ContactCardState(ContactCardStateResult { is_self, is_friend }),
                after_store: false,
            });
        }

        Command::ContactProfile { uid } => {
            let Some(op_id) = op_id else {
                return;
            };
            let clean = strip_user_prefix(&uid);
            if clean.is_empty() {
                out.effects.push(Effect::CompleteOp {
                    op_id,
                    result: OpResult::ContactProfile(None),
                    after_store: false,
                });
                return;
            }
            if let Some(p) = state.session.profile.as_ref()
                && clean == p.user_id
            {
                out.effects.push(Effect::CompleteOp {
                    op_id,
                    result: OpResult::ContactProfile(Some(ContactProfileResult {
                        uid: clean,
                        name: p.display_name.clone(),
                        zalo_name: String::new(),
                        avatar: p.avatar.as_deref().and_then(non_empty_url),
                        bio: String::new(),
                        is_self: true,
                        is_friend: false,
                        is_oa: false,
                    })),
                    after_store: false,
                });
                return;
            }
            if let Some(f) = state.contacts.friends.iter().find(|f| f.id == clean) {
                out.effects.push(Effect::CompleteOp {
                    op_id,
                    result: OpResult::ContactProfile(Some(ContactProfileResult {
                        uid: clean,
                        name: f.name.clone(),
                        zalo_name: f.zalo_name.clone(),
                        avatar: f.avatar.as_deref().and_then(non_empty_url),
                        bio: String::new(),
                        is_self: false,
                        is_friend: true,
                        is_oa: false,
                    })),
                    after_store: false,
                });
                return;
            }
            if let Some(f) = state
                .conversations
                .identities
                .friends
                .iter()
                .find(|f| f.id == clean)
            {
                out.effects.push(Effect::CompleteOp {
                    op_id,
                    result: OpResult::ContactProfile(Some(ContactProfileResult {
                        uid: clean,
                        name: f.name.clone(),
                        zalo_name: String::new(),
                        avatar: f.avatar.as_deref().and_then(non_empty_url),
                        bio: String::new(),
                        is_self: false,
                        is_friend: true,
                        is_oa: false,
                    })),
                    after_store: false,
                });
                return;
            }
            out.effects
                .push(Effect::FetchContactProfileApi { op_id, uid: clean });
        }

        Command::PrepareFriendRequest {
            uid,
            conv_id: _,
            via: _,
        } => {
            let Some(op_id) = op_id else {
                return;
            };
            let clean = strip_user_prefix(&uid);
            let my_uid = state
                .session
                .profile
                .as_ref()
                .map(|p| p.user_id.as_str())
                .unwrap_or("");
            let prep = if !my_uid.is_empty() && clean == my_uid {
                FriendRequestPrepResult {
                    state: "self".to_owned(),
                    default_message: String::new(),
                    max_message: 150,
                }
            } else if state.contacts.friends.iter().any(|f| f.id == clean)
                || state
                    .conversations
                    .identities
                    .friends
                    .iter()
                    .any(|f| f.id == clean)
            {
                FriendRequestPrepResult {
                    state: "friend".to_owned(),
                    default_message: String::new(),
                    max_message: 150,
                }
            } else if state.contacts.sent.iter().any(|r| r.id == clean) {
                FriendRequestPrepResult {
                    state: "requested".to_owned(),
                    default_message: String::new(),
                    max_message: 150,
                }
            } else if state.contacts.received.iter().any(|r| r.id == clean) {
                FriendRequestPrepResult {
                    state: "requesting".to_owned(),
                    default_message: String::new(),
                    max_message: 150,
                }
            } else {
                let my_name = state
                    .session
                    .profile
                    .as_ref()
                    .map(|p| p.display_name.as_str())
                    .unwrap_or("tôi");
                FriendRequestPrepResult {
                    state: "ready".to_owned(),
                    default_message: format!("Xin chào, mình là {my_name}."),
                    max_message: 150,
                }
            };
            out.effects.push(Effect::CompleteOp {
                op_id,
                result: OpResult::FriendRequestPrep(prep),
                after_store: false,
            });
        }

        Command::SubmitFriendRequest { uid, message } => {
            let Some(op_id) = op_id else {
                return;
            };
            out.effects
                .push(Effect::SendFriendRequestApi { op_id, uid, message });
        }

        Command::SaveAlias { uid, name } => {
            let Some(op_id) = op_id else {
                return;
            };
            let clean = strip_user_prefix(&uid);
            let trimmed = name.trim().to_owned();
            out.effects.push(Effect::SetAliasApi {
                op_id,
                uid: clean,
                trimmed_name: trimmed,
            });
        }

        Command::GroupInvitePreview { url } => {
            let Some(op_id) = op_id else {
                return;
            };
            out.effects
                .push(Effect::FetchGroupInvitePreviewApi { op_id, url });
        }

        Command::JoinGroup {
            url,
            preview_group_id,
        } => {
            let Some(op_id) = op_id else {
                return;
            };
            let fallback_group_id = preview_group_id
                .filter(|g| !g.is_empty())
                .or_else(|| state.notify.invite_preview_groups.get(&url).cloned());
            out.effects.push(Effect::JoinGroupByLinkApi {
                op_id,
                url,
                fallback_group_id,
            });
        }

        Command::ReminderWatch {
            conv_id,
            msg_id,
            signature,
        } => {
            let Some(op_id) = op_id else {
                return;
            };
            let event_id = resolve_reminder_id(state, &conv_id, &msg_id);
            if event_id.is_empty() {
                out.effects.push(Effect::CompleteOp {
                    op_id,
                    result: OpResult::ReminderSnapshot(None),
                    after_store: false,
                });
                return;
            }
            let key = format!("{conv_id}|{msg_id}");
            if !signature.is_empty()
                && let Some(cached) = state.notify.reminder_watch_cache.get(&key)
                && cached.sig == signature
            {
                state.notify.next_waiter_id = state.notify.next_waiter_id.wrapping_add(1);
                let waiter_id = state.notify.next_waiter_id;
                state
                    .notify
                    .reminder_waiters
                    .entry(key)
                    .or_default()
                    .push(ReminderWatchWaiter {
                        waiter_id,
                        op_id,
                        conv_id,
                        msg_id,
                        event_id,
                    });
                out.effects.push(Effect::StartReminderWatchTimer {
                    waiter_id,
                    delay: REMINDER_WATCH_TIMEOUT,
                });
                return;
            }
            out.effects.push(Effect::FetchReminderDetailApi {
                op_id,
                conv_id,
                msg_id,
                event_id,
            });
        }

        Command::RespondReminder {
            conv_id,
            msg_id,
            accept,
        } => {
            let Some(op_id) = op_id else {
                return;
            };
            let event_id = resolve_reminder_id(state, &conv_id, &msg_id);
            out.effects.push(Effect::RespondReminderApi {
                op_id,
                conv_id,
                msg_id,
                event_id,
                accept,
            });
        }

        Command::ReminderResponders { conv_id, msg_id } => {
            let Some(op_id) = op_id else {
                return;
            };
            let event_id = resolve_reminder_id(state, &conv_id, &msg_id);
            if event_id.is_empty() {
                out.effects.push(Effect::CompleteOp {
                    op_id,
                    result: OpResult::ReminderResponders(None),
                    after_store: false,
                });
                return;
            }
            out.effects
                .push(Effect::FetchReminderRespondersApi { op_id, event_id });
        }

        Command::ResetCardState => {
            state.notify.reminder_watch_cache.clear();
            let all_waiters: Vec<ReminderWatchWaiter> = state
                .notify
                .reminder_waiters
                .drain()
                .flat_map(|(_, list)| list)
                .collect();
            for w in all_waiters {
                out.effects
                    .push(Effect::CancelReminderWatchTimer { waiter_id: w.waiter_id });
                out.effects.push(Effect::FetchReminderDetailApi {
                    op_id: w.op_id,
                    conv_id: w.conv_id,
                    msg_id: w.msg_id,
                    event_id: w.event_id,
                });
            }
            complete_unit(op_id, out);
        }

        Command::FireReminderWatchTimer { waiter_id } => {
            let mut found: Option<ReminderWatchWaiter> = None;
            let mut empty_key: Option<String> = None;
            for (key, list) in &mut state.notify.reminder_waiters {
                if let Some(pos) = list.iter().position(|w| w.waiter_id == waiter_id) {
                    found = Some(list.remove(pos));
                    if list.is_empty() {
                        empty_key = Some(key.clone());
                    }
                    break;
                }
            }
            if let Some(k) = empty_key {
                state.notify.reminder_waiters.remove(&k);
            }
            if let Some(w) = found {
                out.effects.push(Effect::FetchReminderDetailApi {
                    op_id: w.op_id,
                    conv_id: w.conv_id,
                    msg_id: w.msg_id,
                    event_id: w.event_id,
                });
            }
            complete_unit(op_id, out);
        }

        Command::SyncPinReminderRefs { conv_id, refs } => {
            if refs.is_empty() {
                state.notify.pin_reminder_refs.remove(&conv_id);
            } else {
                state.notify.pin_reminder_refs.insert(conv_id, refs);
            }
            complete_unit(op_id, out);
        }

        _ => complete_unit(op_id, out),
    }
}

/// Applies bootstrap `getmute` entries to `state.notify.settings.mutes` and persists preferences.
pub(crate) fn apply_bootstrap_mutes(
    state: &mut CoreState,
    mutes: &[crate::messages::MuteEntry],
    out: &mut ReduceOutput,
) {
    for m in mutes {
        state.notify.settings.mutes.insert(
            m.conv_id.clone(),
            MuteInfo {
                start_time: m.start as f64,
                duration: m.duration as f64,
            },
        );
    }
    out.dirty.insert(DirtyKey::NotificationSettings);
    persist_notification_preferences(state, out);
}

/// Applies a remote `Route::Mute` WS/LP control frame to `state.notify.settings.mutes` and persists.
pub(crate) fn apply_remote_mute_control(
    state: &mut CoreState,
    conv_id: &str,
    set: bool,
    start: i64,
    duration: i64,
    out: &mut ReduceOutput,
) {
    if conv_id.is_empty() {
        return;
    }
    if set {
        state.notify.settings.mutes.insert(
            conv_id.to_owned(),
            MuteInfo {
                start_time: start as f64,
                duration: duration as f64,
            },
        );
    } else {
        state.notify.settings.mutes.remove(conv_id);
    }
    out.dirty.insert(DirtyKey::NotificationSettings);
    persist_notification_preferences(state, out);
}

pub(crate) fn hydrate_notification_prefs(
    state: &mut CoreState,
    enabled: bool,
    sound: bool,
    mutes: Option< std::collections::BTreeMap<String, MuteInfo> >,
    auth: Option<NotifAuthorization>,
    out: &mut ReduceOutput,
) {
    state.notify.settings.is_loaded = true;
    state.notify.settings.enabled = enabled;
    state.notify.settings.sound = sound;
    state.notify.settings.has_sound_setting = true;
    if let Some(m) = mutes {
        state.notify.settings.mutes = m;
    }
    if let Some(a) = auth {
        state.notify.settings.authorization = a;
    }
    out.dirty.insert(DirtyKey::NotificationSettings);
}
