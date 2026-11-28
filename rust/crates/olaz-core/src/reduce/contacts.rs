//! Pure U9 contacts, friend requests, phone lookup, blocked-users, and alias reducer.
//!
//! No I/O, no clock, and no randomness live here (D9).

use std::collections::BTreeSet;

use olaz_api::BlockedUserEntry;
use olaz_wire::{lossless, normalize_contact_uid, sanitize_profile_uid};
use serde_json::{Map, Value};

use crate::changes::DirtyKey;
use crate::effect::{Effect, HostCall, OpResult, StoreOp};
use crate::input::{Command, Input, SessionFailure};
use crate::messages::{
    BlockedUserState, ContactNotice, ContactSearchState, ContactSearchStatus, ContactsState,
    FoundUserEntry, FriendEntry, FriendRequestEntry, GroupEntry, SaveAliasOutcome,
    apply_fetched_contacts, fold_contact_str, is_valid_url_str,
};
use crate::reduce::ReduceOutput;
use crate::reduce::conversations;
use crate::state::CoreState;
use crate::state::{CoreFailKind, FailReason};
use olaz_wire::UNKNOWN_NAME;

fn complete_op(out: &mut ReduceOutput, op_id: Option<u64>, result: OpResult, after_store: bool) {
    if let Some(op_id) = op_id {
        out.effects.push(Effect::CompleteOp {
            op_id,
            result,
            after_store,
        });
    }
}

fn bump_contacts_notice(contacts: &mut ContactsState, ok: bool, text: &str) {
    let next_seq = contacts.notice.as_ref().map_or(1, |n| n.seq + 1);
    contacts.notice = Some(ContactNotice {
        seq: next_seq,
        ok,
        text: text.to_owned(),
    });
}

fn candidate_uids_equal(a: &str, b: &str) -> bool {
    let ca = normalize_contact_uid(a);
    let cb = normalize_contact_uid(b);
    if ca.is_empty() || cb.is_empty() {
        return false;
    }
    if ca == cb {
        return true;
    }
    let sa = sanitize_profile_uid(&ca).unwrap_or_else(|| ca.clone());
    let sb = sanitize_profile_uid(&cb).unwrap_or_else(|| cb.clone());
    sa == sb
}

fn format_session_failure_localized(failure: &SessionFailure) -> String {
    match failure {
        SessionFailure::Cancelled => "Đã hủy.".to_owned(),
        SessionFailure::QrTimeout => "Mã QR đã hết hạn.".to_owned(),
        SessionFailure::Failed(FailReason::Text(msg)) => msg.clone(),
        SessionFailure::Failed(FailReason::Core(kind)) => match kind {
            CoreFailKind::NotAuthenticated => "Chưa đăng nhập Zalo.".to_owned(),
            CoreFailKind::InvalidJson => "Phản hồi máy chủ không đúng định dạng.".to_owned(),
            CoreFailKind::Http { status } => format!("Lỗi máy chủ HTTP {status}."),
            CoreFailKind::Session { code, message, url } => olaz_net::ZaloSessionError {
                code: *code,
                message: message.clone(),
                url: url.clone(),
            }
            .to_string(),
            CoreFailKind::Network(olaz_net::NetworkErrorKind::Timeout) => {
                "The operation couldn\u{2019}t be completed. (NSURLErrorDomain error -1001.)"
                    .to_owned()
            }
            CoreFailKind::Network(olaz_net::NetworkErrorKind::ConnectionLost) => {
                "The operation couldn\u{2019}t be completed. (NSURLErrorDomain error -1005.)"
                    .to_owned()
            }
            CoreFailKind::Network(olaz_net::NetworkErrorKind::Other) => {
                "The operation couldn\u{2019}t be completed. (NSURLErrorDomain error -1004.)"
                    .to_owned()
            }
            CoreFailKind::Crypto(msg) => format!("SQLite step failed: {msg}"),
        },
    }
}

