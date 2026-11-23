//! Error types and the official-client failure codes (Swift `MediaLoader.LoadError`,
//! `DoHResolver.ResolveError`, `URLError`, `DownloadManager.Failure`).
//!
//! Messages never carry URLs, headers or paths (ADR-008).

/// DoH resolution failure (Swift `DoHResolver.ResolveError`).
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum ResolveError {
    /// Authoritative NXDOMAIN.
    #[error("DoH: no A record")]
    NotFound,
    #[error("DoH: all resolvers failed")]
    AllEndpointsFailed,
}

/// Class of a transport failure (the `URLError` codes the Swift code treated specially).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NetKind {
    CannotFindHost,
    TimedOut,
    /// `notConnectedToInternet` (also what macOS reports for some DNS failures).
    NotConnected,
    ConnectionLost,
    CannotConnect,
    SecureFailed,
    Other,
}

/// Every way a media operation can fail.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum MediaError {
    #[error("unsupported media url")]
    BadUrl,
    #[error("media request failed with HTTP {0}")]
    Http(u16),
    #[error("media data is not decodable")]
    Undecodable,
    /// Deadline / time-to-first-byte / DoH stall (Swift `LoadError.timedOut`).
    #[error("media download timed out")]
    TimedOut,
    #[error("media file is too large")]
    TooLarge,
    #[error("media host no longer exists")]
    HostNotFound,
    #[error("cancelled")]
    Cancelled,
    #[error("{0}")]
    Resolve(#[from] ResolveError),
    #[error("network failure ({0:?})")]
    Net(NetKind),
    /// Local file-system failure (kind only, the path is user data).
    #[error("io: {0}")]
    Io(String),
}

impl MediaError {
    /// Swift `LoadError`: reached the server (or decided locally) and must not be retried elsewhere.
    pub(crate) fn is_load_error(&self) -> bool {
        matches!(
            self,
            Self::BadUrl
                | Self::Http(_)
                | Self::Undecodable
                | Self::TimedOut
                | Self::TooLarge
                | Self::HostNotFound
        )
    }

    /// Swift `isDNSFailure(URLError)`: errors that justify a DoH retry.
    pub(crate) fn is_dns_failure(&self) -> bool {
        matches!(
            self,
            Self::Net(NetKind::CannotFindHost | NetKind::NotConnected | NetKind::TimedOut)
        )
    }

    pub(crate) fn io(e: &std::io::Error) -> Self {
        Self::Io(format!("{:?}", e.kind()))
    }
}

impl From<std::io::Error> for MediaError {
    fn from(e: std::io::Error) -> Self {
        Self::io(&e)
    }
}

/// What the official main process reports for a failed download (Swift `DownloadManager.Failure`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Failure {
    pub name: String,
    pub code: i64,
    pub message: String,
}

impl Failure {
    fn new(name: &str, code: i64) -> Self {
        Self {
            name: name.to_owned(),
            code,
            message: String::new(),
        }
    }

    pub fn aborted() -> Self {
        Self::new("GENERAL_MAIN_CONTROLLER_OBJ_DOWNLOAD_ABORT", 1009)
    }
    pub fn invalid_url() -> Self {
        Self::new("GENERAL_UI_OBJ_DOWNLOAD_INVALID_URL", 9)
    }
    pub fn empty_body() -> Self {
        Self::new(
            "DOWNLOAD_SERVICE_SINGLE_INVALID_CONTENT_LENGTH",
            75_000 + 5002,
        )
    }
    pub fn ttfb_timeout() -> Self {
        Self::new("DOWNLOAD_SERVICE_SINGLE_MAX_TTFB_TIMEOUT", 75_000 + 5027)
    }
    /// Plain `Error` in main: `INS_OF_ERROR_ERR` (14998) with the message.
    pub fn decrypt_failed() -> Self {
        Self {
            name: "INS_OF_ERROR_ERR".to_owned(),
            code: 14998,
            message: "File secure decrypt failed".to_owned(),
        }
    }
    pub fn too_large() -> Self {
        Self::new(
            "DOWNLOAD_SERVICE_SINGLE_FILE_SIZE_LIMIT_EXCEED",
            75_000 + 5026,
        )
    }
    pub fn unknown() -> Self {
        Self::new(
            "DOWNLOAD_SERVICE_SINGLE_DOWNLOAD_ON_EMPTY_ERR",
            75_000 + 5025,
        )
    }
    pub fn http(status: u16) -> Self {
        Self::new(
            &format!("DOWNLOAD_SERVICE_NET_{status}"),
            75_000 + i64::from(status),
        )
    }
    fn net(name: &str, number: i64) -> Self {
        Self::new(name, 30_000 + number)
    }

