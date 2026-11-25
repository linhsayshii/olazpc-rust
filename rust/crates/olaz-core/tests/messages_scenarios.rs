#![allow(clippy::expect_used, clippy::unwrap_used)]
//! Focused unit and integration tests for U4 messages-domain reducer & runner flows:
//! - Conversation open (local cache, empty store fetch, up-to-date skip, open-twice race cancellation)
//! - Older history paging (store-first vs server cursor paging, has_more_history rules, history_ticks)
//! - Sender profile resolution & reaction name refresh
//! - Live push & batch message ingestion (merge dedupe, E2EE readable twin protection, chronological reactions)
//! - Write-through window hooks & coalesced `WindowDelta` delivery through `ChangeHub`

use std::collections::BTreeMap;

use olaz_core::conversations::{CachedProfile, FriendIdentity};
use olaz_core::effect::{Effect, HistoryFetchPurpose, HostCall, StoreOp};
use olaz_core::input::{Command, Input};
use olaz_core::messages::{HistoryFreshness, WindowDelta};
use olaz_core::reduce::reduce;
use olaz_core::state::{CoreState, Phase, Profile};
use olaz_wire::{ChatMessage, Kind, MessageMenu, Reaction, ReactionIcon, Status};
use serde_json::json;

fn make_msg(id: &str, conv_id: &str, sender_id: &str, date_ms: i64, text: &str) -> ChatMessage {
    ChatMessage {
        id: id.to_owned(),
        conversation_id: conv_id.to_owned(),
        sender_id: sender_id.to_owned(),
        sender_name: String::new(),
        sender_avatar: None,
        is_mine: sender_id == "me_1",
        kind: Kind::Text,
        text: text.to_owned(),
        date_ms,
        status: Status::Sent,
        quote: None,
        reactions: Vec::new(),
        is_e2ee: false,
        mentions: Vec::new(),
        card_buttons: Vec::new(),
        suggests_stickers: false,
        menu: MessageMenu::default(),
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
        user_id: "me_1".to_owned(),
        display_name: "Me".to_owned(),
        avatar: Some("https://cdn.example.invalid/me.jpg".to_owned()),
        phone: None,
    });
    state.session.self_conversation_id = Some("9200001".to_owned());
    state
}

#[test]
fn m01_open_twice_cancels_first_open_seq_and_ignores_stale_completions() {
    let mut state = ready_state();

    // Open A (open_seq = 1)
    let out1 = reduce(
        &mut state,
        Input::OpRequest {
            op_id: 10,
            cmd: Command::OpenConversation {
                id: "conv_a".to_owned(),
                preloaded: Vec::new(),
                skip_local_read: false,
            },
        },
    );
    assert_eq!(state.messages.open_seq, 1);
    assert_eq!(
        state.conversations.open_conversation_id.as_deref(),
        Some("conv_a")
    );
    assert!(out1.effects.iter().any(|e| matches!(
        e,
        Effect::Store(StoreOp::LoadOpenLocalMessages { open_seq: 1, conv_id, .. }) if conv_id == "conv_a"
    )));

    // Immediately open B (open_seq = 2) before A's local load finishes
    let _out2 = reduce(
        &mut state,
        Input::OpRequest {
            op_id: 11,
            cmd: Command::OpenConversation {
                id: "conv_b".to_owned(),
                preloaded: Vec::new(),
                skip_local_read: false,
            },
        },
    );
    assert_eq!(state.messages.open_seq, 2);
    assert_eq!(
        state.conversations.open_conversation_id.as_deref(),
        Some("conv_b")
    );

    // Late completion from A (open_seq = 1) completes op_id 10 without mutating windows or fetching A's history
    let stale_out = reduce(
        &mut state,
        Input::OpenLocalMessagesLoaded {
            open_seq: 1,
            conv_id: "conv_a".to_owned(),
            rows: Vec::new(),
            op_id: Some(10),
        },
    );
    assert!(!stale_out.effects.iter().any(|e| matches!(
        e,
        Effect::FetchHistoryPageApi { .. } | Effect::Host(HostCall::MarkReadBoundary { .. })
    )));
    assert!(stale_out.effects.iter().any(|e| matches!(
        e,
        Effect::CompleteOp { op_id: 10, .. }
    )));
}

