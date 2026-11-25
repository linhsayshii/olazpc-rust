//! Pure U5 reducer for sending text messages and core-window `markRead` (send/seen/E2EE boundary).

use std::collections::{BTreeMap, BTreeSet};
use std::fmt;

use olaz_api::SendTextParams;
use olaz_wire::{
    Availability, ChatMessage, DeleteMode, Kind, Mention, MessageMenu, Quote, StarMode, Status,
    TextStyle, encode_chat_message, is_group_id, text_properties_json,
};

use crate::changes::DirtyKey;
use crate::conversations::MessagePreviewInput;
use crate::effect::{Effect, HostCall, OpResult, StoreOp};
use crate::input::{Command, E2eeQuoteArg, Input};
use crate::messages::{WindowChange, is_valid_url_str, to_db_stored};
use crate::reduce::{ReduceOutput, conversations};
use crate::state::CoreState;

/// In-flight `sendText` transaction tracked until `Input::SendTextDone` arrives.
#[derive(Clone, PartialEq)]
struct PendingSend {
    op_id: Option<u64>,
    conv_id: String,
    cli_id: String,
    optimistic: ChatMessage,
}

/// Core-owned U5 send state (`e2ee_threads`, per-conversation auto-delete TTL, in-flight sends).
#[derive(Clone, Default)]
pub struct SendState {
    pub e2ee_threads: BTreeSet<String>,
    pub auto_delete_ttl_ms: BTreeMap<String, i64>,
    in_flight: BTreeMap<u64, PendingSend>,
    next_send_id: u64,
}

impl SendState {
    pub(crate) fn alloc_send_id(&mut self) -> u64 {
        self.next_send_id = self.next_send_id.saturating_add(1);
        self.next_send_id
    }

    #[must_use]
    pub fn auto_delete_ttl(&self, conv_id: &str) -> i64 {
        self.auto_delete_ttl_ms.get(conv_id).copied().unwrap_or(0)
    }

    /// Resets session-scoped send state on logout/expiry and fails any in-flight send ops.
    pub(crate) fn reset(&mut self, out: &mut ReduceOutput) {
        self.e2ee_threads.clear();
        self.auto_delete_ttl_ms.clear();
        let pending = std::mem::take(&mut self.in_flight);
        for (_, send) in pending {
            complete_op(send.op_id, OpResult::Bool(false), false, out);
        }
    }
}

impl fmt::Debug for SendState {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("SendState")
            .field("e2ee_threads_count", &self.e2ee_threads.len())
            .field("auto_delete_count", &self.auto_delete_ttl_ms.len())
            .field("in_flight_count", &self.in_flight.len())
            .finish()
    }
}

/// Reduces a U5 send / mark-read [`Input`].
pub(crate) fn reduce_send(state: &mut CoreState, input: Input, out: &mut ReduceOutput) {
    match input {
        Input::Command(cmd) => reduce_command(state, cmd, None, out),
        Input::OpRequest { op_id, cmd } => reduce_command(state, cmd, Some(op_id), out),
        Input::SendTextDone { send_id, result } => {
            reduce_send_text_done(state, send_id, result, out);
        }
        _ => {}
    }
}

fn reduce_command(state: &mut CoreState, cmd: Command, op_id: Option<u64>, out: &mut ReduceOutput) {
    match cmd {
        Command::SendText {
            conv_id,
            text,
            quote_id,
            mentions,
            styles,
            urgency,
            client_id,
            now_ms,
            is_e2ee,
            ttl_ms,
        } => reduce_send_text(
            state,
            SendTextRequest {
                conv_id,
                text,
                quote_id,
                mentions,
                styles,
                urgency,
                client_id,
                now_ms,
                is_e2ee_override: is_e2ee,
                ttl_ms_override: ttl_ms,
                op_id,
            },
            out,
        ),
        Command::MarkRead { id } => {
            let seen_target = state.messages.seen_target_for(&id);
            conversations::mark_conversation_read(state, id, seen_target, op_id, out);
        }
        Command::SetE2eeThreads(threads) => {
            state.send.e2ee_threads = threads;
            complete_op(op_id, OpResult::Unit, false, out);
        }
        Command::SetAutoDeleteTtl { conv_id, ttl_ms } => {
            if ttl_ms > 0 {
                state.send.auto_delete_ttl_ms.insert(conv_id, ttl_ms);
            } else {
                state.send.auto_delete_ttl_ms.remove(&conv_id);
            }
            complete_op(op_id, OpResult::Unit, false, out);
        }
        _ => {}
    }
}

