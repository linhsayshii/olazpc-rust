//! Pure U8 reducer for message forwarding (`requestForward`, `forwardSelection`, `forward`, `forwardAll`).

use olaz_api::SendMessageResult;
use olaz_wire::{
    Availability, ChatMessage, DeleteMode, Kind, MessageMenu, StarMode, Status,
    encode_chat_message, is_group_id,
};

use crate::changes::DirtyKey;
use crate::composer::{ContactCardContinuation, ContactCardSendSpec};
use crate::effect::{Effect, HostCall, OpResult, StoreOp};
use crate::forward::{
    ActiveForward, ComposerSendOutcome, FileResolutionOutcome, ForwardClientBody, ForwardMode,
    ForwardOutcome, ForwardRequest, ForwardStep, MediaResolutionOutcome,
};
use crate::input::{Command, Input};
use crate::messages::{WindowChange, is_valid_url_str, to_db_stored};
use crate::reduce::ReduceOutput;
use crate::reduce::send::{
    SendCompletion, SendTextRequest, start_send_text, update_conversation_after_send,
};
use crate::state::CoreState;

const MSG_BLOCKED_FORWARD: &str = "Trò chuyện này đã bật Chặn chia sẻ";
const MSG_SELECTION_BLOCKED: &str = "Có tin nhắn không thể chia sẻ";
const MSG_NO_TARGETS: &str = "Chưa chọn cuộc trò chuyện.";
const MSG_FORWARD_DONE: &str = "Đã chia sẻ";
const MSG_FORWARD_ALL_DEFAULT_DONE: &str = "Đã chia sẻ tin nhắn";
const MSG_FORWARD_FAILED: &str = "Có lỗi khi chia sẻ tin nhắn";

/// Reduces a U8 forward [`Input`].
pub(crate) fn reduce_forward(state: &mut CoreState, input: Input, out: &mut ReduceOutput) {
    match input {
        Input::Command(cmd) => reduce_command(state, cmd, None, out),
        Input::OpRequest { op_id, cmd } => reduce_command(state, cmd, Some(op_id), out),
        Input::ForwardClientIdAllocated {
            forward_id,
            client_id,
        } => on_client_id_allocated(state, forward_id, client_id, out),
        Input::ForwardMediaResolved {
            forward_id,
            resolution,
        } => on_media_resolved(state, forward_id, resolution, out),
        Input::ForwardFileResolved {
            forward_id,
            resolution,
        } => on_file_resolved(state, forward_id, resolution, out),
        Input::ForwardFetchMediaDone {
            forward_id,
            temp_path,
        } => on_fetch_media_done(state, forward_id, temp_path, out),
        Input::ForwardSendMediaDone {
            forward_id,
            outcome,
        } => on_send_media_done(state, forward_id, outcome, out),
        Input::ForwardSendFilesDone {
            forward_id,
            outcome,
        } => on_send_files_done(state, forward_id, outcome, out),
        _ => {}
    }
}

/// Callback invoked by `reduce::send` when a forward-initiated `send_text` finishes.
pub(crate) fn on_send_text_done(
    state: &mut CoreState,
    forward_id: u64,
    ok: bool,
    out: &mut ReduceOutput,
) {
    let Some(mut flow) = state.forward.in_flight.remove(&forward_id) else {
        return;
    };
    if !matches!(flow.step, ForwardStep::SendingText) {
        state.forward.in_flight.insert(forward_id, flow);
        return;
    }
    if ok {
        flow.msg_succeeded = flow.msg_succeeded.saturating_add(1);
        flow.wrote_store = true;
    }
    flow.target_idx = flow.target_idx.saturating_add(1);
    flow.step = ForwardStep::Idle;
    state.forward.in_flight.insert(forward_id, flow);
    advance_forward(state, forward_id, out);
}

