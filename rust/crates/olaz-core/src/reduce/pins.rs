//! Pure board-pins domain reducer (U7).
//!
//! No I/O, no wall clock, and no randomness live here (D9).

use olaz_api::{JsonObject, pin_topic_params};
use olaz_wire::{ChatMessage, is_group_id, sanitize_profile_uid, strip_user_prefix};
use serde_json::Value;

use crate::actions::{MessageConfirmAction, MessageConfirmState, PendingIdResolution};
use crate::changes::DirtyKey;
use crate::conversations::message_preview_label;
use crate::effect::{Effect, HostCall, OpResult, StoreOp};
use crate::input::{Command, Input};
use crate::messages::decode_db_stored;
use crate::pins::{
    DEFAULT_PIN_LIMIT, InFlightPin, InFlightUnpin, PIN_FAILED_CARD_TEXT, PinLimitDecision,
    PinnedItem, PinnedList, RefreshBoardFollowup, UNPIN_FAILED_CARD_TEXT, UnpinBoardPurpose,
    is_pinned, parse_board_topics,
};
use crate::reduce::ReduceOutput;
use crate::state::CoreState;

/// Pure transition function for all U7 board-pin commands and completions.
pub fn reduce_pins(state: &mut CoreState, input: Input, out: &mut ReduceOutput) {
    match input {
        Input::Command(cmd) => reduce_command(state, cmd, None, out),
        Input::OpRequest { op_id, cmd } => reduce_command(state, cmd, Some(op_id), out),
        Input::BoardPinsFetched {
            conv_id,
            req_gen,
            result,
            followup,
        } => handle_board_pins_fetched(state, conv_id, req_gen, result, followup, out),
        Input::BoardPinsFetchSkipped { followup, .. } => {
            finish_refresh_followup(state, followup, out);
        }
        Input::UnpinBoardTopicDone { purpose, error } => {
            handle_unpin_board_topic_done(state, purpose, error, out);
        }
        Input::PinBoardMessageDone { pin_op_id, error } => {
            handle_pin_board_message_done(state, pin_op_id, error, out);
        }
        Input::PinTopicApproved { conv_id } => {
            handle_pin_topic_event(state, conv_id, None, out);
        }
        Input::PinnedMessageLookupDone {
            conv_id,
            row,
            op_id,
        } => {
            let Some(stored) = row else {
                complete_opt_string(op_id, None, out);
                return;
            };
            let Some(msg) = decode_db_stored(&stored) else {
                complete_opt_string(op_id, None, out);
                return;
            };
            // U14: temporary host boundary calling existing `ensureMessageLoaded` until U14 lands on main.
            out.effects
                .push(Effect::Host(HostCall::EnsureMessageLoaded {
                    conv_id,
                    message: Box::new(msg),
                    op_id,
                }));
        }
        Input::PinnedEnsureMessageLoadedDone {
            msg_id,
            loaded,
            op_id,
        } => {
            complete_opt_string(op_id, loaded.then_some(msg_id), out);
        }
        _ => {}
    }
}

