//! Pure reducer for the group polls domain (`ZaloEngine+Poll.swift`, U12) and temporary U7
//! read-only board-pin mirror write-throughs.

use std::collections::BTreeMap;
use std::time::Duration;

use olaz_wire::{clean_group_id, is_group_id};
use serde_json::{Map, Value};

use crate::changes::DirtyKey;
use crate::effect::{Effect, OpResult, PollBoardContinuation, PollDetailPurpose, StoreOp};
use crate::input::{Command, Input};
use crate::polls::{
    BoardPinItem, BoardPinList, POLL_DEBOUNCE_DELAY_MS, PollActionResult, PollCapabilities,
    PollPinOutcome, build_pin_limit_confirm, build_poll_voters, clamped_int64,
    merge_fetched_group_metadata, normalize_poll_detail, refresh_poll_pin_state,
    resolve_poll_group_id,
};
use crate::reduce::ReduceOutput;
use crate::state::CoreState;

/// Default board pin limit when `PinnedList(json:)` receives no positive `limit` (`ZaloWireParser.defaultPinLimit`).
pub const DEFAULT_BOARD_PIN_LIMIT: i64 = 3;

fn json_bool(val: Option<&Value>) -> bool {
    match val {
        Some(Value::Bool(b)) => *b,
        Some(Value::Number(n)) => n.as_f64().is_some_and(|x| x != 0.0),
        _ => false,
    }
}

fn json_i64(val: Option<&Value>) -> i64 {
    match val {
        Some(Value::Number(n)) => n
            .as_i64()
            .unwrap_or_else(|| clamped_int64(n.as_f64().unwrap_or(0.0))),
        _ => 0,
    }
}

impl BoardPinList {
    /// Port of `PinnedList.init(json: [String: Any])` (`ZaloEngine+MessageActions.swift`).
    #[must_use]
    pub fn from_json(json: &Map<String, Value>) -> Self {
        let ready = json_bool(json.get("ready"));
        let can_pin = json_bool(json.get("canPin"));
        let raw_limit = json_i64(json.get("limit"));
        let limit = if raw_limit > 0 {
            raw_limit
        } else {
            DEFAULT_BOARD_PIN_LIMIT
        };
        let items = json
            .get("items")
            .and_then(Value::as_array)
            .map(|rows| {
                rows.iter()
                    .filter_map(|v| {
                        let row = v.as_object()?;
                        let ref_id = row
                            .get("ref")
                            .or_else(|| row.get("ref_id"))
                            .and_then(Value::as_str)?;
                        if ref_id.is_empty() {
                            return None;
                        }
                        let raw_kind = row.get("kind").and_then(Value::as_str).unwrap_or("");
                        let kind = match raw_kind {
                            "message" | "note" | "link" | "poll" | "reminder" => raw_kind,
                            _ => "note",
                        }
                        .to_owned();
                        let title = row
                            .get("title")
                            .and_then(Value::as_str)
                            .unwrap_or("")
                            .to_owned();
                        let sender = row
                            .get("sender")
                            .and_then(Value::as_str)
                            .unwrap_or("")
                            .to_owned();
                        let thumbnail = row
                            .get("thumb")
                            .or_else(|| row.get("thumbnail"))
                            .and_then(Value::as_str)
                            .filter(|s| !s.is_empty())
                            .map(str::to_owned);
                        let msg_id = row
                            .get("msgId")
                            .or_else(|| row.get("msg_id"))
                            .and_then(Value::as_str)
                            .unwrap_or("")
                            .to_owned();
                        let cli_msg_id = row
                            .get("cliMsgId")
                            .or_else(|| row.get("cli_msg_id"))
                            .and_then(Value::as_str)
                            .unwrap_or("")
                            .to_owned();
                        Some(BoardPinItem {
                            ref_id: ref_id.to_owned(),
                            kind,
                            title,
                            sender,
                            thumbnail,
                            msg_id,
                            cli_msg_id,
                        })
                    })
                    .collect()
            })
            .unwrap_or_default();
        Self {
            ready,
            can_pin,
            limit,
            items,
        }
    }
}

