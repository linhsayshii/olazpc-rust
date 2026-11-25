//! Pure transport-domain reducer (U2): WebSocket lifecycle, event routing, long-poll loop,
//! and serialized `drain_chat_polling` (ADR-018).
//!
//! No I/O, no clock, and no randomness live here (D9).

use std::time::Duration;

use olaz_api::PollState;

use crate::effect::{Effect, HostCall};
use crate::input::{Command, Input, PollBatchError, PollBatchOutcome};
use crate::reduce::ReduceOutput;
use crate::reduce::classify::{
    CMD_PUSH_MSG_11, CMD_PUSH_MSG_GROUP, LP_EXPIRED_REASON, Route, classify, classify_poll,
};
use crate::reduce::{conversations, session};
use crate::state::{ActiveDrain, CoreState, PendingDrain, Phase, WsPhase};
use crate::typed_chat::{PlainChatParse, try_parse_plain_chat_pure};

/// Sleep between periodic long-poll ticks (`ZaloEngine.startLongPollLoop`: 4 s).
pub const LP_TICK_INTERVAL: Duration = Duration::from_secs(4);

/// Maximum poll batches drained per periodic tick (`ZaloEngine.startLongPollLoop`: `maxBatches: 2`).
pub const LP_PERIODIC_MAX_BATCHES: u32 = 2;

/// True for push commands on the typed plain-chat hot path (`501`, `521`).
#[must_use]
pub fn is_typed_live_push(cmd: u16) -> bool {
    cmd == CMD_PUSH_MSG_11 || cmd == CMD_PUSH_MSG_GROUP
}

/// Starts both the WebSocket client and the periodic long-poll loop after session boot / QR login.
pub(crate) fn start_transport(
    state: &mut CoreState,
    endpoints: Vec<String>,
    out: &mut ReduceOutput,
) {
    // Only cancel drains from a previously running transport session; preserve any explicit
    // `DrainChatPolling` queued while `Phase::Ready` was waiting for boot validation to finish.
    if state.transport.lp_running || state.transport.active_drain.is_some() {
        finish_all_drains(state, out);
    }

    state.transport.ws_gen = state.transport.ws_gen.saturating_add(1);
    state.transport.ws_phase = WsPhase::Running;
    state.transport.ws_authed = false;
    state.transport.seen_typing_shapes.clear();

    state.transport.lp_gen = state.transport.lp_gen.saturating_add(1);
    state.transport.lp_running = true;

    let my_uid = state
        .session
        .profile
        .as_ref()
        .map(|p| p.user_id.clone())
        .unwrap_or_default();
    let self_conv_id = state.session.self_conversation_id.clone();

    out.effects.push(Effect::StartWs {
        ws_gen: state.transport.ws_gen,
        endpoints,
        seed_cursors: state.transport.ws_cursors.clone(),
        my_uid,
        self_conv_id,
    });
    out.effects.push(Effect::StartLpTimer {
        lp_gen: state.transport.lp_gen,
        initial: true,
        delay: LP_TICK_INTERVAL,
    });

    if let Some(queued) = state.transport.pending_drains.pop_front() {
        begin_drain(state, queued, out);
    }
}

/// Stops WebSocket + long-poll loops, bumps both generation counters, and completes any pending
/// `drain_chat_polling` waiters so no caller can hang across logout or session expiry.
pub(crate) fn stop_transport(state: &mut CoreState, reset_cursors: bool, out: &mut ReduceOutput) {
    finish_all_drains(state, out);

    state.transport.ws_gen = state.transport.ws_gen.saturating_add(1);
    state.transport.lp_gen = state.transport.lp_gen.saturating_add(1);
    state.transport.ws_phase = WsPhase::Stopped;
    state.transport.ws_authed = false;
    state.transport.lp_running = false;
    state.transport.seen_typing_shapes.clear();

    if reset_cursors {
        state.transport.ws_cursors.clear();
        state.transport.poll_state = PollState::default();
    }

    out.effects.push(Effect::StopWs { reset_cursors });
    out.effects.push(Effect::StopLongPoll);
}