fn start_contacts_sync(state: &mut CoreState, op_id: Option<u64>, out: &mut ReduceOutput) {
    state.contacts.sync_in_flight = state.contacts.sync_in_flight.saturating_add(1);
    if !state.contacts.loading_requests {
        state.contacts.loading_requests = true;
        out.dirty.insert(DirtyKey::Contacts);
    }
    out.effects.push(Effect::FetchContactsSyncApi { op_id });
}

/// Runs post-contacts-sync follow-ups matching `ZaloEngine.performContactsSync`:
/// `ensureKnownContactsInConversations`, `rebuildConversationFlags`, `rebuildConversationExtras`,
/// `resolveMissingNames` (emitted directly so known contacts resolve missing names), and
/// `refreshReactionNames`.
pub(crate) fn apply_post_contacts_sync_followups(state: &mut CoreState, out: &mut ReduceOutput) {
    let self_conv_id = state.session.self_conversation_id.clone();
    if state
        .conversations
        .ensure_known_contacts(&state.contacts, self_conv_id.as_deref())
    {
        out.dirty.insert(DirtyKey::Conversations);
    }
    conversations::rebuild_flags_and_extras(state, out);

    // Refresh reaction display names across all loaded message windows.
    let snap = state.identity_snapshot();
    let (react_rows, react_ops) = state.messages.refresh_reaction_names(None, &snap);
    if !react_ops.is_empty() {
        out.dirty.insert(DirtyKey::Messages);
    }
    if !react_rows.is_empty() {
        out.effects.push(Effect::Store(StoreOp::SaveMessages {
            rows: react_rows,
            preserve_existing_reactions: true,
        }));
    }
}

fn parse_adapter_friend(json: &Map<String, Value>) -> Option<FriendEntry> {
    let id = json.get("id").and_then(Value::as_str).unwrap_or("");
    if id.is_empty() {
        return None;
    }
    let raw_name = json.get("name").and_then(Value::as_str).unwrap_or("");
    let zalo_name = json
        .get("zaloName")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_owned();
    let name = if raw_name.is_empty() {
        zalo_name.clone()
    } else {
        raw_name.to_owned()
    };
    let sort_key = fold_contact_str(&name).trim().to_owned();
    let first = sort_key
        .chars()
        .next()
        .map(|c| c.to_ascii_uppercase())
        .filter(char::is_ascii_uppercase);
    let section = first.map_or_else(|| "#".to_owned(), |c| c.to_string());
    let last_active_ms = lossless::int64(json.get("lastActive")).filter(|&v| v > 0);
    let avt = json.get("avatar").and_then(Value::as_str).unwrap_or("");
    let avatar = is_valid_url_str(avt).then(|| avt.to_owned());
    let online = json.get("online").and_then(Value::as_bool).unwrap_or(false);
    Some(FriendEntry {
        id: id.to_owned(),
        name,
        zalo_name,
        avatar,
        last_active_ms,
        online,
        section,
        sort_key,
    })
}

fn parse_adapter_group(json: &Map<String, Value>) -> Option<GroupEntry> {
    let id = json.get("id").and_then(Value::as_str).unwrap_or("");
    if id.is_empty() {
        return None;
    }
    let name = json
        .get("name")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_owned();
    let avt = json.get("avatar").and_then(Value::as_str).unwrap_or("");
    let avatar = is_valid_url_str(avt).then(|| avt.to_owned());
    let members = lossless::int64(json.get("members")).unwrap_or(0);
    let sort_key = fold_contact_str(&name);
    Some(GroupEntry {
        id: id.to_owned(),
        name,
        avatar,
        members,
        sort_key,
    })
}

fn parse_adapter_request(json: &Map<String, Value>) -> Option<FriendRequestEntry> {
    let id = json.get("id").and_then(Value::as_str).unwrap_or("");
    if id.is_empty() {
        return None;
    }
    let name = json
        .get("name")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_owned();
    let avt = json.get("avatar").and_then(Value::as_str).unwrap_or("");
    let avatar = is_valid_url_str(avt).then(|| avt.to_owned());
    let message = json
        .get("message")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_owned();
    let time_ms = lossless::int64(json.get("time")).filter(|&v| v > 0);
    Some(FriendRequestEntry {
        id: id.to_owned(),
        name,
        avatar,
        message,
        time_ms,
    })
}

