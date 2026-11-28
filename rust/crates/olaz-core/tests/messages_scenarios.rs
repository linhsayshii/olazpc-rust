#![allow(clippy::expect_used, clippy::unwrap_used)]
//! Focused unit and integration tests for U4 messages-domain reducer & runner flows:
//! - Conversation open (local cache, empty store fetch, up-to-date skip, open-twice race cancellation)
//! - Older history paging (store-first vs server cursor paging, has_more_history rules, history_ticks)
//! - Sender profile resolution & reaction name refresh
//! - Live push & batch message ingestion (merge dedupe, E2EE readable twin protection, chronological reactions)
//! - Write-through window hooks & coalesced `WindowDelta` delivery through `ChangeHub`

use std::collections::BTreeMap;

use olaz_core::conversations::{CachedProfile, FriendIdentity, IdentityTable};
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
    assert!(
        stale_out
            .effects
            .iter()
            .any(|e| matches!(e, Effect::CompleteOp { op_id: 10, .. }))
    );
}

#[test]
fn m02_open_up_to_date_skips_history_fetch_and_emits_pins_and_mark_read() {
    let mut state = ready_state();
    state
        .messages
        .history_freshness
        .insert("friend_1".to_owned(), HistoryFreshness::UpToDate);
    state.contacts.apply_identity_table(IdentityTable {
        friends: vec![FriendIdentity {
            id: "friend_1".to_owned(),
            name: "Alice".to_owned(),
            avatar: Some("https://cdn.example.invalid/alice.jpg".to_owned()),
        }],
        ..IdentityTable::default()
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
    let followup = out.effects.iter().find_map(|e| match e {
        Effect::RefreshBoardPins {
            conv_id, followup, ..
        } if conv_id == "friend_1" => Some(followup.clone()),
        _ => None,
    });
    let followup = followup.expect("expected RefreshBoardPins effect");
    let after_pins = reduce(
        &mut state,
        Input::BoardPinsFetchSkipped {
            conv_id: "friend_1".to_owned(),
            req_gen: 0,
            followup,
        },
    );
    assert!(after_pins.effects.iter().any(|e| matches!(
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
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .expect("rt");

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
    assert!(
        matches!(&first.window_deltas[0], WindowDelta::Reset { conv_id, .. } if conv_id == "conv_1")
    );

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
    state.contacts.cached_profiles.insert(
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
    let cipher_payload =
        serde_json::from_value::<serde_json::Map<String, serde_json::Value>>(json!({
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
        }))
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
                now_ms: None,
            },
        },
    );
    assert!(out.effects.iter().any(|e| matches!(
        e,
        Effect::Host(HostCall::DecryptEnvelope {
            op_id: Some(99),
            default_cmd: 501,
            ..
        })
    )));
}

#[test]
fn unresolved_sync_sender_repairs_persisted_uid_even_without_profile() {
    for profile_available in [false, true] {
        let mut state = ready_state();
        let global = "fixture-global-sender-0000000001";
        assert_eq!(global.len(), 32);
        let original = make_msg("8801", "g9901", global, 1_700_000_000_000, "Preserve body");
        state
            .messages
            .windows
            .insert("g9901".into(), vec![original.clone()]);
        let profiles_map = if profile_available {
            json!({"123": {"displayName": "Fixture sender", "avatar": "https://cdn.example.invalid/avatar.png"}}).as_object().unwrap().clone()
        } else {
            Default::default()
        };
        let out = reduce(
            &mut state,
            Input::SenderProfilesChunkDone {
                resolve_id: 1,
                conv_id: "g9901".into(),
                remaining_chunks: Vec::new(),
                profiles_map,
                resolved_global_ids: BTreeMap::from([(global.into(), "123".into())]),
                cache_updated: false,
            },
        );
        let repaired = &state.messages.windows["g9901"][0];
        assert_eq!(repaired.sender_id, "123");
        assert_eq!(repaired.text, original.text);
        assert_eq!(repaired.client_id, original.client_id);
        if profile_available {
            assert_eq!(repaired.sender_name, "Fixture sender");
        }
        let mut store = olaz_store::Store::open_in_memory().unwrap();
        for effect in out.effects {
            if let Effect::Store(StoreOp::SaveMessages {
                rows,
                preserve_existing_reactions,
            }) = effect
            {
                assert!(preserve_existing_reactions);
                store.save_messages(&rows).unwrap();
            }
        }
        let stored = store.message("g9901", "8801").unwrap().unwrap();
        assert_eq!(stored.sender_id, "123");
        let reopened = olaz_core::messages::decode_db_stored(&stored).unwrap();
        assert_eq!(reopened.sender_id, "123");
        assert_eq!(reopened.id, original.id);
        if !profile_available {
            let ids = olaz_core::messages::collect_missing_sender_uids(
                &[reopened],
                "100",
                &state.identity_snapshot(),
            );
            assert_eq!(ids, vec!["123"]);
        }
    }
}

#[derive(Default)]
struct GidRepairHost;

#[async_trait::async_trait]
impl olaz_core::runner::Host for GidRepairHost {
    async fn load_saved_session(&self) -> Option<String> {
        None
    }
    async fn load_legacy_cookie(&self) -> Option<olaz_core::input::LegacyCookie> {
        None
    }
    async fn set_pref(&self, _key: String, _value: String) {}
    async fn prepare_store(&self, _user_id: String, _account: olaz_net::LoginAccount) {}
    async fn start_bootstrap(&self) {}
    async fn offer_first_login_transfer(&self, _force: bool) {}
    async fn reset_domains(&self) {}
    async fn persist_session(&self, _snapshot_json: String) {}
    async fn clear_session(&self) {}
    async fn mark_expired(&self, _snapshot_json: String) {}
    async fn persist_poll_state(&self, _state: olaz_api::PollState) {}
    async fn persist_ws_cursors(&self, _cursors: olaz_ws::CursorMap) {}
    async fn apply_batch(
        &self,
        _cmd: Option<u16>,
        _increment_unread: bool,
        _notify_incoming: bool,
        _payload: serde_json::Map<String, serde_json::Value>,
    ) -> olaz_core::conversations::BatchApplyDelta {
        Default::default()
    }
    async fn apply_parsed_events(
        &self,
        _cmd: u16,
        _increment_unread: bool,
        _notify_incoming: bool,
        _envelope: olaz_core::typed_chat::TypedChatEnvelope,
    ) -> olaz_core::conversations::BatchApplyDelta {
        Default::default()
    }
    async fn mobile_sync(&self, _events: Vec<olaz_core::reduce::classify::MobileSyncEvent>) {}
    async fn e2ee_signal(&self, _cmd: u16, _payload: serde_json::Map<String, serde_json::Value>) {}
    async fn e2ee_deliver_reports(
        &self,
        _cmd: u16,
        _payload: serde_json::Map<String, serde_json::Value>,
    ) {
    }
    async fn e2ee_connected(&self, _uid: String) {}
    async fn e2ee_disconnected(&self) {}
    async fn voip_control(
        &self,
        _act: String,
        _raw_data: serde_json::Value,
        _data: serde_json::Map<String, serde_json::Value>,
    ) {
    }
    async fn show_typing(&self, _conv_id: String, _uid: String, _on_pc: bool) {}
    async fn pin_topic(&self, _conv_id: String) -> bool {
        false
    }
    async fn group_notice(
        &self,
        _act: String,
        _data: serde_json::Map<String, serde_json::Value>,
        _ts: i64,
    ) {
    }
    async fn mute(
        &self,
        _conv_id: String,
        _set: bool,
        _start: i64,
        _start_explicit: bool,
        _duration: i64,
    ) {
    }
}

#[tokio::test]
async fn opening_existing_sync_rows_resolves_global_sender_and_repairs_sqlite() {
    use olaz_core::actor::CoreHandle;
    use olaz_core::runner::SessionEffectRunner;
    use olaz_net::http::RawResponse;
    use olaz_net::mock::MockTransport;
    use olaz_net::{LoginAccount, SessionClient, ZaloDomains};
    use std::sync::{Arc, Mutex};
    let global = "fixture-global-sender-0000000001";
    let transport = MockTransport::from_fn(move |req| {
        let data = match req.path().as_str() {
            "/api/gid/decrypt" => json!({(global): "123"}),
            "/api/social/group/members" => {
                let body = String::from_utf8(req.body.clone().unwrap()).unwrap();
                let encoded = olaz_crypto::percent_decode(body.strip_prefix("params=").unwrap());
                let plain = olaz_crypto::decode_aes(b"0123456789abcdef", &encoded).unwrap();
                let payload: serde_json::Value = serde_json::from_str(&plain).unwrap();
                assert_eq!(payload["friend_pversion_map"], json!(["123_0"]));
                json!({"profiles": {"123": {"displayName": "Fixture sender", "avatar": "https://cdn.example.invalid/avatar.png"}}})
            }
            _ => json!({}),
        };
        Ok(RawResponse::new(
            200,
            json!({"error_code":0,"data":data}).to_string().into_bytes(),
        ))
    });
    let client = Arc::new(SessionClient::new(
        transport,
        "fixture-imei".into(),
        "FixtureMac".into(),
    ));
    client.update_credentials(
        LoginAccount {
            user_id: "100".into(),
            ..Default::default()
        },
        b"0123456789abcdef".to_vec(),
        "fixture".into(),
        Some(ZaloDomains::default()),
    );
    let runner = Arc::new(SessionEffectRunner::new(
        Arc::clone(&client),
        Arc::new(GidRepairHost),
        tokio::runtime::Handle::current(),
    ));
    let original = make_msg("8801", "g9901", global, 1_700_000_000_000, "Preserve body");
    let stored = olaz_core::messages::to_db_stored(
        &olaz_wire::encode_chat_message(&original, &original.client_id).unwrap(),
    );
    let mut db = olaz_store::Store::open_in_memory().unwrap();
    db.save_messages(&[stored]).unwrap();
    let store = Arc::new(Mutex::new(db));
    *runner.shared_store_slot().lock().unwrap() = Some(Arc::clone(&store));
    let core =
        CoreHandle::start_with_state(ready_state(), runner, tokio::runtime::Handle::current());
    core.request_unit(Command::OpenConversation {
        id: "g9901".into(),
        preloaded: Vec::new(),
        skip_local_read: false,
    })
    .await;
    core.settle().await.unwrap();
    let snapshot = core.full_snapshot().await.unwrap();
    assert_eq!(
        snapshot.messages.windows["g9901"][0].sender_name,
        "Fixture sender"
    );
    assert_eq!(snapshot.messages.windows["g9901"][0].sender_id, "123");
    let saved = store
        .lock()
        .unwrap()
        .message("g9901", "8801")
        .unwrap()
        .unwrap();
    assert_eq!(saved.sender_id, "123");
    assert_eq!(saved.sender_name, "Fixture sender");
    assert_eq!(saved.client_id, original.client_id);
    assert_eq!(
        client
            .transport()
            .requests()
            .iter()
            .filter(|r| r.path() == "/api/gid/decrypt")
            .count(),
        1
    );
    core.stop();
}
