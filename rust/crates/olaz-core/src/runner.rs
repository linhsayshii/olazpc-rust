//! Effect execution: [`EffectRunner`] trait, [`Host`] callback trait, [`WsDriver`] abstraction,
//! and the concrete [`SessionEffectRunner`] backed by `olaz_net::SessionClient`, `olaz_api::ZaloApi`,
//! and `olaz_ws::WsClient`.

use std::collections::BTreeMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use async_trait::async_trait;
use olaz_api::{PollState, ZaloApi};
use olaz_net::{
    LoginAccount, SessionClient, SessionSnapshot as NetSessionSnapshot, Transport, ZaloDomains,
};
use olaz_store::{SaveOptions, Store};
use olaz_wire::{ChatMessage, decode_stored_message, extract_profiles_map};
use olaz_ws::{CryptoDecryptor, CursorMap, WsClient, WsConfig, WsHandle};
use serde_json::{Map, Value};
use tokio::runtime::Handle;
use tokio::sync::{mpsc, oneshot};
use tokio::task::AbortHandle;

use crate::actor::{ActorSink, InFlightGuard};
use crate::conversations::{
    BatchApplyDelta, IdentityTable, MessagePreviewInput, hidden_pin_md5, hidden_pin_sha256,
    load_local_account_from_store, to_wire_stored,
};
use crate::effect::{Effect, HistoryFetchPurpose, HostCall, OpResult, StoreOp};
use crate::input::{
    BootstrapAliasesError, Command, CompletedLogin, Input, LegacyCookie, PollBatchError,
    PollBatchOutcome, SeenTarget, SessionFailure, StoreToken,
};
use crate::messages::MuteEntry;
use crate::reduce::classify::MobileSyncEvent;
use crate::state::PersistedTransportState;
use crate::typed_chat::{
    PlainChatParse, TypedChatEnvelope, new_shared_parse, try_parse_plain_chat,
};

/// Executes effects produced by `reduce` and feeds completion [`Input`]s back via [`ActorSink`].
pub trait EffectRunner: Send + Sync {
    fn dispatch(&self, effects: Vec<Effect>, sink: ActorSink);
    fn shutdown(&self);
}

/// Parameters passed to [`WsDriver::start`] when the core brings up the WebSocket transport.
#[derive(Debug, Clone)]
pub struct WsStartParams {
    pub ws_gen: u64,
    pub endpoints: Vec<String>,
    pub zpw_sek: String,
    pub seed_cursors: CursorMap,
    pub my_uid: String,
    pub self_conv_id: Option<String>,
}

/// Abstraction over the WebSocket transport owned by [`SessionEffectRunner`].
///
/// Production uses [`LiveWsDriver`] (backed by `olaz_ws::WsClient`); tests plug in a scripted
/// driver backed by `olaz_ws::WsCore`.
#[async_trait]
pub trait WsDriver: Send + Sync {
    fn start(&self, params: WsStartParams, sink: ActorSink, runtime: &Handle);
    fn stop(&self, reset_cursors: bool);
    fn record_file_done(&self, file_id: String, url: String);
    async fn send_frame(&self, cmd: u16, sub_cmd: u8, payload_json: Option<Vec<u8>>) -> bool;
    async fn send_frame_versioned(
        &self,
        cmd: u16,
        sub_cmd: u8,
        version: u8,
        payload_json: Option<Vec<u8>>,
    ) -> bool;
    async fn send_request(
        &self,
        cmd: u16,
        sub_cmd: u8,
        version: u8,
        req_id: Option<String>,
        inner_data: Map<String, Value>,
        timeout: Duration,
    ) -> Option<Map<String, Value>>;
    async fn wait_for_file_done(&self, file_id: String, timeout: Duration) -> Option<String>;
    async fn is_authed(&self) -> bool;
    async fn current_cursors(&self) -> CursorMap;
    async fn seed_cursors(&self, cursors: CursorMap);
}

struct LiveWsSession {
    handle: WsHandle,
    pump_abort: AbortHandle,
    runtime: Handle,
}

/// Production [`WsDriver`] driving `olaz_ws::WsClient` directly.
///
/// Uses a single `biased;` pump per generation that delivers `WsEvent` / `WsTypedChat` strictly
/// before any `WsCursorsChanged` caused by the same frame.
#[derive(Default)]
pub struct LiveWsDriver {
    active: Mutex<Option<LiveWsSession>>,
}

impl LiveWsDriver {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    fn current_handle(&self) -> Option<WsHandle> {
        self.active
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .as_ref()
            .map(|s| s.handle.clone())
    }
}

#[async_trait]
impl WsDriver for LiveWsDriver {
    fn start(&self, params: WsStartParams, sink: ActorSink, runtime: &Handle) {
        let prev = self
            .active
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .take();
        if let Some(old) = prev {
            old.pump_abort.abort();
            old.runtime.spawn(async move {
                let _ = old.handle.stop(false).await;
            });
        }

        let mut config = WsConfig::new(params.endpoints, params.zpw_sek);
        config.seed_cursors = params.seed_cursors;

        // `WsClient::start` spawns its transport task on the current tokio runtime.
        let _entered = runtime.enter();
        let (handle, mut events) = WsClient::start(config, Arc::new(CryptoDecryptor));
        drop(_entered);

        let mut authed = handle.watch_authed();
        let mut cursors = handle.watch_cursors();
        let parse_state = new_shared_parse(params.my_uid, params.self_conv_id);
        let ws_gen = params.ws_gen;

        let pump_abort = runtime
            .spawn(async move {
                let mut authed_open = true;
                let mut cursors_open = true;
                loop {
                    tokio::select! {
                        biased;
                        res = authed.changed(), if authed_open => {
                            if res.is_ok() {
                                let now_authed = *authed.borrow_and_update();
                                sink.send(Input::WsAuthChanged {
                                    ws_gen,
                                    authed: now_authed,
                                });
                            } else {
                                authed_open = false;
                            }
                        }
                        ev = events.recv() => {
                            let Some(ev) = ev else {
                                break;
                            };
                            match try_parse_plain_chat(ev.cmd, &ev.payload, &parse_state) {
                                PlainChatParse::Empty => {}
                                PlainChatParse::Typed(envelope) => {
                                    sink.send(Input::WsTypedChat {
                                        ws_gen,
                                        cmd: ev.cmd,
                                        envelope,
                                    });
                                }
                                PlainChatParse::NotPlain => {
                                    sink.send(Input::WsEvent {
                                        ws_gen,
                                        cmd: ev.cmd,
                                        payload: ev.payload,
                                        now_unix_secs: unix_now_secs(),
                                    });
                                }
                            }
                        }
                        res = cursors.changed(), if cursors_open => {
                            if res.is_ok() {
                                let snap = cursors.borrow_and_update().clone();
                                sink.send(Input::WsCursorsChanged {
                                    ws_gen,
                                    cursors: snap,
                                });
                            } else {
                                cursors_open = false;
                            }
                        }
                    }
                }
            })
            .abort_handle();

        *self.active.lock().unwrap_or_else(PoisonError::into_inner) = Some(LiveWsSession {
            handle,
            pump_abort,
            runtime: runtime.clone(),
        });
    }

    fn stop(&self, reset_cursors: bool) {
        let prev = self
            .active
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .take();
        if let Some(old) = prev {
            old.pump_abort.abort();
            old.runtime.spawn(async move {
                let _ = old.handle.stop(reset_cursors).await;
            });
        }
    }

    fn record_file_done(&self, file_id: String, url: String) {
        let info = self
            .active
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .as_ref()
            .map(|s| (s.handle.clone(), s.runtime.clone()));
        if let Some((handle, runtime)) = info {
            runtime.spawn(async move {
                handle.record_file_done(file_id, url).await;
            });
        }
    }

    async fn send_frame(&self, cmd: u16, sub_cmd: u8, payload_json: Option<Vec<u8>>) -> bool {
        let Some(handle) = self.current_handle() else {
            return false;
        };
        handle.send_frame(cmd, sub_cmd, payload_json).await
    }

    async fn send_frame_versioned(
        &self,
        cmd: u16,
        sub_cmd: u8,
        version: u8,
        payload_json: Option<Vec<u8>>,
    ) -> bool {
        let Some(handle) = self.current_handle() else {
            return false;
        };
        handle
            .send_frame_versioned(cmd, sub_cmd, version, payload_json)
            .await
    }

    async fn send_request(
        &self,
        cmd: u16,
        sub_cmd: u8,
        version: u8,
        req_id: Option<String>,
        inner_data: Map<String, Value>,
        timeout: Duration,
    ) -> Option<Map<String, Value>> {
        let handle = self.current_handle()?;
        handle
            .send_request_versioned_with_timeout(cmd, sub_cmd, version, req_id, inner_data, timeout)
            .await
    }

    async fn wait_for_file_done(&self, file_id: String, timeout: Duration) -> Option<String> {
        let handle = self.current_handle()?;
        handle
            .wait_for_file_done_with_timeout(&file_id, timeout)
            .await
    }

    async fn is_authed(&self) -> bool {
        let Some(handle) = self.current_handle() else {
            return false;
        };
        handle.is_authed().await
    }

    async fn current_cursors(&self) -> CursorMap {
        let Some(handle) = self.current_handle() else {
            return CursorMap::new();
        };
        handle.current_cursors().await
    }

    async fn seed_cursors(&self, cursors: CursorMap) {
        if let Some(handle) = self.current_handle() {
            handle.seed_cursors(cursors).await;
        }
    }
}

/// Platform / Swift host boundary called serially by [`SessionEffectRunner`].
///
/// Storage primitives (`load_saved_session`, `load_legacy_cookie`, `load_transport_state`,
/// `set_pref`) live here alongside domain calls that still belong to Swift until later units
/// (`prepare_store`, `start_bootstrap`, `apply_batch`, etc.).
/// Outcome of [`Host::on_batch_received`].
#[derive(Clone, Debug)]
pub enum BatchHookOutcome {
    /// Delegate to legacy `Host::apply_batch` (used by U2/U3 unit tests).
    DelegateToLegacy,
    /// Suppressed by `hostTrace` (skip ingestion, notify transport settle).
    Suppressed,
    /// Ingest natively in `olaz-core` using the (optionally decrypted) payload.
    IngestInCore(Map<String, Value>),
}

/// Outcome of [`Host::on_parsed_events_received`].
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ParsedEventsHookOutcome {
    /// Delegate to legacy `Host::apply_parsed_events` (used by U2/U3 unit tests).
    DelegateToLegacy,
    /// Suppressed by `hostTrace` (skip ingestion, notify transport settle).
    Suppressed,
    /// Ingest natively in `olaz-core`.
    IngestInCore,
}

#[async_trait]
pub trait Host: Send + Sync {
    async fn load_saved_session(&self) -> Option<String>;
    async fn load_legacy_cookie(&self) -> Option<LegacyCookie>;
    async fn load_transport_state(&self) -> PersistedTransportState {
        PersistedTransportState::default()
    }
    async fn set_pref(&self, key: String, value: String);
    async fn prepare_store(&self, user_id: String, account: LoginAccount);
    async fn start_bootstrap(&self);
    async fn offer_first_login_transfer(&self, force: bool);
    async fn reset_domains(&self);
    async fn persist_session(&self, snapshot_json: String);
    async fn clear_session(&self);
    async fn mark_expired(&self, snapshot_json: String);