fn parse_adapter_search(json: &Map<String, Value>) -> ContactSearchState {
    let status =
        ContactSearchStatus::parse(json.get("status").and_then(Value::as_str).unwrap_or(""));
    let error = json.get("error").and_then(Value::as_str).map(str::to_owned);
    let user = json.get("user").and_then(Value::as_object).and_then(|u| {
        let id = u.get("id").and_then(Value::as_str).unwrap_or("");
        if id.is_empty() {
            return None;
        }
        let avt = u.get("avatar").and_then(Value::as_str).unwrap_or("");
        Some(FoundUserEntry {
            id: id.to_owned(),
            name: u
                .get("name")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_owned(),
            zalo_name: u
                .get("zaloName")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_owned(),
            avatar: is_valid_url_str(avt).then(|| avt.to_owned()),
            bio: u
                .get("bio")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_owned(),
            is_friend: u.get("isFriend").and_then(Value::as_bool).unwrap_or(false),
            is_self: u.get("isSelf").and_then(Value::as_bool).unwrap_or(false),
            requested: u.get("requested").and_then(Value::as_bool).unwrap_or(false),
            requesting: u
                .get("requesting")
                .and_then(Value::as_bool)
                .unwrap_or(false),
            default_message: u
                .get("defaultMessage")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_owned(),
            max_message: lossless::int64(u.get("maxMessage")).unwrap_or(150),
        })
    });
    ContactSearchState {
        status,
        error,
        user,
    }
}

/// Applies `ZaloEngine.handleContacts(state:)` adapter state payload.
pub fn apply_contacts_adapter_state(contacts: &mut ContactsState, state_json: &str) -> bool {
    let Some(root) = olaz_json::parse_object_str(state_json) else {
        return false;
    };
    let Some(json) = root.get("contacts").and_then(Value::as_object) else {
        return false;
    };
    let mut next = contacts.clone();
    if let Some(Value::Array(rows)) = json.get("friends") {
        next.friends = rows
            .iter()
            .filter_map(Value::as_object)
            .filter_map(parse_adapter_friend)
            .collect();
        next.friends_loaded = true;
    }
    if let Some(Value::Array(rows)) = json.get("groups") {
        next.groups = rows
            .iter()
            .filter_map(Value::as_object)
            .filter_map(parse_adapter_group)
            .collect();
        next.groups_loaded = true;
    }
    if let Some(Value::Array(rows)) = json.get("received") {
        next.received = rows
            .iter()
            .filter_map(Value::as_object)
            .filter_map(parse_adapter_request)
            .collect();
    }
    if let Some(Value::Array(rows)) = json.get("sent") {
        next.sent = rows
            .iter()
            .filter_map(Value::as_object)
            .filter_map(parse_adapter_request)
            .collect();
    }
    if let Some(count) = lossless::int64(json.get("pendingRequestCount")) {
        next.pending_request_count = usize::try_from(count.max(0)).unwrap_or(0);
    }
    if let Some(flag) = json
        .get("loading")
        .and_then(Value::as_object)
        .and_then(|l| l.get("requests"))
        .and_then(Value::as_bool)
    {
        next.loading_requests = flag;
    }
    if let Some(search_obj) = json.get("search").and_then(Value::as_object) {
        next.search = parse_adapter_search(search_obj);
    }
    if let Some(notice_obj) = json.get("notice").and_then(Value::as_object)
        && let Some(seq) = lossless::int64(notice_obj.get("seq"))
    {
        next.notice = Some(ContactNotice {
            seq,
            ok: notice_obj
                .get("ok")
                .and_then(Value::as_bool)
                .unwrap_or(false),
            text: notice_obj
                .get("text")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_owned(),
        });
    }
    if &next != contacts {
        *contacts = next;
        true
    } else {
        false
    }
}

fn serialize_aliases_json(aliases: &std::collections::BTreeMap<String, String>) -> Vec<u8> {
    serde_json::to_vec(aliases).unwrap_or_else(|_| b"{}".to_vec())
}

