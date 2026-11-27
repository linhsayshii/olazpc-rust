//! Pure reducer for the group polls domain (`ZaloEngine+Poll.swift`, U12) and temporary U7
//! read-only board-pin mirror write-throughs.

use std::time::Duration;

use olaz_wire::{clean_group_id, is_group_id};
use serde_json::{Map, Value};

use crate::changes::DirtyKey;
use crate::effect::{Effect, OpResult, PollBoardContinuation, PollDetailPurpose, StoreOp};
use crate::groups::merge_fetched_group_metadata;
use crate::input::{Command, Input};
use crate::polls::{
    POLL_DEBOUNCE_DELAY_MS, PollActionResult, PollCapabilities, PollPinOutcome,
    build_pin_limit_confirm, build_poll_voters, normalize_poll_detail,
    poll_detail_shape_anomaly_log_line, refresh_poll_pin_state, resolve_poll_group_id,
};
use crate::reduce::ReduceOutput;
use crate::state::CoreState;

/// Default board pin limit when `PinnedList(json:)` receives no positive `limit` (`ZaloWireParser.defaultPinLimit`).
pub const DEFAULT_BOARD_PIN_LIMIT: i64 = 3;

fn complete_op(out: &mut ReduceOutput, op_id: Option<u64>, result: OpResult, after_store: bool) {
    if let Some(op_id) = op_id {
        out.effects.push(Effect::CompleteOp {
            op_id,
            result,
            after_store,
        });
    }
}

fn my_profile_info(state: &CoreState) -> (&str, Option<&str>) {
    match state.session.profile.as_ref() {
        Some(p) => (p.user_id.as_str(), p.avatar.as_deref()),
        None => ("", None),
    }
}

fn finish_poll_refresh(
    state: &mut CoreState,
    poll_id: &str,
    data_node: &Map<String, Value>,
    explicit_group_id: &str,
    op_id: Option<u64>,
    after_store: bool,
    out: &mut ReduceOutput,
) {
    let (my_uid, my_avatar) = my_profile_info(state);
    if let Some(detail) = normalize_poll_detail(
        data_node,
        poll_id,
        Some(explicit_group_id),
        my_uid,
        my_avatar,
        &state.polls,
        &state.contacts,
        &state.groups,
        &state.conversations,
        &state.messages,
    ) {
        let removed_fail = state.polls.failed.remove(poll_id);
        let changed_detail = state.polls.details.get(poll_id) != Some(&detail);
        if changed_detail {
            state.polls.details.insert(poll_id.to_owned(), detail);
        }
        if removed_fail || changed_detail {
            out.dirty.insert(DirtyKey::Polls);
        }
    } else if !state.polls.details.contains_key(poll_id)
        && state.polls.failed.insert(poll_id.to_owned())
    {
        out.dirty.insert(DirtyKey::Polls);
    }
    complete_op(out, op_id, OpResult::Unit, after_store);
}

fn run_refresh_poll_pin_step(
    state: &mut CoreState,
    poll_id: String,
    conv_id: String,
    op_id: Option<u64>,
    then_action_ok: bool,
    then_pin_done: Option<bool>,
    out: &mut ReduceOutput,
) {
    if is_group_id(&conv_id) && !state.pins.lists.contains_key(&conv_id) {
        let req_gen = state.pins.current_gen(&conv_id);
        out.effects.push(Effect::RefreshBoardPinsForPoll {
            conv_id,
            req_gen,
            require_auth: true,
            continuation: PollBoardContinuation::FinishRefreshPin {
                op_id,
                poll_id,
                then_action_ok,
                then_pin_done,
            },
        });
        return;
    }
    complete_refresh_poll_pin_now(
        state,
        &poll_id,
        &conv_id,
        op_id,
        then_action_ok,
        then_pin_done,
        out,
    );
}

