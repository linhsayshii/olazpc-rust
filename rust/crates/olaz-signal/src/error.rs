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

pub(crate) fn format_err<T>(msg: impl Into<String>) -> Result<T> {
    Err(SignalError::Format(msg.into()))
}