fn reduce_command(state: &mut CoreState, cmd: Command, op_id: Option<u64>, out: &mut ReduceOutput) {
    match cmd {
        Command::RequestForward { message } => {
            let message = *message;
            if message.menu.forward != Availability::Available {
                if message.menu.forward == Availability::Blocked {
                    out.effects.push(Effect::Host(HostCall::ShowCard {
                        conv_id: Some(message.conversation_id),
                        text: MSG_BLOCKED_FORWARD.to_owned(),
                    }));
                }
                complete_unit(op_id, out);
                return;
            }
            let id = state.forward.alloc_request_id();
            state.forward.request = Some(ForwardRequest {
                id,
                conversation_id: message.conversation_id.clone(),
                message,
                more: Vec::new(),
            });
            out.dirty.insert(DirtyKey::ForwardRequest);
            complete_unit(op_id, out);
        }

        Command::ForwardSelection { messages } => {
            let mut iter = messages.into_iter();
            let Some(first) = iter.next() else {
                complete_unit(op_id, out);
                return;
            };
            let more: Vec<ChatMessage> = iter.collect();
            let all_available = first.menu.forward == Availability::Available
                && more
                    .iter()
                    .all(|m| m.menu.forward == Availability::Available);
            if !all_available {
                out.effects.push(Effect::Host(HostCall::ShowCard {
                    conv_id: Some(first.conversation_id),
                    text: MSG_SELECTION_BLOCKED.to_owned(),
                }));
                complete_unit(op_id, out);
                return;
            }
            let id = state.forward.alloc_request_id();
            state.forward.request = Some(ForwardRequest {
                id,
                conversation_id: first.conversation_id.clone(),
                message: first,
                more,
            });
            out.dirty.insert(DirtyKey::ForwardRequest);
            complete_unit(op_id, out);
        }

        Command::ClearForwardRequest => {
            if state.forward.clear_request() {
                out.dirty.insert(DirtyKey::ForwardRequest);
            }
            complete_unit(op_id, out);
        }

        Command::Forward {
            message,
            targets,
            now_ms,
        } => {
            let message = *message;
            let forward_id = state.forward.alloc_forward_id();
            state.forward.in_flight.insert(
                forward_id,
                ActiveForward {
                    op_id,
                    mode: ForwardMode::Single,
                    messages: vec![message],
                    msg_idx: 0,
                    targets,
                    target_idx: 0,
                    msg_succeeded: 0,
                    now_ms,
                    wrote_store: false,
                    step: ForwardStep::Idle,
                },
            );
            advance_forward(state, forward_id, out);
        }

        Command::ForwardAll { targets, now_ms } => {
            let Some(req) = state.forward.request.clone() else {
                complete_forward(
                    op_id,
                    ForwardOutcome::Failed(MSG_FORWARD_FAILED.to_owned()),
                    false,
                    out,
                );
                return;
            };
            let forward_id = state.forward.alloc_forward_id();
            let messages = req.all_messages();
            state.forward.in_flight.insert(
                forward_id,
                ActiveForward {
                    op_id,
                    mode: ForwardMode::All {
                        request_id: req.id,
                        request_conv_id: req.conversation_id,
                        has_more: !req.more.is_empty(),
                        overall_outcome: ForwardOutcome::Failed(MSG_FORWARD_FAILED.to_owned()),
                    },
                    messages,
                    msg_idx: 0,
                    targets,
                    target_idx: 0,
                    msg_succeeded: 0,
                    now_ms,
                    wrote_store: false,
                    step: ForwardStep::Idle,
                },
            );
            advance_forward(state, forward_id, out);
        }

        _ => {}
    }
}

fn advance_forward(state: &mut CoreState, forward_id: u64, out: &mut ReduceOutput) {
    let Some(mut flow) = state.forward.in_flight.remove(&forward_id) else {
        return;
    };

    loop {
        if flow.msg_idx >= flow.messages.len() {
            finish_flow(state, flow, out);
            return;
        }

        if flow.targets.is_empty() {
            let one = ForwardOutcome::Failed(MSG_NO_TARGETS.to_owned());
            if record_message_outcome(&mut flow, one) {
                continue;
            }
            finish_single_flow(flow, ForwardOutcome::Failed(MSG_NO_TARGETS.to_owned()), out);
            return;
        }

        if flow.target_idx >= flow.targets.len() {
            let one = if flow.msg_succeeded > 0 {
                ForwardOutcome::Done(Some(MSG_FORWARD_DONE.to_owned()))
            } else {
                ForwardOutcome::Failed(MSG_FORWARD_FAILED.to_owned())
            };
            match &flow.mode {
                ForwardMode::Single => {
                    finish_single_flow(flow, one, out);
                    return;
                }
                ForwardMode::All { .. } => {
                    record_message_outcome(&mut flow, one);
                    continue;
                }
            }
        }

        let target = flow.targets[flow.target_idx].clone();
        let msg = flow.messages[flow.msg_idx].clone();

        match &msg.kind {
            Kind::Text => {
                let body = msg.text.clone();
                if body.trim().is_empty() || target.is_empty() {
                    flow.target_idx = flow.target_idx.saturating_add(1);
                    continue;
                }
                flow.step = ForwardStep::AllocatingClientId {
                    target,
                    body: ForwardClientBody::Text(body),
                };
                state.forward.in_flight.insert(forward_id, flow);
                out.effects.push(Effect::AllocClientId { forward_id });
                return;
            }

            Kind::Link { title, url, .. } => {
                let body = url
                    .as_deref()
                    .filter(|u| !u.is_empty())
                    .map(str::to_owned)
                    .unwrap_or_else(|| {
                        if msg.text.is_empty() {
                            title.clone()
                        } else {
                            msg.text.clone()
                        }
                    });
                if body.trim().is_empty() || target.is_empty() {
                    flow.target_idx = flow.target_idx.saturating_add(1);
                    continue;
                }
                flow.step = ForwardStep::AllocatingClientId {
                    target,
                    body: ForwardClientBody::Text(body),
                };
                state.forward.in_flight.insert(forward_id, flow);
                out.effects.push(Effect::AllocClientId { forward_id });
                return;
            }

            Kind::ContactCard(card) => {
                flow.step = ForwardStep::AllocatingClientId {
                    target,
                    body: ForwardClientBody::ContactCard(card.clone()),
                };
                state.forward.in_flight.insert(forward_id, flow);
                out.effects.push(Effect::AllocClientId { forward_id });
                return;
            }

            Kind::Photo { url, .. } => {
                let fallback_url = url.clone().filter(|u| !u.is_empty());
                flow.step = ForwardStep::ResolvingPhoto {
                    target,
                    fallback_url,
                };
                state.forward.in_flight.insert(forward_id, flow);
                out.effects.push(Effect::Host(HostCall::ResolveMedia {
                    forward_id,
                    conv_id: msg.conversation_id,
                    msg_id: msg.id,
                    kind: "photo".to_owned(),
                }));
                return;
            }

            Kind::File { name, url, .. } => {
                let name = name.clone();
                let url = url.clone().filter(|u| !u.is_empty());
                flow.step = ForwardStep::ResolvingFile { target };
                state.forward.in_flight.insert(forward_id, flow);
                out.effects.push(Effect::Host(HostCall::ResolveFile {
                    forward_id,
                    conv_id: msg.conversation_id,
                    msg_id: msg.id,
                    name,
                    url,
                }));
                return;
            }

            _ => {
                let body = msg.text.clone();
                if body.trim().is_empty() || target.is_empty() {
                    flow.target_idx = flow.target_idx.saturating_add(1);
                    continue;
                }
                flow.step = ForwardStep::AllocatingClientId {
                    target,
                    body: ForwardClientBody::Text(body),
                };
                state.forward.in_flight.insert(forward_id, flow);
                out.effects.push(Effect::AllocClientId { forward_id });
                return;
            }
        }
    }
}

