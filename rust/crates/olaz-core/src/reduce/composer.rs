//! Pure reducer for U13 composer side actions: own contact card, reminders, confirm queue,
//! and outcome reporting.
//!
//! Exposes a shared [`start_contact_card_send`] helper so both `send_my_card` (U13) and
//! contact-card forwarding (U8) route through one plain-vs-E2EE path.

use std::time::Duration;

use olaz_api::{CreateReminderParams, SendContactCardParams};
use olaz_wire::{
    Availability, ChatMessage, ContactCard, DeleteMode, Kind, MessageMenu, StarMode, Status,
    encode_chat_message, is_group_id,
};

use crate::changes::DirtyKey;
use crate::composer::{
    COMPOSER_GENERIC_FAILURE, CONFIRM_PROMOTE_DELAY_MS, ComposerOutcome, ContactCardContinuation,
    ContactCardSendSpec, MyCardInfo, NOT_LOGGED_IN_FAILURE, PendingContactCard,
    REMINDER_API_FAILURE, REMINDER_TITLE_MAX_BYTES, REMINDER_TITLE_MAX_CHARS,
    REMINDER_TOO_LONG_FAILURE, ReminderComposeInfo,
};
use crate::effect::{Effect, HostCall, OpResult, StoreOp};
use crate::input::{Command, Input};
use crate::messages::{WindowChange, is_valid_url_str, to_db_stored};
use crate::reduce::ReduceOutput;
use crate::reduce::send::update_conversation_after_send;
use crate::state::CoreState;

fn complete_op(op_id: Option<u64>, result: OpResult, after_store: bool, out: &mut ReduceOutput) {
    if let Some(op_id) = op_id {
        out.effects.push(Effect::CompleteOp {
            op_id,
            result,
            after_store,
        });
    }
}

/// Shared contact-card send entry point (plain `POST /api/message/contact` vs E2EE 1-1
/// `HostCall::SendE2eeContactCard`). Used by `send_my_card` (U13) and contact-card forward (U8).
pub(crate) fn start_contact_card_send(
    state: &mut CoreState,
    spec: ContactCardSendSpec,
    on_done: ContactCardContinuation,
    out: &mut ReduceOutput,
) -> u64 {
    let is_e2ee = !is_group_id(&spec.conv_id)
        && spec
            .is_e2ee_override
            .unwrap_or_else(|| state.send.e2ee_threads.contains(&spec.conv_id));
    let card_send_id = state.composer.alloc_card_send_id();
    let pending = PendingContactCard {
        spec: spec.clone(),
        is_e2ee,
        on_done,
    };
    state
        .composer
        .in_flight_contact_cards
        .insert(card_send_id, pending);

    if is_e2ee {
        out.effects
            .push(Effect::Host(HostCall::SendE2eeContactCard {
                card_send_id,
                conv_id: spec.conv_id,
                client_id: spec.client_id.map_or_else(String::new, |id| id.to_string()),
                contact_uid: spec.contact_uid,
                title: spec.title,
                phone: spec.phone.unwrap_or_default(),
                avatar: spec.avatar.unwrap_or_default(),
                qr_code_url: spec.qr_code_url,
            }));
    } else {
        out.effects.push(Effect::SendContactCardApi {
            card_send_id,
            params: SendContactCardParams {
                conv_id: spec.conv_id,
                card_uid: spec.contact_uid,
                phone: spec.phone,
                client_id: spec.client_id,
            },
        });
    }
    card_send_id
}

/// Resets composer state on logout / session expiry / explicit `reset_composer`.
pub(crate) fn reset_composer(
    state: &mut CoreState,
    emit_cancel_effect: bool,
    out: &mut ReduceOutput,
) {
    state.composer.bump_confirm_timer_gen();
    let changed = state.composer.active_confirm.take().is_some()
        || !state.composer.queued_confirms.is_empty();
    state.composer.queued_confirms.clear();
    if emit_cancel_effect {
        out.effects.push(Effect::CancelConfirmPromoteDelay);
    }
    if changed {
        out.dirty.insert(DirtyKey::ComposerConfirm);
    }
    let pending = std::mem::take(&mut state.composer.in_flight_contact_cards);
    for (_, item) in pending {
        match item.on_done {
            ContactCardContinuation::SendMyCard { op_id } => {
                complete_op(
                    op_id,
                    OpResult::ComposerOutcome(ComposerOutcome::Failed(
                        COMPOSER_GENERIC_FAILURE.to_owned(),
                    )),
                    false,
                    out,
                );
            }
            ContactCardContinuation::Forward { forward_id } => {
                if emit_cancel_effect {
                    crate::reduce::forward::on_contact_card_done(
                        state,
                        forward_id,
                        item.is_e2ee,
                        Err(COMPOSER_GENERIC_FAILURE.to_owned()),
                        out,
                    );
                }
            }
        }
    }
}

