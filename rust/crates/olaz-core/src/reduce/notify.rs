//! Reducer for notifications, mutes, incoming banner decisions, reminders, and card actions (U16).

use std::collections::{HashMap, HashSet};
use std::time::Duration;

use olaz_wire::ids::normalize_contact_uid;
use olaz_wire::lossless::string;
use olaz_wire::{
    ChatMessage, ECard, ECardStyle, Kind, UNKNOWN_NAME, is_group_id, sanitize_profile_uid,
    strip_user_prefix, web_link_sanitized,
};
use serde_json::{Map, Value};

use crate::changes::DirtyKey;
use crate::conversations::{
    CachedProfile, ConversationSummary, message_preview_label, preferred_profile_name,
};
use crate::effect::{Effect, HostCall, OpResult, StoreOp};
use crate::input::{Command, Input};
use crate::messages::FriendEntry;
use crate::notify::{
    CARD_DEFAULT_FAILED, CARD_DEFAULT_UNSUPPORTED, CardActionOutcomeData, ContactCardStateResult,
    ContactProfileResult, FriendRequestPrepResult, IncomingBatchInFlight, MUTE_ERROR_TOAST_TEXT,
    MuteInFlight, MuteInfo, NotifAuthorization, NotifyBannerPayload, ReminderSnapshotData,
    ReminderWatchWaiter, RespondReminderResult, SubmitFriendRequestResult,
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
            | Command::GroupInvitePreview { .. }
            | Command::JoinGroup { .. }
            | Command::ReminderWatch { .. }
            | Command::RespondReminder { .. }
            | Command::ReminderResponders { .. }
            | Command::ResetCardState
            | Command::FireReminderWatchTimer { .. }
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
    if let Some(list) = state.pins.lists.get(conv_id) {
        if let Some(found) = list.items.iter().find(|r| {
            r.kind == "reminder"
                && !r.ref_id.is_empty()
                && (r.msg_id == msg_id || r.cli_msg_id == msg_id)
        }) {
            return found.ref_id.clone();
        }
        return msg_id.to_owned();
    }
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
        out.effects.push(Effect::CancelReminderWatchTimer {
            waiter_id: w.waiter_id,
        });
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

struct IncomingBurstIndex<'a> {
    state: &'a CoreState,
    conv_by_id: HashMap<&'a str, &'a ConversationSummary>,
    friend_by_id: HashMap<&'a str, &'a FriendEntry>,
    gid_to_uid: HashMap<&'a str, &'a str>,
    clean_my_uid: String,
    sanitized_my_uid: String,
    my_avatar: &'a str,
}

impl<'a> IncomingBurstIndex<'a> {
    fn new(state: &'a CoreState) -> Self {
        let mut conv_by_id = HashMap::with_capacity(state.conversations.conversations.len());
        for c in &state.conversations.conversations {
            conv_by_id.entry(c.id.as_str()).or_insert(c);
        }
        let mut friend_by_id = HashMap::with_capacity(state.contacts.friends.len());
        for f in &state.contacts.friends {
            friend_by_id.entry(f.id.as_str()).or_insert(f);
        }
        let mut gid_to_uid = HashMap::with_capacity(state.contacts.friend_global_ids.len());
        for (uid, gid) in &state.contacts.friend_global_ids {
            gid_to_uid.entry(gid.as_str()).or_insert(uid.as_str());
        }
        let my_uid = state
            .session
            .profile
            .as_ref()
            .map_or("", |p| p.user_id.as_str());
        let my_avatar = state
            .session
            .profile
            .as_ref()
            .and_then(|p| p.avatar.as_deref())
            .unwrap_or("");
        let clean_my_uid = strip_user_prefix(my_uid);
        let sanitized_my_uid =
            sanitize_profile_uid(&clean_my_uid).unwrap_or_else(|| clean_my_uid.clone());
        Self {
            state,
            conv_by_id,
            friend_by_id,
            gid_to_uid,
            clean_my_uid,
            sanitized_my_uid,
            my_avatar,
        }
    }