/// Records the outcome of one message in `ForwardMode::All` and advances `msg_idx`.
/// Returns `true` if `flow` is `ForwardMode::All` and should continue looping.
fn record_message_outcome(flow: &mut ActiveForward, one: ForwardOutcome) -> bool {
    match &mut flow.mode {
        ForwardMode::Single => false,
        ForwardMode::All {
            overall_outcome, ..
        } => {
            if !matches!(overall_outcome, ForwardOutcome::Done(_)) {
                *overall_outcome = one;
            }
            flow.msg_idx = flow.msg_idx.saturating_add(1);
            flow.target_idx = 0;
            flow.msg_succeeded = 0;
            true
        }
    }
}

fn finish_single_flow(flow: ActiveForward, outcome: ForwardOutcome, out: &mut ReduceOutput) {
    complete_forward(flow.op_id, outcome, flow.wrote_store, out);
}

fn finish_flow(state: &mut CoreState, flow: ActiveForward, out: &mut ReduceOutput) {
    match flow.mode {
        ForwardMode::Single => {
            complete_forward(
                flow.op_id,
                ForwardOutcome::Failed(MSG_FORWARD_FAILED.to_owned()),
                flow.wrote_store,
                out,
            );
        }
        ForwardMode::All {
            request_id,
            request_conv_id,
            has_more,
            overall_outcome,
        } => {
            if matches!(overall_outcome, ForwardOutcome::Done(_)) && has_more {
                out.dirty.insert(DirtyKey::ForwardClearSelection);
            }
            match &overall_outcome {
                ForwardOutcome::Done(text) => {
                    out.effects.push(Effect::Host(HostCall::ShowCard {
                        conv_id: Some(request_conv_id),
                        text: text
                            .clone()
                            .unwrap_or_else(|| MSG_FORWARD_ALL_DEFAULT_DONE.to_owned()),
                    }));
                    if state.forward.request.as_ref().map(|r| r.id) == Some(request_id) {
                        state.forward.request = None;
                        out.dirty.insert(DirtyKey::ForwardRequest);
                    }
                }
                ForwardOutcome::Pending(text) => {
                    out.effects.push(Effect::Host(HostCall::ShowCard {
                        conv_id: Some(request_conv_id),
                        text: text.clone(),
                    }));
                    if state.forward.request.as_ref().map(|r| r.id) == Some(request_id) {
                        state.forward.request = None;
                        out.dirty.insert(DirtyKey::ForwardRequest);
                    }
                }
                ForwardOutcome::Failed(_) => {}
            }
            complete_forward(flow.op_id, overall_outcome, flow.wrote_store, out);
        }
    }
}

fn on_client_id_allocated(
    state: &mut CoreState,
    forward_id: u64,
    client_id: i64,
    out: &mut ReduceOutput,
) {
    let Some(mut flow) = state.forward.in_flight.remove(&forward_id) else {
        return;
    };
    let prev_step = std::mem::replace(&mut flow.step, ForwardStep::Idle);
    let ForwardStep::AllocatingClientId { target, body } = prev_step else {
        flow.step = prev_step;
        state.forward.in_flight.insert(forward_id, flow);
        return;
    };

    match body {
        ForwardClientBody::Text(text) => {
            let now_ms = flow.now_ms;
            flow.step = ForwardStep::SendingText;
            state.forward.in_flight.insert(forward_id, flow);
            start_send_text(
                state,
                SendTextRequest {
                    conv_id: target,
                    text,
                    quote_id: None,
                    mentions: Vec::new(),
                    styles: Vec::new(),
                    urgency: 0,
                    client_id,
                    now_ms,
                    is_e2ee_override: None,
                    ttl_ms_override: None,
                    completion: SendCompletion::Forward(forward_id),
                },
                out,
            );
        }
        ForwardClientBody::ContactCard(card) => {
            let now_ms = flow.now_ms;
            let spec = ContactCardSendSpec {
                conv_id: target.clone(),
                contact_uid: card.uid.clone(),
                title: card.name.clone(),
                avatar: card.avatar.clone().filter(|s| !s.is_empty()),
                phone: (!card.phone.is_empty()).then(|| card.phone.clone()),
                qr_code_url: card.qr.clone().unwrap_or_default(),
                client_id: Some(client_id),
                now_ms,
                is_e2ee_override: None,
            };
            flow.step = ForwardStep::SendingContactCard { target, card };
            state.forward.in_flight.insert(forward_id, flow);
            let _ = crate::reduce::composer::start_contact_card_send(
                state,
                spec,
                ContactCardContinuation::Forward { forward_id },
                out,
            );
        }
    }
}