    /// Maps an error to the one the official main process would report.
    pub fn from_error(error: &MediaError) -> Self {
        match error {
            MediaError::Cancelled => Self::aborted(),
            MediaError::Http(status) => Self::http(*status),
            MediaError::HostNotFound => Self::net("ERR_NAME_NOT_RESOLVED", 34),
            MediaError::TimedOut => Self::ttfb_timeout(),
            MediaError::BadUrl => Self::invalid_url(),
            MediaError::TooLarge => Self::too_large(),
            MediaError::Undecodable | MediaError::Io(_) => Self::unknown(),
            MediaError::Resolve(ResolveError::NotFound) => Self::net("ERR_NAME_NOT_RESOLVED", 34),
            MediaError::Resolve(ResolveError::AllEndpointsFailed) => {
                Self::net("ERR_NAME_RESOLUTION_FAILED", 63)
            }
            MediaError::Net(kind) => match kind {
                NetKind::CannotFindHost => Self::net("ERR_NAME_NOT_RESOLVED", 34),
                NetKind::TimedOut => Self::net("ERR_CONNECTION_TIMED_OUT", 47),
                NetKind::NotConnected | NetKind::ConnectionLost => {
                    Self::net("ERR_INTERNET_DISCONNECTED", 35)
                }
                NetKind::CannotConnect => Self::net("ERR_CONNECTION_REFUSED", 31),
                NetKind::SecureFailed => Self::net("ERR_SSL_PROTOCOL_ERROR", 36),
                NetKind::Other => Self::net("ERR_CONNECTION_FAILED", 33),
            },
        }
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used)]

    use super::*;

    #[test]
    fn failure_codes_match_swift_table() {
        assert_eq!(Failure::http(404).code, 75_404);
        assert_eq!(Failure::http(404).name, "DOWNLOAD_SERVICE_NET_404");
        assert_eq!(Failure::from_error(&MediaError::TimedOut).code, 80_027);
        assert_eq!(Failure::from_error(&MediaError::TooLarge).code, 80_026);
        assert_eq!(Failure::from_error(&MediaError::Undecodable).code, 80_025);
        assert_eq!(Failure::from_error(&MediaError::BadUrl).code, 9);
        assert_eq!(Failure::from_error(&MediaError::Cancelled).code, 1009);
        assert_eq!(Failure::from_error(&MediaError::HostNotFound).code, 30_034);
        assert_eq!(Failure::decrypt_failed().code, 14_998);
        assert_eq!(Failure::empty_body().code, 80_002);
        assert_eq!(
            Failure::from_error(&MediaError::Resolve(ResolveError::AllEndpointsFailed)).code,
            30_063
        );
        assert_eq!(
            Failure::from_error(&MediaError::Net(NetKind::TimedOut)).name,
            "ERR_CONNECTION_TIMED_OUT"
        );
        assert_eq!(
            Failure::from_error(&MediaError::Net(NetKind::NotConnected)).code,
            30_035
        );
        assert_eq!(
            Failure::from_error(&MediaError::Net(NetKind::CannotConnect)).code,
            30_031
        );
        assert_eq!(
            Failure::from_error(&MediaError::Net(NetKind::SecureFailed)).code,
            30_036
        );
        assert_eq!(
            Failure::from_error(&MediaError::Net(NetKind::Other)).code,
            30_033
        );
    }

    #[test]
    fn dns_failure_classification_matches_swift() {
        assert!(MediaError::Net(NetKind::CannotFindHost).is_dns_failure());
        assert!(MediaError::Net(NetKind::NotConnected).is_dns_failure());
        assert!(MediaError::Net(NetKind::TimedOut).is_dns_failure());
        assert!(!MediaError::Net(NetKind::CannotConnect).is_dns_failure());
        assert!(!MediaError::Cancelled.is_dns_failure());
        assert!(MediaError::Http(404).is_load_error());
        assert!(!MediaError::Net(NetKind::Other).is_load_error());
    }
}