fn reduce_command(state: &mut CoreState, cmd: Command, op_id: Option<u64>, out: &mut ReduceOutput) {
    match cmd {
        Command::RefreshBoardPins { conv_id } => {
            if conv_id.is_empty() {
                complete_unit(op_id, out);
                return;
            }
            let req_gen = state.pins.current_gen(&conv_id);
            out.effects.push(Effect::RefreshBoardPins {
                conv_id,
                req_gen,
                followup: RefreshBoardFollowup::Standalone { op_id },
            });
        }
        Command::RewatchPins => {
            let Some(conv_id) = state.conversations.open_conversation_id.clone() else {
                complete_unit(op_id, out);
                return;
            };
            let req_gen = state.pins.current_gen(&conv_id);
            out.effects.push(Effect::RefreshBoardPins {
                conv_id,
                req_gen,
                followup: RefreshBoardFollowup::Standalone { op_id },
            });
        }
        Command::PinMessage { conv_id, msg_id } => {
            handle_pin_message(state, &conv_id, &msg_id, op_id, out);
        }
        Command::Pin {
            conv_id,
            msg_id,
            replacing,
        } => {
            start_pin(state, &conv_id, &msg_id, replacing, op_id, out);
        }
        Command::RequestUnpin { conv_id, topic_ref } => {
            if let Some(item) = state
                .pins
                .lists
                .get(&conv_id)
                .and_then(|l| l.items.iter().find(|it| it.ref_id == topic_ref))
                .cloned()
            {
                request_unpin_item(state, &item, &conv_id, out);
            }
            complete_unit(op_id, out);
        }
        Command::RequestUnpinMessage { conv_id, msg_id } => {
            if let Some(msg) = find_message(state, &conv_id, &msg_id)
                && let Some(item) = state
                    .pins
                    .lists
                    .get(&conv_id)
                    .and_then(|l| l.items.iter().find(|it| it.matches_message(&msg)))
                    .cloned()
            {
                request_unpin_item(state, &item, &conv_id, out);
            }
            complete_unit(op_id, out);
        }
        Command::Unpin { conv_id, topic_ref } => {
            start_unpin(state, &conv_id, &topic_ref, op_id, out);
        }
        Command::HandlePinsState { state_json } => {
            handle_pins_state(state, &state_json, out);
            complete_unit(op_id, out);
        }
        Command::HandlePinTopicEvent { conv_id } => {
            handle_pin_topic_event(state, conv_id, op_id, out);
        }
        Command::LoadPinnedMessage { conv_id, topic_ref } => {
            handle_load_pinned_message(state, &conv_id, &topic_ref, op_id, out);
        }
        Command::SeedPins { lists, raw_topics } => {
            let mut changed = false;
            for (conv_id, list) in lists {
                if state.pins.lists.get(&conv_id) != Some(&list) {
                    state.pins.lists.insert(conv_id.clone(), list);
                    state.pins.bump_gen(&conv_id);
                    changed = true;
                }
            }
            for (conv_id, raw) in raw_topics {
                if state.pins.raw_topics.get(&conv_id) != Some(&raw) {
                    state.pins.raw_topics.insert(conv_id.clone(), raw);
                    changed = true;
                }
            }
            if changed {
                out.dirty.insert(DirtyKey::Pins);
            }
            complete_unit(op_id, out);
        }
        _ => {}
    }
}

fn handle_pin_message(
    state: &mut CoreState,
    conv_id: &str,
    msg_id: &str,
    op_id: Option<u64>,
    out: &mut ReduceOutput,
) {
    let Some(msg) = find_message(state, conv_id, msg_id) else {
        complete_unit(op_id, out);
        return;
    };
    if is_pinned(&state.pins.lists, &msg) {
        complete_unit(op_id, out);
        return;
    }
    let (count, limit, oldest) = match state.pins.lists.get(conv_id) {
        Some(list) => (list.items.len(), list.limit, list.items.last().cloned()),
        None => (0, DEFAULT_PIN_LIMIT, None),
    };
    match PinLimitDecision::decide(count, limit) {
        PinLimitDecision::Allowed => {
            start_pin(state, conv_id, &msg.id, None, op_id, out);
        }
        PinLimitDecision::ReplaceOldest => {
            if let Some(oldest) = oldest
                && state.conversations.open_conversation_id.as_deref() == Some(conv_id)
                && state.actions.message_confirm.is_none()
            {
                let what = if oldest.title.is_empty() {
                    oldest.label().to_owned()
                } else {
                    format!("{}: {}", oldest.label(), oldest.title)
                };
                let confirm_id = state.actions.next_id();
                state.actions.message_confirm = Some(MessageConfirmState {
                    id: confirm_id,
                    conv_id: conv_id.to_owned(),
                    action: MessageConfirmAction::Pin {
                        msg_id: msg.id,
                        replacing_ref: Some(oldest.ref_id),
                    },
                    title: "Cập nhật danh sách ghim".to_owned(),
                    message: format!(
                        "Đã đạt giới hạn {limit} ghim. Ghim cũ dưới đây sẽ được bỏ để cập nhật nội dung mới.\n{what}"
                    ),
                    ok: "Xác nhận".to_owned(),
                    destructive: false,
                });
                out.dirty.insert(DirtyKey::MessageConfirm);
            }
            complete_unit(op_id, out);
        }
        PinLimitDecision::ChooseMany { need } => {
            out.effects.push(Effect::Host(HostCall::ShowCard {
                conv_id: conv_id.to_owned(),
                text: format!(
                    "Đã đạt giới hạn {limit} ghim. Vui lòng chọn ít nhất {need} ghim cần bỏ để cập nhật ghim mới."
                ),
            }));
            complete_unit(op_id, out);
        }
    }
}