pub(crate) fn on_contact_card_done(
    state: &mut CoreState,
    forward_id: u64,
    is_e2ee: bool,
    result: Result<SendMessageResult, String>,
    out: &mut ReduceOutput,
) {
    let Some(mut flow) = state.forward.in_flight.remove(&forward_id) else {
        return;
    };
    let prev_step = std::mem::replace(&mut flow.step, ForwardStep::Idle);
    let ForwardStep::SendingContactCard { target, card } = prev_step else {
        flow.step = prev_step;
        state.forward.in_flight.insert(forward_id, flow);
        return;
    };

    if let Ok(res) = result {
        let my_uid = state
            .session
            .profile
            .as_ref()
            .map_or_else(String::new, |p| p.user_id.clone());
        let my_name = state
            .session
            .profile
            .as_ref()
            .map_or_else(|| "Bạn".to_owned(), |p| p.display_name.clone());
        let my_avatar = state
            .session
            .profile
            .as_ref()
            .and_then(|p| p.avatar.clone())
            .filter(|s| is_valid_url_str(s));
        let is_self = state.session.self_conversation_id.as_deref() == Some(target.as_str());
        let is_grp = is_group_id(&target);
        let text = format!("[Danh thiếp] {}", card.name);

        let msg = ChatMessage {
            id: res.msg_id,
            conversation_id: target,
            sender_id: my_uid,
            sender_name: my_name,
            sender_avatar: my_avatar,
            is_mine: true,
            kind: Kind::ContactCard(card),
            text,
            date_ms: flow.now_ms,
            status: Status::Sent,
            quote: None,
            reactions: Vec::new(),
            is_e2ee,
            mentions: Vec::new(),
            card_buttons: Vec::new(),
            suggests_stickers: false,
            menu: MessageMenu {
                forward: Availability::Available,
                recall: !is_self,
                delete: Some(if is_self {
                    DeleteMode::Plain
                } else {
                    DeleteMode::ForMe
                }),
                pin: is_grp && !is_self,
                star: Some(StarMode::Star),
                starred: false,
                pinned: false,
                is_protected: false,
            },
            fallback_urls: Vec::new(),
            client_id: res.cli_msg_id.clone(),
            text_styles: Vec::new(),
            ttl_ms: 0,
            urgency: 0,
        };

        let snap = state.identity_snapshot();
        if matches!(
            state
                .messages
                .merge_message(msg.clone(), Some(&res.cli_msg_id), &snap),
            WindowChange::Changed(_)
        ) {
            out.dirty.insert(DirtyKey::Messages);
        }
        if let Some(stored) = encode_chat_message(&msg, &res.cli_msg_id) {
            out.effects.push(Effect::Store(StoreOp::SaveMessages {
                rows: vec![to_db_stored(&stored)],
                preserve_existing_reactions: false,
            }));
        }
        update_conversation_after_send(state, &msg, out);
        flow.msg_succeeded = flow.msg_succeeded.saturating_add(1);
        flow.wrote_store = true;
    }

    flow.target_idx = flow.target_idx.saturating_add(1);
    flow.step = ForwardStep::Idle;
    state.forward.in_flight.insert(forward_id, flow);
    advance_forward(state, forward_id, out);
}

fn on_media_resolved(
    state: &mut CoreState,
    forward_id: u64,
    resolution: MediaResolutionOutcome,
    out: &mut ReduceOutput,
) {
    let Some(mut flow) = state.forward.in_flight.remove(&forward_id) else {
        return;
    };
    let prev_step = std::mem::replace(&mut flow.step, ForwardStep::Idle);
    let ForwardStep::ResolvingPhoto {
        target,
        fallback_url,
    } = prev_step
    else {
        flow.step = prev_step;
        state.forward.in_flight.insert(forward_id, flow);
        return;
    };

    if let MediaResolutionOutcome::File(path) = resolution {
        flow.step = ForwardStep::SendingResolvedPhoto {
            target: target.clone(),
            fallback_url,
        };
        state.forward.in_flight.insert(forward_id, flow);
        out.effects.push(Effect::Host(HostCall::SendMedia {
            forward_id,
            conv_id: target,
            paths: vec![path],
            cleanup_after: false,
        }));
        return;
    }

    try_photo_fallback_or_advance(state, forward_id, flow, target, fallback_url, out);
}

