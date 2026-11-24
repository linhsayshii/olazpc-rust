//! The only place `olaz-crypto` is used: plugs real frame decryption into [`WsCore`](crate::WsCore).

use crate::core::{DecryptError, FrameDecryptor};

/// [`FrameDecryptor`] backed by `olaz_crypto::decrypt_ws_frame` (`ZaloCrypto.decryptWSFrame`).
#[derive(Debug, Default, Clone, Copy)]
pub struct CryptoDecryptor;

impl FrameDecryptor for CryptoDecryptor {
    fn decrypt_ws_frame(
        &self,
        cipher_key: Option<&[u8]>,
        encrypt: u8,
        data_field: &str,
    ) -> Result<Vec<u8>, DecryptError> {
        olaz_crypto::decrypt_ws_frame(cipher_key, encrypt, data_field)
            .map_err(|e| DecryptError(e.to_string()))
    }
}
