//! Clonable front of the transport task.

use std::time::Duration;

use serde_json::{Map, Value};
use tokio::sync::{mpsc, oneshot, watch};

use super::{Cmd, CursorMap};
use crate::consts::FRAME_VERSION;

/// Async API over the transport task. Every method returns the "failure" value
/// (`false` / `None` / last known cursors) once the task has stopped.
#[derive(Clone)]
pub struct WsHandle {
    cmds: mpsc::Sender<Cmd>,
    cursors: watch::Receiver<CursorMap>,
}

impl WsHandle {
    pub(crate) fn new(cmds: mpsc::Sender<Cmd>, cursors: watch::Receiver<CursorMap>) -> Self {
        Self { cmds, cursors }
    }

    /// `sendFrame`: false unless authenticated and the write succeeded.
    pub async fn send_frame(&self, cmd: u16, sub_cmd: u8, payload_json: Option<Vec<u8>>) -> bool {
        self.send_frame_versioned(cmd, sub_cmd, FRAME_VERSION, payload_json)
            .await
    }

    pub async fn send_frame_versioned(
        &self,
        cmd: u16,
        sub_cmd: u8,
        version: u8,
        payload_json: Option<Vec<u8>>,
    ) -> bool {
        let (reply, rx) = oneshot::channel();
        let sent = self
            .cmds
            .send(Cmd::SendFrame {
                cmd,
                sub_cmd,
                version,
                payload: payload_json,
                reply,
            })
            .await;
        sent.is_ok() && rx.await.unwrap_or(false)
    }

    /// `sendRequestFrame` with the default 10 s timeout. `None`: not authenticated, send
    /// failed, timed out, disconnected or stopped.
    pub async fn send_request(
        &self,
        cmd: u16,
        sub_cmd: u8,
        req_id: Option<String>,
        inner_data: Map<String, Value>,
    ) -> Option<Map<String, Value>> {
        self.request(cmd, sub_cmd, FRAME_VERSION, req_id, inner_data, None)
            .await
    }

    pub async fn send_request_with_timeout(
        &self,
        cmd: u16,
        sub_cmd: u8,
        req_id: Option<String>,
        inner_data: Map<String, Value>,
        timeout: Duration,
    ) -> Option<Map<String, Value>> {
        self.request(
            cmd,
            sub_cmd,
            FRAME_VERSION,
            req_id,
            inner_data,
            Some(timeout),
        )
        .await
    }

    async fn request(
        &self,
        cmd: u16,
        sub_cmd: u8,
        version: u8,
        req_id: Option<String>,
        data: Map<String, Value>,
        timeout: Option<Duration>,
    ) -> Option<Map<String, Value>> {
        let (reply, rx) = oneshot::channel();
        self.cmds
            .send(Cmd::Request {
                cmd,
                sub_cmd,
                version,
                req_id,
                data,
                timeout,
                reply,
            })
            .await
            .ok()?;
        rx.await.ok().flatten()
    }

    /// `waitForFileDone` with the default 12 s timeout: the file url, or `None`.
    pub async fn wait_for_file_done(&self, file_id: &str) -> Option<String> {
        self.wait_file(file_id, None).await
    }

    pub async fn wait_for_file_done_with_timeout(
        &self,
        file_id: &str,
        timeout: Duration,
    ) -> Option<String> {
        self.wait_file(file_id, Some(timeout)).await
    }

    async fn wait_file(&self, file_id: &str, timeout: Option<Duration>) -> Option<String> {
        let (reply, rx) = oneshot::channel();
        self.cmds
            .send(Cmd::WaitFile {
                file_id: file_id.to_owned(),
                timeout,
                reply,
            })
            .await
            .ok()?;
        rx.await.ok().flatten()
    }

    /// `seedQueueCursors` (ignores empty/"0"/"1" last ids).
    pub async fn seed_cursors(&self, snapshots: CursorMap) {
        let _ = self.cmds.send(Cmd::SeedCursors(snapshots)).await;
    }

    /// `currentQueueCursors` (exact, ordered after earlier commands). After the task stopped
    /// it returns the last published snapshot.
    pub async fn current_cursors(&self) -> CursorMap {
        let (reply, rx) = oneshot::channel();
        if self.cmds.send(Cmd::Cursors(reply)).await.is_ok()
            && let Ok(map) = rx.await
        {
            return map;
        }
        self.cursors.borrow().clone()
    }

    /// Live cursor snapshots (updated on every change, also after `stop`).
    pub fn watch_cursors(&self) -> watch::Receiver<CursorMap> {
        self.cursors.clone()
    }

    /// `isAuthed`.
    pub async fn is_authed(&self) -> bool {
        let (reply, rx) = oneshot::channel();
        self.cmds.send(Cmd::IsAuthed(reply)).await.is_ok() && rx.await.unwrap_or(false)
    }

    /// `stop(resetCursors:)`: closes the socket (1000), resolves every waiter with `None`,
    /// ends the event stream and the task. Returns the cursors left (empty after a reset);
    /// pass them as `seed_cursors` to a later `WsClient::start` to resume.
    pub async fn stop(&self, reset_cursors: bool) -> CursorMap {
        let (reply, rx) = oneshot::channel();
        if self
            .cmds
            .send(Cmd::Stop {
                reset_cursors,
                reply,
            })
            .await
            .is_ok()
            && let Ok(map) = rx.await
        {
            return map;
        }
        self.cursors.borrow().clone()
    }
}