fn on_send_media_done(
    state: &mut CoreState,
    forward_id: u64,
    outcome: ComposerSendOutcome,
    out: &mut ReduceOutput,
) {
    let Some(mut flow) = state.forward.in_flight.remove(&forward_id) else {
        return;
    };
    let prev_step = std::mem::replace(&mut flow.step, ForwardStep::Idle);
    match prev_step {
        ForwardStep::SendingResolvedPhoto {
            target,
            fallback_url,
        } => {
            if outcome == ComposerSendOutcome::Done {
                flow.msg_succeeded = flow.msg_succeeded.saturating_add(1);
                flow.target_idx = flow.target_idx.saturating_add(1);
                flow.step = ForwardStep::Idle;
                state.forward.in_flight.insert(forward_id, flow);
                advance_forward(state, forward_id, out);
            } else {
                try_photo_fallback_or_advance(state, forward_id, flow, target, fallback_url, out);
            }
        }
        ForwardStep::SendingFallbackPhoto => {
            if outcome == ComposerSendOutcome::Done {
                flow.msg_succeeded = flow.msg_succeeded.saturating_add(1);
            }
            flow.target_idx = flow.target_idx.saturating_add(1);
            flow.step = ForwardStep::Idle;
            state.forward.in_flight.insert(forward_id, flow);
            advance_forward(state, forward_id, out);
        }
        other => {
            flow.step = other;
            state.forward.in_flight.insert(forward_id, flow);
        }
    }
}

fn try_photo_fallback_or_advance(
    state: &mut CoreState,
    forward_id: u64,
    mut flow: ActiveForward,
    target: String,
    fallback_url: Option<String>,
    out: &mut ReduceOutput,
) {
    if let Some(url) = fallback_url.filter(|u| !u.is_empty()) {
        flow.step = ForwardStep::FetchingPhotoFallback { target };
        state.forward.in_flight.insert(forward_id, flow);
        out.effects
            .push(Effect::Host(HostCall::FetchMediaData { forward_id, url }));
    } else {
        flow.target_idx = flow.target_idx.saturating_add(1);
        flow.step = ForwardStep::Idle;
        state.forward.in_flight.insert(forward_id, flow);
        advance_forward(state, forward_id, out);
    }
}

fn on_fetch_media_done(
    state: &mut CoreState,
    forward_id: u64,
    temp_path: Option<String>,
    out: &mut ReduceOutput,
) {
    let Some(mut flow) = state.forward.in_flight.remove(&forward_id) else {
        return;
    };
    let prev_step = std::mem::replace(&mut flow.step, ForwardStep::Idle);
    let ForwardStep::FetchingPhotoFallback { target } = prev_step else {
        flow.step = prev_step;
        state.forward.in_flight.insert(forward_id, flow);
        return;
    };

    if let Some(path) = temp_path.filter(|p| !p.is_empty()) {
        flow.step = ForwardStep::SendingFallbackPhoto;
        state.forward.in_flight.insert(forward_id, flow);
        out.effects.push(Effect::Host(HostCall::SendMedia {
            forward_id,
            conv_id: target,
            paths: vec![path],
            cleanup_after: true,
        }));
    } else {
        flow.target_idx = flow.target_idx.saturating_add(1);
        flow.step = ForwardStep::Idle;
        state.forward.in_flight.insert(forward_id, flow);
        advance_forward(state, forward_id, out);
    }
}

fn on_file_resolved(
    state: &mut CoreState,
    forward_id: u64,
    resolution: FileResolutionOutcome,
    out: &mut ReduceOutput,
) {
    let Some(mut flow) = state.forward.in_flight.remove(&forward_id) else {
        return;
    };
    let prev_step = std::mem::replace(&mut flow.step, ForwardStep::Idle);
    let ForwardStep::ResolvingFile { target } = prev_step else {
        flow.step = prev_step;
        state.forward.in_flight.insert(forward_id, flow);
        return;
    };

    if let FileResolutionOutcome::Ready(path) = resolution {
        flow.step = ForwardStep::SendingResolvedFile;
        state.forward.in_flight.insert(forward_id, flow);
        out.effects.push(Effect::Host(HostCall::SendFiles {
            forward_id,
            conv_id: target,
            paths: vec![path],
        }));
    } else {
        flow.target_idx = flow.target_idx.saturating_add(1);
        flow.step = ForwardStep::Idle;
        state.forward.in_flight.insert(forward_id, flow);
        advance_forward(state, forward_id, out);
    }
}

fn on_send_files_done(
    state: &mut CoreState,
    forward_id: u64,
    outcome: ComposerSendOutcome,
    out: &mut ReduceOutput,
) {
    let Some(mut flow) = state.forward.in_flight.remove(&forward_id) else {
        return;
    };
    if !matches!(flow.step, ForwardStep::SendingResolvedFile) {
        state.forward.in_flight.insert(forward_id, flow);
        return;
    }
    if outcome == ComposerSendOutcome::Done {
        flow.msg_succeeded = flow.msg_succeeded.saturating_add(1);
    }
    flow.target_idx = flow.target_idx.saturating_add(1);
    flow.step = ForwardStep::Idle;
    state.forward.in_flight.insert(forward_id, flow);
    advance_forward(state, forward_id, out);
}

