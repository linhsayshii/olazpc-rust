//! The single task that owns the socket and the [`WsCore`] (actor style, no locks).

use std::collections::{BTreeMap, HashMap};
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use futures_util::{SinkExt, StreamExt};
use serde_json::{Map, Value};
use tokio::net::TcpStream;
use tokio::sync::{mpsc, oneshot, watch};
use tokio::time::{Instant, MissedTickBehavior, interval_at, sleep, sleep_until};
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::http::{HeaderName, HeaderValue};
use tokio_tungstenite::tungstenite::protocol::CloseFrame;
use tokio_tungstenite::tungstenite::protocol::frame::coding::CloseCode;
use tokio_tungstenite::{
    Connector, MaybeTlsStream, WebSocketStream, connect_async_tls_with_config,
};

use super::{CursorMap, CursorObserver, WsTimings, tls};
use crate::consts::CMD_PING;
use crate::core::{CloseRequest, FrameDecryptor, FrameOutcome, WsCore};
use crate::event::WsEvent;
use crate::files::{FileWait, WaiterToken};
use crate::frame::encode_frame;
use crate::policy::{ReconnectPolicy, build_socket_url, connect_headers};

type Ws = WebSocketStream<MaybeTlsStream<TcpStream>>;

/// Commands sent by [`WsHandle`](super::WsHandle).
pub(crate) enum Cmd {
    SendFrame {
        cmd: u16,
        sub_cmd: u8,
        version: u8,
        payload: Option<Vec<u8>>,
        reply: oneshot::Sender<bool>,
    },
    Request {
        cmd: u16,
        sub_cmd: u8,
        version: u8,
        req_id: Option<String>,
        data: Map<String, Value>,
        timeout: Option<Duration>,
        reply: oneshot::Sender<Option<Map<String, Value>>>,
    },
    WaitFile {
        file_id: String,
        timeout: Option<Duration>,
        reply: oneshot::Sender<Option<String>>,
    },
    RecordFileDone {
        file_id: String,
        url: String,
    },
    SeedCursors(CursorMap),
    Cursors(oneshot::Sender<CursorMap>),
    IsAuthed(oneshot::Sender<bool>),
    Stop {
        reset_cursors: bool,
        reply: oneshot::Sender<CursorMap>,
    },
}

enum Timer {
    Request { req_id: String, token: WaiterToken },
    File { file_id: String, token: WaiterToken },
}

#[derive(PartialEq, Eq)]
enum Flow {
    Continue,
    Stop,
}

pub(crate) struct ActorParts {
    pub core: WsCore,
    pub decryptor: Arc<dyn FrameDecryptor + Send + Sync>,
    pub policy: ReconnectPolicy,
    pub endpoints: Vec<String>,
    pub zpw_sek: String,
    pub preferred_languages: Vec<String>,
    pub timings: WsTimings,
    pub cmds: mpsc::Receiver<Cmd>,
    pub events: mpsc::Sender<WsEvent>,
    pub cursors_tx: watch::Sender<CursorMap>,
    pub authed_tx: watch::Sender<bool>,
    pub on_cursors: Option<CursorObserver>,
}

pub(crate) struct Actor {
    p: ActorParts,
    req_replies: HashMap<WaiterToken, oneshot::Sender<Option<Map<String, Value>>>>,
    file_replies: HashMap<WaiterToken, oneshot::Sender<Option<String>>>,
    timers: BTreeMap<(Instant, u64), Timer>,
    timer_seq: u64,
    tls: Option<Arc<rustls::ClientConfig>>,
}

fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| i64::try_from(d.as_millis()).unwrap_or(i64::MAX))
}

/// Host part of an endpoint for logs (never the query: it carries no secrets, but keep it short).
fn host_label(endpoint: &str) -> &str {
    let rest = endpoint.split_once("://").map_or(endpoint, |(_, r)| r);
    rest.split(['/', '?']).next().unwrap_or("-")
}

/// Resolves when the earliest timer is due; pending forever when there are none.
async fn first_deadline(timers: &BTreeMap<(Instant, u64), Timer>) {
    match timers.keys().next() {
        Some((at, _)) => sleep_until(*at).await,
        None => std::future::pending().await,
    }
}

impl Actor {
    pub(crate) fn new(parts: ActorParts) -> Self {
        Self {
            p: parts,
            req_replies: HashMap::new(),
            file_replies: HashMap::new(),
            timers: BTreeMap::new(),
            timer_seq: 0,
            tls: None,
        }
    }