#[test]
fn m02_open_up_to_date_skips_history_fetch_and_emits_pins_and_mark_read() {
    let mut state = ready_state();
    state
        .messages
        .history_freshness
        .insert("friend_1".to_owned(), HistoryFreshness::UpToDate);
    state
        .conversations
        .identities
        .friends
        .push(FriendIdentity {
            id: "friend_1".to_owned(),
            name: "Alice".to_owned(),
            avatar: Some("https://cdn.example.invalid/alice.jpg".to_owned()),
        });

    let preloaded = vec![make_msg(
        "101",
        "friend_1",
        "friend_1",
        1_700_000_001_000,
        "Hi",
    )];
    let out = reduce(
        &mut state,
        Input::Command(Command::OpenConversation {
            id: "friend_1".to_owned(),
            preloaded,
            skip_local_read: false,
        }),
    );

    assert!(!out.effects.iter().any(|e| matches!(
        e,
        Effect::FetchHistoryPageApi {
            purpose: HistoryFetchPurpose::Open { .. },
            ..
        }
    )));
    assert!(out.effects.iter().any(|e| matches!(
        e,
        Effect::Host(HostCall::RefreshBoardPins { conv_id }) if conv_id == "friend_1"
    )));
    assert!(out.effects.iter().any(|e| matches!(
        e,
        Effect::Host(HostCall::MarkReadBoundary { conv_id, seen_target: Some(t) })
            if conv_id == "friend_1" && t.msg_id == "101"
    )));
    assert_eq!(state.messages.windows["friend_1"][0].sender_name, "Alice");
}

#[test]
fn m03_write_through_hooks_produce_coalesced_window_deltas() {
    let mut state = ready_state();
    let hub = olaz_core::ChangeHub::new();
    let rt = tokio::runtime::Builder::new_current_thread().enable_all().build().expect("rt");

    // Seed initial window for conv_1 with row "1" + temp optimistic row and drain initial Reset
    let existing1 = make_msg("1", "conv_1", "peer_1", 1800, "Existing");
    let mut temp = make_msg("cli_temp", "conv_1", "me_1", 1900, "Temp");
    temp.client_id = "cli_temp".to_owned();
    let init = reduce(
        &mut state,
        Input::Command(Command::WriteThroughReplaceWindow {
            conv_id: "conv_1".to_owned(),
            messages: vec![existing1, temp],
        }),
    );
    let init_ops = state.messages.take_pending_window_ops();
    hub.publish_with_window_ops(&init.dirty, &init_ops, &state);

    let first = rt.block_on(hub.next_changes()).expect("initial Reset");
    assert!(matches!(&first.window_deltas[0], WindowDelta::Reset { conv_id, .. } if conv_id == "conv_1"));

    // Update existing message "1" (Patch) and ack optimistic "cli_temp" -> "2" (Patch)
    let m1 = make_msg("1", "conv_1", "peer_1", 1800, "Updated 1");
    let out1 = reduce(
        &mut state,
        Input::Command(Command::WriteThroughUpsertMessage {
            msg: Box::new(m1),
            replacing_client_id: None,
        }),
    );
    let ops1 = state.messages.take_pending_window_ops();
    hub.publish_with_window_ops(&out1.dirty, &ops1, &state);

    let mut m2 = make_msg("2", "conv_1", "me_1", 2000, "Optimistic");
    m2.client_id = "cli_temp".to_owned();
    let out2 = reduce(
        &mut state,
        Input::Command(Command::WriteThroughUpsertMessage {
            msg: Box::new(m2),
            replacing_client_id: Some("cli_temp".to_owned()),
        }),
    );
    let ops2 = state.messages.take_pending_window_ops();
    hub.publish_with_window_ops(&out2.dirty, &ops2, &state);

    // Remove message 1 before subscriber wakes
    let out3 = reduce(
        &mut state,
        Input::Command(Command::WriteThroughRemoveMessages {
            conv_id: "conv_1".to_owned(),
            ids: vec!["1".to_owned()],
        }),
    );
    let ops3 = state.messages.take_pending_window_ops();
    hub.publish_with_window_ops(&out3.dirty, &ops3, &state);


    let changes = rt
        .block_on(hub.next_changes())
        .expect("coalesced CoreChanges");
    assert_eq!(changes.window_deltas.len(), 1);
    match &changes.window_deltas[0] {
        WindowDelta::Patch {
            conv_id,
            upserts,
            removed_ids,
        } => {
            assert_eq!(conv_id, "conv_1");
            assert_eq!(upserts.len(), 1);
            assert_eq!(upserts[0].id, "2");
            assert!(removed_ids.contains(&"cli_temp".to_owned()));
            assert!(removed_ids.contains(&"1".to_owned()));
            assert_eq!(state.messages.windows["conv_1"].len(), 1);
            assert_eq!(state.messages.windows["conv_1"][0].id, "2");
        }
        other => panic!("expected Patch delta, got {other:?}"),
    }
}