fn complete_unit(op_id: Option<u64>, out: &mut ReduceOutput) {
    if let Some(op_id) = op_id {
        out.effects.push(Effect::CompleteOp {
            op_id,
            result: OpResult::Unit,
            after_store: false,
        });
    }
}

fn complete_forward(
    op_id: Option<u64>,
    outcome: ForwardOutcome,
    after_store: bool,
    out: &mut ReduceOutput,
) {
    if let Some(op_id) = op_id {
        out.effects.push(Effect::CompleteOp {
            op_id,
            result: OpResult::Forward(outcome),
            after_store,
        });
    }
}

#[cfg(test)]
mod tests {
    use olaz_wire::ContactCard;

    use super::*;
    use crate::conversations::ConversationSummary;
    use crate::reduce::reduce;
    use crate::state::{Phase, Profile};

    fn make_msg(
        id: &str,
        conv_id: &str,
        kind: Kind,
        text: &str,
        forward: Availability,
    ) -> ChatMessage {
        ChatMessage {
            id: id.to_owned(),
            conversation_id: conv_id.to_owned(),
            sender_id: conv_id.to_owned(),
            sender_name: "Alice".to_owned(),
            sender_avatar: None,
            is_mine: false,
            kind,
            text: text.to_owned(),
            date_ms: 1_700_000_001_000,
            status: Status::Sent,
            quote: None,
            reactions: Vec::new(),
            is_e2ee: false,
            mentions: Vec::new(),
            card_buttons: Vec::new(),
            suggests_stickers: false,
            menu: MessageMenu {
                forward,
                ..MessageMenu::default()
            },
            fallback_urls: Vec::new(),
            client_id: format!("cli_{id}"),
            text_styles: Vec::new(),
            ttl_ms: 0,
            urgency: 0,
        }
    }

    fn ready_state() -> CoreState {
        let mut state = CoreState::default();
        state.session.phase = Phase::Ready;
        state.session.profile = Some(Profile {
            user_id: "2000800".to_owned(),
            display_name: "Me".to_owned(),
            avatar: Some("https://cdn.example.invalid/me.jpg".to_owned()),
            phone: None,
        });
        state.session.self_conversation_id = Some("92000800".to_owned());
        state.conversations.conversations.push(ConversationSummary {
            id: "3000800b".to_owned(),
            is_group: false,
            name: "Target".to_owned(),
            avatar: None,
            pinned: false,
            members: 0,
            unread: 0,
            preview: None,
        });
        state
    }

    #[test]
    fn request_forward_handles_hidden_blocked_and_available() {
        let mut state = ready_state();

        let hidden = make_msg("1", "3000800a", Kind::Text, "a", Availability::Hidden);
        let out = reduce(
            &mut state,
            Input::Command(Command::RequestForward {
                message: Box::new(hidden),
            }),
        );
        assert!(state.forward.request.is_none());
        assert!(out.effects.is_empty());

        let blocked = make_msg("2", "3000800a", Kind::Text, "b", Availability::Blocked);
        let out = reduce(
            &mut state,
            Input::Command(Command::RequestForward {
                message: Box::new(blocked),
            }),
        );
        assert!(state.forward.request.is_none());
        assert!(matches!(
            out.effects.as_slice(),
            [Effect::Host(HostCall::ShowCard { conv_id: Some(c), text })]
                if c == "3000800a" && text == MSG_BLOCKED_FORWARD
        ));

        let avail = make_msg("3", "3000800a", Kind::Text, "c", Availability::Available);
        let out = reduce(
            &mut state,
            Input::Command(Command::RequestForward {
                message: Box::new(avail),
            }),
        );
        assert_eq!(
            state
                .forward
                .request
                .as_ref()
                .map(|r| r.message.id.as_str()),
            Some("3")
        );
        assert!(out.dirty.contains(&DirtyKey::ForwardRequest));
    }

    #[test]
    fn forward_selection_rejects_any_non_available_and_accepts_all_available() {
        let mut state = ready_state();
        let m1 = make_msg("1", "3000800a", Kind::Text, "one", Availability::Available);
        let m2 = make_msg("2", "3000800a", Kind::Text, "two", Availability::Blocked);
        let m3 = make_msg(
            "3",
            "3000800a",
            Kind::Text,
            "three",
            Availability::Available,
        );

        let out = reduce(
            &mut state,
            Input::Command(Command::ForwardSelection {
                messages: vec![m1.clone(), m2, m3.clone()],
            }),
        );
        assert!(state.forward.request.is_none());
        assert!(matches!(
            out.effects.as_slice(),
            [Effect::Host(HostCall::ShowCard { conv_id: Some(c), text })]
                if c == "3000800a" && text == MSG_SELECTION_BLOCKED
        ));

        let out = reduce(
            &mut state,
            Input::Command(Command::ForwardSelection {
                messages: vec![m1, m3],
            }),
        );
        let req = state.forward.request.as_ref();
        assert_eq!(req.map(|r| r.message.id.as_str()), Some("1"));
        assert_eq!(req.map(|r| r.more.len()), Some(1));
        assert!(out.dirty.contains(&DirtyKey::ForwardRequest));
    }