fn complete_refresh_poll_pin_now(
    state: &mut CoreState,
    poll_id: &str,
    conv_id: &str,
    op_id: Option<u64>,
    then_action_ok: bool,
    then_pin_done: Option<bool>,
    out: &mut ReduceOutput,
) {
    let (pin_state, mutated) =
        refresh_poll_pin_state(&mut state.polls, &state.pins.lists, poll_id, conv_id);
    if mutated {
        out.dirty.insert(DirtyKey::Polls);
    }
    let result = if let Some(for_create) = then_pin_done {
        if for_create {
            OpResult::PollActionResult(PollActionResult::ok())
        } else {
            OpResult::PollPinOutcome(PollPinOutcome::Done)
        }
    } else if then_action_ok {
        OpResult::PollActionResult(PollActionResult::ok())
    } else {
        OpResult::PollPinState(pin_state)
    };
    complete_op(out, op_id, result, false);
}

/// Returns `true` when `cmd` belongs to the U12 polls reducer (or temporary U7 board sync).
pub(crate) fn is_poll_command(cmd: &Command) -> bool {
    matches!(
        cmd,
        Command::WatchPoll { .. }
            | Command::RetryPoll { .. }
            | Command::RewatchPolls { .. }
            | Command::RefreshPoll { .. }
            | Command::PollVoters { .. }
            | Command::RefreshPollPin { .. }
            | Command::PinPoll { .. }
            | Command::UnpinPoll { .. }
            | Command::PollCapabilities { .. }
            | Command::VotePoll { .. }
            | Command::LockPoll { .. }
            | Command::SharePoll { .. }
            | Command::CreatePoll { .. }
            | Command::NotePollMessages { .. }
            | Command::FirePollDebounce { .. }
            | Command::HandlePollState { .. }
            | Command::ResetPolls { .. }
            | Command::SeedPolls { .. }
    )
}

pub(crate) fn handle_poll_board_refreshed(
    state: &mut CoreState,
    conv_id: String,
    continuation: PollBoardContinuation,
    out: &mut ReduceOutput,
) {
    match continuation {
        PollBoardContinuation::FinishRefreshPin {
            op_id,
            poll_id,
            then_action_ok,
            then_pin_done,
        } => {
            complete_refresh_poll_pin_now(
                state,
                &poll_id,
                &conv_id,
                op_id,
                then_action_ok,
                then_pin_done,
                out,
            );
        }
        PollBoardContinuation::AfterPinSuccess {
            op_id,
            poll_id,
            for_create,
        } => {
            run_refresh_poll_pin_step(state, poll_id, conv_id, op_id, false, Some(for_create), out);
        }
        PollBoardContinuation::AfterPinLimitError {
            op_id,
            poll_id,
            mapped,
            for_create,
        } => {
            if for_create {
                complete_op(
                    out,
                    op_id,
                    OpResult::PollActionResult(PollActionResult::ok_pin_skipped()),
                    false,
                );
                return;
            }
            let outcome = match build_pin_limit_confirm(&poll_id, state.pins.lists.get(&conv_id)) {
                Some(confirm) => PollPinOutcome::NeedsConfirmation(confirm),
                None => PollPinOutcome::Failed(mapped),
            };
            complete_op(out, op_id, OpResult::PollPinOutcome(outcome), false);
        }
        PollBoardContinuation::AfterUnpinSuccess { op_id, poll_id } => {
            run_refresh_poll_pin_step(state, poll_id, conv_id, op_id, true, None, out);
        }
    }
}