struct SendTextRequest {
    conv_id: String,
    text: String,
    quote_id: Option<String>,
    mentions: Vec<Mention>,
    styles: Vec<TextStyle>,
    urgency: i64,
    client_id: i64,
    now_ms: i64,
    is_e2ee_override: Option<bool>,
    ttl_ms_override: Option<i64>,
    op_id: Option<u64>,
}

fn reduce_send_text(state: &mut CoreState, req: SendTextRequest, out: &mut ReduceOutput) {
    if req.text.trim().is_empty() || req.conv_id.is_empty() {
        complete_op(req.op_id, OpResult::Bool(false), false, out);
        return;
    }

    state.typing.reset_outgoing(&req.conv_id);

    let quote = req.quote_id.as_deref().and_then(|qid| {
        state
            .messages
            .windows
            .get(&req.conv_id)?
            .iter()
            .find(|m| m.id == qid)
            .cloned()
    });

    let cli_id = req.client_id.to_string();
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

    let quote_block = quote.as_ref().map(|q| Quote {
        sender_name: if q.is_mine {
            "Bạn".to_owned()
        } else {
            q.sender_name.clone()
        },
        text: if q.text.is_empty() {
            "[Tin nhắn]".to_owned()
        } else {
            q.text.clone()
        },
        msg_id: q.id.clone(),
        cli_msg_id: q.client_id.clone(),
    });

    let is_grp = is_group_id(&req.conv_id);
    let is_e2ee = if is_grp {
        false
    } else {
        req.is_e2ee_override
            .unwrap_or_else(|| state.send.e2ee_threads.contains(&req.conv_id))
    };

    let effective_styles = if is_e2ee { Vec::new() } else { req.styles };
    let ttl_ms = if is_e2ee {
        0
    } else {
        req.ttl_ms_override
            .unwrap_or_else(|| state.send.auto_delete_ttl(&req.conv_id))
    };
    let effective_urgency = if is_e2ee { 0 } else { req.urgency };

    let is_self = state.session.self_conversation_id.as_deref() == Some(req.conv_id.as_str());
    let optimistic = ChatMessage {
        id: cli_id.clone(),
        conversation_id: req.conv_id.clone(),
        sender_id: my_uid,
        sender_name: my_name,
        sender_avatar: my_avatar,
        is_mine: true,
        kind: Kind::Text,
        text: req.text.clone(),
        date_ms: req.now_ms,
        status: Status::Sending,
        quote: quote_block,
        reactions: Vec::new(),
        is_e2ee,
        mentions: req.mentions.clone(),
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
        client_id: cli_id.clone(),
        text_styles: effective_styles.clone(),
        ttl_ms,
        urgency: effective_urgency,
    };

    let snap = state.identity_snapshot();
    if matches!(
        state
            .messages
            .merge_message(optimistic.clone(), None, &snap),
        WindowChange::Changed(_)
    ) {
        out.dirty.insert(DirtyKey::Messages);
    }

    let send_id = state.send.alloc_send_id();
    state.send.in_flight.insert(
        send_id,
        PendingSend {
            op_id: req.op_id,
            conv_id: req.conv_id.clone(),
            cli_id: cli_id.clone(),
            optimistic,
        },
    );

    if is_e2ee {
        let quote_arg = quote.as_ref().map(|q| E2eeQuoteArg {
            msg_id: q.id.clone(),
            cli_msg_id: q.client_id.clone(),
            sender_id: q.sender_id.clone(),
            sender_name: q.sender_name.clone(),
            text: q.text.clone(),
            ts_ms: q.date_ms,
        });
        out.effects.push(Effect::Host(HostCall::SendE2eeText {
            send_id,
            conv_id: req.conv_id,
            text: req.text,
            client_id: cli_id,
            quote: quote_arg,
        }));
    } else {
        let params = SendTextParams {
            conv_id: req.conv_id,
            text: req.text,
            cli_msg_id: cli_id,
            quote_msg_id: quote.as_ref().map(|q| q.id.clone()),
            quote_cli_msg_id: quote.as_ref().map(|q| q.id.clone()),
            quote_owner_id: quote.as_ref().map(|q| q.sender_id.clone()),
            quote_text: quote.as_ref().map(|q| q.text.clone()),
            quote_ts_ms: quote.as_ref().map(|q| q.date_ms),
            mentions: req.mentions,
            text_properties: text_properties_json(&effective_styles),
            ttl: ttl_ms,
            urgency: effective_urgency,
        };
        out.effects.push(Effect::SendTextApi { send_id, params });
    }
}