    fn lookup_person(&self, clean: &str) -> Option<(String, String)> {
        if matches!(clean, "" | "0" | "-1" | "__legacy__" | "unknown") {
            return None;
        }
        let mut candidates = Vec::with_capacity(3);
        candidates.push(clean.to_owned());
        if let Some(sanitized) = sanitize_profile_uid(clean)
            && sanitized != clean
        {
            candidates.push(sanitized);
        }
        if let Some(mapped_uid) = candidates
            .iter()
            .find_map(|cand| self.gid_to_uid.get(cand.as_str()).copied())
            && !candidates.iter().any(|c| c == mapped_uid)
        {
            candidates.push(mapped_uid.to_owned());
        }

        if !self.clean_my_uid.is_empty()
            && candidates
                .iter()
                .any(|c| c == &self.clean_my_uid || c == &self.sanitized_my_uid)
        {
            return Some(("Bạn".to_owned(), self.my_avatar.to_owned()));
        }

        let identities = &self.state.contacts;
        for candidate in &candidates {
            let alias = identities.aliases.get(candidate).map(String::as_str);
            if let Some(f) = self.friend_by_id.get(candidate.as_str()) {
                let avt = f
                    .avatar
                    .as_deref()
                    .or_else(|| {
                        identities
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
                return Some((name, avt));
            }
            if let Some(p) = identities.cached_profiles.get(candidate) {
                let best = match alias {
                    Some(a) if !a.is_empty() => a,
                    _ => p.name.as_str(),
                };
                let valid_best = if best == UNKNOWN_NAME { "" } else { best };
                if !valid_best.is_empty() || !p.avatar.is_empty() {
                    return Some((valid_best.to_owned(), p.avatar.clone()));
                }
            }
            if let Some(a) = alias
                && !a.is_empty()
                && a != UNKNOWN_NAME
            {
                return Some((a.to_owned(), String::new()));
            }
        }

        for candidate in &candidates {
            if let Some(conv) = self.conv_by_id.get(candidate.as_str()) {
                let trimmed = conv.name.trim();
                let valid_name =
                    if !trimmed.is_empty() && trimmed != conv.id && trimmed != UNKNOWN_NAME {
                        trimmed
                    } else {
                        ""
                    };
                let avt = conv.avatar.as_deref().unwrap_or("");
                if !valid_name.is_empty() || !avt.is_empty() {
                    return Some((valid_name.to_owned(), avt.to_owned()));
                }
            }
        }
        None
    }
}

enum IncomingLookup<'a> {
    Direct {
        state: &'a CoreState,
        my_uid: &'a str,
        my_avatar: Option<&'a str>,
    },
    Indexed(IncomingBurstIndex<'a>),
}

impl<'a> IncomingLookup<'a> {
    fn new(state: &'a CoreState, remaining: usize) -> Self {
        if remaining > 2 {
            Self::Indexed(IncomingBurstIndex::new(state))
        } else {
            let my_uid = state
                .session
                .profile
                .as_ref()
                .map_or("", |p| p.user_id.as_str());
            let my_avatar = state
                .session
                .profile
                .as_ref()
                .and_then(|p| p.avatar.as_deref());
            Self::Direct {
                state,
                my_uid,
                my_avatar,
            }
        }
    }

    fn conversation(&self, conv_id: &str) -> Option<&'a ConversationSummary> {
        match self {
            Self::Direct { state, .. } => state
                .conversations
                .conversations
                .iter()
                .find(|c| c.id == conv_id),
            Self::Indexed(idx) => idx.conv_by_id.get(conv_id).copied(),
        }
    }

    fn lookup_person(&self, clean_uid: &str) -> Option<(String, String)> {
        match self {
            Self::Direct {
                state,
                my_uid,
                my_avatar,
            } => state.conversations.lookup_person_info(
                &state.contacts,
                clean_uid,
                my_uid,
                *my_avatar,
            ),
            Self::Indexed(idx) => idx.lookup_person(clean_uid),
        }
    }
}

fn step_incoming_batch(
    state: &mut CoreState,
    mut flight: IncomingBatchInFlight,
    mut already_fetched_current: bool,
    out: &mut ReduceOutput,
) {
    if !state.notify.settings.enabled || flight.cursor >= flight.messages.len() {
        complete_unit(flight.op_id, out);
        return;
    }

    let missing_uid: Option<String> = {
        let remaining = flight.messages.len().saturating_sub(flight.cursor);
        let lookup = IncomingLookup::new(state, remaining);
        let shows_preview = state.notify.settings.shows_preview;
        let silent = !state.notify.settings.sound;
        let mut fetch_uid = None;

        while flight.cursor < flight.messages.len() {
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
            let is_group = is_group_id(conv_id);
            let conv = lookup.conversation(conv_id);
            let clean_sender_id = strip_user_prefix(&msg.sender_id);
            let person = (!clean_sender_id.is_empty() && clean_sender_id != "0")
                .then(|| lookup.lookup_person(&clean_sender_id))
                .flatten();
            let local_avatar_url = resolve_local_avatar_url(msg, person.as_ref(), conv, is_group);

            if !already_fetched_current
                && local_avatar_url.is_none()
                && !clean_sender_id.is_empty()
                && clean_sender_id != "0"
            {
                fetch_uid = Some(clean_sender_id);
                break;
            }

            emit_banner_for_single_message(
                msg,
                is_group,
                conv,
                clean_sender_id,
                person.as_ref(),
                local_avatar_url,
                shows_preview,
                silent,
                out,
            );
            flight.cursor += 1;
            already_fetched_current = false;
        }
        fetch_uid
    };

    if let Some(uid) = missing_uid {
        state.notify.next_incoming_id = state.notify.next_incoming_id.wrapping_add(1);
        let batch_id = state.notify.next_incoming_id;
        state.notify.incoming_in_flight.insert(batch_id, flight);
        out.effects.push(Effect::FetchNotifyProfilesApi {
            batch_id,
            uids: vec![uid],
        });
        return;
    }

    complete_unit(flight.op_id, out);
}

fn resolve_local_avatar_url(
    msg: &ChatMessage,
    person: Option<&(String, String)>,
    conv: Option<&ConversationSummary>,
    is_group: bool,
) -> Option<String> {
    if let Some(avt) = msg.sender_avatar.as_deref()
        && let Some(u) = non_empty_url(avt)
    {
        return Some(u);
    }
    if let Some((_, avatar)) = person
        && let Some(u) = non_empty_url(avatar)
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

#[expect(
    clippy::too_many_arguments,
    reason = "pre-resolved incoming banner fields avoid redundant lookups across a burst"
)]
fn emit_banner_for_single_message(
    msg: &ChatMessage,
    is_group: bool,
    conv: Option<&ConversationSummary>,
    clean_sender_id: String,
    person: Option<&(String, String)>,
    resolved_avatar_url: Option<String>,
    shows_preview: bool,
    silent: bool,
    out: &mut ReduceOutput,
) {
    let conv_id = &msg.conversation_id;

    let title = if let Some(c) = conv
        && !c.name.is_empty()
        && c.name != *conv_id
    {
        c.name.clone()
    } else if let Some((p_name, _)) = person
        && !p_name.is_empty()
        && p_name != &clean_sender_id
    {
        p_name.clone()
    } else if msg.sender_name.is_empty() {
        conv_id.clone()
    } else {
        msg.sender_name.clone()
    };

    let sender_name = if !is_group {
        title.clone()
    } else if let Some((p_name, _)) = person
        && !p_name.is_empty()
        && p_name != &clean_sender_id
        && p_name != UNKNOWN_NAME
    {
        p_name.clone()
    } else {
        msg.sender_name.clone()
    };

    let raw_preview = message_preview_label(msg);
    let body = crate::notify::policy::body(&raw_preview, shows_preview);

    out.effects
        .push(Effect::Host(HostCall::NotifyBanner(NotifyBannerPayload {
            title,
            body,
            conv_id: conv_id.clone(),
            sender_id: clean_sender_id,
            sender_name,
            is_group,
            avatar_url: resolved_avatar_url,
            silent,
        })));
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
                    conv_id: Some(flight.conv_id),
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
                let Some(row) = val.as_object() else {
                    continue;
                };
                let clean = strip_user_prefix(&uid);
                let name = preferred_profile_name(row);
                let avatar = string(row.get("avatar").or_else(|| row.get("avt")));
                if !clean.is_empty() && (!name.is_empty() || !avatar.is_empty()) {
                    state
                        .contacts
                        .cached_profiles
                        .insert(clean, CachedProfile { name, avatar });
                    updated_any = true;
                }
            }
            if updated_any {
                out.dirty.insert(DirtyKey::CachedProfiles);
                if let Ok(bytes) = serde_json::to_vec(&state.contacts.cached_profiles) {
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
            let (mapped, should_refresh) =
                map_join_group_outcome(result.as_ref(), fallback_group_id.as_deref());
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
            let snap = resp
                .and_then(|r| normalize_reminder_in_state(state, &r, &conv_id, &event_id, &msg_id));
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
                    state
                        .notify
                        .reminder_watch_cache
                        .insert(key.clone(), u.clone());
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
                let Some(row) = val.as_object() else {
                    continue;
                };
                let clean = strip_user_prefix(&uid);
                let name = preferred_profile_name(row);
                let avatar = string(row.get("avatar").or_else(|| row.get("avt")));
                if !clean.is_empty() && (!name.is_empty() || !avatar.is_empty()) {
                    state
                        .contacts
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

fn handle_command(state: &mut CoreState, cmd: Command, op_id: Option<u64>, out: &mut ReduceOutput) {
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
                && let (Ok(cate_id), Ok(sticker_id)) =
                    (parts[0].parse::<i32>(), parts[1].parse::<i32>())
                && sticker_id > 0
            {
                // U13: send category sticker via host until U13 merges.
                out.effects
                    .push(Effect::Host(HostCall::SendCategorySticker {
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
                .is_some_and(
                    |m| matches!(&m.kind, Kind::Ecard(c) if c.style == ECardStyle::Birthday),
                );
            let keyword = if is_birthday {
                "chúc mừng sinh nhật".to_owned()
            } else {
                "xin chào".to_owned()
            };
            out.effects
                .push(Effect::CardSuggestStickersApi { op_id, keyword });
        }

        Command::ContactCardState { uid } => {
            let Some(op_id) = op_id else {
                return;
            };
            let clean = normalize_contact_uid(&uid);
            let my_uid = normalize_contact_uid(
                state
                    .session
                    .profile
                    .as_ref()
                    .map(|p| p.user_id.as_str())
                    .unwrap_or(""),
            );
            let is_self = !clean.is_empty() && clean == my_uid;
            let is_friend = state.contacts.friends.iter().any(|f| f.id == clean);
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
            let clean = normalize_contact_uid(&uid);
            if clean.is_empty() {
                out.effects.push(Effect::CompleteOp {
                    op_id,
                    result: OpResult::ContactProfile(None),
                    after_store: false,
                });
                return;
            }
            if let Some(p) = state.session.profile.as_ref()
                && clean == normalize_contact_uid(&p.user_id)
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
            let clean = normalize_contact_uid(&uid);
            let my_uid = normalize_contact_uid(
                state
                    .session
                    .profile
                    .as_ref()
                    .map(|p| p.user_id.as_str())
                    .unwrap_or(""),
            );
            let prep = if !clean.is_empty() && clean == my_uid {
                FriendRequestPrepResult {
                    state: "self".to_owned(),
                    default_message: String::new(),
                    max_message: 150,
                }
            } else if state.contacts.friends.iter().any(|f| f.id == clean) {
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
            out.effects.push(Effect::SubmitFriendRequestApi {
                op_id,
                uid: normalize_contact_uid(&uid),
                message,
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
                out.effects.push(Effect::CancelReminderWatchTimer {
                    waiter_id: w.waiter_id,
                });
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
    mutes: Option<std::collections::BTreeMap<String, MuteInfo>>,
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::conversations::ConversationSummary;
    use olaz_wire::{MessageMenu, Status};

    fn sample_msg(
        id: &str,
        conv_id: &str,
        sender_id: &str,
        text: &str,
        avt: Option<&str>,
    ) -> ChatMessage {
        ChatMessage {
            id: id.to_owned(),
            conversation_id: conv_id.to_owned(),
            sender_id: sender_id.to_owned(),
            sender_name: "Fallback Sender".to_owned(),
            sender_avatar: avt.map(str::to_owned),
            is_mine: false,
            kind: Kind::Text,
            text: text.to_owned(),
            date_ms: 1_700_000_000_000,
            status: Status::Sent,
            quote: None,
            reactions: Vec::new(),
            is_e2ee: false,
            mentions: Vec::new(),
            text_styles: Vec::new(),
            fallback_urls: Vec::new(),
            ttl_ms: 0,
            urgency: 0,
            card_buttons: Vec::new(),
            suggests_stickers: false,
            menu: MessageMenu::default(),
            client_id: String::new(),
        }
    }

    #[test]
    fn fire_reminder_watch_timer_command_is_dispatched_and_wakes_waiter() {
        let cmd = Command::FireReminderWatchTimer { waiter_id: 7 };
        assert!(is_notify_command(&cmd));

        let mut state = CoreState::default();
        state.notify.reminder_waiters.insert(
            "g900|m1".to_owned(),
            vec![ReminderWatchWaiter {
                waiter_id: 7,
                op_id: 42,
                conv_id: "g900".to_owned(),
                msg_id: "m1".to_owned(),
                event_id: "rem-1".to_owned(),
            }],
        );
        let mut out = ReduceOutput::default();
        reduce_notify(&mut state, Input::Command(cmd), &mut out);

        assert!(state.notify.reminder_waiters.is_empty());
        assert!(out.effects.iter().any(|e| matches!(
            e,
            Effect::FetchReminderDetailApi {
                op_id: 42,
                conv_id,
                msg_id,
                event_id,
            } if conv_id == "g900" && msg_id == "m1" && event_id == "rem-1"
        )));
    }

    #[test]
    fn mute_failure_preserves_state_skips_store_and_shows_error_card() {
        let mut state = CoreState::default();
        let mut out = ReduceOutput::default();
        reduce_notify(
            &mut state,
            Input::OpRequest {
                op_id: 1,
                cmd: Command::MuteConversation {
                    conv_id: "3001".to_owned(),
                    duration_secs: 3600,
                    now_ms: 1_700_000_000_000,
                },
            },
            &mut out,
        );
        assert!(state.notify.settings.mutes.is_empty());
        let Some(req_id) = out.effects.iter().find_map(|e| match e {
            Effect::SetMuteApi { req_id, .. } => Some(*req_id),
            _ => None,
        }) else {
            panic!("SetMuteApi effect missing");
        };

        let mut out2 = ReduceOutput::default();
        reduce_notify(
            &mut state,
            Input::SetMuteApiDone { req_id, ok: false },
            &mut out2,
        );
        assert!(state.notify.settings.mutes.is_empty());
        assert!(!out2.effects.iter().any(|e| matches!(
            e,
            Effect::Store(StoreOp::SetPreferenceData { .. } | StoreOp::SetPreferenceBool { .. })
        )));
        assert!(out2.effects.iter().any(|e| matches!(
            e,
            Effect::Host(HostCall::ShowCard { conv_id, text })
            if conv_id.as_deref() == Some("3001") && text == MUTE_ERROR_TOAST_TEXT
        )));
    }

    #[test]
    fn incoming_burst_indexed_path_matches_direct_lookup_semantics() {
        let mut state = CoreState::default();
        state.notify.settings.enabled = true;
        state.notify.settings.sound = true;
        state.notify.settings.shows_preview = true;
        state.notify.settings.mutes.insert(
            "300001".to_owned(),
            MuteInfo {
                start_time: 1_700_000_000.0,
                duration: 3600.0,
            },
        );
        for i in 0..20 {
            state.conversations.conversations.push(ConversationSummary {
                id: format!("300{:03}", i),
                is_group: false,
                name: format!("Peer {i}"),
                avatar: Some(format!("https://cdn.example/p{i}.jpg")),
                pinned: false,
                members: 0,
                unread: 0,
                preview: None,
            });
            state.contacts.friends.push(FriendEntry {
                id: format!("300{:03}", i),
                name: format!("Friend {i}"),
                zalo_name: String::new(),
                avatar: Some(format!("https://cdn.example/f{i}.jpg")),
                last_active_ms: None,
                online: false,
                section: "F".to_owned(),
                sort_key: format!("friend {i}"),
            });
        }
        state
            .contacts
            .aliases
            .insert("300002".to_owned(), "Alias Two".to_owned());
        state.conversations.conversations.push(ConversationSummary {
            id: "g90001".to_owned(),
            is_group: true,
            name: "Group Alpha".to_owned(),
            avatar: Some("https://cdn.example/g1.jpg".to_owned()),
            pinned: false,
            members: 10,
            unread: 0,
            preview: None,
        });

        let mut msgs = Vec::with_capacity(200);
        for i in 0..200 {
            let conv_id = if i % 5 == 0 {
                "g90001".to_owned()
            } else {
                format!("300{:03}", i % 20)
            };
            let sender_id = format!("300{:03}", i % 20);
            msgs.push(sample_msg(
                &format!("m{i}"),
                &conv_id,
                &sender_id,
                &format!("Hello {i}"),
                None,
            ));
        }

        let mut out = ReduceOutput::default();
        start_notify_incoming_batch(&mut state, msgs, 1_700_000_100_000, Some(99), &mut out);

        let banners: Vec<&NotifyBannerPayload> = out
            .effects
            .iter()
            .filter_map(|e| match e {
                Effect::Host(HostCall::NotifyBanner(b)) => Some(b),
                _ => None,
            })
            .collect();
        // 10 of 200 messages target muted conv "300001" (i % 20 == 1, none have i % 5 == 0).
        assert_eq!(banners.len(), 190);
        // Group message from aliased friend 300002 uses alias for sender_name and group name for title.
        let group_from_two = banners
            .iter()
            .find(|b| b.conv_id == "g90001" && b.sender_id == "300002");
        assert!(group_from_two.is_none()); // i % 5 == 0 => i % 20 in {0, 5, 10, 15}
        let Some(group_from_five) = banners
            .iter()
            .find(|b| b.conv_id == "g90001" && b.sender_id == "300005")
        else {
            panic!("group banner from 300005 missing");
        };
        assert_eq!(group_from_five.title, "Group Alpha");
        assert_eq!(group_from_five.sender_name, "Friend 5");
        assert!(!group_from_five.silent);
    }
}