pub fn reduce_polls(state: &mut CoreState, input: Input, out: &mut ReduceOutput) {
    match input {
        Input::Command(cmd) => reduce_poll_command(state, cmd, None, out),
        Input::OpRequest { op_id, cmd } => reduce_poll_command(state, cmd, Some(op_id), out),

        Input::PollDetailFetched {
            op_id,
            poll_id,
            purpose,
            payload,
            is_authenticated,
        } => match purpose {
            PollDetailPurpose::Voters => {
                let (my_uid, my_avatar) = my_profile_info(state);
                let voters = payload
                    .as_ref()
                    .and_then(|root| root.get("data"))
                    .and_then(Value::as_object)
                    .map(|d| {
                        build_poll_voters(
                            d,
                            my_uid,
                            my_avatar,
                            &state.conversations,
                            &state.contacts,
                            &state.groups,
                        )
                    });
                complete_op(out, op_id, OpResult::PollVoters(voters), false);
            }
            PollDetailPurpose::Refresh { now_ms } => {
                let Some(data_node) = payload
                    .as_ref()
                    .and_then(|root| root.get("data"))
                    .and_then(Value::as_object)
                    .cloned()
                else {
                    if !state.polls.details.contains_key(&poll_id)
                        && state.polls.failed.insert(poll_id)
                    {
                        out.dirty.insert(DirtyKey::Polls);
                    }
                    complete_op(out, op_id, OpResult::Unit, false);
                    return;
                };
                if let Some(line) = poll_detail_shape_anomaly_log_line(&data_node) {
                    out.effects.push(Effect::EngineLog(line));
                }
                let gid = resolve_poll_group_id(
                    &poll_id,
                    &data_node,
                    None,
                    &state.polls,
                    &state.messages,
                );
                let clean_grid = clean_group_id(&gid);
                if !gid.is_empty()
                    && !clean_grid.is_empty()
                    && !state.groups.details_json.contains_key(&clean_grid)
                    && is_authenticated
                {
                    out.effects.push(Effect::FetchPollGroupDetailApi {
                        op_id,
                        poll_id,
                        group_id: gid,
                        data_node,
                        now_ms,
                    });
                } else {
                    finish_poll_refresh(state, &poll_id, &data_node, &gid, op_id, false, out);
                }
            }
        },

        Input::PollGroupDetailFetched {
            op_id,
            poll_id,
            group_id,
            data_node,
            group_info,
            now_ms,
        } => {
            let mut had_store = false;
            if let Some(info) = group_info
                && let Some(persisted) = merge_fetched_group_metadata(
                    &group_id,
                    &info,
                    &mut state.groups,
                    &mut state.contacts,
                    &mut state.conversations,
                    state.session.self_conversation_id.as_deref(),
                    now_ms,
                )
            {
                out.dirty.insert(DirtyKey::Groups);
                out.dirty.insert(DirtyKey::Contacts);
                out.dirty.insert(DirtyKey::Conversations);
                out.dirty.insert(DirtyKey::ConversationFlags);
                out.dirty.insert(DirtyKey::ConversationExtras);
                out.dirty.insert(DirtyKey::CachedGroups);
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
            }
            finish_poll_refresh(
                state, &poll_id, &data_node, &group_id, op_id, had_store, out,
            );
        }

        Input::PollBoardRefreshed {
            conv_id,
            continuation,
        } => {
            handle_poll_board_refreshed(state, conv_id, continuation, out);
        }

        Input::PollPinApiDone {
            op_id,
            poll_id,
            conv_id,
            for_create,
            step_result,
        } => match step_result {
            Ok(()) => {
                let req_gen = state.pins.current_gen(&conv_id);
                out.effects.push(Effect::RefreshBoardPinsForPoll {
                    conv_id,
                    req_gen,
                    require_auth: false,
                    continuation: PollBoardContinuation::AfterPinSuccess {
                        op_id,
                        poll_id,
                        for_create,
                    },
                });
            }
            Err(mapped) => {
                if mapped.error.as_deref() == Some("limit") {
                    let req_gen = state.pins.current_gen(&conv_id);
                    out.effects.push(Effect::RefreshBoardPinsForPoll {
                        conv_id,
                        req_gen,
                        require_auth: false,
                        continuation: PollBoardContinuation::AfterPinLimitError {
                            op_id,
                            poll_id,
                            mapped,
                            for_create,
                        },
                    });
                } else if for_create {
                    complete_op(
                        out,
                        op_id,
                        OpResult::PollActionResult(PollActionResult::ok_pin_skipped()),
                        false,
                    );
                } else {
                    complete_op(
                        out,
                        op_id,
                        OpResult::PollPinOutcome(PollPinOutcome::Failed(mapped)),
                        false,
                    );
                }
            }
        },

        Input::PollUnpinApiDone {
            op_id,
            poll_id,
            conv_id,
            ok,
        } => {
            if ok {
                let req_gen = state.pins.current_gen(&conv_id);
                out.effects.push(Effect::RefreshBoardPinsForPoll {
                    conv_id,
                    req_gen,
                    require_auth: false,
                    continuation: PollBoardContinuation::AfterUnpinSuccess { op_id, poll_id },
                });
            } else {
                complete_op(
                    out,
                    op_id,
                    OpResult::PollActionResult(PollActionResult::err(Some("network"))),
                    false,
                );
            }
        }

        Input::PollVoteApiDone {
            op_id,
            poll_id,
            ok,
            now_ms,
        } => {
            if ok {
                complete_op(
                    out,
                    op_id,
                    OpResult::PollActionResult(PollActionResult::ok()),
                    false,
                );
                if !poll_id.is_empty() {
                    out.effects.push(Effect::FetchPollDetailApi {
                        op_id: None,
                        poll_id,
                        purpose: PollDetailPurpose::Refresh { now_ms },
                    });
                }
            } else {
                complete_op(
                    out,
                    op_id,
                    OpResult::PollActionResult(PollActionResult::err(Some("network"))),
                    false,
                );
            }
        }

        Input::PollLockApiDone {
            op_id,
            poll_id,
            ok,
            now_ms,
        } => {
            if ok {
                complete_op(
                    out,
                    op_id,
                    OpResult::PollActionResult(PollActionResult::ok()),
                    false,
                );
                if !poll_id.is_empty() {
                    out.effects.push(Effect::FetchPollDetailApi {
                        op_id: None,
                        poll_id,
                        purpose: PollDetailPurpose::Refresh { now_ms },
                    });
                }
            } else {
                complete_op(
                    out,
                    op_id,
                    OpResult::PollActionResult(PollActionResult::err(Some("network"))),
                    false,
                );
            }
        }

        Input::PollShareApiDone { op_id, ok } => {
            let res = if ok {
                PollActionResult::ok()
            } else {
                PollActionResult::err(Some("network"))
            };
            complete_op(out, op_id, OpResult::PollActionResult(res), false);
        }

        Input::PollCreateApiDone {
            op_id,
            conv_id,
            should_pin,
            result,
        } => match result {
            Err(mapped) => {
                complete_op(out, op_id, OpResult::PollActionResult(mapped), false);
            }
            Ok(created_poll_id) => {
                if !should_pin {
                    complete_op(
                        out,
                        op_id,
                        OpResult::PollActionResult(PollActionResult::ok()),
                        false,
                    );
                } else if created_poll_id.trim().is_empty() || !is_group_id(&conv_id) {
                    complete_op(
                        out,
                        op_id,
                        OpResult::PollActionResult(PollActionResult::ok_pin_skipped()),
                        false,
                    );
                } else {
                    out.effects.push(Effect::UnpinThenPinPollApi {
                        op_id,
                        poll_id: created_poll_id,
                        conv_id,
                        replace_ref: None,
                        for_create: true,
                    });
                }
            }
        },

        Input::PollDebounceFired {
            poll_id,
            seq,
            now_ms,
        } => {
            fire_poll_debounce(state, &poll_id, seq, now_ms, None, out);
        }

        _ => {}
    }
}

