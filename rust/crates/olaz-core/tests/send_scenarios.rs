#![allow(clippy::expect_used, clippy::unwrap_used)]
//! Paused-time integration scenarios for the U5 send, optimistic lifecycle, markRead split,
//! E2EE host boundary, and bidirectional typing flows through `CoreHandle` + `SessionEffectRunner`.

use std::collections::{BTreeMap, BTreeSet, VecDeque};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use async_trait::async_trait;
use olaz_api::{PollState, SendMessageResult};
use olaz_core::actor::{ActorSink, CoreHandle};
use olaz_core::conversations::{
    BatchApplyDelta, ConversationPreview, ConversationSummary, IdentityTable,
};
use olaz_core::effect::Effect;
use olaz_core::input::{Command, E2eeQuoteArg, LegacyCookie};
use olaz_core::messages::WindowDelta;
use olaz_core::reduce::classify::MobileSyncEvent;
use olaz_core::runner::{EffectRunner, Host, SessionEffectRunner};
use olaz_core::state::{CoreState, Phase, Profile};
use olaz_core::typed_chat::TypedChatEnvelope;
use olaz_net::NetError;
use olaz_net::http::{RawResponse, RequestSpec, url_path};
use olaz_net::{LoginAccount, SessionClient, Transport, ZaloDomains};
use olaz_store::Store;
use olaz_wire::{ChatMessage, Kind, Mention, MessageMenu, Status, TextStyle, encode_chat_message};
use olaz_ws::CursorMap;
use serde_json::{Map, Value, json};
use tokio::runtime::Handle;
use tokio::sync::{Notify, oneshot};

/// Scripted HTTP transport supporting held responses so tests can observe optimistic rows
/// and inject concurrent WS echoes before the send HTTP reply resolves.
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

/// Captures `Effect::EngineLog` lines emitted during a scenario while delegating all effects
/// to `SessionEffectRunner`.
struct LogSpyRunner<T: Transport + 'static> {
    inner: Arc<SessionEffectRunner<T>>,
    logs: Arc<Mutex<Vec<String>>>,
}

impl<T: Transport + 'static> EffectRunner for LogSpyRunner<T> {
    fn dispatch(&self, effects: Vec<Effect>, sink: ActorSink) {
        for eff in &effects {
            if let Effect::EngineLog(line) = eff {
                self.logs
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner)
                    .push(line.clone());
            }
        }
        self.inner.dispatch(effects, sink);
    }

    fn shutdown(&self) {
        self.inner.shutdown();
    }
}

#[derive(Clone, Debug)]
struct E2eeCall {
    conv_id: String,
    text: String,
    client_id: String,
    quote: Option<E2eeQuoteArg>,
}

#[derive(Default)]
struct SendScenarioHost {
    e2ee_calls: Mutex<Vec<E2eeCall>>,
    e2ee_results: Mutex<VecDeque<Result<SendMessageResult, String>>>,
    typing_calls: Mutex<Vec<(String, String, bool)>>,
}

#[async_trait]
impl Host for SendScenarioHost {
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
    async fn show_typing(&self, conv_id: String, uid: String, on_pc: bool) {
        self.typing_calls
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .push((conv_id, uid, on_pc));
    }
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
    async fn send_e2ee_text(
        &self,
        conv_id: String,
        text: String,
        client_id: String,
        quote: Option<E2eeQuoteArg>,
    ) -> Result<SendMessageResult, String> {
        self.e2ee_calls
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .push(E2eeCall {
                conv_id,
                text,
                client_id,
                quote,
            });
        self.e2ee_results
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .pop_front()
            .unwrap_or_else(|| Err("no scripted e2ee result".to_owned()))
    }
}

fn ok_send_response(msg_id: &str, cli_id: &str) -> Result<RawResponse, NetError> {
    let body = json!({
        "error_code": 0,
        "data": {
            "msgId": msg_id,
            "cliMsgId": cli_id
        }
    })
    .to_string()
    .into_bytes();
    Ok(RawResponse::new(200, body))
}

fn error_send_response(code: i64, msg: &str) -> Result<RawResponse, NetError> {
    let body = json!({
        "error_code": code,
        "error_message": msg
    })
    .to_string()
    .into_bytes();
    Ok(RawResponse::new(200, body))
}

