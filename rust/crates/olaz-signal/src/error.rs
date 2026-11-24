use libsignal_protocol::SignalProtocolError;

pub type Result<T> = std::result::Result<T, SignalError>;

#[derive(Debug, thiserror::Error)]
pub enum SignalError {
    #[error("json: {0}")]
    Json(#[from] serde_json::Error),
    #[error("base64: {0}")]
    Base64(#[from] base64::DecodeError),
    #[error("protobuf: {0}")]
    Proto(#[from] prost::DecodeError),
    /// A stored JS record that does not have the shape `libsignal-protocol.js` writes.
    #[error("invalid stored record: {0}")]
    Format(String),
    #[error("signal protocol: {0}")]
    Protocol(#[from] SignalProtocolError),
    #[error("curve key: {0}")]
    Curve(#[from] libsignal_core::curve::CurveError),
}

impl SignalError {
    /// Short class name without any detail (a protocol error's text can carry the peer address,
    /// so only the variant name leaves this crate; ADR-008).
    #[must_use]
    pub fn kind(&self) -> String {
        match self {
            Self::Json(_) => "json".to_owned(),
            Self::Base64(_) => "base64".to_owned(),
            Self::Proto(_) => "protobuf".to_owned(),
            Self::Format(_) => "format".to_owned(),
            Self::Curve(_) => "curve".to_owned(),
            Self::Protocol(e) => {
                let dbg = format!("{e:?}");
                let name: String = dbg
                    .chars()
                    .take_while(|c| c.is_ascii_alphanumeric())
                    .collect();
                format!("protocol_{}", name.to_ascii_lowercase())
            }
        }
    }
}

pub(crate) fn format_err<T>(msg: impl Into<String>) -> Result<T> {
    Err(SignalError::Format(msg.into()))
}