fn fire_poll_debounce(
    state: &mut CoreState,
    poll_id: &str,
    seq: u64,
    now_ms: i64,
    op_id: Option<u64>,
    out: &mut ReduceOutput,
) {
    if state.polls.complete_debounce(poll_id, seq) {
        out.dirty.insert(DirtyKey::Polls);
        if !poll_id.is_empty() {
            out.effects.push(Effect::FetchPollDetailApi {
                op_id: None,
                poll_id: poll_id.to_owned(),
                purpose: PollDetailPurpose::Refresh { now_ms },
            });
        }
    }
    complete_op(out, op_id, OpResult::Unit, false);
}

fn reduce_poll_command(
    state: &mut CoreState,
    cmd: Command,
    op_id: Option<u64>,
    out: &mut ReduceOutput,
) {
    match cmd {
        Command::WatchPoll {
            id,
            conv_id,
            now_ms,
        } => {
            if id.is_empty() {
                complete_op(out, op_id, OpResult::Unit, false);
                return;
            }
            let should_fetch = state.polls.watch_poll(&id, &conv_id, now_ms);
            out.dirty.insert(DirtyKey::Polls);
            if should_fetch {
                out.effects.push(Effect::FetchPollDetailApi {
                    op_id,
                    poll_id: id,
                    purpose: PollDetailPurpose::Refresh { now_ms },
                });
            } else {
                complete_op(out, op_id, OpResult::Unit, false);
            }
        }

        Command::RetryPoll {
            id,
            conv_id: _,
            now_ms,
        } => {
            let should_fetch = state.polls.retry_poll(&id, now_ms);
            out.dirty.insert(DirtyKey::Polls);
            if should_fetch {
                out.effects.push(Effect::FetchPollDetailApi {
                    op_id,
                    poll_id: id,
                    purpose: PollDetailPurpose::Refresh { now_ms },
                });
            } else {
                complete_op(out, op_id, OpResult::Unit, false);
            }
        }

        Command::RewatchPolls { now_ms } => {
            for poll_id in state.polls.rewatch_poll_ids() {
                out.effects.push(Effect::FetchPollDetailApi {
                    op_id: None,
                    poll_id,
                    purpose: PollDetailPurpose::Refresh { now_ms },
                });
            }
            complete_op(out, op_id, OpResult::Unit, false);
        }

        Command::RefreshPoll { id, now_ms } => {
            if id.is_empty() {
                complete_op(out, op_id, OpResult::Unit, false);
                return;
            }
            out.effects.push(Effect::FetchPollDetailApi {
                op_id,
                poll_id: id,
                purpose: PollDetailPurpose::Refresh { now_ms },
            });
        }

        Command::PollVoters { id } => {
            out.effects.push(Effect::FetchPollDetailApi {
                op_id,
                poll_id: id,
                purpose: PollDetailPurpose::Voters,
            });
        }

        Command::RefreshPollPin { id, conv_id } => {
            run_refresh_poll_pin_step(state, id, conv_id, op_id, false, None, out);
        }

        Command::PinPoll {
            id,
            conv_id,
            confirming,
        } => {
            if !is_group_id(&conv_id) || id.trim().is_empty() {
                complete_op(
                    out,
                    op_id,
                    OpResult::PollPinOutcome(PollPinOutcome::Failed(PollActionResult::err(Some(
                        "forbidden",
                    )))),
                    false,
                );
                return;
            }
            let replace_ref = confirming
                .as_deref()
                .filter(|s| !s.is_empty())
                .map(|ref_id| {
                    let cache = state.pins.raw_topics.get(&conv_id);
                    let raw = cache.and_then(|c| c.topics.get(ref_id)).cloned();
                    let version = cache.map_or(0, |c| c.version);
                    (ref_id.to_owned(), raw, version)
                });
            out.effects.push(Effect::UnpinThenPinPollApi {
                op_id,
                poll_id: id,
                conv_id,
                replace_ref,
                for_create: false,
            });
        }

        Command::UnpinPoll { id, conv_id } => {
            let cache = state.pins.raw_topics.get(&conv_id);
            let raw_topic = cache.and_then(|c| c.topics.get(&id)).cloned();
            let board_version = cache.map_or(0, |c| c.version);
            out.effects.push(Effect::UnpinPollApi {
                op_id,
                poll_id: id,
                conv_id,
                raw_topic,
                board_version,
            });
        }

        Command::PollCapabilities { conv_id } => {
            let caps = PollCapabilities::for_conversation(&conv_id);
            complete_op(out, op_id, OpResult::PollCapabilities(caps), false);
        }

        Command::VotePoll {
            id,
            conv_id: _,
            draft,
            detail,
            now_ms,
        } => {
            let resolved_detail = detail.or_else(|| state.polls.details.get(&id).cloned());
            let Some(detail) = resolved_detail else {
                complete_op(
                    out,
                    op_id,
                    OpResult::PollActionResult(PollActionResult::err(Some("network"))),
                    false,
                );
                return;
            };
            let (new_options, voted_ids) = draft.request(&detail);
            out.effects.push(Effect::VotePollApi {
                op_id,
                poll_id: id,
                new_options,
                voted_ids,
                now_ms,
            });
        }

        Command::LockPoll {
            id,
            conv_id: _,
            now_ms,
        } => {
            out.effects.push(Effect::LockPollApi {
                op_id,
                poll_id: id,
                now_ms,
            });
        }

        Command::SharePoll { id, conv_id: _ } => {
            out.effects
                .push(Effect::SharePollApi { op_id, poll_id: id });
        }

        Command::CreatePoll {
            conv_id,
            draft,
            config,
            can_pin,
        } => {
            let question = draft.truncated_question(&config);
            let options = draft.truncated_options(&config);
            let expired_time_ms = if draft.has_deadline {
                draft.deadline_ms
            } else {
                0
            };
            let allow_multi = draft.multi;
            let allow_add = draft.effective_allow_add();
            let hide_vote_preview = draft.hide_preview && config.enable_hide_preview;
            let is_anonymous = draft.anonymous && config.enable_anonymous;
            let should_pin = draft.pin && can_pin;
            out.effects.push(Effect::CreatePollApi {
                op_id,
                conv_id,
                question,
                options,
                expired_time_ms,
                allow_multi,
                allow_add,
                hide_vote_preview,
                is_anonymous,
                should_pin,
            });
        }

        Command::NotePollMessages {
            notices,
            now_ms,
            host_already_armed,
        } => {
            let prev_seen = state.polls.clock.seen_messages_count();
            let armed = state.polls.note_poll_messages(&notices, now_ms);
            if !armed.is_empty() || state.polls.clock.seen_messages_count() != prev_seen {
                out.dirty.insert(DirtyKey::Polls);
            }
            if !host_already_armed {
                for (poll_id, seq) in armed {
                    out.effects.push(Effect::ArmPollDebounce {
                        poll_id,
                        seq,
                        delay: Duration::from_millis(POLL_DEBOUNCE_DELAY_MS),
                    });
                }
            }
            complete_op(out, op_id, OpResult::Unit, false);
        }

        Command::FirePollDebounce {
            poll_id,
            seq,
            now_ms,
        } => {
            fire_poll_debounce(state, &poll_id, seq, now_ms, op_id, out);
        }

        Command::HandlePollState { state: poll_state } => {
            if state.polls.apply_poll_state_event(&poll_state) {
                out.dirty.insert(DirtyKey::Polls);
            }
            complete_op(out, op_id, OpResult::Unit, false);
        }

        Command::ResetPolls { sync_epoch } => {
            state.polls.reset_to_epoch(sync_epoch);
            out.dirty.insert(DirtyKey::Polls);
            out.effects.push(Effect::CancelAllPollDebounces);
            complete_op(out, op_id, OpResult::Unit, false);
        }

        Command::SeedPolls { polls } => {
            state.polls = *polls;
            complete_op(out, op_id, OpResult::Unit, false);
        }

        _ => {}
    }
}

