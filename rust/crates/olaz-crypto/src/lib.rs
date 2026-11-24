//! Rust port of Olaz `ZaloCrypto.swift` (minus QR PNG rendering) and `JSONLossless`.

mod cipher;
mod digest;
mod error;
mod frame;
mod lenient_base64;
mod param;

pub use cipher::{
    PARAM_CIPHER_KEY, ZERO_IV, aes_cbc_crypt, decode_aes, decode_aes_data, decode_cloud_aes,
    decode_cloud_key, encode_aes, encode_aes_data, encode_aes_hex_upper, encode_cloud_aes,
    encode_cloud_aes_with_iv, parse_secret_key,
};
pub use digest::{md5_hex, random_hex, random_salt, sha256_hex, sha256_hex_upper};
pub use error::CryptoError;
pub use frame::{
    decrypt_ws_frame, gcm_decrypt16, gcm_encrypt16, inflate_zlib_or_gzip, inflate_zlib_or_gzip_max,
    percent_decode,
};
pub use lenient_base64::{decode_foundation_base64, decode_foundation_base64_ignoring_unknown};
pub use olaz_json::{bool_value, int64, parse_any, parse_object, parse_object_str, string};
pub use param::{PASSWORD_KEY_PREFIX, ParamCipher, encrypt_password, sign_key};
