#![allow(clippy::expect_used, clippy::unwrap_used)]
//! Paused-time integration scenarios for the U6 message actions domain (`actions.rs` +
//! `CoreHandle` + `SessionEffectRunner`): delete-undo 5 s timer & replacement, pending local
//! reaction 20 s echo-suppression TTL, and cancellation of in-flight react/recall/delete-undo
//! across logout and session expiry.

use std::collections::{BTreeMap, VecDeque};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use async_trait::async_trait;
use olaz_api::PollState;
use olaz_core::actor::CoreHandle;
use olaz_core::conversations::{
    BatchApplyDelta, ConversationPreview, ConversationSummary, IdentityTable,
};
use olaz_core::input::{Command, LegacyCookie};
use olaz_core::reduce::classify::MobileSyncEvent;
use olaz_core::runner::{Host, SessionEffectRunner};
use olaz_core::state::{CoreState, Phase, Profile};
use olaz_core::typed_chat::TypedChatEnvelope;
use olaz_net::NetError;
use olaz_net::http::{RawResponse, RequestSpec, url_path};
use olaz_net::{LoginAccount, SessionClient, Transport, ZaloDomains};
use olaz_store::Store;
use olaz_wire::{ChatMessage, DeleteMode, Kind, MessageMenu, Status, encode_chat_message};
use olaz_ws::CursorMap;
use serde_json::{Map, Value, json};
use tokio::runtime::Handle;
use tokio::sync::{Notify, oneshot};

struct HeldTransport {
    requests: Mutex<Vec<RequestSpec>>,
    responses: Mutex<VecDeque<(bool, Result<RawResponse, NetError>)>>,
    waiters: Mutex<VecDeque<oneshot::Sender<()>>>,
    arrived: Notify,
    arrived_count: Mutex<usize>,
}

impl HeldTransport {
    fn new(entries: Vec<(bool, Result<RawResponse, NetError>)>) -> Self {
        Self {
            requests: Mutex::new(Vec::new()),
            responses: Mutex::new(VecDeque::from(entries)),
            waiters: Mutex::new(VecDeque::new()),
            arrived: Notify::new(),
            arrived_count: Mutex::new(0),
        }
    }

    async fn wait_for_held(&self, target: usize) {
        loop {
            let notified = self.arrived.notified();
            if *self
                .arrived_count
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                >= target
            {
                return;
            }
            notified.await;
        }
    }

    fn release_one(&self) {
        if let Some(tx) = self
            .waiters
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .pop_front()
        {
            let _ = tx.send(());
        }
    }

    fn paths(&self) -> Vec<String> {
        self.requests
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .iter()
            .map(|r| url_path(&r.url))
            .collect()
    }
}

struct ArcTransport(Arc<HeldTransport>);

impl Transport for ArcTransport {
    fn send(
        &self,
        request: RequestSpec,
    ) -> impl std::future::Future<Output = Result<RawResponse, NetError>> + Send {
        self.0.send(request)
    }
}

impl Transport for HeldTransport {
    fn send(
        &self,
        request: RequestSpec,
    ) -> impl std::future::Future<Output = Result<RawResponse, NetError>> + Send {
        self.requests
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .push(request);
        let (hold, resp) = self
            .responses
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .pop_front()
            .unwrap_or_else(|| {
                (
                    false,
                    Ok(RawResponse::new(
                        200,
                        br#"{"error_code":0,"data":{}}"#.to_vec(),
                    )),
                )
            });
        let rx = if hold {
            let (tx, rx) = oneshot::channel();
            self.waiters
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .push_back(tx);
            *self
                .arrived_count
                .lock()
                .unwrap_or_else(PoisonError::into_inner) += 1;
            self.arrived.notify_waiters();
            Some(rx)
        } else {
            None
        };
        async move {
            if let Some(rx) = rx {
                let _ = rx.await;
            }
            resp
        }
    }
}

#[derive(Default)]
struct ActionsScenarioHost {
    cards: Mutex<Vec<(String, String)>>,
    remote_reactions: Mutex<Vec<String>>,
    remote_recalls: Mutex<Vec<String>>,
}