/// Reduces a transport-domain [`Input`].
pub(crate) fn reduce_transport(state: &mut CoreState, input: Input, out: &mut ReduceOutput) {
    match input {
        Input::Command(Command::DrainChatPolling {
            max_batches,
            notify_incoming,
        }) => {
            let drain_id = state.transport.alloc_drain_id();
            handle_drain_requested(state, drain_id, max_batches, notify_incoming, out);
        }

        Input::DrainRequested {
            drain_id,
            max_batches,
            notify_incoming,
        } => {
            handle_drain_requested(state, drain_id, max_batches, notify_incoming, out);
        }

        Input::WsEvent {
            ws_gen,
            cmd,
            payload,
            now_unix_secs,
        } => {
            if ws_gen != state.transport.ws_gen || state.transport.ws_phase != WsPhase::Running {
                return;
            }
            let my_uid = state
                .session
                .profile
                .as_ref()
                .map(|p| p.user_id.as_str())
                .unwrap_or("");
            let self_conv_id = state.session.self_conversation_id.as_deref();
            match try_parse_plain_chat_pure(cmd, &payload, my_uid, self_conv_id) {
                PlainChatParse::Empty => return,
                PlainChatParse::Typed(envelope) => {
                    let is_live = is_typed_live_push(cmd);
                    out.effects.push(Effect::Host(HostCall::ApplyParsedEvents {
                        cmd,
                        increment_unread: is_live,
                        notify_incoming: is_live,
                        envelope,
                    }));
                    return;
                }
                PlainChatParse::NotPlain => {}
            }
            let routes = classify(cmd, payload, my_uid, now_unix_secs);
            let _ = emit_routes(state, routes, None, out);
        }

        Input::WsTypedChat {
            ws_gen,
            cmd,
            envelope,
        } => {
            if ws_gen != state.transport.ws_gen || state.transport.ws_phase != WsPhase::Running {
                return;
            }
            let is_live = is_typed_live_push(cmd);
            out.effects.push(Effect::Host(HostCall::ApplyParsedEvents {
                cmd,
                increment_unread: is_live,
                notify_incoming: is_live,
                envelope,
            }));
        }

        Input::WsAuthChanged { ws_gen, authed } => {
            if ws_gen != state.transport.ws_gen || state.transport.ws_phase != WsPhase::Running {
                return;
            }
            let was_authed = state.transport.ws_authed;
            if was_authed == authed {
                return;
            }
            state.transport.ws_authed = authed;
            if was_authed && !authed {
                out.effects.push(Effect::Host(HostCall::E2eeDisconnected));
            } else if !was_authed
                && authed
                && let Some(uid) = state
                    .session
                    .profile
                    .as_ref()
                    .map(|p| p.user_id.as_str())
                    .filter(|u| !u.is_empty())
            {
                out.effects.push(Effect::Host(HostCall::E2eeConnected {
                    uid: uid.to_owned(),
                }));
            }
        }

        Input::WsCursorsChanged { ws_gen, cursors } => {
            if ws_gen != state.transport.ws_gen || state.transport.ws_phase != WsPhase::Running {
                return;
            }
            if cursors != state.transport.ws_cursors {
                state.transport.ws_cursors = cursors.clone();
                out.effects
                    .push(Effect::Host(HostCall::PersistWsCursors { cursors }));
            }
        }

        Input::LpTick { lp_gen } => {
            if lp_gen != state.transport.lp_gen || !state.transport.lp_running {
                return;
            }
            let drain_id = state.transport.alloc_drain_id();
            let req = PendingDrain {
                drain_id,
                max_batches: LP_PERIODIC_MAX_BATCHES,
                notify_incoming: true,
                is_periodic: true,
            };
            if state.transport.active_drain.is_some() {
                if !state.transport.pending_drains.iter().any(|d| d.is_periodic) {
                    state.transport.pending_drains.push_back(req);
                }
                return;
            }
            begin_drain(state, req, out);
        }

        Input::PollBatchFetched {
            lp_gen,
            drain_id,
            result,
            now_unix_secs,
        } => {
            if lp_gen != state.transport.lp_gen || !state.transport.lp_running {
                return;
            }
            let matches_active = state
                .transport
                .active_drain
                .as_ref()
                .is_some_and(|a| a.drain_id == drain_id && a.lp_gen == lp_gen);
            if !matches_active {
                return;
            }
            match result {
                Ok(PollBatchOutcome {
                    payload,
                    next_state,
                    more,
                }) => {
                    if next_state != state.transport.poll_state {
                        state.transport.poll_state = next_state.clone();
                        out.effects.push(Effect::Host(HostCall::PersistPollState {
                            state: next_state,
                        }));
                    }
                    let notify_incoming =
                        if let Some(active) = state.transport.active_drain.as_mut() {
                            active.remaining_batches = active.remaining_batches.saturating_sub(1);
                            active.more_after_current = more;
                            active.notify_incoming
                        } else {
                            return;
                        };
                    let my_uid = state
                        .session
                        .profile
                        .as_ref()
                        .map(|p| p.user_id.as_str())
                        .unwrap_or("");
                    let routes = classify_poll(payload, my_uid, now_unix_secs, notify_incoming);
                    let _ = emit_routes(state, routes, Some((lp_gen, drain_id)), out);
                }
                Err(PollBatchError::Auth) => {
                    session::enter_session_expired(state, LP_EXPIRED_REASON.to_owned(), out);
                }
                Err(PollBatchError::Other) => {
                    complete_active_drain(state, out);
                }
            }
        }

        Input::PollBatchApplied {
            lp_gen,
            drain_id,
            delta,
        } => {
            if lp_gen != state.transport.lp_gen || !state.transport.lp_running {
                return;
            }
            let applied_count = delta.applied_count;
            conversations::apply_batch_delta(state, delta, out);
            finish_poll_batch_in_core(state, lp_gen, drain_id, applied_count, out);
        }

        _ => {}
    }
}