fn make_ready_state() -> CoreState {
    let mut state = CoreState::default();
    state.session.phase = Phase::Ready;
    state.session.self_conversation_id = Some("9200001".to_owned());
    state.session.profile = Some(Profile {
        user_id: "2000001".to_owned(),
        display_name: "Alice".to_owned(),
        avatar: Some("https://cdn.example.invalid/alice.jpg".to_owned()),
        phone: None,
    });
    state.conversations.identities = IdentityTable::default();
    state.conversations.conversations.push(ConversationSummary {
        id: "3000001".to_owned(),
        is_group: false,
        name: "Bob".to_owned(),
        avatar: None,
        pinned: false,
        members: 0,
        unread: 3,
        preview: Some(ConversationPreview {
            text: "Before".to_owned(),
            date_ms: Some(1_700_000_000_000),
            from_me: false,
        }),
    });
    state
}

fn make_authenticated_client(transport: HeldTransport) -> Arc<SessionClient<HeldTransport>> {
    let client = Arc::new(SessionClient::new(
        transport,
        "imei-send-scenarios".to_owned(),
        "Mac".to_owned(),
    ));
    client.update_credentials(
        LoginAccount {
            user_id: "2000001".to_owned(),
            display_name: "Alice".to_owned(),
            ..LoginAccount::default()
        },
        b"0123456789abcdef".to_vec(),
        "sek.test".to_owned(),
        Some(ZaloDomains::default()),
    );
    client
}

fn make_message(
    id: &str,
    conv_id: &str,
    sender_id: &str,
    sender_name: &str,
    date_ms: i64,
    text: &str,
    client_id: &str,
) -> ChatMessage {
    ChatMessage {
        id: id.to_owned(),
        conversation_id: conv_id.to_owned(),
        sender_id: sender_id.to_owned(),
        sender_name: sender_name.to_owned(),
        sender_avatar: None,
        is_mine: sender_id == "2000001",
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
        client_id: client_id.to_owned(),
        text_styles: Vec::new(),
        ttl_ms: 0,
        urgency: 0,
    }
}