#[async_trait]
impl Host for ActionsScenarioHost {
    async fn load_saved_session(&self) -> Option<String> {
        None
    }
    async fn load_legacy_cookie(&self) -> Option<LegacyCookie> {
        None
    }
    async fn set_pref(&self, _key: String, _value: String) {}
    async fn prepare_store(&self, _user_id: String, _account: LoginAccount) {}
    async fn start_bootstrap(&self) {}
    async fn offer_first_login_transfer(&self, _force: bool) {}
    async fn reset_domains(&self) {}
    async fn persist_session(&self, _snapshot_json: String) {}
    async fn clear_session(&self) {}
    async fn mark_expired(&self, _snapshot_json: String) {}
    async fn persist_poll_state(&self, _state: PollState) {}
    async fn persist_ws_cursors(&self, _cursors: CursorMap) {}
    async fn apply_batch(
        &self,
        _cmd: Option<u16>,
        _increment_unread: bool,
        _notify_incoming: bool,
        _payload: Map<String, Value>,
    ) -> BatchApplyDelta {
        BatchApplyDelta::default()
    }
    async fn apply_parsed_events(
        &self,
        _cmd: u16,
        _increment_unread: bool,
        _notify_incoming: bool,
        _envelope: TypedChatEnvelope,
    ) -> BatchApplyDelta {
        BatchApplyDelta::default()
    }
    async fn mobile_sync(&self, _events: Vec<MobileSyncEvent>) {}
    async fn e2ee_signal(&self, _cmd: u16, _payload: Map<String, Value>) {}
    async fn e2ee_deliver_reports(&self, _cmd: u16, _payload: Map<String, Value>) {}
    async fn e2ee_connected(&self, _uid: String) {}
    async fn e2ee_disconnected(&self) {}
    async fn voip_control(&self, _act: String, _raw_data: Value, _data: Map<String, Value>) {}
    async fn show_typing(&self, _conv_id: String, _uid: String, _on_pc: bool) {}
    async fn pin_topic(&self, _conv_id: String) {}
    async fn group_notice(&self, _act: String, _data: Map<String, Value>, _ts: i64) {}
    async fn mute(
        &self,
        _conv_id: String,
        _set: bool,
        _start: i64,
        _start_explicit: bool,
        _duration: i64,
    ) {
    }
    async fn apply_remote_reaction(
        &self,
        _conv_id: String,
        msg_id: String,
        _cli_msg_id: String,
        _sender_id: String,
        _r_type: String,
        _r_icon: String,
        _event_id: String,
        _react_client_id: String,
        _sender_name: String,
    ) -> bool {
        self.remote_reactions
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .push(msg_id);
        true
    }
    async fn apply_remote_recall(
        &self,
        _conv_id: String,
        msg_id: String,
        _cli_msg_id: String,
        _update_conversation_preview: bool,
    ) -> bool {
        self.remote_recalls
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .push(msg_id);
        true
    }
    async fn apply_remote_delete(
        &self,
        _conv_id: String,
        _msg_id: String,
        _cli_msg_id: String,
        _update_conversation_preview: bool,
    ) -> bool {
        true
    }
    async fn show_card(&self, conv_id: String, text: String) {
        self.cards
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .push((conv_id, text));
    }
}

fn ok_json_response() -> Result<RawResponse, NetError> {
    Ok(RawResponse::new(
        200,
        br#"{"error_code":0,"data":{}}"#.to_vec(),
    ))
}

fn make_message(conv_id: &str, id: &str, cli_id: &str, text: &str, ts_ms: i64) -> ChatMessage {
    ChatMessage {
        id: id.to_owned(),
        conversation_id: conv_id.to_owned(),
        sender_id: "me100".to_owned(),
        sender_name: "Me".to_owned(),
        sender_avatar: None,
        is_mine: true,
        kind: Kind::Text,
        text: text.to_owned(),
        date_ms: ts_ms,
        status: Status::Sent,
        quote: None,
        reactions: Vec::new(),
        is_e2ee: false,
        mentions: Vec::new(),
        card_buttons: Vec::new(),
        suggests_stickers: false,
        menu: MessageMenu {
            delete: Some(DeleteMode::ForMe),
            recall: true,
            ..MessageMenu::default()
        },
        client_id: cli_id.to_owned(),
        ttl_ms: 0,
        fallback_urls: Vec::new(),
        text_styles: Vec::new(),
        urgency: 0,
    }
}

struct ActionsHarness {
    core: Arc<CoreHandle>,
    transport: Arc<HeldTransport>,
    host: Arc<ActionsScenarioHost>,
    store: Arc<Mutex<Store>>,
    _tmp: tempfile::TempDir,
}