    /// `runLoop`: connect, run the session, back off, rotate endpoint; until stopped.
    pub(crate) async fn run(mut self) {
        loop {
            let Some(idx) = self.p.policy.current_endpoint() else {
                return;
            };
            let endpoint = self.p.endpoints[idx].clone();
            let started = Instant::now();
            match self.run_session(&endpoint).await {
                Flow::Stop => return,
                Flow::Continue => {}
            }
            let delay = self.p.policy.on_session_ended(started.elapsed());
            if self.backoff(delay).await == Flow::Stop {
                return;
            }
        }
    }

    async fn backoff(&mut self, delay: Duration) -> Flow {
        let nap = sleep(delay);
        tokio::pin!(nap);
        loop {
            tokio::select! {
                () = &mut nap => return Flow::Continue,
                cmd = self.p.cmds.recv() => {
                    let Some(cmd) = cmd else { return Flow::Stop };
                    if self.handle_cmd(cmd, None).await == Flow::Stop {
                        return Flow::Stop;
                    }
                }
                () = first_deadline(&self.timers) => self.fire_timers(),
            }
        }
    }

    /// `runSingleSession` including the connect phase.
    async fn run_session(&mut self, endpoint: &str) -> Flow {
        self.p.core.on_connect();
        self.publish_authed();
        let label = host_label(endpoint).to_owned();
        tracing::info!(host = %label, "ws: connecting");

        let (req, connector) = match self.prepare(endpoint).await {
            Ok(x) => x,
            Err(why) => {
                tracing::info!(host = %label, why, "ws: connect failed");
                self.end_session();
                return Flow::Continue;
            }
        };
        let connect = connect_ws(req, connector, self.p.timings.connect_timeout);
        tokio::pin!(connect);
        let mut ws = loop {
            tokio::select! {
                res = &mut connect => match res {
                    Ok(ws) => break ws,
                    Err(why) => {
                        tracing::info!(host = %label, why, "ws: connect failed");
                        self.end_session();
                        return Flow::Continue;
                    }
                },
                cmd = self.p.cmds.recv() => {
                    let Some(cmd) = cmd else { return Flow::Stop };
                    if self.handle_cmd(cmd, None).await == Flow::Stop {
                        return Flow::Stop;
                    }
                }
                () = first_deadline(&self.timers) => self.fire_timers(),
            }
        };

        let mut ping = interval_at(
            Instant::now() + self.p.timings.ping_interval,
            self.p.timings.ping_interval,
        );
        ping.set_missed_tick_behavior(MissedTickBehavior::Delay);

        let flow = loop {
            tokio::select! {
                msg = ws.next() => match msg {
                    Some(Ok(Message::Binary(bytes))) => {
                        if self.on_binary(&bytes, &mut ws).await {
                            break Flow::Continue;
                        }
                    }
                    Some(Ok(Message::Close(frame))) => {
                        let code = frame.map_or(-1, |f| i32::from(u16::from(f.code)));
                        tracing::info!(host = %label, code, "ws: close frame");
                        break Flow::Continue;
                    }
                    Some(Ok(_)) => {}
                    Some(Err(e)) => {
                        tracing::info!(host = %label, err = %e, "ws: disconnected");
                        break Flow::Continue;
                    }
                    None => {
                        tracing::info!(host = %label, "ws: disconnected");
                        break Flow::Continue;
                    }
                },
                cmd = self.p.cmds.recv() => {
                    let Some(cmd) = cmd else { break Flow::Stop };
                    if self.handle_cmd(cmd, Some(&mut ws)).await == Flow::Stop {
                        break Flow::Stop;
                    }
                }
                _ = ping.tick() => {
                    if let Some(frame) = self.p.core.ping_frame_if_authed(now_ms()) {
                        tracing::trace!(cmd = CMD_PING, len = frame.len(), "ws: ping");
                        send_bin(&mut ws, frame).await;
                    }
                }
                () = first_deadline(&self.timers) => self.fire_timers(),
            }
        };

        if flow == Flow::Stop {
            let _ = ws
                .close(Some(CloseFrame {
                    code: CloseCode::Normal,
                    reason: "".into(),
                }))
                .await;
        }
        self.end_session();
        flow
    }

    /// Session end: fail pending requests (`defer` in `runSingleSession`).
    fn end_session(&mut self) {
        for (_, token) in self.p.core.on_disconnect() {
            self.resolve_request(token, None);
        }
        self.publish_authed();
    }