/// Starts pinning `msg_id` in `conv_id` (optionally replacing `replacing` first).
/// Also called from `actions.rs` when `AnswerMessageConfirm { ok: true }` accepts `Pin`.
pub(crate) fn start_pin(
    state: &mut CoreState,
    conv_id: &str,
    msg_id: &str,
    replacing: Option<String>,
    op_id: Option<u64>,
    out: &mut ReduceOutput,
) {
    let Some(msg) = find_message(state, conv_id, msg_id) else {
        complete_unit(op_id, out);
        return;
    };
    let busy_key = format!("{conv_id}|{}|pin", msg.id);
    if !state.pins.busy.insert(busy_key.clone()) {
        complete_unit(op_id, out);
        return;
    }

    // Optimistic insert (matches Swift `insertPinOptimistically`).
    let preview_title = preview_label_for_message(&msg);
    let sender = if msg.is_mine {
        "Bạn".to_owned()
    } else {
        lookup_person_name(state, &msg.sender_id).unwrap_or_default()
    };
    if let Some(list) = state.pins.lists.get_mut(conv_id) {
        if let Some(ref rep) = replacing {
            list.items.retain(|it| it.ref_id != *rep);
        }
        list.items.insert(
            0,
            PinnedItem {
                ref_id: format!("local:{}", msg.id),
                kind: "message".to_owned(),
                title: preview_title,
                sender,
                thumbnail: None,
                msg_id: msg.id.clone(),
                cli_msg_id: msg.id.clone(),
            },
        );
        state.pins.bump_gen(conv_id);
        out.dirty.insert(DirtyKey::Pins);
    }

    let pin_op_id = state.pins.alloc_op_seq();
    let replacing_non_empty = replacing
        .as_deref()
        .filter(|r| !r.is_empty())
        .map(str::to_owned);
    let msg_for_resolve = msg.clone();
    state.pins.in_flight_pins.insert(
        pin_op_id,
        InFlightPin {
            conv_id: conv_id.to_owned(),
            msg,
            replacing,
            busy_key,
            op_id,
        },
    );

    if let Some(ref_id) = replacing_non_empty {
        let (raw_topic, board_version) = snapshot_raw_topic(state, conv_id, &ref_id);
        out.effects.push(Effect::UnpinBoardTopicApi {
            conv_id: conv_id.to_owned(),
            topic_id: ref_id,
            raw_topic,
            board_version,
            purpose: UnpinBoardPurpose::PinReplace { pin_op_id },
        });
    } else {
        dispatch_pin_id_resolution(state, pin_op_id, conv_id, &msg_for_resolve, out);
    }
}

fn dispatch_pin_id_resolution(
    state: &mut CoreState,
    pin_op_id: u64,
    conv_id: &str,
    msg: &ChatMessage,
    out: &mut ReduceOutput,
) {
    let resolve_id = state.actions.next_id();
    state.actions.pending_id_resolutions.insert(
        resolve_id,
        PendingIdResolution::Pin {
            conv_id: conv_id.to_owned(),
            initial_msg_id: msg.id.clone(),
            pin_op_id,
        },
    );
    out.effects.push(Effect::ResolveMessageIds {
        resolve_id,
        conv_id: conv_id.to_owned(),
        msg_id: msg.id.clone(),
        cli_msg_id: msg.client_id.clone(),
    });
}

