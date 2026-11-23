use thiserror::Error;

/// Errors from the crypto helpers (mirrors Swift `ZaloCryptoError`).
#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum CryptoError {
    /// AES key length is not valid for the operation.
    #[error("Invalid AES key length {0}")]
    InvalidKeyLength(usize),
    /// PKCS#7 padding or ciphertext block alignment check failed.
    #[error("PKCS#7 padding verification failed")]
    InvalidPadding,
    /// Payload is not valid Base64 (Foundation-compatible rules).
    #[error("Invalid Base64 payload")]
    InvalidBase64,
    /// IV is not 16 bytes (Swift: `cipherFailed(kCCParamError)`).
    #[error("Invalid AES IV length {0}")]
    InvalidIvLength(usize),
    /// Payload could not be inflated (bad data, empty output, or over the size cap).
    #[error("Failed to decompress payload")]
    InflateFailed,
    /// A WebSocket frame needs a cipher key but none (or an empty one) was given.
    #[error("Missing WebSocket cipher key")]
    MissingCipherKey,
    /// AES-GCM blob is too short (or IV/AAD length is wrong); carries the offending length.
    #[error("AES-GCM blob too short ({0} bytes)")]
    InvalidGcmBlob(usize),
    /// AES-GCM tag verification failed.
    #[error("AES-GCM authentication failed")]
    GcmAuthFailed,
    /// WebSocket `encrypt` kind is not 0..=3.
    #[error("Unsupported encryption scheme {0}")]
    UnsupportedEncryption(u8),
    /// JSON payload could not be serialized.
    #[error("JSON serialization failed: {0}")]
    Json(String),
}