/// Reduces a U13 composer [`Input`].
pub(crate) fn reduce_composer(state: &mut CoreState, input: Input, out: &mut ReduceOutput) {
    match input {
        Input::Command(cmd) => reduce_command(state, cmd, None, out),
        Input::OpRequest { op_id, cmd } => reduce_command(state, cmd, Some(op_id), out),
        Input::ContactCardSendDone {
            card_send_id,
            result,
        } => reduce_contact_card_done(state, card_send_id, result, out),
        Input::CreateReminderDone { op_id, ok } => {
            let outcome = if ok {
                ComposerOutcome::Done
            } else {
                ComposerOutcome::Failed(REMINDER_API_FAILURE.to_owned())
            };
            complete_op(op_id, OpResult::ComposerOutcome(outcome), false, out);
        }
        Input::ConfirmPromoteExpired { confirm_gen } => {
            if state.composer.confirm_timer_gen == confirm_gen
                && state.composer.active_confirm.is_none()
                && let Some(next) = state.composer.queued_confirms.pop_front()
            {
                state.composer.active_confirm = Some(next);
                out.dirty.insert(DirtyKey::ComposerConfirm);
            }
        }
        _ => {}
    }
}

fn reduce_command(state: &mut CoreState, cmd: Command, op_id: Option<u64>, out: &mut ReduceOutput) {
    match cmd {
        Command::MyCard => {
            let info = state.session.profile.as_ref().map(|p| {
                let phone = p.phone.clone().unwrap_or_default();
                let with_phone = !phone.is_empty();
                MyCardInfo {
                    uid: p.user_id.clone(),
                    name: p.display_name.clone(),
                    avatar: p.avatar.clone().filter(|s| !s.is_empty()),
                    phone,
                    with_phone,
                }
            });
            complete_op(op_id, OpResult::MyCard(info), false, out);
        }
        Command::SendMyCard {
            conv_id,
            with_phone,
            client_id,
            now_ms,
            is_e2ee,
        } => {
            let Some(profile) = state.session.profile.clone() else {
                complete_op(
                    op_id,
                    OpResult::ComposerOutcome(ComposerOutcome::Failed(
                        NOT_LOGGED_IN_FAILURE.to_owned(),
                    )),
                    false,
                    out,
                );
                return;
            };
            let phone = if with_phone {
                profile.phone.filter(|s| !s.is_empty())
            } else {
                None
            };
            let spec = ContactCardSendSpec {
                conv_id,
                contact_uid: profile.user_id,
                title: profile.display_name,
                avatar: profile.avatar.filter(|s| !s.is_empty()),
                phone,
                qr_code_url: String::new(),
                client_id,
                now_ms,
                is_e2ee_override: is_e2ee,
            };
            let _ = start_contact_card_send(
                state,
                spec,
                ContactCardContinuation::SendMyCard { op_id },
                out,
            );
        }
        Command::ReminderComposeInfo { conv_id } => {
            let is_group = is_group_id(&conv_id);
            let allowed = state.session.self_conversation_id.as_deref() != Some(conv_id.as_str());
            let info = ReminderComposeInfo {
                allowed,
                hidden: false,
                text: String::new(),
                is_group,
                can_pin: is_group,
                pin_toggle: is_group,
                title_max_chars: REMINDER_TITLE_MAX_CHARS,
                title_max_bytes: REMINDER_TITLE_MAX_BYTES,
            };
            complete_op(op_id, OpResult::ReminderComposeInfo(Some(info)), false, out);
        }
        Command::CreateReminder {
            conv_id,
            title,
            start_ms,
            repeat_mode,
            pin,
        } => {
            // Approved fix 2 (user-decisions item 13.2): enforce official title limits before HTTP.
            if ReminderComposeInfo::is_title_too_long_default(&title) {
                complete_op(
                    op_id,
                    OpResult::ComposerOutcome(ComposerOutcome::Failed(
                        REMINDER_TOO_LONG_FAILURE.to_owned(),
                    )),
                    false,
                    out,
                );
                return;
            }
            out.effects.push(Effect::CreateReminderApi {
                op_id,
                params: CreateReminderParams {
                    conv_id,
                    title,
                    start_time_ms: start_ms,
                    repeat_mode,
                    pin,
                },
            });
        }
        Command::AnswerComposerConfirm { confirm_id, ok: _ } => {
            let matches_active = state
                .composer
                .active_confirm
                .as_ref()
                .is_some_and(|c| c.id == confirm_id);
            if matches_active {
                state.composer.active_confirm = None;
                out.dirty.insert(DirtyKey::ComposerConfirm);
                if !state.composer.queued_confirms.is_empty() {
                    let confirm_gen = state.composer.bump_confirm_timer_gen();
                    out.effects.push(Effect::StartConfirmPromoteDelay {
                        confirm_gen,
                        delay: Duration::from_millis(CONFIRM_PROMOTE_DELAY_MS),
                    });
                }
            }
            complete_op(op_id, OpResult::Unit, false, out);
        }
        Command::DropComposerConfirms => {
            state.composer.bump_confirm_timer_gen();
            let changed = state.composer.active_confirm.take().is_some()
                || !state.composer.queued_confirms.is_empty();
            state.composer.queued_confirms.clear();
            out.effects.push(Effect::CancelConfirmPromoteDelay);
            if changed {
                out.dirty.insert(DirtyKey::ComposerConfirm);
            }
            complete_op(op_id, OpResult::Unit, false, out);
        }
        Command::SeedComposerConfirms { active, queued } => {
            state.composer.bump_confirm_timer_gen();
            out.effects.push(Effect::CancelConfirmPromoteDelay);
            state.composer.active_confirm = active;
            state.composer.queued_confirms = queued.into();
            out.dirty.insert(DirtyKey::ComposerConfirm);
            complete_op(op_id, OpResult::Unit, false, out);
        }
        Command::ComposerReport { conv_id, outcome } => {
            match outcome {
                ComposerOutcome::Failed(text) | ComposerOutcome::Pending(text) => {
                    out.effects.push(Effect::Host(HostCall::ShowCard {
                        conv_id: Some(conv_id),
                        text,
                    }));
                }
                ComposerOutcome::Done | ComposerOutcome::Cancelled => {}
            }
            complete_op(op_id, OpResult::Unit, false, out);
        }
        Command::ResetComposer => {
            reset_composer(state, true, out);
            complete_op(op_id, OpResult::Unit, false, out);
        }
        _ => {}
    }
}