    /// Host hook emitted when the core starts WebSocket. Return `false` to suppress connecting
    /// (used by session/transport recorders when `"ws"` is suppressed). Production returns `true`.
    async fn on_ws_started(&self, _endpoints: Vec<String>) -> bool {
        true
    }
    /// Host hook emitted when the core starts the long-poll loop. Return `false` to suppress
    /// periodic ticks (used by session/transport recorders when `"long_poll"` is suppressed).
    /// Production returns `true`.
    async fn on_long_poll_started(&self) -> bool {
        true
    }
    // U4-bootstrap
    /// Host hook emitted when the core signals launch bootstrap. Return `false` to suppress
    /// auto-dispatching `Command::Bootstrap` (used by case recorders that trigger `bootstrap`
    /// explicitly or test earlier domains in isolation). Production returns `true`.
    async fn on_bootstrap_started(&self) -> bool {
        self.start_bootstrap().await;
        true
    }
    /// Applies server mute entries fetched during launch bootstrap step 3.
    async fn apply_mutes(&self, _mutes: Vec<MuteEntry>) {}
    /// Requests the host to refresh cloud data once launch bootstrap finalizes.
    async fn refresh_cloud(&self) {}
    async fn on_open_conversation_sync(&self, _conv_id: String, _changed: bool) {}
    async fn on_close_conversation(&self) {}
    async fn refresh_board_pins(&self, _conv_id: String) {}
    async fn mark_read_boundary(&self, _conv_id: String, _seen_target: Option<SeenTarget>) {}
    #[expect(
        clippy::too_many_arguments,
        reason = "Matches apply_remote_reaction case schema fields 1-for-1"
    )]
    async fn apply_remote_reaction(
        &self,
        _conv_id: String,
        _msg_id: String,
        _cli_msg_id: String,
        _sender_id: String,
        _r_type: String,
        _r_icon: String,
        _event_id: String,
        _react_client_id: String,
        _sender_name: String,
    ) {
    }
    async fn apply_remote_recall(
        &self,
        _conv_id: String,
        _msg_id: String,
        _cli_msg_id: String,
        _update_conversation_preview: bool,
    ) {
    }
    async fn apply_remote_delete(
        &self,
        _conv_id: String,
        _msg_id: String,
        _cli_msg_id: String,
        _update_conversation_preview: bool,
    ) {
    }
    async fn decrypt_envelope(&self, payload: Map<String, Value>) -> Map<String, Value> {
        payload
    }
    async fn mark_e2ee_conversations(&self, _conv_ids: Vec<String>) {}
    async fn note_poll_messages(&self, _messages: Vec<ChatMessage>) {}
    async fn notify_incoming_messages(&self, _messages: Vec<ChatMessage>) {}
    async fn show_batch_typing(&self, _conv_id: String, _sender_id: String) {}

    // --- Transport domain callbacks (U2) ---
    async fn persist_poll_state(&self, state: PollState);
    async fn persist_ws_cursors(&self, cursors: CursorMap);
    async fn apply_batch(
        &self,
        cmd: Option<u16>,
        increment_unread: bool,
        notify_incoming: bool,
        payload: Map<String, Value>,
    ) -> BatchApplyDelta;
    async fn apply_parsed_events(
        &self,
        cmd: u16,
        increment_unread: bool,
        notify_incoming: bool,
        envelope: TypedChatEnvelope,
    ) -> BatchApplyDelta;
    /// Host hook emitted when transport delivers an `ApplyBatch` frame.
    /// Return `Some(decrypted_payload)` to have `olaz-core` ingest the batch natively
    /// (windows + SQLite + conversation deltas + Pass 2 events). Return `None` to fall back
    /// to legacy `Host::apply_batch`.
    async fn on_batch_received(
        &self,
        _cmd: Option<u16>,
        _increment_unread: bool,
        _notify_incoming: bool,
        _payload: Map<String, Value>,
    ) -> BatchHookOutcome {
        BatchHookOutcome::DelegateToLegacy
    }
    /// Host hook emitted when transport delivers a typed `ApplyParsedEvents` frame.
    /// Return `true` to have `olaz-core` ingest the typed envelope natively; return `false`
    /// to fall back to legacy `Host::apply_parsed_events`.
    async fn on_parsed_events_received(
        &self,
        _cmd: u16,
        _increment_unread: bool,
        _notify_incoming: bool,
        _envelope: &TypedChatEnvelope,
    ) -> ParsedEventsHookOutcome {
        ParsedEventsHookOutcome::DelegateToLegacy
    }
    async fn transport_batch_settled(&self) {}
    async fn engine_log(&self, _message: String) {}
    async fn mobile_sync(&self, events: Vec<MobileSyncEvent>);
    async fn e2ee_signal(&self, cmd: u16, payload: Map<String, Value>);
    async fn e2ee_deliver_reports(&self, cmd: u16, payload: Map<String, Value>);
    async fn e2ee_connected(&self, uid: String);
    async fn e2ee_disconnected(&self);
    async fn voip_control(&self, act: String, raw_data: Value, data: Map<String, Value>);
    async fn show_typing(&self, conv_id: String, uid: String, on_pc: bool);
    async fn pin_topic(&self, conv_id: String);
    async fn group_notice(&self, act: String, data: Map<String, Value>, ts: i64);
    async fn mute(
        &self,
        conv_id: String,
        set: bool,
        start: i64,
        start_explicit: bool,
        duration: i64,
    );
}

enum HostJob {
    LoadSavedSession {
        boot_gen: u64,
        sink: ActorSink,
        _guard: InFlightGuard,
    },
    LoadLegacyCookie {
        boot_gen: u64,
        sink: ActorSink,
        _guard: InFlightGuard,
    },
    SetPref {
        key: String,
        value: String,
        _guard: InFlightGuard,
    },
    PrepareStore {
        token: StoreToken,
        user_id: String,
        account: Box<LoginAccount>,
        identities: Box<IdentityTable>,
        sink: ActorSink,
        _guard: InFlightGuard,
    },
    StartWs {
        params: WsStartParams,
        sink: ActorSink,
        _guard: InFlightGuard,
    },
    StartLpInitial {
        lp_gen: u64,
        delay: Duration,
        sink: ActorSink,
        _guard: InFlightGuard,
    },
    StartBootstrap {
        sink: ActorSink,
        _guard: InFlightGuard,
    },
    // U4-bootstrap
    ApplyMutes {
        mutes: Vec<MuteEntry>,
        _guard: InFlightGuard,
    },
    RefreshCloud {
        _guard: InFlightGuard,
    },
    OnOpenConversationSync {
        conv_id: String,
        changed: bool,
        _guard: InFlightGuard,
    },
    OnCloseConversation {
        _guard: InFlightGuard,
    },
    RefreshBoardPins {
        conv_id: String,
        _guard: InFlightGuard,
    },
    MarkReadBoundary {
        conv_id: String,
        seen_target: Option<SeenTarget>,
        _guard: InFlightGuard,
    },
    ApplyRemoteReaction {
        conv_id: String,
        msg_id: String,
        cli_msg_id: String,
        sender_id: String,
        r_type: String,
        r_icon: String,
        event_id: String,
        react_client_id: String,
        sender_name: String,
        _guard: InFlightGuard,
    },
    ApplyRemoteRecall {
        conv_id: String,
        msg_id: String,
        cli_msg_id: String,
        update_conversation_preview: bool,
        _guard: InFlightGuard,
    },
    ApplyRemoteDelete {
        conv_id: String,
        msg_id: String,
        cli_msg_id: String,
        update_conversation_preview: bool,
        _guard: InFlightGuard,
    },
    DecryptEnvelope {
        payload: Map<String, Value>,
        default_cmd: u16,
        fallback_conv_id: Option<String>,
        is_group_hint: Option<bool>,
        increment_unread: bool,
        notify_incoming: bool,
        persist_conversations: bool,
        probe_freshness: bool,
        poll_batch_done: Option<(u64, u64)>,
        op_id: Option<u64>,
        sink: ActorSink,
        _guard: InFlightGuard,
    },
    MarkE2eeConversations {
        conv_ids: Vec<String>,
        _guard: InFlightGuard,
    },
    NotePollMessages {
        messages: Vec<ChatMessage>,
        _guard: InFlightGuard,
    },
    NotifyIncomingMessages {
        messages: Vec<ChatMessage>,
        _guard: InFlightGuard,
    },
    ShowBatchTyping {
        conv_id: String,
        sender_id: String,
        _guard: InFlightGuard,
    },
    TransportBatchSettled {
        _guard: InFlightGuard,
    },
    EngineLog {
        message: String,
        _guard: InFlightGuard,
    },
    OfferFirstLoginTransfer {
        force: bool,
        _guard: InFlightGuard,
    },
    DetachStore {
        _guard: InFlightGuard,
    },
    ResetDomains {
        _guard: InFlightGuard,
    },
    PersistSession {
        snapshot_json: String,
        _guard: InFlightGuard,
    },
    ClearSession {
        _guard: InFlightGuard,
    },
    MarkExpired {
        snapshot_json: String,
        _guard: InFlightGuard,
    },
    PersistPollState {
        state: PollState,
        _guard: InFlightGuard,
    },
    PersistWsCursors {
        cursors: CursorMap,
        _guard: InFlightGuard,
    },
    ApplyBatch {
        cmd: Option<u16>,
        increment_unread: bool,
        notify_incoming: bool,
        payload: Map<String, Value>,
        poll_batch_done: Option<(u64, u64)>,
        sink: ActorSink,
        _guard: InFlightGuard,
    },
    ApplyParsedEvents {
        cmd: u16,
        increment_unread: bool,
        notify_incoming: bool,
        envelope: TypedChatEnvelope,
        sink: ActorSink,
        _guard: InFlightGuard,
    },
    MobileSync {
        events: Vec<MobileSyncEvent>,
        _guard: InFlightGuard,
    },
    E2eeSignal {
        cmd: u16,
        payload: Map<String, Value>,
        _guard: InFlightGuard,
    },
    E2eeDeliverReports {
        cmd: u16,
        payload: Map<String, Value>,
        _guard: InFlightGuard,
    },
    E2eeConnected {
        uid: String,
        _guard: InFlightGuard,
    },
    E2eeDisconnected {
        _guard: InFlightGuard,
    },
    VoipControl {
        act: String,
        raw_data: Value,
        data: Map<String, Value>,
        _guard: InFlightGuard,
    },
    ShowTyping {
        conv_id: String,
        uid: String,
        on_pc: bool,
        _guard: InFlightGuard,
    },
    PinTopic {
        conv_id: String,
        _guard: InFlightGuard,
    },
    GroupNotice {
        act: String,
        data: Map<String, Value>,
        ts: i64,
        _guard: InFlightGuard,
    },
    Mute {
        conv_id: String,
        set: bool,
        start: i64,
        start_explicit: bool,
        duration: i64,
        _guard: InFlightGuard,
    },
    Drain(oneshot::Sender<()>),
}

/// Shared SQLite store slot attached during `prepare_store` and detached before `reset_domains`.
pub type SharedStoreSlot = Arc<Mutex<Option<Arc<Mutex<Store>>>>>;

enum StoreJob {
    Op {
        op: StoreOp,
        sink: ActorSink,
        _guard: InFlightGuard,
    },
    FlushOp {
        op_id: u64,
        result: OpResult,
        sink: ActorSink,
        _guard: InFlightGuard,
    },
    Drain(oneshot::Sender<()>),
}

/// Real effect runner backed by a shared `SessionClient<T>`, a [`WsDriver`], and a [`Host`].
///
/// Generic over `T: Transport` so production uses `ReqwestTransport` and `tests/cases.rs` plugs
/// in a scripted `Transport` over the exact same request-building code.
pub struct SessionEffectRunner<T: Transport + 'static> {
    client: Arc<SessionClient<T>>,
    api: Arc<ZaloApi<T>>,
    ws_driver: Arc<dyn WsDriver>,
    default_domains: Option<ZaloDomains>,
    suppress_long_poll: bool,
    ws_active_gen: Arc<Mutex<Option<u64>>>,
    lp_active_gen: Arc<Mutex<Option<u64>>>,
    shared_store: SharedStoreSlot,
    host_tx: mpsc::UnboundedSender<HostJob>,
    store_tx: mpsc::UnboundedSender<StoreJob>,
    host_dispatched: AtomicU64,
    store_dispatched: AtomicU64,
    active_tasks: Arc<Mutex<Vec<AbortHandle>>>,
    bootstrap_tasks: Arc<Mutex<Vec<AbortHandle>>>,
    lp_timer_abort: Arc<Mutex<Option<AbortHandle>>>,
    lp_fetch_abort: Mutex<Option<AbortHandle>>,
    host_worker_abort: AbortHandle,
    store_worker_abort: AbortHandle,
    runtime: Handle,
}

