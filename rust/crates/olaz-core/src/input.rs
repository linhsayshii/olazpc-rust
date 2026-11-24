//! Inputs to the pure reducer: external commands and effect completions.

use std::fmt;

use olaz_net::{LoginAccount, NetError, QrScanResult, QrTicket, SessionStatus};

use crate::state::{CoreFailKind, FailReason};

/// Commands sent from Swift (or test scripts) into the actor.
#[derive(Clone)]
pub enum Command {
    Start,
    RefreshQr,
    LogOut,
    SessionExpired { reason: String },
    ApplyAccountProfile(LoginAccount),
}

impl fmt::Debug for Command {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Start => f.write_str("Start"),
            Self::RefreshQr => f.write_str("RefreshQr"),
            Self::LogOut => f.write_str("LogOut"),
            Self::SessionExpired { reason } => f
                .debug_struct("SessionExpired")
                .field("reason_len", &reason.len())
                .finish(),
            Self::ApplyAccountProfile(acc) => f
                .debug_struct("ApplyAccountProfile")
                .field("has_uid", &!acc.user_id.is_empty())
                .finish(),
        }
    }
}

/// Identifies which flow awaits `HostCall::PrepareStore`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StoreToken {
    Boot(u64),
    Qr(u64),
}

/// Legacy WKWebView / HTTPCookieStorage credentials returned by `Host::load_legacy_cookie`.
#[derive(Clone, PartialEq, Eq)]
pub struct LegacyCookie {
    pub zpw_sek: String,
    pub imei: Option<String>,
}

impl fmt::Debug for LegacyCookie {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("LegacyCookie")
            .field("has_sek", &!self.zpw_sek.is_empty())
            .field("has_imei", &self.imei.is_some())
            .finish()
    }
}

/// Result of `complete_login` in the effect runner.
#[derive(Clone)]
pub struct CompletedLogin {
    pub account: LoginAccount,
    pub ws_endpoints: Vec<String>,
    pub profile_synced: bool,
}

impl fmt::Debug for CompletedLogin {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("CompletedLogin")
            .field("has_uid", &!self.account.user_id.is_empty())
            .field("ws_count", &self.ws_endpoints.len())
            .field("profile_synced", &self.profile_synced)
            .finish()
    }
}

/// Typed failure produced by QR login effects.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SessionFailure {
    Cancelled,
    QrTimeout,
    Failed(FailReason),
}

impl From<NetError> for SessionFailure {
    fn from(err: NetError) -> Self {
        match err {
            NetError::Cancelled => Self::Cancelled,
            NetError::QrTimeout => Self::QrTimeout,
            NetError::QrFailed(msg) => Self::Failed(FailReason::Text(msg)),
            NetError::InvalidUrl(raw) => {
                Self::Failed(FailReason::Text(format!("URL không hợp lệ: {raw}")))
            }
            NetError::Session(s) => Self::Failed(FailReason::Core(CoreFailKind::Session {
                code: s.code,
                message: s.message,
                url: s.url,
            })),
            NetError::Http { status, .. } => {
                Self::Failed(FailReason::Core(CoreFailKind::Http { status }))
            }
            NetError::InvalidJson => Self::Failed(FailReason::Core(CoreFailKind::InvalidJson)),
            NetError::NotAuthenticated => {
                Self::Failed(FailReason::Core(CoreFailKind::NotAuthenticated))
            }
            NetError::Network { kind, .. } => {
                Self::Failed(FailReason::Core(CoreFailKind::Network(kind)))
            }
            NetError::Crypto(c) => {
                Self::Failed(FailReason::Core(CoreFailKind::Crypto(c.to_string())))
            }
        }
    }
}

/// Every event entering `reduce(&mut CoreState, Input)`.
#[derive(Clone)]
pub enum Input {
    Command(Command),
    SavedSessionLoaded {
        boot_gen: u64,
        restored: bool,
        account: Option<LoginAccount>,
        ws_endpoints: Vec<String>,
    },
    LegacyCookieResult {
        boot_gen: u64,
        account: Option<LoginAccount>,
        ws_endpoints: Vec<String>,
        profile_synced: bool,
    },
    PrepareStoreDone {
        token: StoreToken,
    },
    SessionStatusResult {
        boot_gen: u64,
        status: SessionStatus,
        updated_from_login_info: bool,
        ws_endpoints: Vec<String>,
    },
    SyncProfileMeDone {
        boot_gen: u64,
        profile_synced: bool,
        account: Option<LoginAccount>,
        ws_endpoints: Vec<String>,
    },
    QrRequested {
        qr_gen: u64,
        result: Result<QrTicket, SessionFailure>,
    },
    QrRotated {
        qr_gen: u64,
        ticket: QrTicket,
    },
    QrScanned {
        qr_gen: u64,
        result: Result<QrScanResult, SessionFailure>,
    },
    QrConfirmed {
        qr_gen: u64,
        result: Result<(), SessionFailure>,
    },
    LoginCompleted {
        qr_gen: u64,
        result: Result<CompletedLogin, SessionFailure>,
    },
}

