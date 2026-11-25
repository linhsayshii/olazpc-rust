use olaz_net::{NetError, ZaloSessionError};
use thiserror::Error;

/// Failure of an API call: the session client's error, unchanged.
#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum ApiError {
    #[error(transparent)]
    Net(#[from] NetError),
}

impl ApiError {
    /// The server `error_code` reply, when this is one.
    pub fn session_error(&self) -> Option<&ZaloSessionError> {
        match self {
            Self::Net(NetError::Session(e)) => Some(e),
            Self::Net(_) => None,
        }
    }

    /// Swift `ZaloSessionError.isAuthError` (codes 600 and -102).
    pub fn is_auth_error(&self) -> bool {
        self.session_error()
            .is_some_and(ZaloSessionError::is_auth_error)
    }

    /// Formats the error without the ` ({url})` suffix on server session errors, matching Swift's
    /// `ZaloSessionError.errorDescription` when `RustCore.mapError` is called without a path
    /// (as in `sendTextAPI` -> `"sendText failed: Zalo error {code}: {message}"`).
    #[must_use]
    pub fn display_without_url(&self) -> String {
        match self {
            Self::Net(NetError::Session(s)) => format!("Zalo error {}: {}", s.code, s.message),
            other => other.to_string(),
        }
    }
}