impl<T: Transport + 'static> SessionEffectRunner<T> {
    /// Starts the runner's serial host worker on `runtime` with [`LiveWsDriver`].
    #[must_use]
    pub fn new(client: Arc<SessionClient<T>>, host: Arc<dyn Host>, runtime: Handle) -> Self {
        Self::with_options(
            client,
            host,
            Arc::new(LiveWsDriver::new()),
            runtime,
            None,
            false,
        )
    }

    /// Starts the runner with an optional domains override restored after `ClearCoreSession`
    /// (used by tests/case replay so QR login after `log_out` still targets the fake server).
    #[must_use]
    pub fn with_default_domains(
        client: Arc<SessionClient<T>>,
        host: Arc<dyn Host>,
        runtime: Handle,
        default_domains: Option<ZaloDomains>,
    ) -> Self {
        Self::with_options(
            client,
            host,
            Arc::new(LiveWsDriver::new()),
            runtime,
            default_domains,
            false,
        )
    }

    /// Full constructor allowing tests to inject a custom [`WsDriver`] and suppress periodic
    /// long-poll timer ticks (still emitting the `start_long_poll` trace marker).
    #[must_use]
    pub fn with_options(
        client: Arc<SessionClient<T>>,
        host: Arc<dyn Host>,
        ws_driver: Arc<dyn WsDriver>,
        runtime: Handle,
        default_domains: Option<ZaloDomains>,
        suppress_long_poll: bool,
    ) -> Self {
        let api = Arc::new(ZaloApi::from_shared(Arc::clone(&client)));
        let (host_tx, host_rx) = mpsc::unbounded_channel();
        let (store_tx, store_rx) = mpsc::unbounded_channel();
        let shared_store: SharedStoreSlot = Arc::new(Mutex::new(None));
        let active_tasks: Arc<Mutex<Vec<AbortHandle>>> = Arc::new(Mutex::new(Vec::new()));
        let bootstrap_tasks: Arc<Mutex<Vec<AbortHandle>>> = Arc::new(Mutex::new(Vec::new()));
        let ws_active_gen: Arc<Mutex<Option<u64>>> = Arc::new(Mutex::new(None));
        let lp_active_gen: Arc<Mutex<Option<u64>>> = Arc::new(Mutex::new(None));
        let lp_timer_abort: Arc<Mutex<Option<AbortHandle>>> = Arc::new(Mutex::new(None));
        let store_handle = runtime.spawn(run_store_worker(
            store_rx,
            Arc::clone(&shared_store),
            runtime.clone(),
        ));
        let worker_handle = runtime.spawn(run_host_worker(HostWorkerDeps {
            rx: host_rx,
            client: Arc::clone(&client),
            host,
            shared_store: Arc::clone(&shared_store),
            store_tx: store_tx.clone(),
            ws_driver: Arc::clone(&ws_driver),
            ws_active_gen: Arc::clone(&ws_active_gen),
            lp_active_gen: Arc::clone(&lp_active_gen),
            lp_timer_abort: Arc::clone(&lp_timer_abort),
            suppress_long_poll,
            active_tasks: Arc::clone(&active_tasks),
            runtime: runtime.clone(),
        }));
        Self {
            client,
            api,
            ws_driver,
            default_domains,
            suppress_long_poll,
            ws_active_gen,
            lp_active_gen,
            shared_store,
            host_tx,
            store_tx,
            host_dispatched: AtomicU64::new(0),
            store_dispatched: AtomicU64::new(0),
            active_tasks,
            bootstrap_tasks,
            lp_timer_abort,
            lp_fetch_abort: Mutex::new(None),
            host_worker_abort: worker_handle.abort_handle(),
            store_worker_abort: store_handle.abort_handle(),
            runtime,
        }
    }

    /// Returns a reference to the runner's [`WsDriver`] (for FFI WS pass-throughs and tests).
    #[must_use]
    pub fn api(&self) -> &Arc<ZaloApi<T>> {
        &self.api
    }

    #[must_use]
    pub fn ws_driver(&self) -> &Arc<dyn WsDriver> {
        &self.ws_driver
    }

    /// Attaches the account's opened SQLite [`Store`] so the core runner can hydrate local state
    /// and execute serial persistence operations directly without Swift hops.
    pub fn attach_store(&self, store: Arc<Mutex<Store>>) {
        *self
            .shared_store
            .lock()
            .unwrap_or_else(PoisonError::into_inner) = Some(store);
    }

    fn send_host(&self, job: HostJob) {
        self.host_dispatched.fetch_add(1, Ordering::AcqRel);
        let _ = self.host_tx.send(job);
    }

    fn send_store(&self, job: StoreJob) {
        self.store_dispatched.fetch_add(1, Ordering::AcqRel);
        let _ = self.store_tx.send(job);
    }

    /// Monotonic count of real host jobs dispatched to the serial host worker.
    #[must_use]
    pub fn host_dispatched(&self) -> u64 {
        self.host_dispatched.load(Ordering::Acquire)
    }

    /// Monotonic count of real store jobs dispatched to the serial SQLite store worker.
    #[must_use]
    pub fn store_dispatched(&self) -> u64 {
        self.store_dispatched.load(Ordering::Acquire)
    }

    /// Waits until all previously queued serial host worker jobs have completed and posted any
    /// resulting inputs back to the actor.
    pub async fn flush_host(&self) {
        let (tx, rx) = oneshot::channel();
        if self.host_tx.send(HostJob::Drain(tx)).is_ok() {
            let _ = rx.await;
        }
    }

    /// Waits until all previously queued serial SQLite store jobs have completed.
    pub async fn flush_store(&self) {
        let (tx, rx) = oneshot::channel();
        if self.store_tx.send(StoreJob::Drain(tx)).is_ok() {
            let _ = rx.await;
        }
    }

    /// Detaches any attached SQLite [`Store`] handle.
    pub fn detach_store(&self) {
        *self
            .shared_store
            .lock()
            .unwrap_or_else(PoisonError::into_inner) = None;
    }

    /// Returns a handle to the shared SQLite store slot (used by test hosts).
    #[must_use]
    pub fn shared_store_slot(&self) -> SharedStoreSlot {
        Arc::clone(&self.shared_store)
    }

    fn cancel_active_tasks(&self) {
        let handles = {
            let mut list = self
                .active_tasks
                .lock()
                .unwrap_or_else(PoisonError::into_inner);
            std::mem::take(&mut *list)
        };
        for handle in handles {
            handle.abort();
        }
    }

    fn cancel_long_poll(&self) {
        if let Some(h) = self
            .lp_timer_abort
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .take()
        {
            h.abort();
        }
        if let Some(h) = self
            .lp_fetch_abort
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .take()
        {
            h.abort();
        }
    }

    fn spawn_cancellable<F>(&self, fut: F)
    where
        F: std::future::Future<Output = ()> + Send + 'static,
    {
        let handle = self.runtime.spawn(fut).abort_handle();
        let mut list = self
            .active_tasks
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        list.retain(|h| !h.is_finished());
        list.push(handle);
    }

    // U4-bootstrap
    fn cancel_bootstrap_tasks(&self) {
        let handles = {
            let mut list = self
                .bootstrap_tasks
                .lock()
                .unwrap_or_else(PoisonError::into_inner);
            std::mem::take(&mut *list)
        };
        for handle in handles {
            handle.abort();
        }
    }

    fn spawn_bootstrap<F>(&self, fut: F)
    where
        F: std::future::Future<Output = ()> + Send + 'static,
    {
        let handle = self.runtime.spawn(fut).abort_handle();
        let mut list = self
            .bootstrap_tasks
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        list.retain(|h| !h.is_finished());
        list.push(handle);
    }

    fn snapshot_json(&self) -> String {
        serde_json::to_string(&self.client.snapshot()).unwrap_or_default()
    }
}

