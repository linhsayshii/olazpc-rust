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
}
