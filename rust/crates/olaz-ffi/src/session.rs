//! `CoreSession`: the session client (`olaz-net`) as a Swift object: restore / snapshot,
//! QR login and session status. Persisting the snapshot (Keychain) stays in Swift.

use std::sync::Arc;

use olaz_json::to_swift_json_string;
use olaz_net::{
    QrTicket, ReqwestTransport, SessionClient, SessionSnapshot, SessionStatus, ZaloDomains,
};
use serde_json::Value;
use tokio::sync::mpsc;

use crate::error::CoreError;
use crate::runtime::{blocking, run};

/// QR login ticket (Swift `ZaloQRTicket`). Pass the same record back to the `wait_*` calls.
/// `qr_payload` is the string to render as a QR image (Swift: CoreImage); `png_data` /
/// `base64_png` are set only when the server sent a ready-made image.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct QrTicketRecord {
    pub token_id: String,
    pub qr_payload: String,
    pub base64_png: Option<String>,
    pub png_data: Option<Vec<u8>>,
    pub chk_wait_scan: String,
    pub chk_wait_cfirm: String,
    pub qr_timeout_seconds: i64,
    pub qr_retry: i64,
}

impl From<QrTicket> for QrTicketRecord {
    fn from(t: QrTicket) -> Self {
        Self {
            token_id: t.token_id,
            qr_payload: t.qr_payload,
            base64_png: t.base64_png,
            png_data: t.png_data,
            chk_wait_scan: t.chk_wait_scan,
            chk_wait_cfirm: t.chk_wait_cfirm,
            qr_timeout_seconds: t.qr_timeout_seconds,
            qr_retry: t.qr_retry,
        }
    }
}

impl From<QrTicketRecord> for QrTicket {
    fn from(t: QrTicketRecord) -> Self {
        Self {
            token_id: t.token_id,
            qr_payload: t.qr_payload,
            base64_png: t.base64_png,
            png_data: t.png_data,
            chk_wait_scan: t.chk_wait_scan,
            chk_wait_cfirm: t.chk_wait_cfirm,
            qr_timeout_seconds: t.qr_timeout_seconds,
            qr_retry: t.qr_retry,
        }
    }
}

/// Outcome of `wait_for_qr_scan`: who scanned and the ticket to confirm with (it differs from
/// the original after a rotation).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct QrScanRecord {
    pub display_name: String,
    pub avatar: Option<String>,
    pub active_ticket: QrTicketRecord,
}

/// Result of `session_status` (Swift `ZaloSessionStatus`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum CoreSessionStatus {
    Valid,
    Expired,
    Unreachable,
}

impl From<SessionStatus> for CoreSessionStatus {
    fn from(s: SessionStatus) -> Self {
        match s {
            SessionStatus::Valid => Self::Valid,
            SessionStatus::Expired => Self::Expired,
            SessionStatus::Unreachable => Self::Unreachable,
        }
    }
}

/// Receiver of QR rotations, implemented in Swift. Called on tokio's blocking pool, in order, never
/// concurrently; all calls have returned before `wait_for_qr_scan` resolves. Return quickly.
#[uniffi::export(with_foreign)]
pub trait QrListener: Send + Sync {
    /// The server rotated to a fresh QR code (`-20`): show `ticket.qr_payload` instead.
    fn on_rotated(&self, ticket: QrTicketRecord);
}

/// The logged-in (or logging-in) session. Share it with [`crate::CoreApi`] (`CoreApi(session:)`),
/// [`crate::CoreHttp`] (`CoreHttp(session:)`), and [`crate::CoreEngine`] (`CoreEngine(session:host:)`).
#[derive(uniffi::Object)]
pub struct CoreSession {
    pub(crate) client: Arc<SessionClient<ReqwestTransport>>,
    pub(crate) default_domains: Option<ZaloDomains>,
}

#[uniffi::export]
impl CoreSession {
    /// A fresh session with a newly generated IMEI. Call `restore` to load a saved one.
    #[uniffi::constructor]
    pub fn new(computer_name: String) -> Result<Arc<Self>, CoreError> {
        let transport = ReqwestTransport::new()?;
        let client = SessionClient::new(transport, olaz_net::generate_imei(), computer_name);
        Ok(Arc::new(Self {
            client: Arc::new(client),
            default_domains: None,
        }))
    }

    /// A fresh session configured with an explicit IMEI and optional `ZaloDomains` JSON override.
    /// Used so `CoreEngine`, `CoreApi`, and `CoreHttp` share one `SessionClient` from startup.
    #[uniffi::constructor]
    pub fn with_config(
        imei: String,
        computer_name: String,
        domains_json: Option<String>,
    ) -> Result<Arc<Self>, CoreError> {
        Self::with_client_config(imei, computer_name, domains_json, Vec::new())
    }