/// Refreshes any live conversation row or message reaction names affected by an alias change (Fix #3).
fn refresh_after_alias_change(state: &mut CoreState, uid: &str, out: &mut ReduceOutput) {
    let snap = state.identity_snapshot();
    let self_conv_id = state.session.self_conversation_id.clone();

    let mut conv_changed = false;
    for conv in &mut state.conversations.conversations {
        if conv.is_group || self_conv_id.as_deref() == Some(conv.id.as_str()) {
            continue;
        }
        if candidate_uids_equal(&conv.id, uid)
            && let Some(hit) = snap.lookup_person(&conv.id)
            && !hit.name.is_empty()
            && hit.name != UNKNOWN_NAME
            && conv.name != hit.name
        {
            conv.name = hit.name;
            conv_changed = true;
        }
    }
    if conv_changed {
        out.dirty.insert(DirtyKey::Conversations);
        conversations::rebuild_flags_and_extras(state, out);
    }

    let (react_rows, react_ops) = state.messages.refresh_reaction_names(None, &snap);
    if !react_ops.is_empty() {
        out.dirty.insert(DirtyKey::Messages);
    }
    if !react_rows.is_empty() {
        out.effects.push(Effect::Store(StoreOp::SaveMessages {
            rows: react_rows,
            preserve_existing_reactions: true,
        }));
    }
}

pub(crate) fn reduce_contacts_command(
    state: &mut CoreState,
    cmd: Command,
    op_id: Option<u64>,
    out: &mut ReduceOutput,
) {
    match cmd {
        Command::RefreshContacts | Command::PerformContactsSync => {
            start_contacts_sync(state, op_id, out);
        }

        Command::AcceptFriendRequest { uid } => {
            out.effects.push(Effect::AcceptFriendRequestApi {
                uid: normalize_contact_uid(&uid),
                op_id,
            });
        }

        Command::DeclineFriendRequest { uid } => {
            out.effects.push(Effect::DeclineFriendRequestApi {
                uid: normalize_contact_uid(&uid),
                op_id,
            });
        }

        Command::CancelFriendRequest { uid } => {
            out.effects.push(Effect::CancelFriendRequestApi {
                uid: normalize_contact_uid(&uid),
                op_id,
            });
        }

        Command::SendFriendRequest { uid, message } => {
            out.effects.push(Effect::SendFriendRequestApi {
                uid: normalize_contact_uid(&uid),
                message,
                op_id,
            });
        }

        Command::FindFriendByPhone { phone } => {
            let trimmed = phone.trim().to_owned();
            if trimmed.is_empty() {
                complete_op(out, op_id, OpResult::Unit, false);
                return;
            }
            state.contacts.search_gen = state.contacts.search_gen.saturating_add(1);
            let search_gen = state.contacts.search_gen;
            state.contacts.search = ContactSearchState {
                status: ContactSearchStatus::Searching,
                error: None,
                user: None,
            };
            out.dirty.insert(DirtyKey::Contacts);
            out.effects.push(Effect::FindFriendByPhoneApi {
                phone: trimmed,
                search_gen,
                op_id,
            });
        }

        Command::ResetFriendSearch => {
            state.contacts.search_gen = state.contacts.search_gen.saturating_add(1);
            if state.contacts.search != ContactSearchState::default() {
                state.contacts.search = ContactSearchState::default();
                out.dirty.insert(DirtyKey::Contacts);
            }
            complete_op(out, op_id, OpResult::Unit, false);
        }

        Command::HandleContactsState { state_json } => {
            if apply_contacts_adapter_state(&mut state.contacts, &state_json) {
                out.dirty.insert(DirtyKey::Contacts);
            }
            complete_op(out, op_id, OpResult::Unit, false);
        }

        Command::LoadBlockedUsers => {
            out.effects.push(Effect::LoadBlockedUsersApi { op_id });
        }

        Command::SetBlocked { uid, blocked, name } => {
            let clean = normalize_contact_uid(&uid);
            if clean.is_empty() {
                complete_op(out, op_id, OpResult::Unit, false);
                return;
            }
            let open_conv_id = state.conversations.open_conversation_id.clone();
            out.effects.push(Effect::SetBlockedApi {
                uid: clean,
                blocked,
                name,
                open_conv_id,
                op_id,
            });
        }

        Command::SaveAlias { uid, name } => {
            let clean = normalize_contact_uid(&uid);
            let trimmed = name.trim().to_owned();
            out.effects.push(Effect::SaveAliasApi {
                uid: clean,
                trimmed_alias: trimmed,
                op_id,
            });
        }

        Command::SeedBlockedUsers(users) => {
            state.contacts.blocked_users = users;
            complete_op(out, op_id, OpResult::Unit, false);
        }

        _ => unreachable!("non-contacts command routed to reduce_contacts_command"),
    }
}