#[test]
fn m04_refresh_reaction_names_updates_in_memory_and_emits_save_messages() {
    let mut state = ready_state();
    let mut msg = make_msg("500", "g_group", "peer_a", 5000, "Reacted msg");
    let mut user_counts = BTreeMap::new();
    user_counts.insert("peer_b".to_owned(), 1);
    msg.reactions.push(Reaction {
        icon: ReactionIcon {
            r#type: "5".to_owned(),
            key: "/-heart".to_owned(),
            emoji: "❤️".to_owned(),
            image: String::new(),
        },
        count: 1,
        includes_me: false,
        names: Vec::new(),
        people: 1,
        user_counts,
    });
    let _ = reduce(
        &mut state,
        Input::Command(Command::WriteThroughReplaceWindow {
            conv_id: "g_group".to_owned(),
            messages: vec![msg],
        }),
    );

    // Add peer_b to cached_profiles and refresh reaction names
    state.conversations.identities.cached_profiles.insert(
        "peer_b".to_owned(),
        CachedProfile {
            name: "Bob Reactor".to_owned(),
            avatar: String::new(),
        },
    );
    let out = reduce(
        &mut state,
        Input::Command(Command::RefreshReactionNames {
            conv_id: Some("g_group".to_owned()),
        }),
    );
    assert_eq!(
        state.messages.windows["g_group"][0].reactions[0].names,
        vec!["Bob Reactor".to_owned()]
    );
    assert!(out.effects.iter().any(|e| matches!(
        e,
        Effect::Store(StoreOp::SaveMessages { rows, preserve_existing_reactions: true })
            if rows.len() == 1 && rows[0].id == "500"
    )));
}

#[test]
fn m05_apply_batch_direct_detects_signal_cipher_and_delegates_to_decrypt_envelope() {
    let mut state = ready_state();
    let cipher_payload = serde_json::from_value::<serde_json::Map<String, serde_json::Value>>(
        json!({
            "data": {
                "msgs": [
                    {
                        "msgId": "777",
                        "uidFrom": "peer_x",
                        "idTo": "me_1",
                        "msgType": "webchat",
                        "content": "AzM31234567890ciphertext==",
                        "ts": 1700000000000_i64
                    }
                ]
            }
        }),
    )
    .expect("map");

    let out = reduce(
        &mut state,
        Input::OpRequest {
            op_id: 99,
            cmd: Command::ApplyBatchDirect {
                payload: cipher_payload,
                default_cmd: 501,
                fallback_conv_id: None,
                is_group_hint: None,
                increment_unread: true,
                notify_incoming: false,
                persist_conversations: true,
                probe_freshness: false,
            },
        },
    );
    assert!(out.effects.iter().any(|e| matches!(
        e,
        Effect::Host(HostCall::DecryptEnvelope { op_id: Some(99), default_cmd: 501, .. })
    )));
}