/// Port of `ZaloEngine.handlePins(state:)` (`// U7:` temporary mirror helper until U7 lands).
pub fn apply_pins_state_event(
    board_pins: &mut BTreeMap<String, BoardPinList>,
    state: &Map<String, Value>,
) -> bool {
    let Some(json) = state.get("pins").and_then(Value::as_object) else {
        return false;
    };
    let Some(conv_id) = json.get("convId").and_then(Value::as_str) else {
        return false;
    };
    if conv_id.is_empty() {
        return false;
    }
    let list = BoardPinList::from_json(json);
    if board_pins.get(conv_id) != Some(&list) {
        board_pins.insert(conv_id.to_owned(), list);
        return true;
    }
    false
}

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
    if is_group_id(&conv_id) && !state.board_pins.contains_key(&conv_id) {
        out.effects.push(Effect::RefreshBoardPinsForPoll {
            conv_id,
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
        refresh_poll_pin_state(&mut state.polls, &state.board_pins, poll_id, conv_id);
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
            | Command::SyncBoardPins { .. }
            | Command::SyncBoardRawTopics { .. }
            | Command::HandlePinsState { .. }
            | Command::ClearBoardCaches
    )
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
                    .map(|d| build_poll_voters(d, my_uid, my_avatar, &state.conversations));
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
                    && !state.contacts.group_details_json.contains_key(&clean_grid)
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
                    &mut state.contacts,
                    &mut state.conversations,
                    state.session.self_conversation_id.as_deref(),
                    now_ms,
                )
            {
                out.dirty.insert(DirtyKey::Contacts);
                out.dirty.insert(DirtyKey::Conversations);
                out.dirty.insert(DirtyKey::ConversationFlags);
                out.dirty.insert(DirtyKey::ConversationExtras);
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
        } => match continuation {
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
                run_refresh_poll_pin_step(
                    state,
                    poll_id,
                    conv_id,
                    op_id,
                    false,
                    Some(for_create),
                    out,
                );
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
                let outcome =
                    match build_pin_limit_confirm(&poll_id, state.board_pins.get(&conv_id)) {
                        Some(confirm) => PollPinOutcome::NeedsConfirmation(confirm),
                        None => PollPinOutcome::Failed(mapped),
                    };
                complete_op(out, op_id, OpResult::PollPinOutcome(outcome), false);
            }
            PollBoardContinuation::AfterUnpinSuccess { op_id, poll_id } => {
                run_refresh_poll_pin_step(state, poll_id, conv_id, op_id, true, None, out);
            }
        },

        Input::PollPinApiDone {
            op_id,
            poll_id,
            conv_id,
            for_create,
            step_result,
        } => match step_result {
            Ok(()) => {
                out.effects.push(Effect::RefreshBoardPinsForPoll {
                    conv_id,
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
                    out.effects.push(Effect::RefreshBoardPinsForPoll {
                        conv_id,
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
                out.effects.push(Effect::RefreshBoardPinsForPoll {
                    conv_id,
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
                    let cache = state.board_raw_topics.get(&conv_id);
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
            let cache = state.board_raw_topics.get(&conv_id);
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

        // U7: temporary write-throughs from Swift board pins until U7 lands (never dirty CoreChanges).
        Command::SyncBoardPins { conv_id, list } => {
            match list {
                Some(list) => {
                    state.board_pins.insert(conv_id, list);
                }
                None => {
                    state.board_pins.remove(&conv_id);
                }
            }
            complete_op(out, op_id, OpResult::Unit, false);
        }
        Command::SyncBoardRawTopics { conv_id, raw } => {
            match raw {
                Some(raw) => {
                    state.board_raw_topics.insert(conv_id, raw);
                }
                None => {
                    state.board_raw_topics.remove(&conv_id);
                }
            }
            complete_op(out, op_id, OpResult::Unit, false);
        }
        Command::HandlePinsState { state: pins_state } => {
            let _ = apply_pins_state_event(&mut state.board_pins, &pins_state);
            complete_op(out, op_id, OpResult::Unit, false);
        }
        Command::ClearBoardCaches => {
            state.board_pins.clear();
            state.board_raw_topics.clear();
            complete_op(out, op_id, OpResult::Unit, false);
        }

        _ => {}
    }
}