/// Called from `actions.rs` when `Effect::ResolveMessageIds` completes for a pending pin.
pub(crate) fn on_pin_ids_resolved(
    state: &mut CoreState,
    pin_op_id: u64,
    effective_msg_id: String,
    resolved_cli_id: String,
    out: &mut ReduceOutput,
) {
    let Some(in_flight) = state.pins.in_flight_pins.get(&pin_op_id).cloned() else {
        return;
    };
    let me = state
        .session
        .profile
        .as_ref()
        .map_or("", |p| p.user_id.as_str());
    let sender_uid = if in_flight.msg.is_mine
        || in_flight.msg.sender_id.is_empty()
        || in_flight.msg.sender_id == "0"
    {
        me.to_owned()
    } else {
        in_flight.msg.sender_id.clone()
    };
    let sender_name = if in_flight.msg.is_mine {
        state
            .session
            .profile
            .as_ref()
            .map_or("", |p| p.display_name.as_str())
            .to_owned()
    } else {
        lookup_person_name(state, &in_flight.msg.sender_id)
            .unwrap_or_else(|| in_flight.msg.sender_name.clone())
    };
    let cli_for_params = if resolved_cli_id.is_empty() {
        effective_msg_id.as_str()
    } else {
        resolved_cli_id.as_str()
    };
    let params = pin_topic_params(
        &effective_msg_id,
        cli_for_params,
        &sender_uid,
        &sender_name,
        &in_flight.msg.kind,
        &in_flight.msg.text,
    );
    let board_version = state
        .pins
        .raw_topics
        .get(&in_flight.conv_id)
        .map_or(0, |r| r.version);
    out.effects.push(Effect::PinBoardMessageApi {
        pin_op_id,
        conv_id: in_flight.conv_id,
        params,
        board_version,
    });
}

fn request_unpin_item(
    state: &mut CoreState,
    item: &PinnedItem,
    conv_id: &str,
    out: &mut ReduceOutput,
) {
    if state.conversations.open_conversation_id.as_deref() != Some(conv_id)
        || state.actions.message_confirm.is_some()
    {
        return;
    }
    let is_msg = item.kind == "message";
    let confirm_id = state.actions.next_id();
    state.actions.message_confirm = Some(MessageConfirmState {
        id: confirm_id,
        conv_id: conv_id.to_owned(),
        action: MessageConfirmAction::Unpin {
            topic_ref: item.ref_id.clone(),
        },
        title: if is_msg {
            "Bỏ ghim tin nhắn".to_owned()
        } else {
            "Bỏ ghim".to_owned()
        },
        message: if is_msg {
            "Bạn muốn bỏ ghim tin nhắn?".to_owned()
        } else {
            "Bạn muốn bỏ ghim nội dung này?".to_owned()
        },
        ok: "Bỏ ghim".to_owned(),
        destructive: true,
    });
    out.dirty.insert(DirtyKey::MessageConfirm);
}

/// Starts unpinning `topic_ref` in `conv_id`.
/// Also called from `actions.rs` when `AnswerMessageConfirm { ok: true }` accepts `Unpin`.
pub(crate) fn start_unpin(
    state: &mut CoreState,
    conv_id: &str,
    topic_ref: &str,
    op_id: Option<u64>,
    out: &mut ReduceOutput,
) {
    let busy_key = format!("{conv_id}|{topic_ref}|unpin");
    if !state.pins.busy.insert(busy_key.clone()) {
        complete_unit(op_id, out);
        return;
    }
    let (raw_topic, board_version) = snapshot_raw_topic(state, conv_id, topic_ref);
    if let Some(list) = state.pins.lists.get_mut(conv_id) {
        let before = list.items.len();
        list.items.retain(|it| it.ref_id != topic_ref);
        if list.items.len() != before {
            state.pins.bump_gen(conv_id);
            out.dirty.insert(DirtyKey::Pins);
        }
    }
    let unpin_op_id = state.pins.alloc_op_seq();
    state.pins.in_flight_unpins.insert(
        unpin_op_id,
        InFlightUnpin {
            conv_id: conv_id.to_owned(),
            busy_key,
            op_id,
        },
    );
    out.effects.push(Effect::UnpinBoardTopicApi {
        conv_id: conv_id.to_owned(),
        topic_id: topic_ref.to_owned(),
        raw_topic,
        board_version,
        purpose: UnpinBoardPurpose::Unpin { unpin_op_id },
    });
}