impl<T: Transport + 'static> EffectRunner for SessionEffectRunner<T> {
    fn dispatch(&self, effects: Vec<Effect>, sink: ActorSink) {
        for effect in effects {
            match effect {
                Effect::CancelSessionTasks => {
                    self.cancel_active_tasks();
                    self.cancel_bootstrap_tasks();
                }
                Effect::ClearCoreSession => {
                    self.api.reset_state();
                    let pre_clear_domains = self.client.domains();
                    self.client.clear_session();
                    let restore = if pre_clear_domains.isolated {
                        Some(pre_clear_domains)
                    } else {
                        self.default_domains
                            .as_ref()
                            .filter(|d| d.isolated)
                            .cloned()
                    };
                    if let Some(domains) = restore {
                        self.client.with_session(|s| s.domains = domains);
                    }
                }
                Effect::MarkCoreSessionExpired => {
                    self.client.mark_expired();
                }
                Effect::LoadSavedSession { boot_gen } => {
                    let guard = sink.track();
                    self.send_host(HostJob::LoadSavedSession {
                        boot_gen,
                        sink: sink.clone(),
                        _guard: guard,
                    });
                }
                Effect::LoadLegacyCookie { boot_gen } => {
                    let guard = sink.track();
                    self.send_host(HostJob::LoadLegacyCookie {
                        boot_gen,
                        sink: sink.clone(),
                        _guard: guard,
                    });
                }
                Effect::CheckSessionStatus { boot_gen } => {
                    let client = Arc::clone(&self.client);
                    let _api = Arc::clone(&self.api);
                    let sink = sink.clone();
                    let guard = sink.track();
                    self.spawn_cancellable(async move {
                        let (status, updated_from_login_info) =
                            client.session_status_detailed().await;
                        let ws_endpoints = client.domains().ws;
                        sink.send(Input::SessionStatusResult {
                            boot_gen,
                            status,
                            updated_from_login_info,
                            ws_endpoints,
                        });
                        drop(guard);
                    });
                }
                Effect::SyncProfileMe { boot_gen } => {
                    let client = Arc::clone(&self.client);
                    let _api = Arc::clone(&self.api);
                    let sink = sink.clone();
                    let guard = sink.track();
                    self.spawn_cancellable(async move {
                        let synced = client.sync_profile_me().await;
                        let profile_synced = synced.is_some();
                        let account = synced.or_else(|| client.account());
                        let ws_endpoints = client.domains().ws;
                        sink.send(Input::SyncProfileMeDone {
                            boot_gen,
                            profile_synced,
                            account,
                            ws_endpoints,
                        });
                        drop(guard);
                    });
                }
                Effect::RequestQr { qr_gen, language } => {
                    let client = Arc::clone(&self.client);
                    let _api = Arc::clone(&self.api);
                    let sink = sink.clone();
                    let guard = sink.track();
                    self.spawn_cancellable(async move {
                        let result = client
                            .request_qr(&language)
                            .await
                            .map_err(SessionFailure::from);
                        sink.send(Input::QrRequested { qr_gen, result });
                        drop(guard);
                    });
                }
                Effect::WaitQrScan { qr_gen, ticket } => {
                    let client = Arc::clone(&self.client);
                    let _api = Arc::clone(&self.api);
                    let sink = sink.clone();
                    let guard = sink.track();
                    self.spawn_cancellable(async move {
                        let rot_sink = sink.clone();
                        let mut on_rotated = move |rotated: &olaz_net::QrTicket| {
                            rot_sink.send(Input::QrRotated {
                                qr_gen,
                                ticket: rotated.clone(),
                            });
                        };
                        let result = client
                            .wait_for_qr_scan(&ticket, Some(&mut on_rotated))
                            .await
                            .map_err(SessionFailure::from);
                        sink.send(Input::QrScanned { qr_gen, result });
                        drop(guard);
                    });
                }
                Effect::WaitQrConfirm { qr_gen, ticket } => {
                    let client = Arc::clone(&self.client);
                    let _api = Arc::clone(&self.api);
                    let sink = sink.clone();
                    let guard = sink.track();
                    self.spawn_cancellable(async move {
                        let result = client
                            .wait_for_qr_confirm(&ticket)
                            .await
                            .map(|_| ())
                            .map_err(SessionFailure::from);
                        sink.send(Input::QrConfirmed { qr_gen, result });
                        drop(guard);
                    });
                }
                Effect::CompleteLogin { qr_gen } => {
                    let client = Arc::clone(&self.client);
                    let _api = Arc::clone(&self.api);
                    let sink = sink.clone();
                    let guard = sink.track();
                    self.spawn_cancellable(async move {
                        let result = client
                            .complete_login_detailed()
                            .await
                            .map(|(account, profile_synced)| CompletedLogin {
                                account,
                                ws_endpoints: client.domains().ws,
                                profile_synced,
                            })
                            .map_err(SessionFailure::from);
                        sink.send(Input::LoginCompleted { qr_gen, result });
                        drop(guard);
                    });
                }
                Effect::SetPref { key, value } => {
                    let guard = sink.track();
                    self.send_host(HostJob::SetPref {
                        key,
                        value,
                        _guard: guard,
                    });
                }
                Effect::StartWs {
                    ws_gen,
                    endpoints,
                    seed_cursors,
                    my_uid,
                    self_conv_id,
                } => {
                    *self
                        .ws_active_gen
                        .lock()
                        .unwrap_or_else(PoisonError::into_inner) = Some(ws_gen);
                    let zpw_sek = self.client.zpw_sek().unwrap_or_default();
                    let guard = sink.track();
                    self.send_host(HostJob::StartWs {
                        params: WsStartParams {
                            ws_gen,
                            endpoints,
                            zpw_sek,
                            seed_cursors,
                            my_uid,
                            self_conv_id,
                        },
                        sink: sink.clone(),
                        _guard: guard,
                    });
                }
                Effect::StopWs { reset_cursors } => {
                    *self
                        .ws_active_gen
                        .lock()
                        .unwrap_or_else(PoisonError::into_inner) = None;
                    self.ws_driver.stop(reset_cursors);
                }
                Effect::RecordFileDone { file_id, url } => {
                    self.ws_driver.record_file_done(file_id, url);
                }
                Effect::StartLpTimer {
                    lp_gen,
                    initial,
                    delay,
                } => {
                    if let Some(prev) = self
                        .lp_timer_abort
                        .lock()
                        .unwrap_or_else(PoisonError::into_inner)
                        .take()
                    {
                        prev.abort();
                    }
                    if initial {
                        *self
                            .lp_active_gen
                            .lock()
                            .unwrap_or_else(PoisonError::into_inner) = Some(lp_gen);
                        let guard = sink.track();
                        self.send_host(HostJob::StartLpInitial {
                            lp_gen,
                            delay,
                            sink: sink.clone(),
                            _guard: guard,
                        });
                    } else if !self.suppress_long_poll
                        && *self
                            .lp_active_gen
                            .lock()
                            .unwrap_or_else(PoisonError::into_inner)
                            == Some(lp_gen)
                    {
                        let timer_sink = sink.clone();
                        let handle = self
                            .runtime
                            .spawn(async move {
                                tokio::time::sleep(delay).await;
                                timer_sink.send(Input::LpTick { lp_gen });
                            })
                            .abort_handle();
                        *self
                            .lp_timer_abort
                            .lock()
                            .unwrap_or_else(PoisonError::into_inner) = Some(handle);
                    }
                }
                Effect::StopLongPoll => {
                    *self
                        .lp_active_gen
                        .lock()
                        .unwrap_or_else(PoisonError::into_inner) = None;
                    self.cancel_long_poll();
                }
                Effect::FetchPollBatch {
                    lp_gen,
                    drain_id,
                    poll_state,
                } => {
                    if let Some(prev) = self
                        .lp_fetch_abort
                        .lock()
                        .unwrap_or_else(PoisonError::into_inner)
                        .take()
                    {
                        prev.abort();
                    }
                    let _client = Arc::clone(&self.client);
                    let api = Arc::clone(&self.api);
                    let fetch_sink = sink.clone();
                    let guard = sink.track();
                    let handle = self
                        .runtime
                        .spawn(async move {
                            let result = match api.fetch_chat_from_polling(&poll_state).await {
                                Ok(outcome) => Ok(PollBatchOutcome {
                                    payload: outcome.response,
                                    next_state: outcome.next_state,
                                    more: outcome.more,
                                }),
                                Err(err) if err.is_auth_error() => Err(PollBatchError::Auth),
                                Err(_) => Err(PollBatchError::Other),
                            };
                            fetch_sink.send(Input::PollBatchFetched {
                                lp_gen,
                                drain_id,
                                result,
                                now_unix_secs: unix_now_secs(),
                            });
                            drop(guard);
                        })
                        .abort_handle();
                    *self
                        .lp_fetch_abort
                        .lock()
                        .unwrap_or_else(PoisonError::into_inner) = Some(handle);
                }
                Effect::CompleteDrain { .. } => {
                    // Handled directly by the actor before reaching EffectRunner.
                }
                Effect::EngineLog(msg) => {
                    tracing::info!(target: "olaz_core::engine_log", "{msg}");
                    self.send_host(HostJob::EngineLog {
                        message: msg,
                        _guard: sink.track(),
                    });
                }
                Effect::Store(op) => {
                    let guard = sink.track();
                    self.send_store(StoreJob::Op {
                        op,
                        sink: sink.clone(),
                        _guard: guard,
                    });
                }
                Effect::DetachStore => {
                    let guard = sink.track();
                    self.send_host(HostJob::DetachStore { _guard: guard });
                }
                Effect::CompleteOp {
                    op_id,
                    result,
                    after_store: true,
                } => {
                    let guard = sink.track();
                    self.send_store(StoreJob::FlushOp {
                        op_id,
                        result,
                        sink: sink.clone(),
                        _guard: guard,
                    });
                }
                Effect::CompleteOp {
                    after_store: false, ..
                } => {
                    // Handled directly by the actor before reaching EffectRunner.
                }
                Effect::UpdatePinnedConversationApi { id, pinned, op_id } => {
                    let _client = Arc::clone(&self.client);
                    let api = Arc::clone(&self.api);
                    let sink = sink.clone();
                    let guard = sink.track();
                    self.runtime.spawn(async move {
                        let ok = api.update_pinned_conversation(&id, pinned).await.is_ok();
                        sink.send(Input::PinApiDone {
                            id,
                            pinned,
                            ok,
                            op_id,
                        });
                        drop(guard);
                    });
                }
                Effect::PinReplacingApi {
                    op_id,
                    target_id,
                    pinned,
                    unpin_remaining,
                    pin_id,
                } => {
                    let _client = Arc::clone(&self.client);
                    let api = Arc::clone(&self.api);
                    let sink = sink.clone();
                    let guard = sink.track();
                    self.runtime.spawn(async move {
                        let ok = api
                            .update_pinned_conversation(&target_id, pinned)
                            .await
                            .is_ok();
                        sink.send(Input::PinReplacingStepDone {
                            op_id,
                            target_id,
                            pinned,
                            unpin_remaining,
                            pin_id,
                            ok,
                        });
                        drop(guard);
                    });
                }
                Effect::UpdateArchivedChatApi {
                    id,
                    archived,
                    op_id,
                } => {
                    let _client = Arc::clone(&self.client);
                    let api = Arc::clone(&self.api);
                    let sink = sink.clone();
                    let guard = sink.track();
                    self.runtime.spawn(async move {
                        let ok = api.update_archived_chat(&id, archived).await.is_ok();
                        sink.send(Input::MoveApiDone {
                            id,
                            to_other: archived,
                            ok,
                            op_id,
                        });
                        drop(guard);
                    });
                }
                Effect::DeleteConversationApi {
                    id,
                    last_cli_msg_id,
                    op_id,
                } => {
                    let _client = Arc::clone(&self.client);
                    let api = Arc::clone(&self.api);
                    let sink = sink.clone();
                    let guard = sink.track();
                    self.runtime.spawn(async move {
                        let _ = api.delete_conversation(&id, &last_cli_msg_id).await;
                        sink.send(Input::DeleteApiDone { id, op_id });
                        drop(guard);
                    });
                }
                Effect::SetUnreadMarkApi { conv_id, unread } => {
                    let _client = Arc::clone(&self.client);
                    let api = Arc::clone(&self.api);
                    let guard = sink.track();
                    self.runtime.spawn(async move {
                        let _ = api.set_unread_mark(&conv_id, unread).await;
                        drop(guard);
                    });
                }
                Effect::SendSeenApi(target) => {
                    let _client = Arc::clone(&self.client);
                    let api = Arc::clone(&self.api);
                    let guard = sink.track();
                    self.runtime.spawn(async move {
                        let _ = api
                            .send_seen(
                                &target.conv_id,
                                &target.msg_id,
                                &target.cli_msg_id,
                                &target.sender_id,
                            )
                            .await;
                        drop(guard);
                    });
                }
                Effect::SetHiddenConversationApi {
                    conv_id,
                    hidden,
                    op_id,
                    result,
                } => {
                    let _client = Arc::clone(&self.client);
                    let api = Arc::clone(&self.api);
                    let sink = sink.clone();
                    let guard = sink.track();
                    self.runtime.spawn(async move {
                        let _ = api.set_hidden_conversation(&conv_id, hidden).await;
                        if let (Some(id), Some(res)) = (op_id, result) {
                            sink.send(Input::OpApiDone {
                                op_id: id,
                                result: OpResult::ActionResult(res),
                            });
                        }
                        drop(guard);
                    });
                }
                Effect::UpdateHiddenPinApi { pin, kind, op_id } => {
                    let client = Arc::clone(&self.client);
                    let api = Arc::clone(&self.api);
                    let sink = sink.clone();
                    let guard = sink.track();
                    self.runtime.spawn(async move {
                        let md5 = if client.is_authenticated() {
                            if api.update_hidden_pin(&pin).await.is_err() {
                                sink.send(Input::HiddenPinSyncDone {
                                    op_id,
                                    kind,
                                    ok: false,
                                    md5: None,
                                    sha256: String::new(),
                                });
                                drop(guard);
                                return;
                            }
                            Some(hidden_pin_md5(&pin))
                        } else {
                            None
                        };
                        let sha256 = hidden_pin_sha256(&pin);
                        sink.send(Input::HiddenPinSyncDone {
                            op_id,
                            kind,
                            ok: true,
                            md5,
                            sha256,
                        });
                        drop(guard);
                    });
                }
                Effect::ResetHiddenPinApi { op_id } => {
                    let client = Arc::clone(&self.client);
                    let api = Arc::clone(&self.api);
                    let sink = sink.clone();
                    let guard = sink.track();
                    self.runtime.spawn(async move {
                        let ok = if client.is_authenticated() {
                            api.reset_hidden_pin().await.is_ok()
                        } else {
                            true
                        };
                        sink.send(Input::ResetHiddenPinApiDone { op_id, ok });
                        drop(guard);
                    });
                }
                Effect::FetchHiddenConversationsApi { op_id } => {
                    let client = Arc::clone(&self.client);
                    let api = Arc::clone(&self.api);
                    let sink = sink.clone();
                    let guard = sink.track();
                    self.runtime.spawn(async move {
                        let snapshot = if client.is_authenticated() {
                            api.fetch_hidden_conversations().await.ok()
                        } else {
                            None
                        };
                        sink.send(Input::SyncHiddenFetched { op_id, snapshot });
                        drop(guard);
                    });
                }
                Effect::FetchProfilesChunkApi {
                    op_id,
                    chunk,
                    remaining_chunks,
                    profiles_cache_changed,
                } => {
                    let _client = Arc::clone(&self.client);
                    let api = Arc::clone(&self.api);
                    let sink = sink.clone();
                    let guard = sink.track();
                    self.runtime.spawn(async move {
                        let profiles_map = match api.fetch_profiles(&chunk).await {
                            Ok(raw) => extract_profiles_map(&raw),
                            Err(_) => Map::new(),
                        };
                        sink.send(Input::ResolveNamesChunkDone {
                            op_id,
                            remaining_chunks,
                            profiles_map,
                            profiles_cache_changed,
                        });
                        drop(guard);
                    });
                }
                Effect::UpdateConversationLabelsApi {
                    label_data_json,
                    op_id,
                } => {
                    let _client = Arc::clone(&self.client);
                    let api = Arc::clone(&self.api);
                    let sink = sink.clone();
                    let guard = sink.track();
                    self.runtime.spawn(async move {
                        let _ = api.update_conversation_labels(&label_data_json).await;
                        if let Some(id) = op_id {
                            sink.send(Input::OpApiDone {
                                op_id: id,
                                result: OpResult::Unit,
                            });
                        }
                        drop(guard);
                    });
                }
                Effect::FetchConversationLabelsApi { op_id } => {
                    let _client = Arc::clone(&self.client);
                    let api = Arc::clone(&self.api);
                    let sink = sink.clone();
                    let guard = sink.track();
                    self.runtime.spawn(async move {
                        let payload = api.fetch_conversation_labels().await.ok();
                        sink.send(Input::SyncLabelsFetched { op_id, payload });
                        drop(guard);
                    });
                }
                // --- Launch bootstrap network effects (U4-bootstrap) ---
                Effect::CancelBootstrapTasks => {
                    self.cancel_bootstrap_tasks();
                }
                Effect::BootstrapFetchAliasesApi { boot_gen } => {
                    let _client = Arc::clone(&self.client);
                    let api = Arc::clone(&self.api);
                    let sink = sink.clone();
                    let guard = sink.track();
                    self.spawn_bootstrap(async move {
                        let result = match api.fetch_aliases().await {
                            Ok(aliases) => Ok(aliases),
                            Err(err) if err.is_auth_error() => Err(BootstrapAliasesError::Auth),
                            Err(_) => Err(BootstrapAliasesError::Other),
                        };
                        sink.send(Input::BootstrapAliasesDone { boot_gen, result });
                        drop(guard);
                    });
                }
                Effect::BootstrapFetchPamApi { boot_gen } => {
                    let _client = Arc::clone(&self.client);
                    let api = Arc::clone(&self.api);
                    let sink = sink.clone();
                    let guard = sink.track();
                    self.spawn_bootstrap(async move {
                        let (pinned_res, archived_res, mute_res) = tokio::join!(
                            api.fetch_pinned_conversations(),
                            api.fetch_archived_chats(),
                            api.fetch_mute_list(),
                        );
                        sink.send(Input::BootstrapPamDone {
                            boot_gen,
                            pinned_ids: pinned_res.ok(),
                            archived_ids: archived_res.ok(),
                            mute_rows: mute_res.ok(),
                        });
                        drop(guard);
                    });
                }
                Effect::BootstrapFetchLabelsApi { boot_gen } => {
                    let _client = Arc::clone(&self.client);
                    let api = Arc::clone(&self.api);
                    let sink = sink.clone();
                    let guard = sink.track();
                    self.spawn_bootstrap(async move {
                        let payload = api.fetch_conversation_labels().await.ok();
                        sink.send(Input::BootstrapLabelsDone { boot_gen, payload });
                        drop(guard);
                    });
                }
                Effect::BootstrapFetchHiddenApi { boot_gen } => {
                    let client = Arc::clone(&self.client);
                    let api = Arc::clone(&self.api);
                    let sink = sink.clone();
                    let guard = sink.track();
                    self.spawn_bootstrap(async move {
                        let snapshot = if client.is_authenticated() {
                            api.fetch_hidden_conversations().await.ok()
                        } else {
                            None
                        };
                        sink.send(Input::BootstrapHiddenDone { boot_gen, snapshot });
                        drop(guard);
                    });
                }
                Effect::BootstrapFetchContactsApi { boot_gen } => {
                    let _client = Arc::clone(&self.client);
                    let api = Arc::clone(&self.api);
                    let sink = sink.clone();
                    let guard = sink.track();
                    self.spawn_bootstrap(async move {
                        let (friends_res, groups_res, sent_res, received_res) = tokio::join!(
                            api.fetch_friends(1, 20000),
                            api.fetch_groups_list(),
                            api.fetch_sent_friend_requests(),
                            api.fetch_received_friend_requests(),
                        );
                        sink.send(Input::BootstrapContactsDone {
                            boot_gen,
                            friends_rows: friends_res.ok(),
                            groups_dict: groups_res.ok(),
                            sent_rows: sent_res.ok(),
                            received_rows: received_res.ok(),
                        });
                        drop(guard);
                    });
                }
                Effect::BootstrapFetchPreloadApi {
                    boot_gen,
                    thread_ids,
                    is_overview,
                } => {
                    let _client = Arc::clone(&self.client);
                    let api = Arc::clone(&self.api);
                    let sink = sink.clone();
                    let guard = sink.track();
                    self.spawn_bootstrap(async move {
                        let payload = api.fetch_preload_conversations(&thread_ids).await.ok();
                        sink.send(Input::BootstrapPreloadDone {
                            boot_gen,
                            is_overview,
                            payload,
                        });
                        drop(guard);
                    });
                }
                Effect::BootstrapFetchHistoryApi {
                    boot_gen,
                    conv_id,
                    count,
                } => {
                    let _client = Arc::clone(&self.client);
                    let api = Arc::clone(&self.api);
                    let sink = sink.clone();
                    let guard = sink.track();
                    self.spawn_bootstrap(async move {
                        let payload = api
                            .fetch_history(&conv_id, None, count, Some(false))
                            .await
                            .ok();
                        sink.send(Input::BootstrapSelfCloudDone {
                            boot_gen,
                            conv_id,
                            payload,
                        });
                        drop(guard);
                    });
                }
                Effect::BootstrapFetchGroupWaveApi {
                    boot_gen,
                    gids,
                    count,
                } => {
                    let client = Arc::clone(&self.client);
                    let _api = Arc::clone(&self.api);
                    let sink = sink.clone();
                    let guard = sink.track();
                    self.spawn_bootstrap(async move {
                        type WaveEntry = (String, Option<Map<String, Value>>);
                        let len = gids.len();
                        let mut set: tokio::task::JoinSet<(usize, WaveEntry)> =
                            tokio::task::JoinSet::new();
                        for (idx, gid) in gids.into_iter().enumerate() {
                            let task_client = Arc::clone(&client);
                            set.spawn(async move {
                                let api = ZaloApi::from_shared(task_client);
                                let payload =
                                    api.fetch_history(&gid, None, count, Some(false)).await.ok();
                                (idx, (gid, payload))
                            });
                        }
                        let mut slots: Vec<Option<WaveEntry>> = vec![None; len];
                        while let Some(joined) = set.join_next().await {
                            if let Ok((idx, entry)) = joined
                                && let Some(slot) = slots.get_mut(idx)
                            {
                                *slot = Some(entry);
                            }
                        }
                        let results: Vec<WaveEntry> = slots.into_iter().flatten().collect();
                        sink.send(Input::BootstrapGroupWaveDone { boot_gen, results });
                        drop(guard);
                    });
                }
                Effect::BootstrapFetchProfilesChunkApi {
                    boot_gen,
                    chunk,
                    remaining_chunks,
                    profiles_cache_changed,
                } => {
                    let _client = Arc::clone(&self.client);
                    let api = Arc::clone(&self.api);
                    let sink = sink.clone();
                    let guard = sink.track();
                    self.spawn_bootstrap(async move {
                        let profiles_map = match api.fetch_profiles(&chunk).await {
                            Ok(raw) => extract_profiles_map(&raw),
                            Err(_) => Map::new(),
                        };
                        sink.send(Input::BootstrapResolveNamesChunkDone {
                            boot_gen,
                            remaining_chunks,
                            profiles_map,
                            profiles_cache_changed,
                        });
                        drop(guard);
                    });
                }
                Effect::FetchHistoryPageApi {
                    conv_id,
                    before_msg_id,
                    count,
                    is_old,
                    purpose,
                } => {
                    let client = Arc::clone(&self.client);
                    let api = Arc::clone(&self.api);
                    let sink = sink.clone();
                    let guard = sink.track();
                    self.spawn_cancellable(async move {
                        let page = if client.is_authenticated() {
                            api.fetch_history(&conv_id, before_msg_id.as_deref(), count, is_old)
                                .await
                                .ok()
                        } else {
                            None
                        };
                        match purpose {
                            HistoryFetchPurpose::Open { open_seq, op_id } => {
                                sink.send(Input::OpenHistoryPageFetched {
                                    open_seq,
                                    conv_id,
                                    page,
                                    op_id,
                                });
                            }
                            HistoryFetchPurpose::LoadOlder { load_seq, op_id } => {
                                sink.send(Input::LoadOlderPageFetched {
                                    load_seq,
                                    conv_id,
                                    before_msg_id,
                                    page,
                                    op_id,
                                });
                            }
                        }
                        drop(guard);
                    });
                }
                Effect::FetchSenderProfilesChunkApi {
                    resolve_id,
                    conv_id,
                    chunk,
                    remaining_chunks,
                    cache_updated,
                } => {
                    let client = Arc::clone(&self.client);
                    let api = Arc::clone(&self.api);
                    let sink = sink.clone();
                    let guard = sink.track();
                    self.spawn_cancellable(async move {
                        let profiles_map = if client.is_authenticated() {
                            match api.fetch_profiles(&chunk).await {
                                Ok(raw) => extract_profiles_map(&raw),
                                Err(_) => Map::new(),
                            }
                        } else {
                            Map::new()
                        };
                        sink.send(Input::SenderProfilesChunkDone {
                            resolve_id,
                            conv_id,
                            remaining_chunks,
                            profiles_map,
                            cache_updated,
                        });
                        drop(guard);
                    });
                }
                Effect::Host(call) => {
                    let guard = sink.track();
                    let job = match call {
                        HostCall::PrepareStore {
                            token,
                            user_id,
                            account,
                            identities,
                        } => HostJob::PrepareStore {
                            token,
                            user_id,
                            account,
                            identities,
                            sink: sink.clone(),
                            _guard: guard,
                        },
                        HostCall::StartBootstrap => HostJob::StartBootstrap {
                            sink: sink.clone(),
                            _guard: guard,
                        },
                        HostCall::OfferFirstLoginTransfer { force } => {
                            HostJob::OfferFirstLoginTransfer {
                                force,
                                _guard: guard,
                            }
                        }
                        HostCall::ResetDomains => HostJob::ResetDomains { _guard: guard },
                        HostCall::PersistSession => HostJob::PersistSession {
                            snapshot_json: self.snapshot_json(),
                            _guard: guard,
                        },
                        HostCall::ClearSession => HostJob::ClearSession { _guard: guard },
                        HostCall::MarkExpired => HostJob::MarkExpired {
                            snapshot_json: self.snapshot_json(),
                            _guard: guard,
                        },
                        HostCall::PersistPollState { state } => HostJob::PersistPollState {
                            state,
                            _guard: guard,
                        },
                        HostCall::PersistWsCursors { cursors } => HostJob::PersistWsCursors {
                            cursors,
                            _guard: guard,
                        },
                        HostCall::ApplyBatch {
                            cmd,
                            increment_unread,
                            notify_incoming,
                            payload,
                            poll_batch_done,
                        } => HostJob::ApplyBatch {
                            cmd,
                            increment_unread,
                            notify_incoming,
                            payload,
                            poll_batch_done,
                            sink: sink.clone(),
                            _guard: guard,
                        },
                        HostCall::ApplyParsedEvents {
                            cmd,
                            increment_unread,
                            notify_incoming,
                            envelope,
                        } => HostJob::ApplyParsedEvents {
                            cmd,
                            increment_unread,
                            notify_incoming,
                            envelope,
                            sink: sink.clone(),
                            _guard: guard,
                        },
                        HostCall::MobileSync { events } => HostJob::MobileSync {
                            events,
                            _guard: guard,
                        },
                        HostCall::E2eeSignal { cmd, payload } => HostJob::E2eeSignal {
                            cmd,
                            payload,
                            _guard: guard,
                        },
                        HostCall::E2eeDeliverReports { cmd, payload } => {
                            HostJob::E2eeDeliverReports {
                                cmd,
                                payload,
                                _guard: guard,
                            }
                        }
                        HostCall::E2eeConnected { uid } => {
                            HostJob::E2eeConnected { uid, _guard: guard }
                        }
                        HostCall::E2eeDisconnected => HostJob::E2eeDisconnected { _guard: guard },
                        HostCall::VoipControl {
                            act,
                            raw_data,
                            data,
                        } => HostJob::VoipControl {
                            act,
                            raw_data,
                            data,
                            _guard: guard,
                        },
                        HostCall::ShowTyping {
                            conv_id,
                            uid,
                            on_pc,
                        } => HostJob::ShowTyping {
                            conv_id,
                            uid,
                            on_pc,
                            _guard: guard,
                        },
                        HostCall::PinTopic { conv_id } => HostJob::PinTopic {
                            conv_id,
                            _guard: guard,
                        },
                        HostCall::GroupNotice { act, data, ts } => HostJob::GroupNotice {
                            act,
                            data,
                            ts,
                            _guard: guard,
                        },
                        HostCall::Mute {
                            conv_id,
                            set,
                            start,
                            start_explicit,
                            duration,
                        } => HostJob::Mute {
                            conv_id,
                            set,
                            start,
                            start_explicit,
                            duration,
                            _guard: guard,
                        },
                        // U4-bootstrap
                        HostCall::ApplyMutes { mutes } => HostJob::ApplyMutes {
                            mutes,
                            _guard: guard,
                        },
                        HostCall::RefreshCloud => HostJob::RefreshCloud { _guard: guard },
                        HostCall::OnOpenConversationSync { conv_id, changed } => {
                            HostJob::OnOpenConversationSync {
                                conv_id,
                                changed,
                                _guard: guard,
                            }
                        }
                        HostCall::OnCloseConversation => {
                            HostJob::OnCloseConversation { _guard: guard }
                        }
                        HostCall::RefreshBoardPins { conv_id } => HostJob::RefreshBoardPins {
                            conv_id,
                            _guard: guard,
                        },
                        HostCall::MarkReadBoundary {
                            conv_id,
                            seen_target,
                        } => HostJob::MarkReadBoundary {
                            conv_id,
                            seen_target,
                            _guard: guard,
                        },
                        HostCall::ApplyRemoteReaction {
                            conv_id,
                            msg_id,
                            cli_msg_id,
                            sender_id,
                            r_type,
                            r_icon,
                            event_id,
                            react_client_id,
                            sender_name,
                        } => HostJob::ApplyRemoteReaction {
                            conv_id,
                            msg_id,
                            cli_msg_id,
                            sender_id,
                            r_type,
                            r_icon,
                            event_id,
                            react_client_id,
                            sender_name,
                            _guard: guard,
                        },
                        HostCall::ApplyRemoteRecall {
                            conv_id,
                            msg_id,
                            cli_msg_id,
                            update_conversation_preview,
                        } => HostJob::ApplyRemoteRecall {
                            conv_id,
                            msg_id,
                            cli_msg_id,
                            update_conversation_preview,
                            _guard: guard,
                        },
                        HostCall::ApplyRemoteDelete {
                            conv_id,
                            msg_id,
                            cli_msg_id,
                            update_conversation_preview,
                        } => HostJob::ApplyRemoteDelete {
                            conv_id,
                            msg_id,
                            cli_msg_id,
                            update_conversation_preview,
                            _guard: guard,
                        },
                        HostCall::DecryptEnvelope {
                            payload,
                            default_cmd,
                            fallback_conv_id,
                            is_group_hint,
                            increment_unread,
                            notify_incoming,
                            persist_conversations,
                            probe_freshness,
                            poll_batch_done,
                            op_id,
                        } => HostJob::DecryptEnvelope {
                            payload,
                            default_cmd,
                            fallback_conv_id,
                            is_group_hint,
                            increment_unread,
                            notify_incoming,
                            persist_conversations,
                            probe_freshness,
                            poll_batch_done,
                            op_id,
                            sink: sink.clone(),
                            _guard: guard,
                        },
                        HostCall::MarkE2eeConversations { conv_ids } => {
                            HostJob::MarkE2eeConversations {
                                conv_ids,
                                _guard: guard,
                            }
                        }
                        HostCall::NotePollMessages { messages } => HostJob::NotePollMessages {
                            messages,
                            _guard: guard,
                        },
                        HostCall::NotifyIncomingMessages { messages } => {
                            HostJob::NotifyIncomingMessages {
                                messages,
                                _guard: guard,
                            }
                        }
                        HostCall::ShowBatchTyping { conv_id, sender_id } => {
                            HostJob::ShowBatchTyping {
                                conv_id,
                                sender_id,
                                _guard: guard,
                            }
                        }
                        HostCall::TransportBatchSettled => {
                            HostJob::TransportBatchSettled { _guard: guard }
                        }
                    };
                    self.send_host(job);
                }
            }
        }
    }

    fn shutdown(&self) {
        *self
            .ws_active_gen
            .lock()
            .unwrap_or_else(PoisonError::into_inner) = None;
        *self
            .lp_active_gen
            .lock()
            .unwrap_or_else(PoisonError::into_inner) = None;
        self.cancel_active_tasks();
        self.cancel_bootstrap_tasks();
        self.cancel_long_poll();
        self.ws_driver.stop(false);
        self.host_worker_abort.abort();
        self.store_worker_abort.abort();
    }
}