#[tokio::test(start_paused = true)]
async fn s01_optimistic_row_visible_before_http_reply_and_swaps_on_ack() {
    let transport = HeldTransport::new(vec![(true, ok_send_response("9001001", "5000000000001"))]);
    let client = make_authenticated_client(transport);
    let host = Arc::new(SendScenarioHost::default());
    let inner_runner = Arc::new(SessionEffectRunner::new(
        Arc::clone(&client),
        Arc::clone(&host) as Arc<dyn Host>,
        Handle::current(),
    ));
    let store = Arc::new(Mutex::new(
        Store::open_in_memory().expect("in-memory store"),
    ));
    inner_runner.attach_store(Arc::clone(&store));

    let logs = Arc::new(Mutex::new(Vec::new()));
    let runner: Arc<dyn EffectRunner> = Arc::new(LogSpyRunner {
        inner: Arc::clone(&inner_runner),
        logs: Arc::clone(&logs),
    });

    let mut initial = make_ready_state();
    initial
        .send
        .auto_delete_ttl_ms
        .insert("3000001".to_owned(), 86_400_000);
    let core = Arc::new(CoreHandle::start_with_state(
        initial,
        runner,
        Handle::current(),
    ));
    core.request_unit(Command::WriteThroughReplaceWindow {
        conv_id: "3000001".to_owned(),
        messages: vec![make_message(
            "8000001",
            "3000001",
            "3000001",
            "Bob",
            1_700_000_000_000,
            "Before",
            "c_8000001",
        )],
    })
    .await;
    let _ = core.next_changes().await.expect("initial window reset");

    let core_bg = Arc::clone(&core);
    let send_task = tokio::spawn(async move {
        core_bg
            .request_bool(Command::SendText {
                conv_id: "3000001".to_owned(),
                text: "Hello optimistic".to_owned(),
                quote_id: None,
                mentions: vec![Mention {
                    uid: "3000001".to_owned(),
                    pos: 0,
                    len: 5,
                    is_all: false,
                }],
                styles: vec![TextStyle {
                    start: 0,
                    len: 5,
                    st: "b".to_owned(),
                }],
                urgency: 2,
                client_id: 5_000_000_000_001,
                now_ms: 1_700_000_010_000,
                is_e2ee: None,
                ttl_ms: None,
            })
            .await
    });

    // Wait until the held HTTP request reaches the transport — the optimistic row MUST already
    // be published through ChangeHub while the HTTP request is still in flight.
    client.transport().wait_for_held(1).await;
    let _ = core.settle().await;

    let pre_ack = core.next_changes().await.expect("optimistic changes");
    assert_eq!(pre_ack.window_deltas.len(), 1);
    match &pre_ack.window_deltas[0] {
        WindowDelta::Append { conv_id, messages } => {
            assert_eq!(conv_id, "3000001");
            assert_eq!(messages.len(), 1);
            assert_eq!(messages[0].id, "5000000000001");
            assert_eq!(messages[0].status, Status::Sending);
            assert_eq!(messages[0].ttl_ms, 86_400_000);
            assert_eq!(messages[0].urgency, 2);
            assert_eq!(messages[0].text_styles.len(), 1);
        }
        other => panic!("expected Append delta for optimistic row, got {other:?}"),
    }
    assert!(!send_task.is_finished());

    // Release HTTP response and verify ack swap + SQLite persistence + conversation preview.
    client.transport().release_one();
    assert!(send_task.await.expect("send task join"));

    let post_ack = core.next_changes().await.expect("post-ack changes");
    assert_eq!(post_ack.window_deltas.len(), 1);
    match &post_ack.window_deltas[0] {
        WindowDelta::Patch {
            conv_id,
            upserts,
            removed_ids,
        } => {
            assert_eq!(conv_id, "3000001");
            assert_eq!(removed_ids, &vec!["5000000000001".to_owned()]);
            assert_eq!(upserts.len(), 1);
            assert_eq!(upserts[0].id, "9001001");
            assert_eq!(upserts[0].status, Status::Sent);
        }
        other => panic!("expected Patch delta on ack swap, got {other:?}"),
    }

    let snap = core.full_snapshot().await.expect("snapshot");
    let win = &snap.messages.windows["3000001"];
    assert_eq!(win.len(), 2);
    assert_eq!(win[1].id, "9001001");
    assert_eq!(win[1].client_id, "5000000000001");
    assert_eq!(win[1].status, Status::Sent);
    assert_eq!(
        snap.conversations.conversations[0]
            .preview
            .as_ref()
            .map(|p| (p.text.as_str(), p.from_me)),
        Some(("Hello optimistic", true))
    );

    let persisted = store
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .messages("3000001", None, 10)
        .expect("read messages");
    assert_eq!(persisted.len(), 1);
    assert_eq!(persisted[0].id, "9001001");
    assert!(
        logs.lock()
            .unwrap_or_else(PoisonError::into_inner)
            .is_empty()
    );

    core.stop();
}