fn build_harness(
    conv_id: &str,
    msgs: Vec<ChatMessage>,
    responses: Vec<(bool, Result<RawResponse, NetError>)>,
) -> ActionsHarness {
    let tmp = tempfile::tempdir().expect("tempdir");
    let db_path = tmp.path().join("actions_scenario.sqlite3");
    let mut store_raw = Store::open(&db_path).expect("open store");
    let stored_rows: Vec<olaz_store::StoredMessage> = msgs
        .iter()
        .filter_map(|m| {
            let wire = encode_chat_message(m, &m.client_id)?;
            Some(olaz_store::StoredMessage {
                id: wire.id,
                conv_id: wire.conv_id,
                client_id: wire.client_id,
                sender_id: wire.sender_id,
                sender_name: wire.sender_name,
                sender_avatar: wire.sender_avatar,
                is_mine: wire.is_mine,
                text: wire.text,
                kind_tag: wire.kind_tag,
                ts_ms: wire.ts_ms,
                status: wire.status,
                raw_json_data: wire.raw_json_data,
            })
        })
        .collect();
    store_raw.save_messages(&stored_rows).expect("save msgs");
    let store = Arc::new(Mutex::new(store_raw));

    let transport = Arc::new(HeldTransport::new(responses));
    let client = Arc::new(SessionClient::new(
        ArcTransport(Arc::clone(&transport)),
        "test-imei".to_owned(),
        "TestMac".to_owned(),
    ));
    let domains = ZaloDomains {
        auth: "http://fake.local".to_owned(),
        wpa_chat: "http://fake.local".to_owned(),
        lp_chat: "http://fake.local".to_owned(),
        lp_control: "http://fake.local".to_owned(),
        service_candidates: BTreeMap::from([
            ("chat".to_owned(), vec!["http://fake.local".to_owned()]),
            ("chat_e2e".to_owned(), vec!["http://fake.local".to_owned()]),
            ("reaction".to_owned(), vec!["http://fake.local".to_owned()]),
            ("group".to_owned(), vec!["http://fake.local".to_owned()]),
            ("group_e2e".to_owned(), vec!["http://fake.local".to_owned()]),
            (
                "conversation".to_owned(),
                vec!["http://fake.local".to_owned()],
            ),
        ]),
        ..Default::default()
    };
    client.with_session(|s| {
        s.domains = domains.clone();
        s.zpw_sek = Some("sek_actions_test".to_owned());
        s.secret_key = Some(b"0123456789abcdef".to_vec());
        s.account = Some(LoginAccount {
            user_id: "me100".to_owned(),
            display_name: "Me".to_owned(),
            avatar: String::new(),
            phone: String::new(),
            send2me_id: "9me100".to_owned(),
            dkey: String::new(),
            zpw_enk: "0123456789abcdef".to_owned(),
            zpw_sek: "sek_actions_test".to_owned(),
            need_sync_msg: Some(false),
        });
    });

    let host = Arc::new(ActionsScenarioHost::default());
    let runner = Arc::new(SessionEffectRunner::new(
        Arc::clone(&client),
        Arc::clone(&host) as Arc<dyn Host>,
        Handle::current(),
    ));
    runner.attach_store(Arc::clone(&store));

    let mut initial = CoreState::default();
    initial.session.phase = Phase::Ready;
    initial.session.profile = Some(Profile {
        user_id: "me100".to_owned(),
        display_name: "Me".to_owned(),
        avatar: None,
        phone: None,
    });
    initial.session.self_conversation_id = Some("9me100".to_owned());
    initial.conversations.open_conversation_id = Some(conv_id.to_owned());
    initial.conversations.identities = IdentityTable::default();
    let last_msg = msgs.last();
    initial.conversations.conversations = vec![ConversationSummary {
        id: conv_id.to_owned(),
        is_group: false,
        name: "Peer".to_owned(),
        avatar: None,
        pinned: false,
        members: 0,
        unread: 0,
        preview: last_msg.map(|m| ConversationPreview {
            text: m.text.clone(),
            date_ms: Some(m.date_ms),
            from_me: m.is_mine,
        }),
    }];
    initial.messages.windows.insert(conv_id.to_owned(), msgs);

    let core = Arc::new(CoreHandle::start_with_state(
        initial,
        runner,
        Handle::current(),
    ));
    ActionsHarness {
        core,
        transport,
        host,
        store,
        _tmp: tmp,
    }
}