fn handle_unpin_board_topic_done(
    state: &mut CoreState,
    purpose: UnpinBoardPurpose,
    error: Option<String>,
    out: &mut ReduceOutput,
) {
    match purpose {
        UnpinBoardPurpose::PinReplace { pin_op_id } => {
            let Some(in_flight) = state.pins.in_flight_pins.get(&pin_op_id).cloned() else {
                return;
            };
            let req_gen = state.pins.current_gen(&in_flight.conv_id);
            if let Some(err_shape) = error {
                out.effects.push(Effect::EngineLog(format!(
                    "pins: pin failed group={} replacing={} {err_shape}",
                    is_group_id(&in_flight.conv_id),
                    in_flight.replacing.is_some()
                )));
                out.effects.push(Effect::RefreshBoardPins {
                    conv_id: in_flight.conv_id,
                    req_gen,
                    followup: RefreshBoardFollowup::PinFailed { pin_op_id },
                });
            } else {
                out.effects.push(Effect::RefreshBoardPins {
                    conv_id: in_flight.conv_id,
                    req_gen,
                    followup: RefreshBoardFollowup::PinReplaceAfterUnpin { pin_op_id },
                });
            }
        }
        UnpinBoardPurpose::Unpin { unpin_op_id } => {
            let Some(in_flight) = state.pins.in_flight_unpins.get(&unpin_op_id).cloned() else {
                return;
            };
            let req_gen = state.pins.current_gen(&in_flight.conv_id);
            let followup = if error.is_some() {
                RefreshBoardFollowup::UnpinFailed { unpin_op_id }
            } else {
                RefreshBoardFollowup::UnpinSucceeded { unpin_op_id }
            };
            out.effects.push(Effect::RefreshBoardPins {
                conv_id: in_flight.conv_id,
                req_gen,
                followup,
            });
        }
    }
}

fn handle_pin_board_message_done(
    state: &mut CoreState,
    pin_op_id: u64,
    error: Option<String>,
    out: &mut ReduceOutput,
) {
    let Some(in_flight) = state.pins.in_flight_pins.get(&pin_op_id).cloned() else {
        return;
    };
    let req_gen = state.pins.current_gen(&in_flight.conv_id);
    if let Some(err_shape) = error {
        out.effects.push(Effect::EngineLog(format!(
            "pins: pin failed group={} replacing={} {err_shape}",
            is_group_id(&in_flight.conv_id),
            in_flight.replacing.is_some()
        )));
        out.effects.push(Effect::RefreshBoardPins {
            conv_id: in_flight.conv_id,
            req_gen,
            followup: RefreshBoardFollowup::PinFailed { pin_op_id },
        });
    } else {
        out.effects.push(Effect::RefreshBoardPins {
            conv_id: in_flight.conv_id,
            req_gen,
            followup: RefreshBoardFollowup::PinSucceeded { pin_op_id },
        });
    }
}

fn handle_board_pins_fetched(
    state: &mut CoreState,
    conv_id: String,
    req_gen: u64,
    result: Result<JsonObject, String>,
    followup: RefreshBoardFollowup,
    out: &mut ReduceOutput,
) {
    let group = is_group_id(&conv_id);
    match result {
        Ok(box_obj) => {
            let parsed = parse_board_topics(&box_obj, |uid| lookup_person_name(state, uid));
            out.effects.push(Effect::EngineLog(format!(
                "pins: list ok group={group} rows={} items={}",
                parsed.raw_rows_count,
                parsed.list.items.len()
            )));
            if req_gen >= state.pins.current_gen(&conv_id) {
                let raw_changed = state.pins.raw_topics.get(&conv_id) != Some(&parsed.raw_topics);
                state
                    .pins
                    .raw_topics
                    .insert(conv_id.clone(), parsed.raw_topics);
                let list_changed = state.pins.lists.get(&conv_id) != Some(&parsed.list);
                if list_changed {
                    state.pins.lists.insert(conv_id, parsed.list);
                }
                if list_changed || raw_changed {
                    out.dirty.insert(DirtyKey::Pins);
                }
            }
        }
        Err(err_shape) => {
            out.effects.push(Effect::EngineLog(format!(
                "pins: list failed group={group} {err_shape}"
            )));
        }
    }
    finish_refresh_followup(state, followup, out);
}