impl fmt::Debug for Input {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Command(c) => f.debug_tuple("Command").field(c).finish(),
            Self::SavedSessionLoaded {
                boot_gen,
                restored,
                account,
                ws_endpoints,
            } => f
                .debug_struct("SavedSessionLoaded")
                .field("boot_gen", boot_gen)
                .field("restored", restored)
                .field("has_account", &account.is_some())
                .field("ws_count", &ws_endpoints.len())
                .finish(),
            Self::LegacyCookieResult {
                boot_gen,
                account,
                ws_endpoints,
                profile_synced,
            } => f
                .debug_struct("LegacyCookieResult")
                .field("boot_gen", boot_gen)
                .field("has_account", &account.is_some())
                .field("ws_count", &ws_endpoints.len())
                .field("profile_synced", profile_synced)
                .finish(),
            Self::PrepareStoreDone { token } => f
                .debug_struct("PrepareStoreDone")
                .field("token", token)
                .finish(),
            Self::SessionStatusResult {
                boot_gen,
                status,
                updated_from_login_info,
                ws_endpoints,
            } => f
                .debug_struct("SessionStatusResult")
                .field("boot_gen", boot_gen)
                .field("status", status)
                .field("updated_from_login_info", updated_from_login_info)
                .field("ws_count", &ws_endpoints.len())
                .finish(),
            Self::SyncProfileMeDone {
                boot_gen,
                profile_synced,
                account,
                ws_endpoints,
            } => f
                .debug_struct("SyncProfileMeDone")
                .field("boot_gen", boot_gen)
                .field("profile_synced", profile_synced)
                .field("has_account", &account.is_some())
                .field("ws_count", &ws_endpoints.len())
                .finish(),
            Self::QrRequested { qr_gen, result } => f
                .debug_struct("QrRequested")
                .field("qr_gen", qr_gen)
                .field("ok", &result.is_ok())
                .finish(),
            Self::QrRotated { qr_gen, .. } => {
                f.debug_struct("QrRotated").field("qr_gen", qr_gen).finish()
            }
            Self::QrScanned { qr_gen, result } => f
                .debug_struct("QrScanned")
                .field("qr_gen", qr_gen)
                .field("ok", &result.is_ok())
                .finish(),
            Self::QrConfirmed { qr_gen, result } => f
                .debug_struct("QrConfirmed")
                .field("qr_gen", qr_gen)
                .field("ok", &result.is_ok())
                .finish(),
            Self::LoginCompleted { qr_gen, result } => f
                .debug_struct("LoginCompleted")
                .field("qr_gen", qr_gen)
                .field("ok", &result.is_ok())
                .finish(),
        }
    }
}

#[cfg(test)]
mod tests {
    use olaz_net::{NetworkErrorKind, ZaloSessionError};

    use super::*;

    #[test]
    fn net_error_mapping_preserves_swift_strings_and_typed_core_errors() {
        assert_eq!(
            SessionFailure::from(NetError::Cancelled),
            SessionFailure::Cancelled
        );
        assert_eq!(
            SessionFailure::from(NetError::QrTimeout),
            SessionFailure::QrTimeout
        );
        assert_eq!(
            SessionFailure::from(NetError::QrFailed(
                "Máy chủ không trả về dữ liệu QR.".into()
            )),
            SessionFailure::Failed(FailReason::Text("Máy chủ không trả về dữ liệu QR.".into()))
        );
        assert_eq!(
            SessionFailure::from(NetError::Session(ZaloSessionError {
                code: -1,
                message: "Không tạo được mã QR".into(),
                url: "/api/login/reqqr".into(),
            })),
            SessionFailure::Failed(FailReason::Core(CoreFailKind::Session {
                code: -1,
                message: "Không tạo được mã QR".into(),
                url: "/api/login/reqqr".into(),
            }))
        );
        assert_eq!(
            SessionFailure::from(NetError::network(NetworkErrorKind::Other, "refused")),
            SessionFailure::Failed(FailReason::Core(CoreFailKind::Network(
                NetworkErrorKind::Other
            )))
        );
    }
}