#[tokio::test(start_paused = true)]
async fn delete_undo_expires_after_5s_and_commits_api_and_store() {
    let conv_id = "peer1";
    let m1 = make_message(conv_id, "m1", "c1", "Delete me", 1_700_000_001_000);
    let h = build_harness(conv_id, vec![m1], vec![(false, ok_json_response())]);

    h.core
        .request_unit(Command::DeleteForMe {
            conv_id: conv_id.to_owned(),
            msg_id: "m1".to_owned(),
            confirmed: true,
            now_ms: 1_700_000_010_000,
        })
        .await;

    let snap = h.core.full_snapshot().await.expect("snap");
    assert!(snap.messages.windows[conv_id].is_empty());
    let undo = snap.delete_undo.expect("delete_undo active");
    assert_eq!(undo.conv_id, conv_id);
    assert_eq!(undo.count, 1);
    assert_eq!(undo.deadline_ms, 1_700_000_015_000);
    assert!(
        h.transport.paths().is_empty(),
        "delete API must not fire before 5 s undo window expires"
    );

    // Let the spawned 5 s timer task register its sleep at virtual t = 0.
    for _ in 0..4 {
        tokio::task::yield_now().await;
    }

    // Advance 4.9 s — still pending.
    tokio::time::advance(Duration::from_millis(4_900)).await;
    tokio::task::yield_now().await;
    assert!(h.transport.paths().is_empty());

    // Advance past 5 s — timer commits API and deletes from SQLite.
    tokio::time::advance(Duration::from_millis(200)).await;
    for _ in 0..4 {
        tokio::task::yield_now().await;
    }
    h.core.wait_idle().await;

    let after = h.core.full_snapshot().await.expect("after");
    assert!(after.delete_undo.is_none());
    assert_eq!(h.transport.paths(), vec!["/api/message/delete"]);
    let stored = h
        .store
        .lock()
        .unwrap()
        .load_all_messages()
        .expect("load_all");
    assert!(stored.is_empty(), "SQLite row must be deleted on commit");
    h.core.stop();
}

#[tokio::test(start_paused = true)]
async fn delete_undo_before_5s_cancels_timer_restores_message_and_skips_api() {
    let conv_id = "peer2";
    let m1 = make_message(conv_id, "m1", "c1", "Restore me", 1_700_000_001_000);
    let h = build_harness(conv_id, vec![m1], vec![]);

    h.core
        .request_unit(Command::DeleteForMe {
            conv_id: conv_id.to_owned(),
            msg_id: "m1".to_owned(),
            confirmed: true,
            now_ms: 1_700_000_010_000,
        })
        .await;
    assert!(h.core.full_snapshot().await.expect("snap").messages.windows[conv_id].is_empty());

    tokio::time::advance(Duration::from_secs(2)).await;
    h.core.request_unit(Command::UndoDelete).await;
    h.core.wait_idle().await;

    // Advance well past original 5 s deadline — cancelled timer must never commit.
    tokio::time::advance(Duration::from_secs(10)).await;
    h.core.wait_idle().await;

    let after = h.core.full_snapshot().await.expect("after");
    assert!(after.delete_undo.is_none());
    assert_eq!(after.messages.windows[conv_id].len(), 1);
    assert_eq!(after.messages.windows[conv_id][0].id, "m1");
    assert!(h.transport.paths().is_empty());
    let cards = h.host.cards.lock().unwrap().clone();
    assert_eq!(
        cards,
        vec![(conv_id.to_owned(), "Khôi phục thành công".to_owned())]
    );
    h.core.stop();
}