fn finish_refresh_followup(
    state: &mut CoreState,
    followup: RefreshBoardFollowup,
    out: &mut ReduceOutput,
) {
    match followup {
        RefreshBoardFollowup::Standalone { op_id } => {
            complete_unit(op_id, out);
        }
        RefreshBoardFollowup::OpenConversation {
            conv_id,
            seen_target,
            op_id,
        } => {
            out.effects.push(Effect::Host(HostCall::MarkReadBoundary {
                conv_id,
                seen_target,
            }));
            if let Some(id) = op_id {
                out.effects.push(Effect::CompleteOp {
                    op_id: id,
                    result: OpResult::Unit,
                    after_store: true,
                });
            }
        }
        RefreshBoardFollowup::PinReplaceAfterUnpin { pin_op_id } => {
            if let Some(in_flight) = state.pins.in_flight_pins.get(&pin_op_id).cloned() {
                dispatch_pin_id_resolution(
                    state,
                    pin_op_id,
                    &in_flight.conv_id,
                    &in_flight.msg,
                    out,
                );
            }
        }
        RefreshBoardFollowup::PinSucceeded { pin_op_id } => {
            if let Some(in_flight) = state.pins.in_flight_pins.remove(&pin_op_id) {
                state.pins.busy.remove(&in_flight.busy_key);
                complete_unit(in_flight.op_id, out);
            }
        }
        RefreshBoardFollowup::PinFailed { pin_op_id } => {
            if let Some(in_flight) = state.pins.in_flight_pins.remove(&pin_op_id) {
                state.pins.busy.remove(&in_flight.busy_key);
                out.effects.push(Effect::Host(HostCall::ShowCard {
                    conv_id: in_flight.conv_id,
                    text: PIN_FAILED_CARD_TEXT.to_owned(),
                }));
                complete_unit(in_flight.op_id, out);
            }
        }
        RefreshBoardFollowup::UnpinSucceeded { unpin_op_id } => {
            if let Some(in_flight) = state.pins.in_flight_unpins.remove(&unpin_op_id) {
                state.pins.busy.remove(&in_flight.busy_key);
                complete_unit(in_flight.op_id, out);
            }
        }
        RefreshBoardFollowup::UnpinFailed { unpin_op_id } => {
            if let Some(in_flight) = state.pins.in_flight_unpins.remove(&unpin_op_id) {
                state.pins.busy.remove(&in_flight.busy_key);
                out.effects.push(Effect::Host(HostCall::ShowCard {
                    conv_id: in_flight.conv_id,
                    text: UNPIN_FAILED_CARD_TEXT.to_owned(),
                }));
                complete_unit(in_flight.op_id, out);
            }
        }
    }
}

fn handle_pins_state(state: &mut CoreState, state_json: &JsonObject, out: &mut ReduceOutput) {
    let Some(pins_obj) = state_json.get("pins").and_then(Value::as_object) else {
        return;
    };
    let conv_id = pins_obj.get("convId").and_then(Value::as_str).unwrap_or("");
    if conv_id.is_empty() {
        return;
    }
    let list = PinnedList::from_json(pins_obj);
    if state.pins.lists.get(conv_id) != Some(&list) {
        state.pins.lists.insert(conv_id.to_owned(), list);
        state.pins.bump_gen(conv_id);
        out.dirty.insert(DirtyKey::Pins);
    }
}