#[tokio::test(start_paused = true)]
async fn s02_echo_first_reconciliation_drops_optimistic_and_keeps_echo() {
    // HTTP returns msgId == cliId (echo-first reconciliation path).
    let transport = HeldTransport::new(vec![(
        true,
        ok_send_response("5000000000008", "5000000000008"),
    )]);
    let client = make_authenticated_client(transport);
    let host = Arc::new(SendScenarioHost::default());
    let inner_runner = Arc::new(SessionEffectRunner::new(
        Arc::clone(&client),
        Arc::clone(&host) as Arc<dyn Host>,
        Handle::current(),
    ));
    let store = Arc::new(Mutex::new(
        Store::open_in_memory().expect("in-memory store"),
    ));
    inner_runner.attach_store(Arc::clone(&store));

    let core = Arc::new(CoreHandle::start_with_state(
        make_ready_state(),
        Arc::clone(&inner_runner) as Arc<dyn EffectRunner>,
        Handle::current(),
    ));

    let core_bg = Arc::clone(&core);
    let send_task = tokio::spawn(async move {
        core_bg
            .request_bool(Command::SendText {
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
            })
            .await
    });

    client.transport().wait_for_held(1).await;
    let _ = core.settle().await;

    // Inject the WS echo via ApplyBatchDirect while HTTP is still held.
    let echo_payload: Map<String, Value> = serde_json::from_value(json!({
        "data": {
            "msgs": [{
                "msgId": "9008001",
                "cliMsgId": "5000000000008",
                "uidFrom": "2000001",
                "idTo": "3000001",
                "msgType": "webchat",
                "content": "Echo before reply",
                "ts": 1_700_000_080_500_i64
            }]
        }
    }))
    .expect("echo map");
    core.send(Command::ApplyBatchDirect {
        payload: echo_payload,
        default_cmd: 501,
        fallback_conv_id: None,
        is_group_hint: None,
        increment_unread: true,
        notify_incoming: false,
        persist_conversations: true,
        probe_freshness: false,
    });
    let _ = core.settle().await;
    inner_runner.flush_store().await;

    // Now release the HTTP reply.
    client.transport().release_one();
    assert!(send_task.await.expect("send task join"));

    let snap = core.full_snapshot().await.expect("snapshot");
    let win = &snap.messages.windows["3000001"];
    assert_eq!(win.len(), 1);
    assert_eq!(win[0].id, "9008001");
    assert_eq!(win[0].client_id, "5000000000008");
    assert_eq!(win[0].date_ms, 1_700_000_080_500);
    assert_eq!(win[0].status, Status::Sent);

    core.stop();
}

#[tokio::test(start_paused = true)]
async fn s03_same_id_dedupe_and_send_failure_rollback() {
    let transport = HeldTransport::new(vec![
        (false, ok_send_response("9009001", "5000000000009")),
        (false, error_send_response(112, "Simulated send failure")),
    ]);
    let client = make_authenticated_client(transport);
    let host = Arc::new(SendScenarioHost::default());
    let inner_runner = Arc::new(SessionEffectRunner::new(
        Arc::clone(&client),
        Arc::clone(&host) as Arc<dyn Host>,
        Handle::current(),
    ));
    let logs = Arc::new(Mutex::new(Vec::new()));
    let runner: Arc<dyn EffectRunner> = Arc::new(LogSpyRunner {
        inner: Arc::clone(&inner_runner),
        logs: Arc::clone(&logs),
    });

    let mut initial = make_ready_state();
    let existing = make_message(
        "9009001",
        "3000001",
        "2000001",
        "Alice",
        1_700_000_090_000,
        "Already present",
        "c_old",
    );
    initial
        .messages
        .windows
        .insert("3000001".to_owned(), vec![existing]);

    let core = CoreHandle::start_with_state(initial, runner, Handle::current());

    // 1. Same-id dedupe: server replies with "9009001" already in window -> still 1 row.
    let ok = core
        .request_bool(Command::SendText {
            conv_id: "3000001".to_owned(),
            text: "Same id".to_owned(),
            quote_id: None,
            mentions: Vec::new(),
            styles: Vec::new(),
            urgency: 0,
            client_id: 5_000_000_000_009,
            now_ms: 1_700_000_090_500,
            is_e2ee: None,
            ttl_ms: None,
        })
        .await;
    assert!(ok);
    let snap = core.full_snapshot().await.expect("snapshot");
    let win = &snap.messages.windows["3000001"];
    assert_eq!(win.len(), 1);
    assert_eq!(win[0].id, "9009001");
    assert_eq!(win[0].text, "Same id");

    // 2. Failure rollback: HTTP error removes optimistic row, returns false, logs sendText failed.
    let fail_ok = core
        .request_bool(Command::SendText {
            conv_id: "3000001".to_owned(),
            text: "Will fail".to_owned(),
            quote_id: None,
            mentions: Vec::new(),
            styles: Vec::new(),
            urgency: 0,
            client_id: 5_000_000_000_010,
            now_ms: 1_700_000_091_000,
            is_e2ee: None,
            ttl_ms: None,
        })
        .await;
    assert!(!fail_ok);
    let snap = core.full_snapshot().await.expect("snapshot");
    let win = &snap.messages.windows["3000001"];
    assert_eq!(win.len(), 1);
    assert_eq!(win[0].id, "9009001");
    let captured_logs = logs.lock().unwrap_or_else(PoisonError::into_inner).clone();
    assert!(
        captured_logs
            .iter()
            .any(|line| line.starts_with("sendText failed:")),
        "expected sendText failed log, got {captured_logs:?}"
    );

    core.stop();
}