#[cfg(test)]
#[expect(
    clippy::expect_used,
    reason = "unit tests assert invariants on synthetic fixtures"
)]
mod tests {
    use serde_json::json;

    use super::*;
    use crate::reduce::reduce;

    #[test]
    fn poll_detail_fetched_emits_shape_engine_log_and_parses_numeric_flags() {
        let mut state = CoreState::default();
        let payload = json!({
            "data": {
                "group_id": "500101",
                "question": "SECRET_POLL_QUESTION",
                "creator": "2001001",
                "status": 1,
                "expired_time": 0,
                "is_add_new_option": 1,
                "is_multi_choice": 1,
                "is_anonymous": 0,
                "is_hide_vote_preview": 0,
                "options": [
                    {"option_id": 1, "content": "SECRET_OPT", "voters": []},
                ],
            }
        });
        let out = reduce(
            &mut state,
            Input::PollDetailFetched {
                op_id: None,
                poll_id: "9301".to_owned(),
                purpose: PollDetailPurpose::Refresh {
                    now_ms: 1_700_010_000_000,
                },
                payload: payload.as_object().cloned(),
                is_authenticated: false,
            },
        );
        let detail = state.polls.details.get("9301").expect("poll detail stored");
        assert!(detail.allow_add);
        assert!(detail.multi);
        assert!(!detail.anonymous);
        assert!(!detail.hide_preview);
        let shape_logs: Vec<&str> = out
            .effects
            .iter()
            .filter_map(|e| match e {
                Effect::EngineLog(line) => Some(line.as_str()),
                _ => None,
            })
            .collect();
        assert_eq!(shape_logs.len(), 1);
        assert!(shape_logs[0].starts_with("poll detail shape: "));
        assert!(shape_logs[0].contains("is_add_new_option:number"));
        assert!(!shape_logs[0].contains("SECRET_POLL_QUESTION"));
        assert!(!shape_logs[0].contains("SECRET_OPT"));
    }

