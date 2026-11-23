//! The single error type crossing the FFI boundary.

/// Error thrown by every fallible export (`throws CoreError` in Swift). Variants carry a
/// human-readable `message` that never contains tokens or message bodies.
#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum CoreError {
    #[error("store: {message}")]
    Store { message: String },
    #[error("parse: {message}")]
    Parse { message: String },
    #[error("crypto: {message}")]
    Crypto { message: String },
    #[error("websocket: {message}")]
    Ws { message: String },
    #[error("internal: {message}")]
    Internal { message: String },
    /// The server answered with a non-zero `error_code` (Swift `ZaloSessionError`). `is_auth` is
    /// true for 600 / -102: the session is dead, re-login.
    #[error("Zalo error {code}: {message}")]
    Session {
        code: i64,
        message: String,
        is_auth: bool,
    },
    /// Socket / DNS / TLS / timeout failure (the message never contains the request URL).
    #[error("network ({kind:?}): {message}")]
    Network { kind: NetworkKind, message: String },
    /// Non-2xx HTTP answer.
    #[error("HTTP {status}")]
    Http { status: u16 },
    /// No logged-in session (Swift `ZaloTransportError.notAuthenticated`).
    #[error("not authenticated")]
    NotAuthenticated,
    /// QR login failed; `message` is a user-facing Vietnamese string from the engine.
    #[error("qr: {message}")]
    Qr { message: String },
    /// The QR code expired before it was scanned / confirmed.
    #[error("qr timeout")]
    QrTimeout,
    /// The operation was cancelled.
    #[error("cancelled")]
    Cancelled,
}

/// Class of a transport failure (Swift `URLError` codes treated specially).
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum NetworkKind {
    Timeout,
    ConnectionLost,
    Other,
}

impl CoreError {
    /// True for a dead session (codes 600 / -102): the caller must run the QR login again.
    #[must_use]
    pub fn is_auth_error(&self) -> bool {
        matches!(self, Self::Session { is_auth: true, .. })
    }
}

impl From<olaz_net::NetError> for CoreError {
    fn from(e: olaz_net::NetError) -> Self {
        use olaz_net::{NetError, NetworkErrorKind};
        match e {
            NetError::Session(s) => Self::Session {
                is_auth: s.is_auth_error(),
                code: s.code,
                message: s.message,
            },
            NetError::Network { kind, message } => Self::Network {
                kind: match kind {
                    NetworkErrorKind::Timeout => NetworkKind::Timeout,
                    NetworkErrorKind::ConnectionLost => NetworkKind::ConnectionLost,
                    NetworkErrorKind::Other => NetworkKind::Other,
                },
                message,
            },
            NetError::Http { status, .. } => Self::Http { status },
            NetError::NotAuthenticated => Self::NotAuthenticated,
            NetError::QrFailed(message) => Self::Qr { message },
            NetError::QrTimeout => Self::QrTimeout,
            NetError::Cancelled => Self::Cancelled,
            NetError::Crypto(c) => c.into(),
            NetError::InvalidUrl(_) => Self::Parse {
                message: "invalid url".to_owned(),
            },
            NetError::InvalidJson => Self::Parse {
                message: "invalid json answer".to_owned(),
            },
        }
    }
}

impl From<olaz_api::ApiError> for CoreError {
    fn from(e: olaz_api::ApiError) -> Self {
        match e {
            olaz_api::ApiError::Net(n) => n.into(),
        }
    }
}

impl From<olaz_store::StoreError> for CoreError {
    fn from(e: olaz_store::StoreError) -> Self {
        Self::Store {
            message: e.to_string(),
        }
    }
}

impl From<olaz_crypto::CryptoError> for CoreError {
    fn from(e: olaz_crypto::CryptoError) -> Self {
        Self::Crypto {
            message: e.to_string(),
        }
    }
}

impl From<tokio::task::JoinError> for CoreError {
    fn from(e: tokio::task::JoinError) -> Self {
        Self::Internal {
            message: format!("task failed: {e}"),
        }
    }
}