fn handle_drain_requested(
    state: &mut CoreState,
    drain_id: u64,
    max_batches: u32,
    notify_incoming: bool,
    out: &mut ReduceOutput,
) {
    let is_ready = matches!(state.session.phase, Phase::Ready);
    if max_batches == 0 || (!state.transport.lp_running && !is_ready) {
        out.effects.push(Effect::CompleteDrain {
            drain_id,
            total_events: 0,
        });
        return;
    }
    let req = PendingDrain {
        drain_id,
        max_batches,
        notify_incoming,
        is_periodic: false,
    };
    if !state.transport.lp_running || state.transport.active_drain.is_some() {
        state.transport.pending_drains.push_back(req);
    } else {
        begin_drain(state, req, out);
    }
}

fn begin_drain(state: &mut CoreState, req: PendingDrain, out: &mut ReduceOutput) {
    let lp_gen = state.transport.lp_gen;
    let drain_id = req.drain_id;
    state.transport.active_drain = Some(ActiveDrain {
        drain_id,
        lp_gen,
        remaining_batches: req.max_batches,
        notify_incoming: req.notify_incoming,
        is_periodic: req.is_periodic,
        total_events: 0,
        more_after_current: false,
    });
    out.effects.push(Effect::FetchPollBatch {
        lp_gen,
        drain_id,
        poll_state: state.transport.poll_state.clone(),
    });
}

fn complete_active_drain(state: &mut CoreState, out: &mut ReduceOutput) {
    let Some(done) = state.transport.active_drain.take() else {
        return;
    };
    out.effects.push(Effect::CompleteDrain {
        drain_id: done.drain_id,
        total_events: done.total_events,
    });
    if done.is_periodic && state.transport.lp_running && done.lp_gen == state.transport.lp_gen {
        out.effects.push(Effect::StartLpTimer {
            lp_gen: state.transport.lp_gen,
            initial: false,
            delay: LP_TICK_INTERVAL,
        });
    }
    if state.transport.lp_running
        && let Some(next) = state.transport.pending_drains.pop_front()
    {
        begin_drain(state, next, out);
    }
}

fn finish_all_drains(state: &mut CoreState, out: &mut ReduceOutput) {
    if let Some(active) = state.transport.active_drain.take() {
        out.effects.push(Effect::CompleteDrain {
            drain_id: active.drain_id,
            total_events: active.total_events,
        });
    }
    while let Some(pending) = state.transport.pending_drains.pop_front() {
        out.effects.push(Effect::CompleteDrain {
            drain_id: pending.drain_id,
            total_events: 0,
        });
    }
}