    /// Builds the handshake request (URL + headers) and, for `wss`, the TLS connector.
    async fn prepare(
        &mut self,
        endpoint: &str,
    ) -> Result<
        (
            tokio_tungstenite::tungstenite::handshake::client::Request,
            Option<Connector>,
        ),
        String,
    > {
        let url = build_socket_url(endpoint, now_ms());
        let mut req = url
            .as_str()
            .into_client_request()
            .map_err(|e| e.to_string())?;
        for (name, value) in connect_headers(
            req.uri().host().unwrap_or(""),
            &self.p.zpw_sek,
            &self.p.preferred_languages,
        ) {
            let name = HeaderName::from_bytes(name.as_bytes()).map_err(|e| e.to_string())?;
            let value = HeaderValue::from_str(&value).map_err(|_| "invalid header value")?;
            req.headers_mut().insert(name, value);
        }
        let connector = if url.starts_with("wss://") {
            if self.tls.is_none() {
                let cfg = tokio::task::spawn_blocking(tls::build_client_config)
                    .await
                    .map_err(|e| e.to_string())??;
                self.tls = Some(cfg);
            }
            self.tls.clone().map(Connector::Rustls)
        } else {
            None
        };
        Ok((req, connector))
    }

    /// Returns true when the session must end (close requested).
    async fn on_binary(&mut self, data: &[u8], ws: &mut Ws) -> bool {
        let out = self
            .p
            .core
            .handle_binary_frame(data, self.p.decryptor.as_ref());
        self.publish_authed();
        self.apply_outcome(out, data.len(), ws).await
    }

    async fn apply_outcome(&mut self, out: FrameOutcome, in_len: usize, ws: &mut Ws) -> bool {
        let FrameOutcome {
            event,
            sends,
            resolved_request,
            file_wakes,
            cursors_changed,
            close,
            log,
        } = out;
        if let Some(ev) = &event {
            tracing::trace!(cmd = ev.cmd, sub = ev.sub_cmd, len = in_len, "ws: frame");
        }
        for line in log {
            tracing::info!("{line}");
        }
        if let Some(r) = resolved_request {
            self.resolve_request(r.token, Some(r.payload));
        }
        for wake in file_wakes {
            for token in wake.waiters {
                self.resolve_file(token, Some(wake.url.clone()));
            }
        }
        for frame in sends {
            send_bin(ws, frame).await;
        }
        if let Some(ev) = event {
            // The consumer may be gone; Swift's finished continuation also drops events.
            let _ = self.p.events.send(ev).await;
        }
        if let Some(cursors) = cursors_changed {
            self.publish_cursors(cursors, true);
        }
        if close == Some(CloseRequest::PolicyViolation) {
            let _ = ws
                .close(Some(CloseFrame {
                    code: CloseCode::Policy,
                    reason: "".into(),
                }))
                .await;
            return true;
        }
        false
    }

    fn publish_cursors(&self, cursors: CursorMap, notify: bool) {
        if notify && let Some(obs) = &self.p.on_cursors {
            obs(&cursors);
        }
        self.p.cursors_tx.send_replace(cursors);
    }

    fn publish_authed(&self) {
        let authed = self.p.core.is_authed();
        self.p.authed_tx.send_if_modified(|cur| {
            if *cur == authed {
                false
            } else {
                *cur = authed;
                true
            }
        });
    }

    fn resolve_request(&mut self, token: WaiterToken, value: Option<Map<String, Value>>) {
        if let Some(tx) = self.req_replies.remove(&token) {
            let _ = tx.send(value);
        }
    }

    fn resolve_file(&mut self, token: WaiterToken, value: Option<String>) {
        if let Some(tx) = self.file_replies.remove(&token) {
            let _ = tx.send(value);
        }
    }

    fn add_timer(&mut self, after: Duration, timer: Timer) {
        self.timer_seq += 1;
        self.timers
            .insert((Instant::now() + after, self.timer_seq), timer);
    }

    fn fire_timers(&mut self) {
        let now = Instant::now();
        while let Some(entry) = self.timers.first_entry() {
            if entry.key().0 > now {
                break;
            }
            match entry.remove() {
                Timer::Request { req_id, token } => {
                    // `finishRequestWaiter`: only if this very waiter is still pending.
                    match self.p.core.requests.finish(&req_id) {
                        Some(t) if t == token => self.resolve_request(token, None),
                        Some(other) => {
                            self.p.core.requests.register(&req_id, other);
                        }
                        None => {}
                    }
                }
                Timer::File { file_id, token } => {
                    // `timeoutFileWaiters` drops every waiter of the id; a stale timer
                    // (our waiter already woken) must not kill a newer waiter.
                    if self.file_replies.contains_key(&token) {
                        for t in self.p.core.files.timeout(&file_id) {
                            self.resolve_file(t, None);
                        }
                    }
                }
            }
        }
    }