#[tokio::test(start_paused = true)]
async fn second_delete_commits_first_pending_batch_immediately() {
    let conv_id = "peer3";
    let m1 = make_message(conv_id, "m1", "c1", "First", 1_700_000_001_000);
    let m2 = make_message(conv_id, "m2", "c2", "Second", 1_700_000_002_000);
    let h = build_harness(
        conv_id,
        vec![m1, m2],
        vec![(false, ok_json_response()), (false, ok_json_response())],
    );

    h.core
        .request_unit(Command::DeleteForMe {
            conv_id: conv_id.to_owned(),
            msg_id: "m1".to_owned(),
            confirmed: true,
            now_ms: 1_700_000_010_000,
        })
        .await;
    assert!(h.transport.paths().is_empty());

    tokio::time::advance(Duration::from_secs(2)).await;
    h.core
        .request_unit(Command::DeleteForMe {
            conv_id: conv_id.to_owned(),
            msg_id: "m2".to_owned(),
            confirmed: true,
            now_ms: 1_700_000_012_000,
        })
        .await;
    h.core.settle().await;
    // Allow first commit API to run while second timer is still pending.
    tokio::time::advance(Duration::from_millis(50)).await;
    tokio::task::yield_now().await;

    assert_eq!(
        h.transport.paths(),
        vec!["/api/message/delete"],
        "second delete must immediately commit the first pending batch"
    );
    let mid = h.core.full_snapshot().await.expect("mid");
    assert_eq!(
        mid.delete_undo.as_ref().map(|u| u.deadline_ms),
        Some(1_700_000_017_000)
    );

    // Undo the second delete before its 5 s window expires: m2 comes back, m1 stays deleted.
    h.core.request_unit(Command::UndoDelete).await;
    h.core.wait_idle().await;
    let final_snap = h.core.full_snapshot().await.expect("final");
    assert_eq!(final_snap.messages.windows[conv_id].len(), 1);
    assert_eq!(final_snap.messages.windows[conv_id][0].id, "m2");
    assert_eq!(h.transport.paths().len(), 1);
    h.core.stop();
}

#[tokio::test(start_paused = true)]
async fn pending_local_reaction_suppresses_echo_within_20s_and_accepts_after_ttl() {
    let conv_id = "peer4";
    let m1 = make_message(conv_id, "m1", "c1", "React target", 1_700_000_001_000);
    let h = build_harness(conv_id, vec![m1], vec![(false, ok_json_response())]);

    // 1. Local react at t = 1_700_000_010_000 -> optimistic count = 1, pending local reaction recorded.
    h.core
        .request_unit(Command::React {
            conv_id: conv_id.to_owned(),
            msg_id: "m1".to_owned(),
            emoji: "❤️".to_owned(),
            remove_all: false,
            now_ms: 1_700_000_010_000,
        })
        .await;
    h.core.wait_idle().await;
    let after_local = h.core.full_snapshot().await.expect("after_local");
    assert_eq!(
        after_local.messages.windows[conv_id][0].reactions[0].count,
        1
    );

    // 2. Echo arrives 10 s later (within 20 s TTL) with a different eventId -> suppressed!
    let echo_payload = json!({
        "msgs": [{
            "uidFrom": "me100",
            "idTo": conv_id,
            "msgType": "chat.reaction",
            "actionId": "act_echo_1",
            "content": {
                "rType": "5",
                "rIcon": "/-heart",
                "rMsg": [{"gMsgID": "m1", "cMsgID": "c1"}]
            }
        }]
    });
    let _ = h
        .core
        .request(Command::ApplyBatchDirect {
            payload: echo_payload.as_object().cloned().unwrap(),
            default_cmd: 501,
            fallback_conv_id: None,
            is_group_hint: Some(false),
            increment_unread: false,
            notify_incoming: false,
            persist_conversations: false,
            probe_freshness: false,
            now_ms: Some(1_700_000_020_000),
        })
        .await;
    h.core.wait_idle().await;
    let after_echo = h.core.full_snapshot().await.expect("after_echo");
    assert_eq!(
        after_echo.messages.windows[conv_id][0].reactions[0].count, 1,
        "self echo within 20 s TTL must be suppressed"
    );

    // 3. Another reaction event from self arrives 25 s after local react (> 20 s TTL) -> accepted!
    let late_payload = json!({
        "msgs": [{
            "uidFrom": "me100",
            "idTo": conv_id,
            "msgType": "chat.reaction",
            "actionId": "act_late_2",
            "content": {
                "rType": "5",
                "rIcon": "/-heart",
                "rMsg": [{"gMsgID": "m1", "cMsgID": "c1"}]
            }
        }]
    });
    let _ = h
        .core
        .request(Command::ApplyBatchDirect {
            payload: late_payload.as_object().cloned().unwrap(),
            default_cmd: 501,
            fallback_conv_id: None,
            is_group_hint: Some(false),
            increment_unread: false,
            notify_incoming: false,
            persist_conversations: false,
            probe_freshness: false,
            now_ms: Some(1_700_000_035_000),
        })
        .await;
    h.core.wait_idle().await;
    let after_late = h.core.full_snapshot().await.expect("after_late");
    assert_eq!(
        after_late.messages.windows[conv_id][0].reactions[0].count, 2,
        "event after 20 s pending TTL must not be suppressed"
    );
    h.core.stop();
}

