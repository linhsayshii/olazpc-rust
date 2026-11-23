use olaz_crypto::CryptoError;
use thiserror::Error;

/// A Zalo server answer with a non-zero `error_code` (Swift `ZaloSessionError`).
///
/// This is an application-level reply, never a reason to fail over to another host.
#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub struct ZaloSessionError {
    pub code: i64,
    pub message: String,
    /// Request path (no host, no query), e.g. `/api/social/profile/me-v2`.
    pub url: String,
}

impl ZaloSessionError {
    /// Codes that mean the session is dead (Swift `authErrorCodes`).
    pub const AUTH_ERROR_CODES: [i64; 2] = [600, -102];

    pub fn is_auth_error(&self) -> bool {
        Self::AUTH_ERROR_CODES.contains(&self.code)
    }
}

impl std::fmt::Display for ZaloSessionError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        if self.url.is_empty() {
            write!(f, "Zalo error {}: {}", self.code, self.message)
        } else {
            write!(
                f,
                "Zalo error {}: {} ({})",
                self.code, self.message, self.url
            )
        }
    }
}

/// Class of a transport-level failure (the `URLError` codes Swift treats specially).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NetworkErrorKind {
    /// `URLError.timedOut`.
    Timeout,
    /// `URLError.networkConnectionLost`.
    ConnectionLost,
    /// Anything else (DNS, TLS, refused, ...).
    Other,
}

/// Everything that can go wrong in the session client (Swift `ZaloTransportError` +
/// `ZaloSessionError` + `URLError`).
#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum NetError {
    #[error("Chưa đăng nhập Zalo.")]
    NotAuthenticated,
    #[error("URL không hợp lệ: {0}")]
    InvalidUrl(String),
    /// Non-2xx HTTP status; `body` is at most the first 200 bytes (lossy UTF-8).
    #[error("Lỗi máy chủ HTTP {status}.")]
    Http { status: u16, body: String },
    #[error("Phản hồi máy chủ không đúng định dạng.")]
    InvalidJson,
    #[error("{0}")]
    QrFailed(String),
    #[error("Mã QR đã hết hạn.")]
    QrTimeout,
    #[error("Đã hủy.")]
    Cancelled,
    #[error(transparent)]
    Session(#[from] ZaloSessionError),
    /// Socket/DNS/TLS/timeout failure. `message` never contains the request URL.
    #[error("network error ({kind:?}): {message}")]
    Network {
        kind: NetworkErrorKind,
        message: String,
    },
    #[error(transparent)]
    Crypto(#[from] CryptoError),
}

impl NetError {
    pub fn network(kind: NetworkErrorKind, message: impl Into<String>) -> Self {
        Self::Network {
            kind,
            message: message.into(),
        }
    }

    /// Swift `ZaloSessionClient.shouldFailover`: only HTTP 404, HTTP >= 500 and network errors
    /// move on to the next host. A server `error_code` (`Session`) never does.
    pub fn should_failover(&self) -> bool {
        match self {
            Self::Http { status, .. } => *status == 404 || *status >= 500,
            Self::Network { .. } => true,
            _ => false,
        }
    }

    /// `URLError.timedOut` / `.networkConnectionLost`, the two the QR long-poll retries.
    pub fn is_timeout_or_connection_lost(&self) -> bool {
        matches!(
            self,
            Self::Network {
                kind: NetworkErrorKind::Timeout | NetworkErrorKind::ConnectionLost,
                ..
            }
        )
    }
}