fn reduce_send_text_done(
    state: &mut CoreState,
    send_id: u64,
    result: Result<olaz_api::SendMessageResult, String>,
    out: &mut ReduceOutput,
) {
    let Some(mut pending) = state.send.in_flight.remove(&send_id) else {
        return;
    };

    match result {
        Ok(res) => {
            let final_cli_id = if res.cli_msg_id.is_empty() {
                pending.cli_id.clone()
            } else {
                res.cli_msg_id
            };

            // If the HTTP reply carried no server msgId (`res.msg_id == cli_id`) and the WS echo
            // already delivered the server copy, keep the echoed row and drop any leftover optimistic.
            if res.msg_id == pending.cli_id
                && let Some(echoed) =
                    state
                        .messages
                        .windows
                        .get(&pending.conv_id)
                        .and_then(|list| {
                            list.iter()
                                .find(|m| m.client_id == final_cli_id && m.id != pending.cli_id)
                                .cloned()
                        })
            {
                if matches!(
                    state.messages.write_through_remove(
                        &pending.conv_id,
                        std::slice::from_ref(&pending.cli_id)
                    ),
                    WindowChange::Changed(_)
                ) {
                    out.dirty.insert(DirtyKey::Messages);
                }
                update_conversation_after_send(state, &echoed, out);
                complete_op(pending.op_id, OpResult::Bool(true), true, out);
                return;
            }

            pending.optimistic.id = res.msg_id;
            pending.optimistic.client_id = final_cli_id.clone();
            pending.optimistic.status = Status::Sent;

            if state.messages.windows.contains_key(&pending.conv_id) {
                let snap = state.identity_snapshot();
                if matches!(
                    state.messages.merge_message(
                        pending.optimistic.clone(),
                        Some(&pending.cli_id),
                        &snap
                    ),
                    WindowChange::Changed(_)
                ) {
                    out.dirty.insert(DirtyKey::Messages);
                }
            }

            if let Some(stored) = encode_chat_message(&pending.optimistic, &final_cli_id) {
                out.effects.push(Effect::Store(StoreOp::SaveMessages {
                    rows: vec![to_db_stored(&stored)],
                    preserve_existing_reactions: false,
                }));
            }
            update_conversation_after_send(state, &pending.optimistic, out);
            complete_op(pending.op_id, OpResult::Bool(true), true, out);
        }
        Err(err_msg) => {
            if !err_msg.is_empty() {
                out.effects
                    .push(Effect::EngineLog(format!("sendText failed: {err_msg}")));
            }
            if matches!(
                state
                    .messages
                    .write_through_remove(&pending.conv_id, std::slice::from_ref(&pending.cli_id)),
                WindowChange::Changed(_)
            ) {
                out.dirty.insert(DirtyKey::Messages);
            }
            complete_op(pending.op_id, OpResult::Bool(false), false, out);
        }
    }
}