#[tokio::test(start_paused = true)]
async fn s04_e2ee_host_boundary_quote_stripping_and_failure_removal() {
    let transport = HeldTransport::new(Vec::new());
    let client = make_authenticated_client(transport);
    let host = Arc::new(SendScenarioHost::default());
    {
        let mut q = host
            .e2ee_results
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        q.push_back(Ok(SendMessageResult {
            msg_id: "9010001".to_owned(),
            cli_msg_id: "5000000000011".to_owned(),
            ts_ms: 1_700_000_100_100,
        }));
        q.push_back(Err("e2ee session closed".to_owned()));
    }
    let inner_runner = Arc::new(SessionEffectRunner::new(
        Arc::clone(&client),
        Arc::clone(&host) as Arc<dyn Host>,
        Handle::current(),
    ));
    let mut initial = make_ready_state();
    let quoted = make_message(
        "8010001",
        "3000001",
        "3000001",
        "Bob",
        1_700_000_099_000,
        "Quote me",
        "c_8010001",
    );
    initial
        .messages
        .windows
        .insert("3000001".to_owned(), vec![quoted]);

    let core = CoreHandle::start_with_state(initial, inner_runner, Handle::current());
    core.request_unit(Command::SetE2eeThreads(BTreeSet::from([
        "3000001".to_owned()
    ])))
    .await;
    core.request_unit(Command::SetAutoDeleteTtl {
        conv_id: "3000001".to_owned(),
        ttl_ms: 86_400_000,
    })
    .await;

    // 1. E2EE send succeeds with quote, strips styles/TTL/urgency, never touches plain HTTP.
    let ok = core
        .request_bool(Command::SendText {
            conv_id: "3000001".to_owned(),
            text: "Secret reply".to_owned(),
            quote_id: Some("8010001".to_owned()),
            mentions: Vec::new(),
            styles: vec![TextStyle {
                start: 0,
                len: 6,
                st: "b".to_owned(),
            }],
            urgency: 2,
            client_id: 5_000_000_000_011,
            now_ms: 1_700_000_100_000,
            is_e2ee: None,
            ttl_ms: None,
        })
        .await;
    assert!(ok);
    assert!(client.transport().paths().is_empty());

    let snap = core.full_snapshot().await.expect("snapshot");
    let win = &snap.messages.windows["3000001"];
    assert_eq!(win.len(), 2);
    assert_eq!(win[1].id, "9010001");
    assert!(win[1].is_e2ee);
    assert!(win[1].text_styles.is_empty());
    assert_eq!(win[1].ttl_ms, 0);
    assert_eq!(win[1].urgency, 0);
    assert_eq!(
        win[1].quote.as_ref().map(|q| q.msg_id.as_str()),
        Some("8010001")
    );

    // 2. E2EE host failure removes optimistic row and returns false.
    let fail = core
        .request_bool(Command::SendText {
            conv_id: "3000001".to_owned(),
            text: "Secret fails".to_owned(),
            quote_id: None,
            mentions: Vec::new(),
            styles: Vec::new(),
            urgency: 0,
            client_id: 5_000_000_000_012,
            now_ms: 1_700_000_101_000,
            is_e2ee: None,
            ttl_ms: None,
        })
        .await;
    assert!(!fail);
    let snap = core.full_snapshot().await.expect("snapshot");
    assert_eq!(snap.messages.windows["3000001"].len(), 2);

    let calls = host
        .e2ee_calls
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .clone();
    assert_eq!(calls.len(), 2);
    assert_eq!(calls[0].conv_id, "3000001");
    assert_eq!(calls[0].text, "Secret reply");
    assert_eq!(calls[0].client_id, "5000000000011");
    assert_eq!(
        calls[0]
            .quote
            .as_ref()
            .map(|q| (q.msg_id.as_str(), q.ts_ms)),
        Some(("8010001", 1_700_000_099_000))
    );

    core.stop();
}

