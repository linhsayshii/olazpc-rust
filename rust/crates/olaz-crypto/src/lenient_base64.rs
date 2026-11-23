//! Foundation base64 decoding lives in `olaz-json`; these wrappers keep the `CryptoError` API.

use crate::CryptoError;

/// See [`olaz_json::decode_foundation_base64`].
pub fn decode_foundation_base64(s: &str) -> Result<Vec<u8>, CryptoError> {
    olaz_json::decode_foundation_base64(s).map_err(|_| CryptoError::InvalidBase64)
}

/// See [`olaz_json::decode_foundation_base64_ignoring_unknown`].
pub fn decode_foundation_base64_ignoring_unknown(s: &str) -> Result<Vec<u8>, CryptoError> {
    olaz_json::decode_foundation_base64_ignoring_unknown(s).map_err(|_| CryptoError::InvalidBase64)
}