fn update_conversation_after_send(
    state: &mut CoreState,
    msg: &ChatMessage,
    out: &mut ReduceOutput,
) {
    let my_uid = state
        .session
        .profile
        .as_ref()
        .map_or("", |p| p.user_id.as_str())
        .to_owned();
    let my_avatar = state
        .session
        .profile
        .as_ref()
        .and_then(|p| p.avatar.as_deref())
        .map(str::to_owned);
    let self_conv_id = state.session.self_conversation_id.clone();
    let preview_input = MessagePreviewInput::from_chat_message(msg);
    if state.conversations.update_conversation_on_message(
        &preview_input,
        false,
        &my_uid,
        my_avatar.as_deref(),
        self_conv_id.as_deref(),
    ) {
        out.dirty.insert(DirtyKey::Conversations);
        out.dirty.insert(DirtyKey::ConversationFlags);
        out.dirty.insert(DirtyKey::ConversationExtras);
        conversations::emit_save_conversations(state, out);
    }
}

fn complete_op(op_id: Option<u64>, result: OpResult, after_store: bool, out: &mut ReduceOutput) {
    if let Some(op_id) = op_id {
        out.effects.push(Effect::CompleteOp {
            op_id,
            result,
            after_store,
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::conversations::{ConversationPreview, ConversationSummary};
    use crate::reduce::reduce;
    use crate::state::{Phase, Profile};

    fn ready_state() -> CoreState {
        let mut state = CoreState::default();
        state.session.phase = Phase::Ready;
        state.session.self_conversation_id = Some("9200001".to_owned());
        state.session.profile = Some(Profile {
            user_id: "2000001".to_owned(),
            display_name: "Alice".to_owned(),
            avatar: Some("https://cdn.example.invalid/me.jpg".to_owned()),
            phone: None,
        });
        state.conversations.conversations.push(ConversationSummary {
            id: "3000001".to_owned(),
            is_group: false,
            name: "Bob".to_owned(),
            avatar: None,
            pinned: false,
            members: 0,
            unread: 2,
            preview: Some(ConversationPreview {
                text: "Old".to_owned(),
                date_ms: Some(1_700_000_000_000),
                from_me: false,
            }),
        });
        state
    }

    #[test]
    fn empty_or_whitespace_returns_false_without_side_effects() {
        let mut state = ready_state();
        let out = reduce(
            &mut state,
            Input::OpRequest {
                op_id: 1,
                cmd: Command::SendText {
                    conv_id: "3000001".to_owned(),
                    text: "   \n\t ".to_owned(),
                    quote_id: None,
                    mentions: Vec::new(),
                    styles: Vec::new(),
                    urgency: 0,
                    client_id: 0,
                    now_ms: 1_700_000_010_000,
                    is_e2ee: None,
                    ttl_ms: None,
                },
            },
        );
        assert!(state.messages.windows.is_empty());
        assert!(out.dirty.is_empty());
        assert_eq!(out.effects.len(), 1);
        assert!(matches!(
            out.effects[0],
            Effect::CompleteOp {
                op_id: 1,
                result: OpResult::Bool(false),
                after_store: false
            }
        ));
    }

    #[test]
    fn plain_send_optimistic_then_ok_updates_window_store_and_preview() {
        let mut state = ready_state();
        let out = reduce(
            &mut state,
            Input::OpRequest {
                op_id: 7,
                cmd: Command::SendText {
                    conv_id: "3000001".to_owned(),
                    text: "Hello Bob".to_owned(),
                    quote_id: None,
                    mentions: Vec::new(),
                    styles: vec![TextStyle {
                        start: 0,
                        len: 5,
                        st: "b".to_owned(),
                    }],
                    urgency: 1,
                    client_id: 5_000_000_000_001,
                    now_ms: 1_700_000_010_000,
                    is_e2ee: None,
                    ttl_ms: None,
                },
            },
        );
        assert!(out.dirty.contains(&DirtyKey::Messages));
        let win = &state.messages.windows["3000001"];
        assert_eq!(win.len(), 1);
        assert_eq!(win[0].id, "5000000000001");
        assert_eq!(win[0].status, Status::Sending);
        assert_eq!(win[0].urgency, 1);
        assert_eq!(win[0].text_styles.len(), 1);
        let send_id = match &out.effects[0] {
            Effect::SendTextApi { send_id, params } => {
                assert_eq!(params.cli_msg_id, "5000000000001");
                assert_eq!(params.urgency, 1);
                assert!(params.text_properties.is_some());
                *send_id
            }
            other => panic!("unexpected effect {other:?}"),
        };

        let done = reduce(
            &mut state,
            Input::SendTextDone {
                send_id,
                result: Ok(olaz_api::SendMessageResult {
                    msg_id: "9001001".to_owned(),
                    cli_msg_id: "5000000000001".to_owned(),
                    ts_ms: 1_700_000_010_500,
                }),
            },
        );
        assert!(done.dirty.contains(&DirtyKey::Messages));
        assert!(done.dirty.contains(&DirtyKey::Conversations));
        let win = &state.messages.windows["3000001"];
        assert_eq!(win.len(), 1);
        assert_eq!(win[0].id, "9001001");
        assert_eq!(win[0].status, Status::Sent);
        assert_eq!(win[0].date_ms, 1_700_000_010_000);
        assert_eq!(
            state.conversations.conversations[0]
                .preview
                .as_ref()
                .map(|p| p.text.as_str()),
            Some("Hello Bob")
        );
        assert!(
            done.effects
                .iter()
                .any(|e| matches!(e, Effect::Store(StoreOp::SaveMessages { .. })))
        );
        assert!(done.effects.iter().any(|e| matches!(
            e,
            Effect::CompleteOp {
                op_id: 7,
                result: OpResult::Bool(true),
                after_store: true
            }
        )));
    }

    #[test]
    fn failed_send_removes_optimistic_and_logs() {
        let mut state = ready_state();
        let out = reduce(
            &mut state,
            Input::OpRequest {
                op_id: 9,
                cmd: Command::SendText {
                    conv_id: "3000001".to_owned(),
                    text: "Will fail".to_owned(),
                    quote_id: None,
                    mentions: Vec::new(),
                    styles: Vec::new(),
                    urgency: 0,
                    client_id: 5_000_000_000_002,
                    now_ms: 1_700_000_020_000,
                    is_e2ee: None,
                    ttl_ms: None,
                },
            },
        );
        let send_id = match &out.effects[0] {
            Effect::SendTextApi { send_id, .. } => *send_id,
            other => panic!("unexpected effect {other:?}"),
        };
        let done = reduce(
            &mut state,
            Input::SendTextDone {
                send_id,
                result: Err("Zalo error 112: Send failed".to_owned()),
            },
        );
        assert!(state.messages.windows["3000001"].is_empty());
        assert!(done.dirty.contains(&DirtyKey::Messages));
        assert!(done.effects.iter().any(|e| matches!(
            e,
            Effect::EngineLog(msg) if msg == "sendText failed: Zalo error 112: Send failed"
        )));
        assert!(done.effects.iter().any(|e| matches!(
            e,
            Effect::CompleteOp {
                op_id: 9,
                result: OpResult::Bool(false),
                after_store: false
            }
        )));
    }

    #[test]
    fn echo_first_reconciliation_keeps_echoed_copy_without_resave() {
        let mut state = ready_state();
        let out = reduce(
            &mut state,
            Input::OpRequest {
                op_id: 11,
                cmd: Command::SendText {
                    conv_id: "3000001".to_owned(),
                    text: "Echo before reply".to_owned(),
                    quote_id: None,
                    mentions: Vec::new(),
                    styles: Vec::new(),
                    urgency: 0,
                    client_id: 5_000_000_000_008,
                    now_ms: 1_700_000_080_000,
                    is_e2ee: None,
                    ttl_ms: None,
                },
            },
        );
        let send_id = match &out.effects[0] {
            Effect::SendTextApi { send_id, .. } => *send_id,
            other => panic!("unexpected effect {other:?}"),
        };

        // Simulate WS echo arriving before HTTP reply.
        let mut echoed = state.messages.windows["3000001"][0].clone();
        echoed.id = "9008001".to_owned();
        echoed.status = Status::Sent;
        echoed.date_ms = 1_700_000_080_500;
        let snap = state.identity_snapshot();
        state
            .messages
            .merge_message(echoed, Some("5000000000008"), &snap);

        // HTTP returns msg_id == cli_id.
        let done = reduce(
            &mut state,
            Input::SendTextDone {
                send_id,
                result: Ok(olaz_api::SendMessageResult {
                    msg_id: "5000000000008".to_owned(),
                    cli_msg_id: "5000000000008".to_owned(),
                    ts_ms: 1_700_000_080_600,
                }),
            },
        );
        let win = &state.messages.windows["3000001"];
        assert_eq!(win.len(), 1);
        assert_eq!(win[0].id, "9008001");
        assert_eq!(win[0].date_ms, 1_700_000_080_500);
        assert!(
            !done
                .effects
                .iter()
                .any(|e| matches!(e, Effect::Store(StoreOp::SaveMessages { .. })))
        );
        assert!(done.effects.iter().any(|e| matches!(
            e,
            Effect::CompleteOp {
                op_id: 11,
                result: OpResult::Bool(true),
                after_store: true
            }
        )));
    }

    #[test]
    fn e2ee_send_strips_styles_ttl_urgency_and_emits_host_call() {
        let mut state = ready_state();
        state.send.e2ee_threads.insert("3000001".to_owned());
        state
            .send
            .auto_delete_ttl_ms
            .insert("3000001".to_owned(), 86_400_000);
        let out = reduce(
            &mut state,
            Input::Command(Command::SendText {
                conv_id: "3000001".to_owned(),
                text: "Secret".to_owned(),
                quote_id: None,
                mentions: Vec::new(),
                styles: vec![TextStyle {
                    start: 0,
                    len: 6,
                    st: "b".to_owned(),
                }],
                urgency: 2,
                client_id: 5_000_000_000_010,
                now_ms: 1_700_000_100_000,
                is_e2ee: None,
                ttl_ms: None,
            }),
        );
        let win = &state.messages.windows["3000001"];
        assert!(win[0].is_e2ee);
        assert!(win[0].text_styles.is_empty());
        assert_eq!(win[0].ttl_ms, 0);
        assert_eq!(win[0].urgency, 0);
        assert!(matches!(
            &out.effects[0],
            Effect::Host(HostCall::SendE2eeText { conv_id, client_id, quote: None, .. })
                if conv_id == "3000001" && client_id == "5000000000010"
        ));
    }

    #[test]
    fn mark_read_uses_core_window_seen_target() {
        let mut state = ready_state();
        let snap = state.identity_snapshot();
        state.messages.merge_message(
            ChatMessage {
                id: "8012001".to_owned(),
                conversation_id: "3000001".to_owned(),
                sender_id: "3000001".to_owned(),
                sender_name: "Bob".to_owned(),
                sender_avatar: None,
                is_mine: false,
                kind: Kind::Text,
                text: "Hi".to_owned(),
                date_ms: 1_700_000_120_000,
                status: Status::Sent,
                quote: None,
                reactions: Vec::new(),
                is_e2ee: false,
                mentions: Vec::new(),
                card_buttons: Vec::new(),
                suggests_stickers: false,
                menu: MessageMenu::default(),
                fallback_urls: Vec::new(),
                client_id: "c8012001".to_owned(),
                text_styles: Vec::new(),
                ttl_ms: 0,
                urgency: 0,
            },
            None,
            &snap,
        );
        let out = reduce(
            &mut state,
            Input::Command(Command::MarkRead {
                id: "3000001".to_owned(),
            }),
        );
        assert_eq!(state.conversations.conversations[0].unread, 0);
        assert!(out.effects.iter().any(|e| matches!(
            e,
            Effect::SendSeenApi(target)
                if target.conv_id == "3000001"
                    && target.msg_id == "8012001"
                    && target.cli_msg_id == "8012001"
        )));
    }
}