#[tokio::test(start_paused = true)]
async fn s05_mark_read_split_clears_unread_mark_and_sends_seen_only_for_peer_last_msg() {
    let transport = HeldTransport::new(Vec::new());
    let client = make_authenticated_client(transport);
    let host = Arc::new(SendScenarioHost::default());
    let inner_runner = Arc::new(SessionEffectRunner::new(
        Arc::clone(&client),
        Arc::clone(&host) as Arc<dyn Host>,
        Handle::current(),
    ));
    let store = Arc::new(Mutex::new(
        Store::open_in_memory().expect("in-memory store"),
    ));
    inner_runner.attach_store(Arc::clone(&store));

    let mut initial = make_ready_state();
    initial
        .conversations
        .unread_marks
        .insert("3000001".to_owned());
    let peer_msg = make_message(
        "8012001",
        "3000001",
        "3000001",
        "Bob",
        1_700_000_120_000,
        "Read me",
        "c_8012001",
    );
    let own_msg = make_message(
        "8012002",
        "3000002",
        "2000001",
        "Alice",
        1_700_000_121_000,
        "Mine",
        "c_8012002",
    );
    initial
        .conversations
        .conversations
        .push(ConversationSummary {
            id: "3000002".to_owned(),
            is_group: false,
            name: "Carol".to_owned(),
            avatar: None,
            pinned: false,
            members: 0,
            unread: 1,
            preview: None,
        });
    initial
        .messages
        .windows
        .insert("3000001".to_owned(), vec![peer_msg]);
    initial
        .messages
        .windows
        .insert("3000002".to_owned(), vec![own_msg]);

    let core = CoreHandle::start_with_state(
        initial,
        Arc::clone(&inner_runner) as Arc<dyn EffectRunner>,
        Handle::current(),
    );

    // 1. Peer last message + unread + unreadMark -> both unread-mark API and seen API fire.
    core.request_unit(Command::MarkRead {
        id: "3000001".to_owned(),
    })
    .await;
    core.wait_idle().await;

    let snap = core.full_snapshot().await.expect("snapshot");
    assert_eq!(snap.conversations.conversations[0].unread, 0);
    assert!(!snap.conversations.unread_marks.contains("3000001"));
    let paths = client.transport().paths();
    assert!(
        paths.iter().any(|p| p.contains("removeUnreadMark")),
        "expected unreadmark request, got {paths:?}"
    );
    assert!(
        paths
            .iter()
            .any(|p| p.contains("deliveredv2") || p.contains("seenv2")),
        "expected seen request, got {paths:?}"
    );

    // 2. Own last message -> unread cleared, NO additional seen request.
    let before = client.transport().paths().len();
    core.request_unit(Command::MarkRead {
        id: "3000002".to_owned(),
    })
    .await;
    core.wait_idle().await;
    assert_eq!(client.transport().paths().len(), before);

    core.stop();
}