fn unix_now_secs() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| i64::try_from(d.as_secs()).unwrap_or(i64::MAX))
}

fn unix_now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| i64::try_from(d.as_millis()).unwrap_or(i64::MAX))
}

async fn run_store_worker(
    mut rx: mpsc::UnboundedReceiver<StoreJob>,
    shared_store: SharedStoreSlot,
    runtime: Handle,
) {
    while let Some(job) = rx.recv().await {
        match job {
            StoreJob::Op { op, sink, _guard } => {
                let store_opt = shared_store
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner)
                    .clone();
                match op {
                    StoreOp::LoadMentionPreviewMessages {
                        op_id,
                        group_ids,
                        my_uid: _,
                    } => {
                        let messages = if let Some(store_arc) = store_opt {
                            runtime
                                .spawn_blocking(move || {
                                    let store =
                                        store_arc.lock().unwrap_or_else(PoisonError::into_inner);
                                    let mut map = BTreeMap::new();
                                    for gid in group_ids {
                                        if let Ok(rows) = store.messages(&gid, None, 1)
                                            && let Some(latest) = rows.last()
                                            && let Some(msg) =
                                                decode_stored_message(&to_wire_stored(latest))
                                        {
                                            map.insert(
                                                gid,
                                                MessagePreviewInput::from_chat_message(&msg),
                                            );
                                        }
                                    }
                                    map
                                })
                                .await
                                .unwrap_or_default()
                        } else {
                            BTreeMap::new()
                        };
                        sink.send(Input::MentionPreviewsLoaded { op_id, messages });
                    }
                    StoreOp::LoadOpenLocalMessages {
                        open_seq,
                        conv_id,
                        limit,
                        op_id,
                    } => {
                        let conv_clone = conv_id.clone();
                        let rows = if let Some(store_arc) = store_opt {
                            runtime
                                .spawn_blocking(move || {
                                    let store =
                                        store_arc.lock().unwrap_or_else(PoisonError::into_inner);
                                    store
                                        .messages(
                                            &conv_clone,
                                            None,
                                            i64::try_from(limit).unwrap_or(50),
                                        )
                                        .unwrap_or_default()
                                })
                                .await
                                .unwrap_or_default()
                        } else {
                            Vec::new()
                        };
                        sink.send(Input::OpenLocalMessagesLoaded {
                            open_seq,
                            conv_id,
                            rows,
                            op_id,
                        });
                    }
                    StoreOp::LoadOlderStoreMessages {
                        load_seq,
                        conv_id,
                        before_ts_ms,
                        limit,
                        op_id,
                    } => {
                        let conv_clone = conv_id.clone();
                        let rows = if let Some(store_arc) = store_opt {
                            runtime
                                .spawn_blocking(move || {
                                    let store =
                                        store_arc.lock().unwrap_or_else(PoisonError::into_inner);
                                    store
                                        .messages(
                                            &conv_clone,
                                            Some(before_ts_ms),
                                            i64::try_from(limit).unwrap_or(50),
                                        )
                                        .unwrap_or_default()
                                })
                                .await
                                .unwrap_or_default()
                        } else {
                            Vec::new()
                        };
                        sink.send(Input::LoadOlderStoreRead {
                            load_seq,
                            conv_id,
                            rows,
                            had_before_cursor: true,
                            op_id,
                        });
                    }
                    // U4-bootstrap
                    StoreOp::LoadPreferenceString { key, boot_gen } => {
                        let last_refresh_pref = if let Some(store_arc) = store_opt {
                            runtime
                                .spawn_blocking(move || {
                                    let store =
                                        store_arc.lock().unwrap_or_else(PoisonError::into_inner);
                                    store.get_preference_string(&key).ok().flatten()
                                })
                                .await
                                .ok()
                                .flatten()
                        } else {
                            None
                        };
                        sink.send(Input::BootstrapFreshnessLoaded {
                            boot_gen,
                            last_refresh_pref,
                        });
                    }
                    StoreOp::ProbeAndSaveMessages {
                        probe_targets,
                        rows,
                        preserve_existing_reactions,
                        reply_boot_gen,
                    } => {
                        let probes = if let Some(store_arc) = store_opt {
                            runtime
                                .spawn_blocking(move || {
                                    let mut store =
                                        store_arc.lock().unwrap_or_else(PoisonError::into_inner);
                                    let mut out = Vec::with_capacity(probe_targets.len());
                                    for (conv_id, msg_id) in probe_targets {
                                        let exists = store
                                            .existing_message_ids(
                                                &conv_id,
                                                std::slice::from_ref(&msg_id),
                                            )
                                            .map(|set| set.contains(&msg_id))
                                            .unwrap_or(false);
                                        out.push((conv_id, exists));
                                    }
                                    if !rows.is_empty() {
                                        let _ = store.save_messages_with(
                                            &rows,
                                            SaveOptions {
                                                skip_twin_checks: false,
                                                preserve_existing_reactions,
                                            },
                                        );
                                    }
                                    out
                                })
                                .await
                                .unwrap_or_default()
                        } else {
                            probe_targets
                                .into_keys()
                                .map(|conv_id| (conv_id, false))
                                .collect()
                        };
                        if !probes.is_empty() || reply_boot_gen.is_some() {
                            sink.send(Input::FreshnessProbed {
                                boot_gen: reply_boot_gen,
                                probes,
                            });
                        }
                    }
                    other => {
                        if let Some(store_arc) = store_opt {
                            let _ = runtime
                                .spawn_blocking(move || {
                                    let mut store =
                                        store_arc.lock().unwrap_or_else(PoisonError::into_inner);
                                    match other {
                                        StoreOp::SaveConversations(mut rows) => {
                                            let now = unix_now_ms();
                                            for row in &mut rows {
                                                row.updated_at_ms = now;
                                            }
                                            let _ = store.save_conversations(&rows);
                                        }
                                        StoreOp::SetConversationPinned { id, pinned } => {
                                            let _ = store.set_conversation_pinned(&id, pinned);
                                        }
                                        StoreOp::SetConversationUnread { id, unread } => {
                                            let _ = store.set_conversation_unread(&id, unread);
                                        }
                                        StoreOp::SetConversationPreview {
                                            id,
                                            preview_text,
                                            preview_ts_ms,
                                            preview_from_me,
                                        } => {
                                            let _ = store.set_conversation_preview(
                                                &id,
                                                &preview_text,
                                                preview_ts_ms,
                                                preview_from_me,
                                                unix_now_ms(),
                                            );
                                        }
                                        StoreOp::DeleteConversation { id } => {
                                            let _ = store.delete_conversation(&id);
                                        }
                                        StoreOp::SetPreferenceString { key, value } => {
                                            let _ = store.set_preference_string(&key, &value);
                                        }
                                        StoreOp::SetPreferenceStrings { key, values } => {
                                            let _ = store.set_preference_strings(&key, &values);
                                        }
                                        StoreOp::SetPreferenceData { key, data } => {
                                            let _ = store.set_preference_data(&key, &data);
                                        }
                                        StoreOp::DeletePreference { key } => {
                                            let _ = store.delete_preference(&key);
                                        }
                                        StoreOp::SaveMessages {
                                            rows,
                                            preserve_existing_reactions,
                                        } => {
                                            let _ = store.save_messages_with(
                                                &rows,
                                                SaveOptions {
                                                    skip_twin_checks: false,
                                                    preserve_existing_reactions,
                                                },
                                            );
                                        }
                                        StoreOp::LoadMentionPreviewMessages { .. }
                                        | StoreOp::LoadPreferenceString { .. }
                                        | StoreOp::ProbeAndSaveMessages { .. }
                                        | StoreOp::LoadOpenLocalMessages { .. }
                                        | StoreOp::LoadOlderStoreMessages { .. } => {}
                                    }
                                })
                                .await;
                        }
                    }
                }
            }
            StoreJob::FlushOp {
                op_id,
                result,
                sink,
                _guard,
            } => {
                sink.send(Input::OpStoreFlushed { op_id, result });
            }
            StoreJob::Drain(tx) => {
                let _ = tx.send(());
            }
        }
    }
}