    /// Host language preferences apply to all HTTP calls through this session, including login.
    #[uniffi::constructor]
    pub fn with_client_config(
        imei: String,
        computer_name: String,
        domains_json: Option<String>,
        preferred_languages: Vec<String>,
    ) -> Result<Arc<Self>, CoreError> {
        let domains = match domains_json {
            Some(json) => {
                let parsed: ZaloDomains =
                    serde_json::from_str(&json).map_err(|e| CoreError::Parse {
                        message: format!("domains json: {e}"),
                    })?;
                Some(parsed)
            }
            None => None,
        };
        let transport = ReqwestTransport::with_preferred_languages(preferred_languages)?;
        let client = SessionClient::new(transport, imei, computer_name);
        if let Some(d) = &domains {
            client.with_session(|s| s.domains = d.clone());
        }
        Ok(Arc::new(Self {
            client: Arc::new(client),
            default_domains: domains,
        }))
    }

    /// Loads a persisted snapshot (JSON of `olaz_net::SessionSnapshot`: `zpwType`, `imei`,
    /// `computerName`, `domains`, `plainAccount`, `expiredAt`; unknown keys such as
    /// `sealedSecretsBase64` are ignored). Returns false when the account lacks a usable
    /// `zpw_sek` / `zpw_enk` (log in again).
    pub fn restore(&self, snapshot_json: String) -> Result<bool, CoreError> {
        let snapshot: SessionSnapshot =
            serde_json::from_str(&snapshot_json).map_err(|e| CoreError::Parse {
                // serde messages describe the shape, never echo values.
                message: format!("session snapshot: {e}"),
            })?;
        Ok(self.client.restore(snapshot))
    }

    /// The current session as JSON (same keys as `restore`), to persist after login / expiry.
    pub fn snapshot_json(&self) -> Result<String, CoreError> {
        serde_json::to_string(&self.client.snapshot()).map_err(|e| CoreError::Internal {
            message: format!("snapshot: {e}"),
        })
    }

    pub fn is_authenticated(&self) -> bool {
        self.client.is_authenticated()
    }

    /// Seeds the deterministic client id sequence (test recorder).
    pub fn seed_next_client_id(&self, next: i64) {
        self.client.seed_next_client_id(next);
    }

    /// Next strictly increasing client message id (epoch ms).
    pub fn next_client_id(&self) -> i64 {
        self.client.next_client_id()
    }

    /// Records the expiry time; persist `snapshot_json()` afterwards.
    pub fn mark_expired(&self) {
        self.client.mark_expired();
    }

    /// Drops account, cookie, key and domains (then delete the persisted snapshot).
    pub fn clear_session(&self) {
        self.client.clear_session();
    }

    /// `getServerInfo` (also merges the service map). Returns the answer as JSON.
    pub async fn fetch_server_info(&self) -> Result<String, CoreError> {
        let client = Arc::clone(&self.client);
        let info = run(async move { client.fetch_server_info().await }).await??;
        Ok(to_swift_json_string(&Value::Object(info)))
    }

    /// Requests a QR login code (refreshes server info first).
    pub async fn request_qr(&self, language: String) -> Result<QrTicketRecord, CoreError> {
        let client = Arc::clone(&self.client);
        let ticket = run(async move { client.request_qr(&language).await }).await??;
        Ok(ticket.into())
    }

    /// Long-polls until the phone scans the code. `on_rotated` fires when the server swaps in a
    /// new code.
    pub async fn wait_for_qr_scan(
        &self,
        ticket: QrTicketRecord,
        on_rotated: Option<Arc<dyn QrListener>>,
    ) -> Result<QrScanRecord, CoreError> {
        let client = Arc::clone(&self.client);
        let ticket: QrTicket = ticket.into();
        run(async move {
            let (tx, mut rx) = mpsc::unbounded_channel::<QrTicketRecord>();
            let pump = on_rotated.map(|listener| {
                tokio::spawn(async move {
                    while let Some(t) = rx.recv().await {
                        let l = Arc::clone(&listener);
                        let _ = blocking(move || l.on_rotated(t)).await;
                    }
                })
            });
            let mut forward = move |t: &QrTicket| {
                let _ = tx.send(t.clone().into());
            };
            let result = client.wait_for_qr_scan(&ticket, Some(&mut forward)).await;
            drop(forward);
            if let Some(pump) = pump {
                let _ = pump.await;
            }
            result
        })
        .await?
        .map(|r| QrScanRecord {
            display_name: r.display_name,
            avatar: r.avatar,
            active_ticket: r.active_ticket.into(),
        })
        .map_err(Into::into)
    }

    /// Long-polls until the user confirms on the phone (stores the new cookie in the session).
    pub async fn wait_for_qr_confirm(&self, ticket: QrTicketRecord) -> Result<(), CoreError> {
        let client = Arc::clone(&self.client);
        let ticket: QrTicket = ticket.into();
        run(async move { client.wait_for_qr_confirm(&ticket).await }).await??;
        Ok(())
    }

    /// Finishes login (`getLoginInfo` + profile sync) and returns the snapshot JSON to persist.
    pub async fn complete_login(&self) -> Result<String, CoreError> {
        let client = Arc::clone(&self.client);
        run(async move { client.complete_login().await }).await??;
        self.snapshot_json()
    }

    /// Validates the stored session against the server.
    pub async fn session_status(&self) -> Result<CoreSessionStatus, CoreError> {
        let client = Arc::clone(&self.client);
        Ok(run(async move { client.session_status().await })
            .await?
            .into())
    }
}
