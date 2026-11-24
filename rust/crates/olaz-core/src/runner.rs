//! Effect execution: [`EffectRunner`] trait, [`Host`] callback trait, [`WsDriver`] abstraction,
//! and the concrete [`SessionEffectRunner`] backed by `olaz_net::SessionClient`, `olaz_api::ZaloApi`,
//! and `olaz_ws::WsClient`.

use std::sync::{Arc, Mutex, PoisonError};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use async_trait::async_trait;
use olaz_api::{PollState, ZaloApi};
use olaz_net::{
    LoginAccount, SessionClient, SessionSnapshot as NetSessionSnapshot, Transport, ZaloDomains,
};
use olaz_ws::{CryptoDecryptor, CursorMap, WsClient, WsConfig, WsHandle};
use serde_json::{Map, Value};
use tokio::runtime::Handle;
use tokio::sync::mpsc;
use tokio::task::AbortHandle;

use crate::actor::{ActorSink, InFlightGuard};
use crate::effect::{Effect, HostCall};
use crate::input::{
    CompletedLogin, Input, LegacyCookie, PollBatchError, PollBatchOutcome, SessionFailure,
    StoreToken,
};
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

    // --- Transport domain callbacks (U2) ---
    async fn persist_poll_state(&self, state: PollState);
    async fn persist_ws_cursors(&self, cursors: CursorMap);
    async fn apply_batch(
        &self,
        cmd: Option<u16>,
        increment_unread: bool,
        notify_incoming: bool,
        payload: Map<String, Value>,
    ) -> u32;
    async fn apply_parsed_events(
        &self,
        cmd: u16,
        increment_unread: bool,
        notify_incoming: bool,
        envelope: TypedChatEnvelope,
    );
    async fn mobile_sync(&self, events: Vec<MobileSyncEvent>);
    async fn e2ee_signal(&self, cmd: u16, payload: Map<String, Value>);
    async fn e2ee_deliver_reports(&self, cmd: u16, payload: Map<String, Value>);
    async fn e2ee_connected(&self, uid: String);
    async fn e2ee_disconnected(&self);
    async fn voip_control(&self, act: String, raw_data: Value, data: Map<String, Value>);
    async fn show_typing(&self, conv_id: String, uid: String, on_pc: bool);
    async fn pin_topic(&self, conv_id: String);
    async fn group_notice(&self, act: String, data: Map<String, Value>, ts: i64);
    async fn mute(&self, conv_id: String, set: bool, start: i64, duration: i64);
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
        _guard: InFlightGuard,
    },
    OfferFirstLoginTransfer {
        force: bool,
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
        duration: i64,
        _guard: InFlightGuard,
    },
}