    #[test]
    fn poll_group_detail_fetched_dirties_cached_groups() {
        let mut state = CoreState::default();
        let data_node = json!({
            "group_id": "500202",
            "question": "Q",
            "creator": "2001001",
            "status": 1,
            "expired_time": 0,
            "is_add_new_option": 1,
            "options": [],
        })
        .as_object()
        .cloned()
        .expect("object");
        let group_info = json!({
            "groupId": "500202",
            "name": "Nhóm Poll",
            "avt": "https://cdn.example.invalid/g.jpg",
            "creatorId": "2001001",
            "memVerList": ["2001001_0", "3001001_1"],
        })
        .as_object()
        .cloned()
        .expect("object");

        let out = reduce(
            &mut state,
            Input::PollGroupDetailFetched {
                op_id: None,
                poll_id: "9302".to_owned(),
                group_id: "g500202".to_owned(),
                data_node,
                group_info: Some(group_info),
                now_ms: 1_700_010_000_000,
            },
        );
        assert!(out.dirty.contains(&DirtyKey::CachedGroups));
        assert!(out.dirty.contains(&DirtyKey::Polls));
        let cached = state
            .groups
            .cached_groups
            .get("g500202")
            .expect("cached group updated");
        assert_eq!(cached.name, "Nhóm Poll");
        assert_eq!(cached.members, 2);
    }