fn reduce_contact_card_done(
    state: &mut CoreState,
    card_send_id: u64,
    result: Result<olaz_api::SendMessageResult, String>,
    out: &mut ReduceOutput,
) {
    let Some(pending) = state.composer.in_flight_contact_cards.remove(&card_send_id) else {
        return;
    };

    match pending.on_done {
        ContactCardContinuation::SendMyCard { op_id } => match result {
            Ok(res) => {
                let final_cli_id = if res.cli_msg_id.is_empty() {
                    pending
                        .spec
                        .client_id
                        .map_or_else(String::new, |id| id.to_string())
                } else {
                    res.cli_msg_id
                };
                let is_self = state.session.self_conversation_id.as_deref()
                    == Some(pending.spec.conv_id.as_str());
                let is_grp = is_group_id(&pending.spec.conv_id);
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

                let card = ContactCard {
                    name: pending.spec.title.clone(),
                    uid: pending.spec.contact_uid.clone(),
                    avatar: pending.spec.avatar.clone(),
                    phone: pending.spec.phone.clone().unwrap_or_default(),
                    qr: None,
                    oa_link: String::new(),
                    is_official_account: false,
                };
                let msg = ChatMessage {
                    id: res.msg_id,
                    conversation_id: pending.spec.conv_id.clone(),
                    sender_id: my_uid,
                    sender_name: my_name,
                    sender_avatar: my_avatar,
                    is_mine: true,
                    kind: Kind::ContactCard(card),
                    text: format!("[Danh thiếp] {}", pending.spec.title),
                    date_ms: pending.spec.now_ms,
                    status: Status::Sent,
                    quote: None,
                    reactions: Vec::new(),
                    is_e2ee: pending.is_e2ee,
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
                    client_id: final_cli_id.clone(),
                    text_styles: Vec::new(),
                    ttl_ms: 0,
                    urgency: 0,
                };

                let snap = state.identity_snapshot();
                if matches!(
                    state
                        .messages
                        .merge_message(msg.clone(), Some(&final_cli_id), &snap),
                    WindowChange::Changed(_)
                ) {
                    out.dirty.insert(DirtyKey::Messages);
                }
                if let Some(stored) = encode_chat_message(&msg, &final_cli_id) {
                    out.effects.push(Effect::Store(StoreOp::SaveMessages {
                        rows: vec![to_db_stored(&stored)],
                        preserve_existing_reactions: false,
                    }));
                }
                update_conversation_after_send(state, &msg, out);
                complete_op(
                    op_id,
                    OpResult::ComposerOutcome(ComposerOutcome::Done),
                    true,
                    out,
                );
            }
            Err(_) => {
                complete_op(
                    op_id,
                    OpResult::ComposerOutcome(ComposerOutcome::Failed(
                        COMPOSER_GENERIC_FAILURE.to_owned(),
                    )),
                    false,
                    out,
                );
            }
        },
        ContactCardContinuation::Forward { forward_id } => {
            crate::reduce::forward::on_contact_card_done(
                state,
                forward_id,
                pending.is_e2ee,
                result,
                out,
            );
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::reduce::reduce;
    use crate::state::{Phase, Profile};

    fn ready_state() -> CoreState {
        let mut state = CoreState::default();
        state.session.phase = Phase::Ready;
        state.session.profile = Some(Profile {
            user_id: "2001308".to_owned(),
            display_name: "Reminder User".to_owned(),
            avatar: None,
            phone: None,
        });
        state.session.self_conversation_id = Some("9201308".to_owned());
        state
    }

    #[test]
    fn create_reminder_rejects_overlong_title_without_http_call() {
        let mut state = ready_state();
        let over_utf16 = "a".repeat(3000);
        let out = reduce(
            &mut state,
            Input::OpRequest {
                op_id: 41,
                cmd: Command::CreateReminder {
                    conv_id: "3001308".to_owned(),
                    title: over_utf16,
                    start_ms: 1_700_001_000_000,
                    repeat_mode: 0,
                    pin: false,
                },
            },
        );
        assert!(
            !out.effects
                .iter()
                .any(|e| matches!(e, Effect::CreateReminderApi { .. })),
            "overlong title must not emit an HTTP request"
        );
        assert!(out.effects.iter().any(|e| matches!(
            e,
            Effect::CompleteOp {
                op_id: 41,
                result: OpResult::ComposerOutcome(ComposerOutcome::Failed(msg)),
                after_store: false,
            } if msg == REMINDER_TOO_LONG_FAILURE
        )));

        // Also test trimmed UTF-8 > 3700 bytes while UTF-16 < 3000.
        let over_utf8 = "ệ".repeat(1234);
        let out2 = reduce(
            &mut state,
            Input::OpRequest {
                op_id: 42,
                cmd: Command::CreateReminder {
                    conv_id: "g501308".to_owned(),
                    title: over_utf8,
                    start_ms: 1_700_002_000_000,
                    repeat_mode: 1,
                    pin: true,
                },
            },
        );
        assert!(
            !out2
                .effects
                .iter()
                .any(|e| matches!(e, Effect::CreateReminderApi { .. })),
            "over-byte-limit title must not emit an HTTP request"
        );
        assert!(out2.effects.iter().any(|e| matches!(
            e,
            Effect::CompleteOp {
                op_id: 42,
                result: OpResult::ComposerOutcome(ComposerOutcome::Failed(msg)),
                after_store: false,
            } if msg == REMINDER_TOO_LONG_FAILURE
        )));
    }
}