#[tokio::test(start_paused = true)]
async fn s06_typing_incoming_expiry_outgoing_throttle_send_reset_and_guards() {
    let transport = HeldTransport::new(vec![
        (
            false,
            Ok(RawResponse::new(
                200,
                br#"{"error_code":0,"data":{}}"#.to_vec(),
            )),
        ),
        (false, ok_send_response("9011001", "5000000000020")),
        (
            false,
            Ok(RawResponse::new(
                200,
                br#"{"error_code":0,"data":{}}"#.to_vec(),
            )),
        ),
        (
            false,
            Ok(RawResponse::new(
                200,
                br#"{"error_code":0,"data":{}}"#.to_vec(),
            )),
        ),
    ]);
    let client = make_authenticated_client(transport);
    let host = Arc::new(SendScenarioHost::default());
    let inner_runner = Arc::new(SessionEffectRunner::new(
        Arc::clone(&client),
        Arc::clone(&host) as Arc<dyn Host>,
        Handle::current(),
    ));
    let mut initial = make_ready_state();
    // Seed a stored message so save/merge paths stay exercised.
    let _ = encode_chat_message(
        &make_message(
            "1",
            "3000001",
            "3000001",
            "Bob",
            1_700_000_000_000,
            "Hi",
            "c1",
        ),
        "c1",
    );
    initial.conversations.identities.cached_profiles = BTreeMap::new();

    let core = CoreHandle::start_with_state(initial, inner_runner, Handle::current());

    // 1. Incoming typing via HandleTyping shows in state and expires after 8 s on paused time.
    let state_map: Map<String, Value> = serde_json::from_value(json!({
        "typing": {
            "convId": "3000001",
            "name": "Bob",
            "isPC": true
        }
    }))
    .expect("typing state map");
    core.request_unit(Command::HandleTyping { state: state_map })
        .await;
    let snap = core.full_snapshot().await.expect("snapshot");
    let info = snap.typing.get("3000001").expect("typing present");
    assert_eq!(info.name, "Bob");
    assert!(info.on_pc);

    tokio::time::advance(Duration::from_secs(9)).await;
    tokio::task::yield_now().await;
    core.wait_idle().await;
    let snap = core.full_snapshot().await.expect("snapshot");
    assert!(snap.typing.contains_key("3000001"));

    tokio::time::advance(Duration::from_secs(2)).await;
    tokio::task::yield_now().await;
    core.wait_idle().await;
    let snap = core.full_snapshot().await.expect("snapshot");
    assert!(snap.typing.is_empty());

    // 2. Outgoing typing: trims whitespace, throttles within 10 s, resets on SendText, then sends.
    core.request_unit(Command::NotifyTyping {
        conv_id: "  3000001  ".to_owned(),
        now_ms: 1_700_000_200_000,
    })
    .await;
    core.request_unit(Command::NotifyTyping {
        conv_id: "3000001".to_owned(),
        now_ms: 1_700_000_205_000, // throttled (5 s < 10 s)
    })
    .await;
    core.wait_idle().await;
    assert_eq!(
        client
            .transport()
            .paths()
            .iter()
            .filter(|p| p.contains("/typing"))
            .count(),
        1
    );

    // SendText resets the outgoing typing throttle for 3000001.
    let sent = core
        .request_bool(Command::SendText {
            conv_id: "3000001".to_owned(),
            text: "Reset throttle".to_owned(),
            quote_id: None,
            mentions: Vec::new(),
            styles: Vec::new(),
            urgency: 0,
            client_id: 5_000_000_000_020,
            now_ms: 1_700_000_206_000,
            is_e2ee: None,
            ttl_ms: None,
        })
        .await;
    assert!(sent);

    // Typing 1 s after send (only 7 s after first typing) now goes out!
    core.request_unit(Command::NotifyTyping {
        conv_id: "3000001".to_owned(),
        now_ms: 1_700_000_207_000,
    })
    .await;
    core.wait_idle().await;
    assert_eq!(
        client
            .transport()
            .paths()
            .iter()
            .filter(|p| p.contains("/typing"))
            .count(),
        2
    );

    // 3. Disabling sendTyping pref suppresses outgoing typing even after 11 s.
    core.request_unit(Command::SetSendTypingEnabled { enabled: false })
        .await;
    core.request_unit(Command::NotifyTyping {
        conv_id: "3000001".to_owned(),
        now_ms: 1_700_000_220_000,
    })
    .await;
    core.wait_idle().await;
    assert_eq!(
        client
            .transport()
            .paths()
            .iter()
            .filter(|p| p.contains("/typing"))
            .count(),
        2
    );

    // Re-enabling works after 11 s, then clearing client auth suppresses again.
    core.request_unit(Command::SetSendTypingEnabled { enabled: true })
        .await;
    core.request_unit(Command::NotifyTyping {
        conv_id: "3000001".to_owned(),
        now_ms: 1_700_000_235_000,
    })
    .await;
    core.wait_idle().await;
    assert_eq!(
        client
            .transport()
            .paths()
            .iter()
            .filter(|p| p.contains("/typing"))
            .count(),
        3
    );

    client.clear_session();
    core.request_unit(Command::NotifyTyping {
        conv_id: "3000001".to_owned(),
        now_ms: 1_700_000_250_000,
    })
    .await;
    core.wait_idle().await;
    assert_eq!(
        client
            .transport()
            .paths()
            .iter()
            .filter(|p| p.contains("/typing"))
            .count(),
        3
    );

    core.stop();
}