fn handle_pin_topic_event(
    state: &mut CoreState,
    conv_id: String,
    op_id: Option<u64>,
    out: &mut ReduceOutput,
) {
    let is_open = state.conversations.open_conversation_id.as_deref() == Some(conv_id.as_str());
    out.effects.push(Effect::EngineLog(format!(
        "pins: event group={} open={is_open}",
        is_group_id(&conv_id)
    )));
    if is_open {
        let req_gen = state.pins.current_gen(&conv_id);
        out.effects.push(Effect::RefreshBoardPins {
            conv_id,
            req_gen,
            followup: RefreshBoardFollowup::Standalone { op_id },
        });
    } else {
        if state.pins.lists.remove(&conv_id).is_some() {
            state.pins.bump_gen(&conv_id);
            out.dirty.insert(DirtyKey::Pins);
        }
        complete_unit(op_id, out);
    }
}

fn handle_load_pinned_message(
    state: &CoreState,
    conv_id: &str,
    topic_ref: &str,
    op_id: Option<u64>,
    out: &mut ReduceOutput,
) {
    let Some(item) = state
        .pins
        .lists
        .get(conv_id)
        .and_then(|l| l.items.iter().find(|it| it.ref_id == topic_ref))
    else {
        complete_opt_string(op_id, None, out);
        return;
    };
    let window = state
        .messages
        .windows
        .get(conv_id)
        .map_or(&[][..], Vec::as_slice);
    if let Some(loaded) = item.find_message(window) {
        complete_opt_string(op_id, Some(loaded.id.clone()), out);
        return;
    }
    if item.kind != "message" {
        complete_opt_string(op_id, None, out);
        return;
    }
    let keys: Vec<String> = [item.msg_id.as_str(), item.cli_msg_id.as_str()]
        .into_iter()
        .filter(|k| !k.is_empty())
        .map(str::to_owned)
        .collect();
    if keys.is_empty() {
        complete_opt_string(op_id, None, out);
        return;
    }
    out.effects
        .push(Effect::Store(StoreOp::LookupPinnedMessage {
            conv_id: conv_id.to_owned(),
            keys,
            op_id,
        }));
}

fn find_message(state: &CoreState, conv_id: &str, msg_id: &str) -> Option<ChatMessage> {
    state.messages.windows.get(conv_id).and_then(|list| {
        list.iter()
            .find(|m| m.id == msg_id || (!m.client_id.is_empty() && m.client_id == msg_id))
            .cloned()
    })
}

fn snapshot_raw_topic(
    state: &CoreState,
    conv_id: &str,
    topic_ref: &str,
) -> (Option<JsonObject>, i64) {
    match state.pins.raw_topics.get(conv_id) {
        Some(raw) => (raw.topics.get(topic_ref).cloned(), raw.version),
        None => (None, 0),
    }
}

fn preview_label_for_message(msg: &ChatMessage) -> String {
    message_preview_label(msg)
}

/// Resolves a person's display name matching `ZaloEngine.lookupPersonInfo(_:)?.name`,
/// checking `IdentitySnapshot` (self, aliases, identity friends, conversations, cached profiles)
/// and falling back to `state.contacts.friends`.
fn lookup_person_name(state: &CoreState, uid: &str) -> Option<String> {
    if let Some(found) = state.identity_snapshot().lookup_person(uid)
        && !found.name.is_empty()
    {
        return Some(found.name);
    }
    let clean = strip_user_prefix(uid);
    if matches!(clean.as_str(), "" | "0" | "-1" | "__legacy__" | "unknown") {
        return None;
    }
    let mut candidates = vec![clean.clone()];
    if let Some(sanitized) = sanitize_profile_uid(&clean)
        && sanitized != clean
    {
        candidates.push(sanitized);
    }
    for cand in &candidates {
        if let Some(friend) = state.contacts.friends.iter().find(|f| f.id == *cand) {
            if let Some(alias) = state.conversations.identities.aliases.get(cand)
                && !alias.is_empty()
            {
                return Some(alias.clone());
            }
            if !friend.name.is_empty() {
                return Some(friend.name.clone());
            }
        }
    }
    None
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

fn complete_opt_string(op_id: Option<u64>, val: Option<String>, out: &mut ReduceOutput) {
    if let Some(id) = op_id {
        out.effects.push(Effect::CompleteOp {
            op_id: id,
            result: OpResult::OptString(val),
            after_store: false,
        });
    }
}