#[tokio::test(start_paused = true)]
async fn logout_and_session_expired_cancel_inflight_react_recall_and_delete_undo() {
    // Part A: LogOut cancels held react + held recall + active 5 s delete-undo timer.
    let conv_id = "peer5";
    let m1 = make_message(conv_id, "m1", "c1", "React in flight", 1_700_000_001_000);
    let m2 = make_message(conv_id, "m2", "c2", "Recall in flight", 1_700_000_002_000);
    let m3 = make_message(conv_id, "m3", "c3", "Delete pending", 1_700_000_003_000);
    let h = build_harness(
        conv_id,
        vec![m1, m2, m3],
        vec![
            (true, ok_json_response()), // held react
            (true, ok_json_response()), // held recall
        ],
    );

    let core_react = Arc::clone(&h.core);
    let react_task = tokio::spawn(async move {
        core_react
            .request_unit(Command::React {
                conv_id: conv_id.to_owned(),
                msg_id: "m1".to_owned(),
                emoji: "👍".to_owned(),
                remove_all: false,
                now_ms: 1_700_000_010_000,
            })
            .await;
    });
    h.transport.wait_for_held(1).await;

    let core_recall = Arc::clone(&h.core);
    let recall_task = tokio::spawn(async move {
        core_recall
            .request_unit(Command::Recall {
                conv_id: conv_id.to_owned(),
                msg_id: "m2".to_owned(),
                is_e2ee_thread: Some(false),
                now_ms: 1_700_000_010_000,
            })
            .await;
    });
    h.transport.wait_for_held(2).await;

    h.core
        .request_unit(Command::DeleteForMe {
            conv_id: conv_id.to_owned(),
            msg_id: "m3".to_owned(),
            confirmed: true,
            now_ms: 1_700_000_010_000,
        })
        .await;
    assert!(
        h.core
            .full_snapshot()
            .await
            .expect("snap")
            .delete_undo
            .is_some()
    );

    // LogOut aborts in-flight work and clears delete_undo + action state.
    h.core.send(Command::LogOut);
    let _ = tokio::time::timeout(Duration::from_secs(2), react_task).await;
    let _ = tokio::time::timeout(Duration::from_secs(2), recall_task).await;

    // Release held responses and advance past 5 s delete-undo deadline: nothing stale fires.
    h.transport.release_one();
    h.transport.release_one();
    tokio::time::advance(Duration::from_secs(10)).await;
    h.core.settle().await;

    let after = h.core.full_snapshot().await.expect("after logout");
    assert!(after.delete_undo.is_none());
    assert!(after.message_confirm.is_none());
    assert!(after.auto_delete.is_none());
    assert!(after.starred_ids.is_empty());
    assert!(
        !h.transport
            .paths()
            .iter()
            .any(|p| p == "/api/message/delete"),
        "delete timer must not commit after LogOut"
    );
    assert!(
        h.host.remote_recalls.lock().unwrap().is_empty(),
        "stale recall completion must be dropped after LogOut"
    );
    h.core.stop();

    // Part B: SessionExpired also cancels active delete-undo timer cleanly.
    let m4 = make_message(conv_id, "m4", "c4", "Expire pending", 1_700_000_004_000);
    let h2 = build_harness(conv_id, vec![m4], vec![]);
    h2.core
        .request_unit(Command::DeleteForMe {
            conv_id: conv_id.to_owned(),
            msg_id: "m4".to_owned(),
            confirmed: true,
            now_ms: 1_700_000_010_000,
        })
        .await;
    h2.core.send(Command::SessionExpired {
        reason: "expired".to_owned(),
    });
    tokio::time::advance(Duration::from_secs(10)).await;
    h2.core.settle().await;

    let after_exp = h2.core.full_snapshot().await.expect("after expire");
    assert!(after_exp.delete_undo.is_none());
    assert!(
        !h2.transport
            .paths()
            .iter()
            .any(|p| p == "/api/message/delete"),
        "delete timer must not commit after SessionExpired"
    );
    h2.core.stop();
}
