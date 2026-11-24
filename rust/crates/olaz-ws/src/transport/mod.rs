//! Live `zpw_ws` transport (tokio + tokio-tungstenite) on top of the pure [`WsCore`].
//!
//! One task ([`actor`]) owns the socket and the `WsCore`; [`WsHandle`] talks to it over a
//! command channel. No protocol logic lives here (see `ARCH.md`).

mod actor;
mod crypto;
mod handle;
mod tls;

use std::collections::BTreeMap;
use std::sync::Arc;
use std::time::Duration;

use tokio::sync::{mpsc, watch};

use crate::consts::{DEFAULT_WS_ENDPOINTS, FILE_WAIT_TIMEOUT_SECS, PING_INTERVAL_SECS};
use crate::core::{FrameDecryptor, WsCore};
use crate::event::WsEvent;
use crate::policy::ReconnectPolicy;
use crate::queue::WsQueueCursorSnapshot;

pub use crypto::CryptoDecryptor;
pub use handle::WsHandle;

/// Cursor snapshot keyed by queue key (`"<cmd>_<sub>"`), as persisted by the app.
pub type CursorMap = BTreeMap<String, WsQueueCursorSnapshot>;

/// Called (from the transport task, must not block) whenever queue cursors change
/// (Swift: `setQueueCursorObserver`).
pub type CursorObserver = Arc<dyn Fn(&CursorMap) + Send + Sync>;

/// All timing knobs. `Default` is the Swift behavior; tests shrink them.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct WsTimings {
    pub ping_interval: Duration,
    pub request_timeout: Duration,
    pub file_timeout: Duration,
    pub connect_timeout: Duration,
    pub backoff_initial: Duration,
    pub backoff_max: Duration,
    /// A session longer than this resets the backoff.
    pub stable_session: Duration,
}

impl Default for WsTimings {
    fn default() -> Self {
        Self {
            ping_interval: Duration::from_secs(PING_INTERVAL_SECS),
            request_timeout: Duration::from_secs_f64(crate::consts::REQUEST_TIMEOUT_SECS),
            file_timeout: Duration::from_secs_f64(FILE_WAIT_TIMEOUT_SECS),
            connect_timeout: Duration::from_secs(60),
            backoff_initial: Duration::from_secs_f64(ReconnectPolicy::INITIAL_BACKOFF_SECS),
            backoff_max: Duration::from_secs_f64(ReconnectPolicy::MAX_BACKOFF_SECS),
            stable_session: Duration::from_secs_f64(ReconnectPolicy::STABLE_SESSION_SECS),
        }
    }
}

/// Input of [`WsClient::start`].
pub struct WsConfig {
    /// `wss://host` bases (rotated on reconnect). Empty means [`DEFAULT_WS_ENDPOINTS`].
    pub endpoints: Vec<String>,
    /// Session key (`zpw_sek`): sent as cookie/header only, never logged.
    pub zpw_sek: String,
    /// Cursors to resume from (`seedQueueCursors`).
    pub seed_cursors: CursorMap,
    /// Persist-cursors hook (`setQueueCursorObserver`).
    pub on_cursors_changed: Option<CursorObserver>,
    pub timings: WsTimings,
    /// Capacity of the event channel (the task waits when it is full).
    pub event_capacity: usize,
}

impl WsConfig {
    pub fn new(endpoints: Vec<String>, zpw_sek: impl Into<String>) -> Self {
        Self {
            endpoints,
            zpw_sek: zpw_sek.into(),
            seed_cursors: CursorMap::new(),
            on_cursors_changed: None,
            timings: WsTimings::default(),
            event_capacity: 1024,
        }
    }
}

/// Entry point.
pub struct WsClient;

impl WsClient {
    /// `start(endpoints:zpwSek:)`: spawns the transport task on the current tokio runtime and
    /// returns its handle plus the event stream (ends after `stop`).
    pub fn start(
        config: WsConfig,
        decryptor: Arc<dyn FrameDecryptor + Send + Sync>,
    ) -> (WsHandle, mpsc::Receiver<WsEvent>) {
        let endpoints = if config.endpoints.is_empty() {
            DEFAULT_WS_ENDPOINTS
                .iter()
                .map(|s| (*s).to_owned())
                .collect()
        } else {
            config.endpoints
        };
        let mut core = WsCore::new();
        core.cursors.seed(&config.seed_cursors);
        let (cursors_tx, cursors_rx) = watch::channel(core.cursors.current());
        let (authed_tx, authed_rx) = watch::channel(core.is_authed());
        let (cmd_tx, cmd_rx) = mpsc::channel(64);
        let (event_tx, event_rx) = mpsc::channel(config.event_capacity.max(1));
        let t = config.timings;
        let actor = actor::Actor::new(actor::ActorParts {
            core,
            decryptor,
            policy: ReconnectPolicy::with_timings(
                endpoints.len(),
                t.backoff_initial.as_secs_f64(),
                t.backoff_max.as_secs_f64(),
                t.stable_session.as_secs_f64(),
            ),
            endpoints,
            zpw_sek: config.zpw_sek,
            timings: t,
            cmds: cmd_rx,
            events: event_tx,
            cursors_tx,
            authed_tx,
            on_cursors: config.on_cursors_changed,
        });
        tokio::spawn(actor.run());
        (WsHandle::new(cmd_tx, cursors_rx, authed_rx), event_rx)
    }
}

pub(crate) use actor::Cmd;
