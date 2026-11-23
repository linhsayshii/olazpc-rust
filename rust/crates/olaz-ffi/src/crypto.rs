//! Hot crypto helpers (thin wrappers over `olaz-crypto`).

use crate::error::CoreError;

/// `ZaloCrypto.decryptWSFrame`: decodes a `zpw_ws` frame `data` field by `encrypt` kind
/// (0 raw, 1 b64+inflate, 2 percent+b64+GCM+inflate, 3 percent+b64+GCM). `cipher_key` is the raw
/// AES key from the auth frame (needed for 2 and 3).
#[uniffi::export]
pub fn decrypt_ws_frame(
    cipher_key: Option<Vec<u8>>,
    encrypt: u8,
    data_field: String,
) -> Result<Vec<u8>, CoreError> {
    Ok(olaz_crypto::decrypt_ws_frame(
        cipher_key.as_deref(),
        encrypt,
        &data_field,
    )?)
}

/// Inflates a zlib or gzip stream (`ZaloCrypto.inflate`).
#[uniffi::export]
pub fn inflate(data: Vec<u8>) -> Result<Vec<u8>, CoreError> {
    Ok(olaz_crypto::inflate_zlib_or_gzip(&data)?)
}