struct HostWorkerDeps<T: Transport + 'static> {
    rx: mpsc::UnboundedReceiver<HostJob>,
    client: Arc<SessionClient<T>>,
    host: Arc<dyn Host>,
    shared_store: SharedStoreSlot,
    store_tx: mpsc::UnboundedSender<StoreJob>,
    ws_driver: Arc<dyn WsDriver>,
    ws_active_gen: Arc<Mutex<Option<u64>>>,
    lp_active_gen: Arc<Mutex<Option<u64>>>,
    lp_timer_abort: Arc<Mutex<Option<AbortHandle>>>,
    suppress_long_poll: bool,
    active_tasks: Arc<Mutex<Vec<AbortHandle>>>,
    runtime: Handle,
}

async fn run_host_worker<T: Transport + 'static>(deps: HostWorkerDeps<T>) {
    let HostWorkerDeps {
        mut rx,
        client,
        host,
        shared_store,
        store_tx,
        ws_driver,
        ws_active_gen,
        lp_active_gen,
        lp_timer_abort,
        suppress_long_poll,
        active_tasks,
        runtime,
    } = deps;
    while let Some(job) = rx.recv().await {
        match job {
            HostJob::LoadSavedSession {
                boot_gen,
                sink,
                _guard,
            } => {
                let saved = host.load_saved_session().await;
                let (restored, account, ws_endpoints) = match saved
                    .as_deref()
                    .and_then(|json| serde_json::from_str::<NetSessionSnapshot>(json).ok())
                {
                    Some(snap) => {
                        let ok = client.restore(snap);
                        let account = if ok { client.account() } else { None };
                        let ws = client.domains().ws;
                        (ok, account, ws)
                    }
                    None => (false, None, Vec::new()),
                };
                sink.send(Input::SavedSessionLoaded {
                    boot_gen,
                    restored,
                    account,
                    ws_endpoints,
                });
            }
            HostJob::LoadLegacyCookie {
                boot_gen,
                sink,
                _guard,
            } => {
                let Some(cookie) = host.load_legacy_cookie().await else {
                    sink.send(Input::LegacyCookieResult {
                        boot_gen,
                        account: None,
                        ws_endpoints: Vec::new(),
                        profile_synced: false,
                    });
                    continue;
                };
                // Spawn the network `complete_login` so it stays cancellable without blocking
                // subsequent host calls.
                let client = Arc::clone(&client);
                let net_guard = sink.track();
                let handle = runtime
                    .spawn(async move {
                        client.with_session(|s| {
                            if let Some(imei) = cookie.imei
                                && imei.chars().count() == 69
                            {
                                s.imei = imei;
                            }
                            s.zpw_sek = Some(cookie.zpw_sek);
                        });
                        match client.complete_login_detailed().await {
                            Ok((account, profile_synced)) if client.is_authenticated() => {
                                let ws_endpoints = client.domains().ws;
                                sink.send(Input::LegacyCookieResult {
                                    boot_gen,
                                    account: Some(account),
                                    ws_endpoints,
                                    profile_synced,
                                });
                            }
                            _ => {
                                client.with_session(|s| {
                                    s.zpw_sek = None;
                                    s.account = None;
                                    s.secret_key = None;
                                });
                                sink.send(Input::LegacyCookieResult {
                                    boot_gen,
                                    account: None,
                                    ws_endpoints: Vec::new(),
                                    profile_synced: false,
                                });
                            }
                        }
                        drop(net_guard);
                    })
                    .abort_handle();
                let mut list = active_tasks.lock().unwrap_or_else(PoisonError::into_inner);
                list.retain(|h| !h.is_finished());
                list.push(handle);
            }
            HostJob::SetPref { key, value, _guard } => {
                host.set_pref(key, value).await;
            }
            HostJob::PrepareStore {
                token,
                user_id,
                account,
                identities,
                sink,
                _guard,
            } => {
                let my_uid = user_id.clone();
                let my_avatar = (!account.avatar.is_empty()).then(|| account.avatar.clone());
                let self_conv_id = if account.send2me_id.is_empty() {
                    Some(account.user_id.clone())
                } else {
                    Some(account.send2me_id.clone())
                };
                host.prepare_store(user_id, *account).await;
                let transport_state = host.load_transport_state().await;
                let store_opt = shared_store
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner)
                    .clone();
                let local_hydration = if let Some(store_arc) = store_opt {
                    runtime
                        .spawn_blocking(move || {
                            let mut store =
                                store_arc.lock().unwrap_or_else(PoisonError::into_inner);
                            load_local_account_from_store(
                                &mut store,
                                &my_uid,
                                my_avatar.as_deref(),
                                self_conv_id.as_deref(),
                                &identities,
                            )
                        })
                        .await
                        .ok()
                } else {
                    None
                };
                sink.send(Input::PrepareStoreDone {
                    token,
                    transport_state,
                    local_hydration: local_hydration.map(Box::new),
                });
            }
            HostJob::StartWs {
                params,
                sink,
                _guard,
            } => {
                let run_ws = host.on_ws_started(params.endpoints.clone()).await;
                if run_ws
                    && *ws_active_gen.lock().unwrap_or_else(PoisonError::into_inner)
                        == Some(params.ws_gen)
                {
                    ws_driver.start(params, sink, &runtime);
                }
            }
            HostJob::StartLpInitial {
                lp_gen,
                delay,
                sink,
                _guard,
            } => {
                let run_lp = host.on_long_poll_started().await;
                if !run_lp {
                    let mut active = lp_active_gen.lock().unwrap_or_else(PoisonError::into_inner);
                    if *active == Some(lp_gen) {
                        *active = None;
                    }
                } else if !suppress_long_poll
                    && *lp_active_gen.lock().unwrap_or_else(PoisonError::into_inner) == Some(lp_gen)
                {
                    let handle = runtime
                        .spawn(async move {
                            tokio::time::sleep(delay).await;
                            sink.send(Input::LpTick { lp_gen });
                        })
                        .abort_handle();
                    let prev = lp_timer_abort
                        .lock()
                        .unwrap_or_else(PoisonError::into_inner)
                        .replace(handle);
                    if let Some(old) = prev {
                        old.abort();
                    }
                }
            }
            HostJob::StartBootstrap { sink, _guard } => {
                if host.on_bootstrap_started().await {
                    sink.send(Input::Command(Command::Bootstrap {
                        now_ms: unix_now_ms(),
                    }));
                }
            }
            // U4-bootstrap
            HostJob::ApplyMutes { mutes, _guard } => {
                host.apply_mutes(mutes).await;
            }
            HostJob::RefreshCloud { _guard } => {
                host.refresh_cloud().await;
            }
            HostJob::OnOpenConversationSync {
                conv_id,
                changed,
                _guard,
            } => {
                host.on_open_conversation_sync(conv_id, changed).await;
            }
            HostJob::OnCloseConversation { _guard } => {
                host.on_close_conversation().await;
            }
            HostJob::RefreshBoardPins { conv_id, _guard } => {
                host.refresh_board_pins(conv_id).await;
            }
            HostJob::MarkReadBoundary {
                conv_id,
                seen_target,
                _guard,
            } => {
                host.mark_read_boundary(conv_id, seen_target).await;
            }
            HostJob::ApplyRemoteReaction {
                conv_id,
                msg_id,
                cli_msg_id,
                sender_id,
                r_type,
                r_icon,
                event_id,
                react_client_id,
                sender_name,
                _guard,
            } => {
                host.apply_remote_reaction(
                    conv_id,
                    msg_id,
                    cli_msg_id,
                    sender_id,
                    r_type,
                    r_icon,
                    event_id,
                    react_client_id,
                    sender_name,
                )
                .await;
            }
            HostJob::ApplyRemoteRecall {
                conv_id,
                msg_id,
                cli_msg_id,
                update_conversation_preview,
                _guard,
            } => {
                host.apply_remote_recall(conv_id, msg_id, cli_msg_id, update_conversation_preview)
                    .await;
            }
            HostJob::ApplyRemoteDelete {
                conv_id,
                msg_id,
                cli_msg_id,
                update_conversation_preview,
                _guard,
            } => {
                host.apply_remote_delete(conv_id, msg_id, cli_msg_id, update_conversation_preview)
                    .await;
            }
            HostJob::DecryptEnvelope {
                payload,
                default_cmd,
                fallback_conv_id,
                is_group_hint,
                increment_unread,
                notify_incoming,
                persist_conversations,
                probe_freshness,
                poll_batch_done,
                op_id,
                sink,
                _guard,
            } => {
                let decrypted = host.decrypt_envelope(payload).await;
                sink.send(Input::DecryptedEnvelopeReady {
                    payload: decrypted,
                    default_cmd,
                    fallback_conv_id,
                    is_group_hint,
                    increment_unread,
                    notify_incoming,
                    persist_conversations,
                    probe_freshness,
                    poll_batch_done,
                    op_id,
                });
            }
            HostJob::MarkE2eeConversations { conv_ids, _guard } => {
                host.mark_e2ee_conversations(conv_ids).await;
            }
            HostJob::NotePollMessages { messages, _guard } => {
                host.note_poll_messages(messages).await;
            }
            HostJob::NotifyIncomingMessages { messages, _guard } => {
                host.notify_incoming_messages(messages).await;
            }
            HostJob::ShowBatchTyping {
                conv_id,
                sender_id,
                _guard,
            } => {
                host.show_batch_typing(conv_id, sender_id).await;
            }
            HostJob::TransportBatchSettled { _guard } => {
                host.transport_batch_settled().await;
            }
            HostJob::EngineLog { message, _guard } => {
                host.engine_log(message).await;
            }
            HostJob::OfferFirstLoginTransfer { force, _guard } => {
                host.offer_first_login_transfer(force).await;
            }
            HostJob::DetachStore { _guard } => {
                let (tx, rx) = oneshot::channel();
                if store_tx.send(StoreJob::Drain(tx)).is_ok() {
                    let _ = rx.await;
                }
                *shared_store.lock().unwrap_or_else(PoisonError::into_inner) = None;
            }
            HostJob::ResetDomains { _guard } => {
                host.reset_domains().await;
            }
            HostJob::PersistSession {
                snapshot_json,
                _guard,
            } => {
                host.persist_session(snapshot_json).await;
            }
            HostJob::ClearSession { _guard } => {
                host.clear_session().await;
            }
            HostJob::MarkExpired {
                snapshot_json,
                _guard,
            } => {
                // U4-bootstrap: Swift `markExpired` calls `hostResetDomains` and closes SQLite,
                // so drain pending store ops and detach the shared store handle first.
                let (tx, rx) = oneshot::channel();
                if store_tx.send(StoreJob::Drain(tx)).is_ok() {
                    let _ = rx.await;
                }
                *shared_store.lock().unwrap_or_else(PoisonError::into_inner) = None;
                host.mark_expired(snapshot_json).await;
            }
            HostJob::PersistPollState { state, _guard } => {
                host.persist_poll_state(state).await;
            }
            HostJob::PersistWsCursors { cursors, _guard } => {
                host.persist_ws_cursors(cursors).await;
            }
            HostJob::ApplyBatch {
                cmd,
                increment_unread,
                notify_incoming,
                payload,
                poll_batch_done,
                sink,
                _guard,
            } => {
                match host
                    .on_batch_received(cmd, increment_unread, notify_incoming, payload.clone())
                    .await
                {
                    BatchHookOutcome::IngestInCore(decrypted) => {
                        sink.send(Input::DecryptedEnvelopeReady {
                            payload: decrypted,
                            default_cmd: cmd.unwrap_or(0),
                            fallback_conv_id: None,
                            is_group_hint: None,
                            increment_unread,
                            notify_incoming,
                            persist_conversations: true,
                            probe_freshness: false,
                            poll_batch_done,
                            op_id: None,
                        });
                    }
                    BatchHookOutcome::Suppressed => {
                        host.transport_batch_settled().await;
                        if let Some((lp_gen, drain_id)) = poll_batch_done {
                            sink.send(Input::PollBatchApplied {
                                lp_gen,
                                drain_id,
                                delta: crate::conversations::BatchApplyDelta::default(),
                            });
                        }
                    }
                    BatchHookOutcome::DelegateToLegacy => {
                        let delta = host
                            .apply_batch(cmd, increment_unread, notify_incoming, payload)
                            .await;
                        if let Some((lp_gen, drain_id)) = poll_batch_done {
                            sink.send(Input::PollBatchApplied {
                                lp_gen,
                                drain_id,
                                delta,
                            });
                        } else if delta.applied_count > 0
                            || !delta.updates.is_empty()
                            || !delta.preview_overrides.is_empty()
                        {
                            sink.send(Input::BatchDeltaApplied { delta });
                        }
                    }
                }
            }
            HostJob::ApplyParsedEvents {
                cmd,
                increment_unread,
                notify_incoming,
                envelope,
                sink,
                _guard,
            } => {
                match host
                    .on_parsed_events_received(cmd, increment_unread, notify_incoming, &envelope)
                    .await
                {
                    ParsedEventsHookOutcome::IngestInCore => {
                        sink.send(Input::TypedEnvelopeReady {
                            cmd,
                            increment_unread,
                            notify_incoming,
                            envelope,
                        });
                    }
                    ParsedEventsHookOutcome::Suppressed => {
                        host.transport_batch_settled().await;
                    }
                    ParsedEventsHookOutcome::DelegateToLegacy => {
                        let delta = host
                            .apply_parsed_events(cmd, increment_unread, notify_incoming, envelope)
                            .await;
                        if delta.applied_count > 0
                            || !delta.updates.is_empty()
                            || !delta.preview_overrides.is_empty()
                        {
                            sink.send(Input::BatchDeltaApplied { delta });
                        }
                    }
                }
            }
            HostJob::MobileSync { events, _guard } => {
                host.mobile_sync(events).await;
            }
            HostJob::E2eeSignal {
                cmd,
                payload,
                _guard,
            } => {
                host.e2ee_signal(cmd, payload).await;
            }
            HostJob::E2eeDeliverReports {
                cmd,
                payload,
                _guard,
            } => {
                host.e2ee_deliver_reports(cmd, payload).await;
            }
            HostJob::E2eeConnected { uid, _guard } => {
                host.e2ee_connected(uid).await;
            }
            HostJob::E2eeDisconnected { _guard } => {
                host.e2ee_disconnected().await;
            }
            HostJob::VoipControl {
                act,
                raw_data,
                data,
                _guard,
            } => {
                host.voip_control(act, raw_data, data).await;
            }
            HostJob::ShowTyping {
                conv_id,
                uid,
                on_pc,
                _guard,
            } => {
                host.show_typing(conv_id, uid, on_pc).await;
            }
            HostJob::PinTopic { conv_id, _guard } => {
                host.pin_topic(conv_id).await;
            }
            HostJob::GroupNotice {
                act,
                data,
                ts,
                _guard,
            } => {
                host.group_notice(act, data, ts).await;
            }
            HostJob::Mute {
                conv_id,
                set,
                start,
                start_explicit,
                duration,
                _guard,
            } => {
                host.mute(conv_id, set, start, start_explicit, duration)
                    .await;
            }
            HostJob::Drain(tx) => {
                let _ = tx.send(());
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::time::Duration;

    use olaz_net::mock::MockTransport;

    use super::*;
    use crate::actor::CoreHandle;
    use crate::input::Command;

    struct SlowOrderedHost {
        log: Mutex<Vec<&'static str>>,
        active: AtomicUsize,
        max_concurrent: AtomicUsize,
    }

    impl SlowOrderedHost {
        fn new() -> Self {
            Self {
                log: Mutex::new(Vec::new()),
                active: AtomicUsize::new(0),
                max_concurrent: AtomicUsize::new(0),
            }
        }

        async fn record(&self, name: &'static str, delay_ms: u64) {
            let now = self.active.fetch_add(1, Ordering::SeqCst) + 1;
            self.max_concurrent.fetch_max(now, Ordering::SeqCst);
            tokio::time::sleep(Duration::from_millis(delay_ms)).await;
            self.log
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .push(name);
            self.active.fetch_sub(1, Ordering::SeqCst);
        }
    }

    #[async_trait]
    impl Host for SlowOrderedHost {
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
        async fn reset_domains(&self) {
            self.record("reset_domains", 5).await;
        }
        async fn persist_session(&self, _snapshot_json: String) {}
        async fn clear_session(&self) {
            // Slower than reset_domains: serial execution must still finish clear_session first.
            self.record("clear_session", 30).await;
        }
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
    }

    #[tokio::test]
    async fn host_calls_run_serially_in_emitted_order() {
        let host = Arc::new(SlowOrderedHost::new());
        let client = Arc::new(SessionClient::new(
            MockTransport::scripted(vec![]),
            "imei-1".to_owned(),
            "Mac".to_owned(),
        ));
        let runner = Arc::new(SessionEffectRunner::new(
            client,
            Arc::clone(&host) as Arc<dyn Host>,
            Handle::current(),
        ));
        let core = CoreHandle::start(runner, Handle::current());
        core.send(Command::LogOut);
        core.wait_idle().await;

        assert_eq!(host.max_concurrent.load(Ordering::SeqCst), 1);
        assert_eq!(
            *host.log.lock().unwrap_or_else(PoisonError::into_inner),
            vec!["clear_session", "reset_domains"]
        );
        core.stop();
    }

    #[tokio::test]
    async fn flush_host_waits_for_returned_batch_delta_to_reach_actor() {
        struct DelayedDeltaHost {
            entered: Arc<tokio::sync::Notify>,
            release: Arc<tokio::sync::Notify>,
        }

        #[async_trait]
        impl Host for DelayedDeltaHost {
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
            async fn on_batch_received(
                &self,
                _cmd: Option<u16>,
                _increment_unread: bool,
                _notify_incoming: bool,
                _payload: Map<String, Value>,
            ) -> BatchHookOutcome {
                BatchHookOutcome::DelegateToLegacy
            }
            async fn apply_batch(
                &self,
                _cmd: Option<u16>,
                _increment_unread: bool,
                _notify_incoming: bool,
                _payload: Map<String, Value>,
            ) -> BatchApplyDelta {
                self.entered.notify_waiters();
                self.release.notified().await;
                BatchApplyDelta {
                    applied_count: 1,
                    updates: vec![crate::conversations::ConvMessageDelta {
                        conv_id: "u42".to_owned(),
                        preview_text: "hello".to_owned(),
                        preview_date_ms: 1_700_000_000_000,
                        preview_from_me: false,
                        is_mine: false,
                        sender_name: "Peer 42".to_owned(),
                        sender_avatar: None,
                        unread_delta: 1,
                    }],
                    preview_overrides: Vec::new(),
                    persist_conversations: false,
                }
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
            async fn voip_control(
                &self,
                _act: String,
                _raw_data: Value,
                _data: Map<String, Value>,
            ) {
            }
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
        }

        struct SinkCaptureRunner<T: Transport + 'static> {
            inner: Arc<SessionEffectRunner<T>>,
            sink: Mutex<Option<ActorSink>>,
        }

        impl<T: Transport + 'static> EffectRunner for SinkCaptureRunner<T> {
            fn dispatch(&self, effects: Vec<Effect>, sink: ActorSink) {
                *self.sink.lock().unwrap_or_else(PoisonError::into_inner) = Some(sink.clone());
                self.inner.dispatch(effects, sink);
            }

            fn shutdown(&self) {
                self.inner.shutdown();
            }
        }

        let entered = Arc::new(tokio::sync::Notify::new());
        let release = Arc::new(tokio::sync::Notify::new());
        let host = Arc::new(DelayedDeltaHost {
            entered: Arc::clone(&entered),
            release: Arc::clone(&release),
        });
        let client = Arc::new(SessionClient::new(
            MockTransport::scripted(vec![]),
            "imei-2".to_owned(),
            "Mac".to_owned(),
        ));
        let runner = Arc::new(SessionEffectRunner::new(client, host, Handle::current()));
        let wrapper = Arc::new(SinkCaptureRunner {
            inner: Arc::clone(&runner),
            sink: Mutex::new(None),
        });
        let core = CoreHandle::start(
            Arc::clone(&wrapper) as Arc<dyn EffectRunner>,
            Handle::current(),
        );
        // Trigger a StoreOp effect to capture the actor's real sink.
        core.send(Command::UpdateConversationOnMessage {
            msg: MessagePreviewInput {
                conv_id: "u_seed".to_owned(),
                text: "seed".to_owned(),
                mentions: Vec::new(),
                preview_label: "seed".to_owned(),
                date_ms: 1_700_000_000_000,
                is_mine: false,
                sender_name: "Seed".to_owned(),
                sender_avatar: None,
            },
            increment_unread: false,
        });
        let _ = core.settle().await;
        let Some(sink) = wrapper
            .sink
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone()
        else {
            panic!("actor sink captured");
        };

        // Dispatch a host ApplyBatch whose delta is delayed until `release` fires.
        let entered_fut = entered.notified();
        tokio::pin!(entered_fut);
        entered_fut.as_mut().enable();
        runner.dispatch(
            vec![Effect::Host(HostCall::ApplyBatch {
                cmd: Some(501),
                increment_unread: true,
                notify_incoming: false,
                payload: Map::new(),
                poll_batch_done: None,
            })],
            sink,
        );
        entered_fut.await;

        let settle_task = tokio::spawn({
            let runner = Arc::clone(&runner);
            async move {
                runner.flush_host().await;
            }
        });
        // Give flush_host a chance to enqueue behind the blocked ApplyBatch.
        tokio::task::yield_now().await;
        assert!(!settle_task.is_finished());

        release.notify_waiters();
        assert!(settle_task.await.is_ok(), "flush_host task succeeded");

        // After flush_host + actor settle, the returned delta MUST already be reduced.
        let Some(version) = core.settle().await else {
            panic!("actor running");
        };
        assert!(version >= 2);
        let Some(snap) = core.full_snapshot().await else {
            panic!("snapshot available");
        };
        assert!(
            snap.conversations
                .conversations
                .iter()
                .any(|c| c.id == "u42" && c.unread == 1),
            "expected u42 from returned ApplyBatch delta, got {:?}",
            snap.conversations
        );
        core.stop();
    }
}