fn emit_routes(
    state: &mut CoreState,
    routes: Vec<Route>,
    poll_batch_done: Option<(u64, u64)>,
    out: &mut ReduceOutput,
) -> bool {
    for route in routes {
        match route {
            Route::SessionExpired { reason } => {
                session::enter_session_expired(state, reason, out);
                return true;
            }
            Route::E2eeSignal { cmd, payload } => {
                out.effects
                    .push(Effect::Host(HostCall::E2eeSignal { cmd, payload }));
            }
            Route::E2eeDeliverReports { cmd, payload } => {
                out.effects
                    .push(Effect::Host(HostCall::E2eeDeliverReports { cmd, payload }));
            }
            Route::LogSyncAck { cmd, code } => {
                out.effects.push(Effect::EngineLog(format!(
                    "sync-ws: ack cmd={cmd} code={code}"
                )));
            }
            Route::MobileSync(events) => {
                out.effects
                    .push(Effect::Host(HostCall::MobileSync { events }));
            }
            Route::RecordFileDone { file_id, url } => {
                out.effects.push(Effect::RecordFileDone { file_id, url });
            }
            Route::LogUndecodedControl {
                cmd,
                encrypt,
                data_is_string,
            } => {
                let data_kind = if data_is_string { "string" } else { "other" };
                out.effects.push(Effect::EngineLog(format!(
                    "ctrl: undecoded cmd={cmd} encrypt={encrypt} data={data_kind}"
                )));
            }
            Route::VoipControl {
                act,
                raw_data,
                data,
            } => {
                out.effects.push(Effect::Host(HostCall::VoipControl {
                    act,
                    raw_data,
                    data,
                }));
            }
            Route::LogTypingShape { shape } => {
                if state.transport.seen_typing_shapes.insert(shape.clone()) {
                    out.effects
                        .push(Effect::EngineLog(format!("typing: shape {shape}")));
                }
            }
            Route::ShowTyping {
                conv_id,
                uid,
                on_pc,
            } => {
                out.effects.push(Effect::Host(HostCall::ShowTyping {
                    conv_id,
                    uid,
                    on_pc,
                }));
            }
            Route::PinTopic { conv_id } => {
                out.effects
                    .push(Effect::Host(HostCall::PinTopic { conv_id }));
            }
            Route::GroupNotice { act, data, ts } => {
                out.effects
                    .push(Effect::Host(HostCall::GroupNotice { act, data, ts }));
            }
            Route::Mute {
                conv_id,
                set,
                start,
                start_explicit,
                duration,
            } => {
                out.effects.push(Effect::Host(HostCall::Mute {
                    conv_id,
                    set,
                    start,
                    start_explicit,
                    duration,
                }));
            }
            Route::ApplyBatch {
                cmd,
                increment_unread,
                notify_incoming,
                payload,
            } => {
                out.effects.push(Effect::Host(HostCall::ApplyBatch {
                    cmd,
                    increment_unread,
                    notify_incoming,
                    payload,
                    poll_batch_done,
                }));
            }
        }
    }
    false
}

/// Advances or finishes an active long-poll drain after one batch has been applied.
pub(crate) fn finish_poll_batch_in_core(
    state: &mut CoreState,
    lp_gen: u64,
    drain_id: u64,
    applied_count: u32,
    out: &mut ReduceOutput,
) {
    if lp_gen != state.transport.lp_gen || !state.transport.lp_running {
        return;
    }
    let should_continue = match state.transport.active_drain.as_mut() {
        Some(active) if active.drain_id == drain_id && active.lp_gen == lp_gen => {
            active.total_events = active.total_events.saturating_add(applied_count);
            active.more_after_current && active.remaining_batches > 0
        }
        _ => return,
    };
    if should_continue {
        out.effects.push(Effect::FetchPollBatch {
            lp_gen,
            drain_id,
            poll_state: state.transport.poll_state.clone(),
        });
    } else {
        complete_active_drain(state, out);
    }
}