    #[test]
    fn loading_group_with_many_polls_triggers_at_most_one_identity_update() {
        let mut state = CoreState::default();
        let group_info = json!({
            "groupId": "500303",
            "name": "Nhóm Nhiều Poll",
            "avt": "https://cdn.example.invalid/g303.jpg",
            "creatorId": "2001001",
            "memVerList": ["2001001_0", "3001001_1"],
        })
        .as_object()
        .cloned()
        .expect("object");

        let mut group_fetch_count = 0usize;
        let mut cached_groups_dirty_count = 0usize;
        let mut contacts_dirty_count = 0usize;
        let mut refresh_identity_count = 0usize;

        for idx in 0..20usize {
            let poll_id = format!("94{:02}", idx);
            let payload = json!({
                "data": {
                    "group_id": "500303",
                    "question": format!("Poll {idx}"),
                    "creator": "2001001",
                    "status": 1,
                    "expired_time": 0,
                    "allow_add_new_option": true,
                    "allow_multi_choices": false,
                    "is_anonymous": false,
                    "is_hide_vote_preview": false,
                    "options": [{"option_id": 1, "content": "A", "voters": []}],
                }
            });
            let out = reduce(
                &mut state,
                Input::PollDetailFetched {
                    op_id: None,
                    poll_id: poll_id.clone(),
                    purpose: PollDetailPurpose::Refresh {
                        now_ms: 1_700_020_000_000 + i64::try_from(idx).unwrap_or(0),
                    },
                    payload: payload.as_object().cloned(),
                    is_authenticated: true,
                },
            );
            if out.dirty.contains(&DirtyKey::CachedGroups) {
                cached_groups_dirty_count += 1;
            }
            if out.dirty.contains(&DirtyKey::Contacts) {
                contacts_dirty_count += 1;
            }
            if out.refresh_identity_snapshot {
                refresh_identity_count += 1;
            }

            for effect in out.effects {
                if let Effect::FetchPollGroupDetailApi {
                    op_id,
                    poll_id,
                    group_id,
                    data_node,
                    now_ms,
                } = effect
                {
                    group_fetch_count += 1;
                    let merged_out = reduce(
                        &mut state,
                        Input::PollGroupDetailFetched {
                            op_id,
                            poll_id,
                            group_id,
                            data_node,
                            group_info: Some(group_info.clone()),
                            now_ms,
                        },
                    );
                    if merged_out.dirty.contains(&DirtyKey::CachedGroups) {
                        cached_groups_dirty_count += 1;
                    }
                    if merged_out.dirty.contains(&DirtyKey::Contacts) {
                        contacts_dirty_count += 1;
                    }
                    if merged_out.refresh_identity_snapshot {
                        refresh_identity_count += 1;
                    }
                }
            }
        }

        assert_eq!(state.polls.details.len(), 20);
        assert_eq!(
            group_fetch_count, 1,
            "missing group metadata must be fetched at most once across N polls"
        );
        assert!(
            cached_groups_dirty_count <= 1,
            "cached_groups must update at most once across N polls, got {cached_groups_dirty_count}"
        );
        assert!(
            contacts_dirty_count <= 1,
            "contacts must update at most once across N polls, got {contacts_dirty_count}"
        );
        assert!(
            refresh_identity_count <= 1,
            "identity snapshot refresh must trigger at most once across N polls, got {refresh_identity_count}"
        );
    }