    #[test]
    fn forward_empty_targets_and_empty_text_never_allocate_client_id() {
        let mut state = ready_state();
        let m = make_msg("1", "3000800a", Kind::Text, "hi", Availability::Available);
        let out = reduce(
            &mut state,
            Input::OpRequest {
                op_id: 1,
                cmd: Command::Forward {
                    message: Box::new(m),
                    targets: Vec::new(),
                    now_ms: 1_700_000_010_000,
                },
            },
        );
        assert!(matches!(
            out.effects.as_slice(),
            [Effect::CompleteOp {
                op_id: 1,
                result: OpResult::Forward(ForwardOutcome::Failed(msg)),
                after_store: false,
            }] if msg == MSG_NO_TARGETS
        ));

        let empty = make_msg("2", "3000800a", Kind::Text, "   ", Availability::Available);
        let out = reduce(
            &mut state,
            Input::OpRequest {
                op_id: 2,
                cmd: Command::Forward {
                    message: Box::new(empty),
                    targets: vec!["3000800b".to_owned()],
                    now_ms: 1_700_000_010_000,
                },
            },
        );
        assert!(matches!(
            out.effects.as_slice(),
            [Effect::CompleteOp {
                op_id: 2,
                result: OpResult::Forward(ForwardOutcome::Failed(msg)),
                after_store: false,
            }] if msg == MSG_FORWARD_FAILED
        ));
    }

    #[test]
    fn contact_card_forward_persists_message_and_updates_conversation() {
        let mut state = ready_state();
        let card = ContactCard {
            uid: "9001".to_owned(),
            name: "Bob".to_owned(),
            avatar: None,
            phone: "+84901234567".to_owned(),
            qr: None,
            is_official_account: false,
            oa_link: String::new(),
        };
        let m = make_msg(
            "10",
            "3000800a",
            Kind::ContactCard(card),
            "[Danh thiếp] Bob",
            Availability::Available,
        );
        let out = reduce(
            &mut state,
            Input::OpRequest {
                op_id: 5,
                cmd: Command::Forward {
                    message: Box::new(m),
                    targets: vec!["3000800b".to_owned()],
                    now_ms: 1_700_000_020_000,
                },
            },
        );
        assert!(matches!(
            out.effects.as_slice(),
            [Effect::AllocClientId { forward_id: 1 }]
        ));

        let out = reduce(
            &mut state,
            Input::ForwardClientIdAllocated {
                forward_id: 1,
                client_id: 8_000_000_000_001,
            },
        );
        assert!(matches!(
            out.effects.as_slice(),
            [Effect::SendContactCardApi { card_send_id: 1, params }]
                if params.conv_id == "3000800b"
                    && params.card_uid == "9001"
                    && params.phone.as_deref() == Some("+84901234567")
                    && params.client_id == Some(8_000_000_000_001)
        ));

        let out = reduce(
            &mut state,
            Input::ContactCardSendDone {
                card_send_id: 1,
                result: Ok(SendMessageResult {
                    msg_id: "9009001".to_owned(),
                    cli_msg_id: "8000000000001".to_owned(),
                    ts_ms: 1_700_000_020_000,
                }),
            },
        );
        assert!(out.dirty.contains(&DirtyKey::Messages));
        assert!(out.dirty.contains(&DirtyKey::Conversations));
        assert_eq!(
            state.messages.windows.get("3000800b").map(Vec::len),
            Some(1)
        );
        assert!(out.effects.iter().any(|e| matches!(
            e,
            Effect::CompleteOp {
                op_id: 5,
                result: OpResult::Forward(ForwardOutcome::Done(Some(t))),
                after_store: true,
            } if t == MSG_FORWARD_DONE
        )));
    }