pub(crate) fn reduce_contacts_input(state: &mut CoreState, input: Input, out: &mut ReduceOutput) {
    match input {
        Input::ContactsSyncDone {
            friends_rows,
            groups_dict,
            sent_rows,
            received_rows,
            op_id,
        } => {
            state.contacts.sync_in_flight = state.contacts.sync_in_flight.saturating_sub(1);
            if state.contacts.sync_in_flight == 0 {
                state.contacts.loading_requests = false;
            }
            apply_fetched_contacts(
                &mut state.contacts,
                friends_rows,
                groups_dict,
                sent_rows,
                received_rows,
            );
            out.dirty.insert(DirtyKey::Contacts);
            apply_post_contacts_sync_followups(state, out);
            complete_op(out, op_id, OpResult::Unit, true);
        }

        Input::FriendRequestAccepted { uid: _, ok, op_id } => {
            if ok {
                bump_contacts_notice(&mut state.contacts, true, "Đã chấp nhận lời mời kết bạn.");
                out.dirty.insert(DirtyKey::Contacts);
                start_contacts_sync(state, op_id, out);
            } else {
                bump_contacts_notice(&mut state.contacts, false, "Không thể chấp nhận lời mời.");
                out.dirty.insert(DirtyKey::Contacts);
                complete_op(out, op_id, OpResult::Unit, false);
            }
        }

        Input::FriendRequestDeclined { uid, ok, op_id } => {
            if ok {
                state
                    .contacts
                    .received
                    .retain(|r| !candidate_uids_equal(&r.id, &uid));
                state.contacts.pending_request_count = state.contacts.received.len();
                bump_contacts_notice(&mut state.contacts, true, "Đã từ chối lời mời kết bạn.");
            } else {
                bump_contacts_notice(&mut state.contacts, false, "Không thể từ chối lời mời.");
            }
            out.dirty.insert(DirtyKey::Contacts);
            complete_op(out, op_id, OpResult::Unit, false);
        }

        Input::FriendRequestCancelled { uid, ok, op_id } => {
            if ok {
                state
                    .contacts
                    .sent
                    .retain(|r| !candidate_uids_equal(&r.id, &uid));
                bump_contacts_notice(&mut state.contacts, true, "Đã thu hồi lời mời kết bạn.");
            } else {
                bump_contacts_notice(&mut state.contacts, false, "Không thể thu hồi lời mời.");
            }
            out.dirty.insert(DirtyKey::Contacts);
            complete_op(out, op_id, OpResult::Unit, false);
        }

        Input::FriendRequestSent { uid: _, ok, op_id } => {
            if ok {
                bump_contacts_notice(&mut state.contacts, true, "Đã gửi lời mời kết bạn.");
                out.dirty.insert(DirtyKey::Contacts);
                start_contacts_sync(state, op_id, out);
            } else {
                bump_contacts_notice(&mut state.contacts, false, "Không thể gửi lời mời kết bạn.");
                out.dirty.insert(DirtyKey::Contacts);
                complete_op(out, op_id, OpResult::Unit, false);
            }
        }

        Input::FriendFoundByPhone {
            search_gen,
            result,
            op_id,
        } => {
            if search_gen != state.contacts.search_gen {
                complete_op(out, op_id, OpResult::Unit, false);
                return;
            }
            match result {
                Ok(resp) => {
                    let d = resp.get("data").and_then(Value::as_object).unwrap_or(&resp);
                    let uid = normalize_contact_uid(&lossless::string(
                        d.get("uid").or_else(|| d.get("userId")),
                    ));
                    if uid.is_empty() {
                        state.contacts.search = ContactSearchState {
                            status: ContactSearchStatus::Error,
                            error: Some(
                                "Không tìm thấy người dùng với số điện thoại này.".to_owned(),
                            ),
                            user: None,
                        };
                    } else {
                        // Item 6.1 + 6.3: normalize UID and guard `is_friend` on `friends_loaded`.
                        let my_uid = state
                            .session
                            .profile
                            .as_ref()
                            .map_or("", |p| p.user_id.as_str());
                        let is_self = !my_uid.is_empty() && candidate_uids_equal(&uid, my_uid);
                        let is_friend = state.contacts.friends_loaded
                            && state
                                .contacts
                                .friends
                                .iter()
                                .any(|f| candidate_uids_equal(&f.id, &uid));
                        let requested = state
                            .contacts
                            .sent
                            .iter()
                            .any(|r| candidate_uids_equal(&r.id, &uid));
                        let requesting = state
                            .contacts
                            .received
                            .iter()
                            .any(|r| candidate_uids_equal(&r.id, &uid));
                        let my_name = state
                            .session
                            .profile
                            .as_ref()
                            .map_or("tôi", |p| p.display_name.as_str());
                        let name = lossless::string(
                            d.get("display_name")
                                .or_else(|| d.get("displayName"))
                                .or_else(|| d.get("zalo_name")),
                        );
                        let zalo_name =
                            lossless::string(d.get("zalo_name").or_else(|| d.get("zaloName")));
                        let avt = lossless::string(d.get("avatar"));
                        let bio = lossless::string(d.get("status"));
                        state.contacts.search = ContactSearchState {
                            status: ContactSearchStatus::Found,
                            error: None,
                            user: Some(FoundUserEntry {
                                id: uid,
                                name,
                                zalo_name,
                                avatar: is_valid_url_str(&avt).then_some(avt),
                                bio,
                                is_friend,
                                is_self,
                                requested,
                                requesting,
                                default_message: format!("Xin chào, mình là {my_name}."),
                                max_message: 150,
                            }),
                        };
                    }
                }
                Err(failure) => {
                    state.contacts.search = ContactSearchState {
                        status: ContactSearchStatus::Error,
                        error: Some(format_session_failure_localized(&failure)),
                        user: None,
                    };
                }
            }
            out.dirty.insert(DirtyKey::Contacts);
            complete_op(out, op_id, OpResult::Unit, false);
        }

        Input::BlockedUsersLoaded { users, op_id } => {
            match users {
                Some(entries) => {
                    let mapped: Vec<BlockedUserState> = entries
                        .into_iter()
                        .map(|BlockedUserEntry { id, name, avatar }| BlockedUserState {
                            id: normalize_contact_uid(&id),
                            name,
                            avatar,
                        })
                        .collect();
                    state.contacts.blocked_users = Some(mapped);
                    out.dirty.insert(DirtyKey::Contacts);
                }
                None => {
                    if state.contacts.blocked_users.is_none() {
                        state.contacts.blocked_users = Some(Vec::new());
                        out.dirty.insert(DirtyKey::Contacts);
                    }
                }
            }
            complete_op(out, op_id, OpResult::Unit, false);
        }

        Input::BlockedUserUpdated {
            uid,
            blocked,
            name,
            open_conv_id,
            ok,
            op_id,
        } => {
            let uid = normalize_contact_uid(&uid);
            if ok {
                let mut list = state.contacts.blocked_users.take().unwrap_or_default();
                // Item 6.2: capture any existing entry before retaining so re-blocking with an
                // empty name preserves the previous name & avatar when lookup_person misses.
                let prev = list
                    .iter()
                    .find(|u| candidate_uids_equal(&u.id, &uid))
                    .cloned();
                let mut seen = BTreeSet::new();
                list.retain(|u| !candidate_uids_equal(&u.id, &uid) && seen.insert(u.id.clone()));
                if blocked {
                    let snap = state.identity_snapshot();
                    let info = snap.lookup_person(&uid);
                    let shown = if !name.is_empty() {
                        name
                    } else if let Some(h) = info.as_ref().filter(|h| !h.name.is_empty()) {
                        h.name.clone()
                    } else {
                        prev.as_ref().map_or_else(String::new, |p| p.name.clone())
                    };
                    let avatar = info
                        .and_then(|h| is_valid_url_str(&h.avatar).then_some(h.avatar))
                        .or_else(|| prev.and_then(|p| p.avatar));
                    list.insert(
                        0,
                        BlockedUserState {
                            id: uid,
                            name: shown,
                            avatar,
                        },
                    );
                }
                state.contacts.blocked_users = Some(list);
                out.dirty.insert(DirtyKey::Contacts);
                let text = if blocked {
                    "Bạn đã chặn tin nhắn và cuộc gọi từ người này"
                } else {
                    "Bỏ chặn thành công"
                };
                out.effects.push(Effect::Host(HostCall::ShowCard {
                    conv_id: open_conv_id.filter(|s| !s.is_empty()),
                    text: text.to_owned(),
                }));
            } else {
                let text = if blocked {
                    "Chặn bạn không thành công. Vui lòng thử lại sau"
                } else {
                    "Bỏ chặn bạn không thành công. Vui lòng thử lại sau"
                };
                out.effects.push(Effect::Host(HostCall::ShowCard {
                    conv_id: open_conv_id.filter(|s| !s.is_empty()),
                    text: text.to_owned(),
                }));
            }
            complete_op(out, op_id, OpResult::Unit, false);
        }

        Input::AliasSaved {
            uid,
            trimmed_alias,
            ok,
            op_id,
        } => {
            let uid = normalize_contact_uid(&uid);
            if ok {
                state
                    .contacts
                    .aliases
                    .retain(|k, _| normalize_contact_uid(k) != uid);
                if !trimmed_alias.is_empty() {
                    state
                        .contacts
                        .aliases
                        .insert(uid.clone(), trimmed_alias.clone());
                }
                out.dirty.insert(DirtyKey::Contacts);
                out.dirty.insert(DirtyKey::Aliases);
                out.refresh_identity_snapshot = true;
                out.effects.push(Effect::Store(StoreOp::SetPreferenceData {
                    key: "aliases".to_owned(),
                    data: serialize_aliases_json(&state.contacts.aliases),
                }));
                refresh_after_alias_change(state, &uid, out);
                let text = if trimmed_alias.is_empty() {
                    "Đã xóa tên gợi nhớ."
                } else {
                    "Đã lưu tên gợi nhớ."
                };
                complete_op(
                    out,
                    op_id,
                    OpResult::SaveAlias(SaveAliasOutcome {
                        ok: true,
                        text: text.to_owned(),
                    }),
                    true,
                );
            } else {
                complete_op(
                    out,
                    op_id,
                    OpResult::SaveAlias(SaveAliasOutcome {
                        ok: false,
                        text: "Không lưu được tên gợi nhớ.".to_owned(),
                    }),
                    false,
                );
            }
        }

        _ => unreachable!("non-contacts input routed to reduce_contacts_input"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::messages::{contact_fold, localized_standard_cmp};
    use crate::reduce::reduce;
    use serde_json::json;

    #[test]
    fn contact_fold_vietnamese_and_fullwidth_parity() {
        assert_eq!(contact_fold("Đặng Dương"), "dang duong");
        assert_eq!(contact_fold("Nguyễn Ánh"), "nguyen anh");
        assert_eq!(contact_fold("  ＡＢＣ１２３  "), "  abc123  ");
        assert_eq!(
            localized_standard_cmp("Nhóm 2", "Nhóm 10"),
            std::cmp::Ordering::Less
        );
    }

    #[test]
    fn adapter_state_and_reset_search_pure_transitions() {
        let mut state = CoreState::default();
        let payload = json!({
            "contacts": {
                "friends": [{ "id": "301", "name": "Đào Anh", "zaloName": "Đào", "online": true }],
                "groups": [{ "id": "g501", "name": "Nhóm A", "members": 5 }],
                "pendingRequestCount": 3,
                "search": {
                    "status": "found",
                    "user": { "id": "302", "name": "Bình", "zaloName": "Bình", "maxMessage": 150 }
                },
                "notice": { "seq": 2, "ok": true, "text": "OK" }
            }
        })
        .to_string();
        let out = reduce(
            &mut state,
            Input::Command(Command::HandleContactsState {
                state_json: payload,
            }),
        );
        assert!(out.dirty.contains(&DirtyKey::Contacts));
        assert!(state.contacts.friends_loaded);
        assert!(state.contacts.groups_loaded);
        assert_eq!(state.contacts.friends[0].section, "D");
        assert_eq!(state.contacts.friends[0].sort_key, "dao anh");
        assert_eq!(state.contacts.pending_request_count, 3);
        assert_eq!(state.contacts.search.status, ContactSearchStatus::Found);

        let out2 = reduce(&mut state, Input::Command(Command::ResetFriendSearch));
        assert!(out2.dirty.contains(&DirtyKey::Contacts));
        assert_eq!(state.contacts.search.status, ContactSearchStatus::Idle);
        assert!(state.contacts.search.user.is_none());
    }

    #[test]
    fn item6_fixes_uid_normalization_blocked_preserve_and_friends_loaded_guard() {
        let mut state = CoreState::default();
        // Seed a friend row while friends_loaded == false (item 6.3).
        state.contacts.friends.push(FriendEntry {
            id: "3000940".to_owned(),
            name: "Seeded Unloaded".to_owned(),
            zalo_name: "Seeded Unloaded".to_owned(),
            avatar: None,
            last_active_ms: None,
            online: false,
            section: "S".to_owned(),
            sort_key: "seeded unloaded".to_owned(),
        });
        state.contacts.friends_loaded = false;
        state.contacts.search_gen = 1;
        let Ok(resp) = serde_json::from_value(json!({
            "data": { "uid": "u3000940", "display_name": "Found Peer" }
        })) else {
            panic!("deserialize find response");
        };
        let _ = reduce(
            &mut state,
            Input::FriendFoundByPhone {
                search_gen: 1,
                result: Ok(resp),
                op_id: None,
            },
        );
        let Some(found) = state.contacts.search.user.as_ref() else {
            panic!("expected found user");
        };
        assert_eq!(found.id, "3000940");
        assert!(!found.is_friend);

        // Once friends_loaded is true, is_friend becomes true.
        state.contacts.friends_loaded = true;
        state.contacts.search_gen = 2;
        let Ok(resp2) = serde_json::from_value(json!({
            "data": { "uid": "u3000940", "display_name": "Found Peer" }
        })) else {
            panic!("deserialize second find response");
        };
        let _ = reduce(
            &mut state,
            Input::FriendFoundByPhone {
                search_gen: 2,
                result: Ok(resp2),
                op_id: None,
            },
        );
        let Some(found2) = state.contacts.search.user.as_ref() else {
            panic!("expected second found user");
        };
        assert!(found2.is_friend);

        // Item 6.2: re-blocking an existing blocked user with empty name preserves previous name/avatar.
        state.contacts.blocked_users = Some(vec![BlockedUserState {
            id: "3000980".to_owned(),
            name: "Existing Blocked".to_owned(),
            avatar: Some("https://cdn.example.invalid/b.jpg".to_owned()),
        }]);
        let _ = reduce(
            &mut state,
            Input::BlockedUserUpdated {
                uid: "u3000980".to_owned(),
                blocked: true,
                name: String::new(),
                open_conv_id: None,
                ok: true,
                op_id: None,
            },
        );
        let Some(blocked) = state.contacts.blocked_users.as_ref() else {
            panic!("expected blocked users");
        };
        assert_eq!(blocked.len(), 1);
        assert_eq!(blocked[0].id, "3000980");
        assert_eq!(blocked[0].name, "Existing Blocked");
        assert_eq!(
            blocked[0].avatar.as_deref(),
            Some("https://cdn.example.invalid/b.jpg")
        );
    }
}
