//! Side effects returned by `reduce` and executed by [`crate::runner::EffectRunner`].

use std::fmt;

use olaz_net::{LoginAccount, QrTicket};

use crate::input::StoreToken;

/// Activities handed to Swift-owned domains (the `host` list in Case format v1).
///
/// Host calls emitted by a `reduce` step always execute serially in emitted order.
/// Credential snapshots for `PersistSession` / `MarkExpired` are read from `SessionClient` by the
/// effect runner at dispatch time so no secret material sits inside reducer effects.
#[derive(Clone)]
pub enum HostCall {
    PrepareStore {
        token: StoreToken,
        user_id: String,
        account: Box<LoginAccount>,
    },
    StartWs {
        endpoints: Vec<String>,
    },
    StartLongPoll,
    StartBootstrap,
    OfferFirstLoginTransfer {
        force: bool,
    },
    ResetDomains,
    PersistSession,
    ClearSession,
    MarkExpired,
}

impl fmt::Debug for HostCall {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::PrepareStore { token, user_id, .. } => f
                .debug_struct("PrepareStore")
                .field("token", token)
                .field("has_uid", &!user_id.is_empty())
                .finish(),
            Self::StartWs { endpoints } => f
                .debug_struct("StartWs")
                .field("endpoints_count", &endpoints.len())
                .finish(),
            Self::StartLongPoll => f.write_str("StartLongPoll"),
            Self::StartBootstrap => f.write_str("StartBootstrap"),
            Self::OfferFirstLoginTransfer { force } => f
                .debug_struct("OfferFirstLoginTransfer")
                .field("force", force)
                .finish(),
            Self::ResetDomains => f.write_str("ResetDomains"),
            Self::PersistSession => f.write_str("PersistSession"),
            Self::ClearSession => f.write_str("ClearSession"),
            Self::MarkExpired => f.write_str("MarkExpired"),
        }
    }
}

/// Every side effect `reduce` can request.
#[derive(Clone)]
pub enum Effect {
    /// Aborts any in-flight QR / boot network tasks.
    CancelSessionTasks,
    /// Loads and restores the saved session via `Host::load_saved_session` + `SessionClient::restore`.
    LoadSavedSession { boot_gen: u64 },
    /// Reads the legacy cookie via `Host::load_legacy_cookie` and runs `complete_login` if present.
    LoadLegacyCookie { boot_gen: u64 },
    /// Validates the restored session against the server (`session_status_detailed`).
    CheckSessionStatus { boot_gen: u64 },
    /// Refreshes the signed-in user's profile (`sync_profile_me`).
    SyncProfileMe { boot_gen: u64 },
    /// Requests a fresh QR login ticket (`request_qr`).
    RequestQr { qr_gen: u64, language: String },
    /// Long-polls until the phone scans the QR code (rotations arrive as `Input::QrRotated`).
    WaitQrScan { qr_gen: u64, ticket: QrTicket },
    /// Long-polls until the phone confirms the login.
    WaitQrConfirm { qr_gen: u64, ticket: QrTicket },
    /// Finishes login (`getLoginInfo` + `syncProfileMe`).
    CompleteLogin { qr_gen: u64 },
    /// Clears the in-memory `SessionClient` credentials and domains before `HostCall::ClearSession`.
    ClearCoreSession,
    /// Marks `expired_at` on the in-memory `SessionClient` before `HostCall::MarkExpired`.
    MarkCoreSessionExpired,
    /// Writes a session-domain preference to the opened store (storage primitive, not in `hostTrace`).
    SetPref { key: String, value: String },
    /// Domain activity delegated to Swift via `CoreHost`.
    Host(HostCall),
}

impl fmt::Debug for Effect {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::CancelSessionTasks => f.write_str("CancelSessionTasks"),
            Self::LoadSavedSession { boot_gen } => f
                .debug_struct("LoadSavedSession")
                .field("boot_gen", boot_gen)
                .finish(),
            Self::LoadLegacyCookie { boot_gen } => f
                .debug_struct("LoadLegacyCookie")
                .field("boot_gen", boot_gen)
                .finish(),
            Self::CheckSessionStatus { boot_gen } => f
                .debug_struct("CheckSessionStatus")
                .field("boot_gen", boot_gen)
                .finish(),
            Self::SyncProfileMe { boot_gen } => f
                .debug_struct("SyncProfileMe")
                .field("boot_gen", boot_gen)
                .finish(),
            Self::RequestQr { qr_gen, language } => f
                .debug_struct("RequestQr")
                .field("qr_gen", qr_gen)
                .field("language", language)
                .finish(),
            Self::WaitQrScan { qr_gen, .. } => f
                .debug_struct("WaitQrScan")
                .field("qr_gen", qr_gen)
                .finish(),
            Self::WaitQrConfirm { qr_gen, .. } => f
                .debug_struct("WaitQrConfirm")
                .field("qr_gen", qr_gen)
                .finish(),
            Self::CompleteLogin { qr_gen } => f
                .debug_struct("CompleteLogin")
                .field("qr_gen", qr_gen)
                .finish(),
            Self::ClearCoreSession => f.write_str("ClearCoreSession"),
            Self::MarkCoreSessionExpired => f.write_str("MarkCoreSessionExpired"),
            Self::SetPref { key, .. } => f.debug_struct("SetPref").field("key", key).finish(),
            Self::Host(call) => f.debug_tuple("Host").field(call).finish(),
        }
    }
}