    #[test]
    fn forward_contact_card_to_e2ee_routes_through_shared_e2ee_host_bridge() {
        let mut state = ready_state();
        state.send.e2ee_threads.insert("3000800b".to_owned());
        let m = make_msg(
            "9008005",
            "3000800a",
            Kind::ContactCard(olaz_wire::ContactCard {
                name: "Card E2EE".to_owned(),
                uid: "9002".to_owned(),
                avatar: Some("https://cdn.example.invalid/c.jpg".to_owned()),
                phone: "+84901234569".to_owned(),
                qr: Some("https://cdn.example.invalid/qr.png".to_owned()),
                oa_link: String::new(),
                is_official_account: false,
            }),
            "[Danh thiếp] Card E2EE",
            Availability::Available,
        );
        let out = reduce(
            &mut state,
            Input::OpRequest {
                op_id: 6,
                cmd: Command::Forward {
                    message: Box::new(m),
                    targets: vec!["3000800b".to_owned()],
                    now_ms: 1_700_000_030_000,
                },
            },
        );
        assert!(matches!(
            out.effects.as_slice(),
            [Effect::AllocClientId { forward_id: 1 }]
        ));

        let out = reduce(
            &mut state,
            Input::ForwardClientIdAllocated {
                forward_id: 1,
                client_id: 8_000_000_000_900,
            },
        );
        assert!(matches!(
            out.effects.as_slice(),
            [Effect::Host(HostCall::SendE2eeContactCard {
                card_send_id: 1,
                conv_id,
                client_id,
                contact_uid,
                title,
                phone,
                avatar,
                qr_code_url,
            })] if conv_id == "3000800b"
                && client_id == "8000000000900"
                && contact_uid == "9002"
                && title == "Card E2EE"
                && phone == "+84901234569"
                && avatar == "https://cdn.example.invalid/c.jpg"
                && qr_code_url == "https://cdn.example.invalid/qr.png"
        ));

        let out = reduce(
            &mut state,
            Input::ContactCardSendDone {
                card_send_id: 1,
                result: Ok(SendMessageResult {
                    msg_id: "8000000000900".to_owned(),
                    cli_msg_id: "8000000000900".to_owned(),
                    ts_ms: 0,
                }),
            },
        );
        let rows = state
            .messages
            .windows
            .get("3000800b")
            .map(Vec::as_slice)
            .unwrap_or(&[]);
        assert_eq!(rows.len(), 1);
        assert!(rows[0].is_e2ee);
        assert_eq!(rows[0].id, "8000000000900");
        assert!(out.effects.iter().any(|e| matches!(
            e,
            Effect::CompleteOp {
                op_id: 6,
                result: OpResult::Forward(ForwardOutcome::Done(Some(t))),
                after_store: true,
            } if t == MSG_FORWARD_DONE
        )));
    }

    #[test]
    fn photo_fallback_and_forward_all_clear_selection_and_request() {
        let mut state = ready_state();
        let p = make_msg(
            "20",
            "3000800a",
            Kind::Photo {
                url: Some("https://cdn.example.invalid/p.jpg".to_owned()),
                width: 100,
                height: 100,
            },
            "[Hình ảnh]",
            Availability::Available,
        );
        let t = make_msg("21", "3000800a", Kind::Text, "ok", Availability::Available);
        let _ = reduce(
            &mut state,
            Input::Command(Command::ForwardSelection {
                messages: vec![p, t],
            }),
        );
        let out = reduce(
            &mut state,
            Input::OpRequest {
                op_id: 9,
                cmd: Command::ForwardAll {
                    targets: vec!["3000800b".to_owned()],
                    now_ms: 1_700_000_030_000,
                },
            },
        );
        assert!(matches!(
            out.effects.as_slice(),
            [Effect::Host(HostCall::ResolveMedia { forward_id: 1, conv_id, msg_id, kind })]
                if conv_id == "3000800a" && msg_id == "20" && kind == "photo"
        ));

        // Resolve unavailable -> falls back to FetchMediaData
        let out = reduce(
            &mut state,
            Input::ForwardMediaResolved {
                forward_id: 1,
                resolution: MediaResolutionOutcome::Unavailable,
            },
        );
        assert!(matches!(
            out.effects.as_slice(),
            [Effect::Host(HostCall::FetchMediaData { forward_id: 1, url })]
                if url == "https://cdn.example.invalid/p.jpg"
        ));

        // Fetch succeeds -> SendMedia with cleanup_after = true
        let out = reduce(
            &mut state,
            Input::ForwardFetchMediaDone {
                forward_id: 1,
                temp_path: Some("/tmp/fwd-1.jpg".to_owned()),
            },
        );
        assert!(matches!(
            out.effects.as_slice(),
            [Effect::Host(HostCall::SendMedia { forward_id: 1, conv_id, paths, cleanup_after: true })]
                if conv_id == "3000800b" && paths == &["/tmp/fwd-1.jpg"]
        ));

        // SendMedia succeeds -> moves to second message (text)
        let out = reduce(
            &mut state,
            Input::ForwardSendMediaDone {
                forward_id: 1,
                outcome: ComposerSendOutcome::Done,
            },
        );
        assert!(matches!(
            out.effects.as_slice(),
            [Effect::AllocClientId { forward_id: 1 }]
        ));

        // Second message fails, but overall outcome stays Done!
        let _ = reduce(
            &mut state,
            Input::ForwardClientIdAllocated {
                forward_id: 1,
                client_id: 8_000_000_000_002,
            },
        );
        let out = reduce(
            &mut state,
            Input::SendTextDone {
                send_id: 1,
                result: Err("boom".to_owned()),
            },
        );
        assert!(state.forward.request.is_none());
        assert!(out.dirty.contains(&DirtyKey::ForwardRequest));
        assert!(out.dirty.contains(&DirtyKey::ForwardClearSelection));
        assert!(out.effects.iter().any(|e| matches!(
            e,
            Effect::Host(HostCall::ShowCard { conv_id: Some(c), text })
                if c == "3000800a" && text == MSG_FORWARD_DONE
        )));
        assert!(out.effects.iter().any(|e| matches!(
            e,
            Effect::CompleteOp {
                op_id: 9,
                result: OpResult::Forward(ForwardOutcome::Done(Some(t))),
                after_store: false,
            } if t == MSG_FORWARD_DONE
        )));
    }
}