    #[test]
    fn poll_detail_fetched_omits_shape_log_for_normal_bool_live_payload() {
        let mut state = CoreState::default();
        let payload = json!({
            "data": {
                "allow_add_new_option": true,
                "allow_multi_choices": true,
                "closed": false,
                "created_time": 1_700_000_000_i64,
                "creator": "2001001",
                "expired_time": 0,
                "is_anonymous": false,
                "is_hide_vote_preview": false,
                "joined": false,
                "num_vote": 0,
                "options": [
                    {"option_id": 1, "content": "Opt 1", "voters": []},
                ],
                "poll_id": 9303,
                "poll_type": 0,
                "question": "Normal live poll",
                "updated_time": 1_700_000_000_i64,
            }
        });
        let out = reduce(
            &mut state,
            Input::PollDetailFetched {
                op_id: None,
                poll_id: "9303".to_owned(),
                purpose: PollDetailPurpose::Refresh {
                    now_ms: 1_700_010_000_000,
                },
                payload: payload.as_object().cloned(),
                is_authenticated: false,
            },
        );
        let detail = state.polls.details.get("9303").expect("poll detail stored");
        assert!(detail.allow_add);
        assert!(detail.multi);
        assert!(!detail.anonymous);
        assert!(!detail.hide_preview);
        assert!(
            !out.effects.iter().any(
                |e| matches!(e, Effect::EngineLog(line) if line.starts_with("poll detail shape:"))
            ),
            "normal all-bool live payload must not emit shape log"
        );
    }
}