/// Real effect runner backed by a shared `SessionClient<T>`, a [`WsDriver`], and a [`Host`].
///
/// Generic over `T: Transport` so production uses `ReqwestTransport` and `tests/cases.rs` plugs
/// in a scripted `Transport` over the exact same request-building code.
pub struct SessionEffectRunner<T: Transport + 'static> {
    client: Arc<SessionClient<T>>,
    ws_driver: Arc<dyn WsDriver>,
    default_domains: Option<ZaloDomains>,
    suppress_long_poll: bool,
    ws_active_gen: Arc<Mutex<Option<u64>>>,
    lp_active_gen: Arc<Mutex<Option<u64>>>,
    host_tx: mpsc::UnboundedSender<HostJob>,
    active_tasks: Arc<Mutex<Vec<AbortHandle>>>,
    lp_timer_abort: Arc<Mutex<Option<AbortHandle>>>,
    lp_fetch_abort: Mutex<Option<AbortHandle>>,
    host_worker_abort: AbortHandle,
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
        let (host_tx, host_rx) = mpsc::unbounded_channel();
        let active_tasks: Arc<Mutex<Vec<AbortHandle>>> = Arc::new(Mutex::new(Vec::new()));
        let ws_active_gen: Arc<Mutex<Option<u64>>> = Arc::new(Mutex::new(None));
        let lp_active_gen: Arc<Mutex<Option<u64>>> = Arc::new(Mutex::new(None));
        let lp_timer_abort: Arc<Mutex<Option<AbortHandle>>> = Arc::new(Mutex::new(None));
        let worker_handle = runtime.spawn(run_host_worker(HostWorkerDeps {
            rx: host_rx,
            client: Arc::clone(&client),
            host,
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
            ws_driver,
            default_domains,
            suppress_long_poll,
            ws_active_gen,
            lp_active_gen,
            host_tx,
            active_tasks,
            lp_timer_abort,
            lp_fetch_abort: Mutex::new(None),
            host_worker_abort: worker_handle.abort_handle(),
            runtime,
        }
    }

    /// Returns a reference to the runner's [`WsDriver`] (for FFI WS pass-throughs and tests).
    #[must_use]
    pub fn ws_driver(&self) -> &Arc<dyn WsDriver> {
        &self.ws_driver
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
                }
                Effect::ClearCoreSession => {
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
                    let _ = self.host_tx.send(HostJob::LoadSavedSession {
                        boot_gen,
                        sink: sink.clone(),
                        _guard: guard,
                    });
                }
                Effect::LoadLegacyCookie { boot_gen } => {
                    let guard = sink.track();
                    let _ = self.host_tx.send(HostJob::LoadLegacyCookie {
                        boot_gen,
                        sink: sink.clone(),
                        _guard: guard,
                    });
                }
                Effect::CheckSessionStatus { boot_gen } => {
                    let client = Arc::clone(&self.client);
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
                    let _ = self.host_tx.send(HostJob::SetPref {
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
                    let _ = self.host_tx.send(HostJob::StartWs {
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
                        let _ = self.host_tx.send(HostJob::StartLpInitial {
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
                    let client = Arc::clone(&self.client);
                    let fetch_sink = sink.clone();
                    let guard = sink.track();
                    let handle = self
                        .runtime
                        .spawn(async move {
                            let api = ZaloApi::from_shared(client);
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
                }
                Effect::Host(call) => {
                    let guard = sink.track();
                    let job = match call {
                        HostCall::PrepareStore {
                            token,
                            user_id,
                            account,
                        } => HostJob::PrepareStore {
                            token,
                            user_id,
                            account,
                            sink: sink.clone(),
                            _guard: guard,
                        },
                        HostCall::StartBootstrap => HostJob::StartBootstrap { _guard: guard },
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
                            duration,
                        } => HostJob::Mute {
                            conv_id,
                            set,
                            start,
                            duration,
                            _guard: guard,
                        },
                    };
                    let _ = self.host_tx.send(job);
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
        self.cancel_long_poll();
        self.ws_driver.stop(false);
        self.host_worker_abort.abort();
    }
}

fn unix_now_secs() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| i64::try_from(d.as_secs()).unwrap_or(i64::MAX))
}

struct HostWorkerDeps<T: Transport + 'static> {
    rx: mpsc::UnboundedReceiver<HostJob>,
    client: Arc<SessionClient<T>>,
    host: Arc<dyn Host>,
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
                sink,
                _guard,
            } => {
                host.prepare_store(user_id, *account).await;
                let transport_state = host.load_transport_state().await;
                sink.send(Input::PrepareStoreDone {
                    token,
                    transport_state,
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
            HostJob::StartBootstrap { _guard } => {
                host.start_bootstrap().await;
            }
            HostJob::OfferFirstLoginTransfer { force, _guard } => {
                host.offer_first_login_transfer(force).await;
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
                let applied_count = host
                    .apply_batch(cmd, increment_unread, notify_incoming, payload)
                    .await;
                if let Some((lp_gen, drain_id)) = poll_batch_done {
                    sink.send(Input::PollBatchApplied {
                        lp_gen,
                        drain_id,
                        applied_count,
                    });
                }
            }
            HostJob::ApplyParsedEvents {
                cmd,
                increment_unread,
                notify_incoming,
                envelope,
                _guard,
            } => {
                host.apply_parsed_events(cmd, increment_unread, notify_incoming, envelope)
                    .await;
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
                duration,
                _guard,
            } => {
                host.mute(conv_id, set, start, duration).await;
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
        ) -> u32 {
            0
        }
        async fn apply_parsed_events(
            &self,
            _cmd: u16,
            _increment_unread: bool,
            _notify_incoming: bool,
            _envelope: TypedChatEnvelope,
        ) {
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
        async fn mute(&self, _conv_id: String, _set: bool, _start: i64, _duration: i64) {}
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
}