    async fn handle_cmd(&mut self, cmd: Cmd, ws: Option<&mut Ws>) -> Flow {
        match cmd {
            Cmd::SendFrame {
                cmd,
                sub_cmd,
                version,
                payload,
                reply,
            } => {
                let ok = match ws {
                    Some(ws) if self.p.core.is_authed() => {
                        let frame = encode_frame(cmd, sub_cmd, version, payload.as_deref());
                        tracing::trace!(cmd, sub = sub_cmd, len = frame.len(), "ws: send");
                        send_bin(ws, frame).await
                    }
                    _ => false,
                };
                let _ = reply.send(ok);
            }
            Cmd::Request {
                cmd,
                sub_cmd,
                version,
                req_id,
                data,
                timeout,
                reply,
            } => {
                let Some(ws) = ws else {
                    let _ = reply.send(None);
                    return Flow::Continue;
                };
                let Some(prep) =
                    self.p
                        .core
                        .prepare_request(cmd, sub_cmd, version, req_id.as_deref(), &data)
                else {
                    let _ = reply.send(None);
                    return Flow::Continue;
                };
                if let Some(old) = prep.replaced {
                    self.resolve_request(old, None);
                }
                tracing::trace!(cmd, sub = sub_cmd, len = prep.frame.len(), "ws: request");
                self.req_replies.insert(prep.token, reply);
                if send_bin(ws, prep.frame).await {
                    let after = timeout.unwrap_or(self.p.timings.request_timeout);
                    self.add_timer(
                        after,
                        Timer::Request {
                            req_id: prep.req_id,
                            token: prep.token,
                        },
                    );
                } else {
                    self.p.core.requests.finish(&prep.req_id);
                    self.resolve_request(prep.token, None);
                }
            }
            Cmd::WaitFile {
                file_id,
                timeout,
                reply,
            } => match self.p.core.wait_for_file_done(&file_id) {
                FileWait::Invalid => {
                    let _ = reply.send(None);
                }
                FileWait::Ready(url) => {
                    let _ = reply.send(Some(url));
                }
                FileWait::Pending(token) => {
                    self.file_replies.insert(token, reply);
                    let after = timeout.unwrap_or(self.p.timings.file_timeout);
                    self.add_timer(after, Timer::File { file_id, token });
                }
            },
            Cmd::RecordFileDone { file_id, url } => {
                for token in self.p.core.files.record(&file_id, &url) {
                    self.resolve_file(token, Some(url.clone()));
                }
            }
            Cmd::SeedCursors(snaps) => {
                self.p.core.cursors.seed(&snaps);
                let cur = self.p.core.cursors.current();
                self.publish_cursors(cur, false);
            }
            Cmd::Cursors(reply) => {
                let _ = reply.send(self.p.core.cursors.current());
            }
            Cmd::IsAuthed(reply) => {
                let _ = reply.send(self.p.core.is_authed());
            }
            Cmd::Stop {
                reset_cursors,
                reply,
            } => {
                let (reqs, files) = self.p.core.stop(reset_cursors);
                for t in reqs {
                    self.resolve_request(t, None);
                }
                for t in files {
                    self.resolve_file(t, None);
                }
                self.publish_authed();
                let cur = self.p.core.cursors.current();
                self.publish_cursors(cur.clone(), false);
                let _ = reply.send(cur);
                return Flow::Stop;
            }
        }
        Flow::Continue
    }
}

async fn connect_ws(
    req: tokio_tungstenite::tungstenite::handshake::client::Request,
    connector: Option<Connector>,
    timeout: Duration,
) -> Result<Ws, String> {
    let fut = connect_async_tls_with_config(req, None, false, connector);
    match tokio::time::timeout(timeout, fut).await {
        Ok(Ok((ws, _resp))) => Ok(ws),
        Ok(Err(e)) => Err(e.to_string()),
        Err(_) => Err("connect timeout".into()),
    }
}

async fn send_bin(ws: &mut Ws, bytes: Vec<u8>) -> bool {
    ws.send(Message::Binary(bytes.into())).await.is_ok()
}
