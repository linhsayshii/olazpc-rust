//! Effect runner and `Host` trait (ADR-016).
//!
//! Host calls execute serially on a dedicated FIFO worker so their observed order always matches
//! the order `reduce` emitted them. Network calls run as cancellable tokio tasks.

use std::sync::{Arc, Mutex, PoisonError};

use async_trait::async_trait;
use olaz_net::http::Transport;
use olaz_net::{LoginAccount, SessionClient, SessionSnapshot as NetSessionSnapshot, ZaloDomains};
use tokio::runtime::Handle;
use tokio::sync::mpsc;
use tokio::task::AbortHandle;

use crate::actor::{ActorSink, InFlightGuard};
use crate::effect::{Effect, HostCall};
use crate::input::{CompletedLogin, Input, LegacyCookie, SessionFailure, StoreToken};

/// Platform callbacks for activities owned by Swift (or recorded by the test host in `cases.rs`).
#[async_trait]
pub trait Host: Send + Sync {
    /// Reads and unseals the saved `StoredNativeSession` JSON, or `None` if absent/unreadable.
    async fn load_saved_session(&self) -> Option<String>;
    /// Reads legacy WKWebView/HTTPCookieStorage credentials if present.
    async fn load_legacy_cookie(&self) -> Option<LegacyCookie>;
    /// Persists a session-domain preference into the open SQLite store (not traced in `host`).
    async fn set_pref(&self, key: String, value: String);

    // Traced domain activities (Case format v1 `host` list):
    async fn prepare_store(&self, user_id: String, account: LoginAccount);
    async fn start_ws(&self, endpoints: Vec<String>, zpw_sek: String);
    async fn start_long_poll(&self);
    async fn start_bootstrap(&self);
    async fn offer_first_login_transfer(&self, force: bool);
    async fn reset_domains(&self);
    async fn persist_session(&self, snapshot_json: String);
    async fn clear_session(&self);
    async fn mark_expired(&self, snapshot_json: String);
}

/// Executes effects emitted by `reduce` and posts resulting [`Input`]s back to the actor.
pub trait EffectRunner: Send + Sync {
    fn dispatch(&self, effects: Vec<Effect>, sink: ActorSink);
    fn shutdown(&self);
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
        endpoints: Vec<String>,
        zpw_sek: String,
        _guard: InFlightGuard,
    },
    StartLongPoll {
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
}

/// Real effect runner backed by a shared `SessionClient<T>` and a [`Host`] implementation.
///
/// Generic over `T: Transport` so production uses `ReqwestTransport` and `tests/cases.rs` plugs
/// in a scripted `Transport` over the exact same request-building code.
pub struct SessionEffectRunner<T: Transport + 'static> {
    client: Arc<SessionClient<T>>,
    default_domains: Option<ZaloDomains>,
    host_tx: mpsc::UnboundedSender<HostJob>,
    active_tasks: Arc<Mutex<Vec<AbortHandle>>>,
    host_worker_abort: AbortHandle,
    runtime: Handle,
}

impl<T: Transport + 'static> SessionEffectRunner<T> {
    /// Starts the runner's serial host worker on `runtime`.
    #[must_use]
    pub fn new(client: Arc<SessionClient<T>>, host: Arc<dyn Host>, runtime: Handle) -> Self {
        Self::with_default_domains(client, host, runtime, None)
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
        let (host_tx, host_rx) = mpsc::unbounded_channel();
        let active_tasks: Arc<Mutex<Vec<AbortHandle>>> = Arc::new(Mutex::new(Vec::new()));
        let worker_handle = runtime.spawn(run_host_worker(
            host_rx,
            Arc::clone(&client),
            host,
            Arc::clone(&active_tasks),
            runtime.clone(),
        ));
        Self {
            client,
            default_domains,
            host_tx,
            active_tasks,
            host_worker_abort: worker_handle.abort_handle(),
            runtime,
        }
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
                    let isolated_domains = {
                        let current = self.client.domains();
                        current.isolated.then_some(current)
                    };
                    self.client.clear_session();
                    if let Some(domains) =
                        self.default_domains.as_ref().or(isolated_domains.as_ref())
                    {
                        self.client.with_session(|s| s.domains = domains.clone());
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
                        HostCall::StartWs { endpoints } => HostJob::StartWs {
                            endpoints,
                            zpw_sek: self.client.zpw_sek().unwrap_or_default(),
                            _guard: guard,
                        },
                        HostCall::StartLongPoll => HostJob::StartLongPoll { _guard: guard },
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
                    };
                    let _ = self.host_tx.send(job);
                }
            }
        }
    }

    fn shutdown(&self) {
        self.cancel_active_tasks();
        self.host_worker_abort.abort();
    }
}

async fn run_host_worker<T: Transport + 'static>(
    mut rx: mpsc::UnboundedReceiver<HostJob>,
    client: Arc<SessionClient<T>>,
    host: Arc<dyn Host>,
    active_tasks: Arc<Mutex<Vec<AbortHandle>>>,
    runtime: Handle,
) {
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
                sink.send(Input::PrepareStoreDone { token });
            }
            HostJob::StartWs {
                endpoints,
                zpw_sek,
                _guard,
            } => {
                host.start_ws(endpoints, zpw_sek).await;
            }
            HostJob::StartLongPoll { _guard } => {
                host.start_long_poll().await;
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
        async fn start_ws(&self, _endpoints: Vec<String>, _zpw_sek: String) {}
        async fn start_long_poll(&self) {}
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
        let calls = host
            .log
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone();
        assert_eq!(calls, vec!["clear_session", "reset_domains"]);
        core.stop();
    }
}
