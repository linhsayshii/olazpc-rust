use crate::CryptoError;
use crate::lenient_base64::decode_foundation_base64_ignoring_unknown;
use aes::{Aes128, Aes192, Aes256};
use aes_gcm::{
    AesGcm, KeyInit,
    aead::{Aead, Payload, consts::U16},
};
use flate2::read::{DeflateDecoder, GzDecoder, ZlibDecoder};
use std::io::Read;

/// Default inflate output cap (64 MiB), as in Swift.
const DEFAULT_MAX_INFLATE: usize = 64 * 1024 * 1024;

/// Decodes `%XX` escapes (invalid or truncated escapes are kept verbatim; result is lossy UTF-8).
pub fn percent_decode(s: &str) -> String {
    fn nibble(b: u8) -> Option<u8> {
        match b {
            b'0'..=b'9' => Some(b - b'0'),
            b'a'..=b'f' => Some(b - b'a' + 10),
            b'A'..=b'F' => Some(b - b'A' + 10),
            _ => None,
        }
    }
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%'
            && i + 2 < bytes.len()
            && let (Some(hi), Some(lo)) = (nibble(bytes[i + 1]), nibble(bytes[i + 2]))
        {
            out.push((hi << 4) | lo);
            i += 3;
            continue;
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn read_capped(mut r: impl Read, max_bytes: usize) -> Option<Vec<u8>> {
    let mut out = Vec::new();
    let limit = u64::try_from(max_bytes)
        .unwrap_or(u64::MAX)
        .saturating_add(1);
    (&mut r).take(limit).read_to_end(&mut out).ok()?;
    (out.len() <= max_bytes && !out.is_empty()).then_some(out)
}

/// Inflates zlib or gzip (auto-detected), falling back to raw deflate; 64 MiB output cap.
///
/// Empty input yields empty output. Empty output from non-empty input is an error.
pub fn inflate_zlib_or_gzip(data: &[u8]) -> Result<Vec<u8>, CryptoError> {
    inflate_zlib_or_gzip_max(data, DEFAULT_MAX_INFLATE)
}

/// [`inflate_zlib_or_gzip`] with an explicit output cap (output longer than `max_bytes` fails).
pub fn inflate_zlib_or_gzip_max(data: &[u8], max_bytes: usize) -> Result<Vec<u8>, CryptoError> {
    if data.is_empty() {
        return Ok(Vec::new());
    }
    let auto = if data.starts_with(&[0x1f, 0x8b]) {
        read_capped(GzDecoder::new(data), max_bytes)
    } else {
        read_capped(ZlibDecoder::new(data), max_bytes)
    };
    auto.or_else(|| read_capped(DeflateDecoder::new(data), max_bytes))
        .ok_or(CryptoError::InflateFailed)
}

fn gcm_open<C>(key: &[u8], iv: &[u8], aad: &[u8], ct_tag: &[u8]) -> Result<Vec<u8>, CryptoError>
where
    C: aes::cipher::BlockCipherEncrypt + aes::cipher::BlockSizeUser<BlockSize = U16> + KeyInit,
{
    let cipher = AesGcm::<C, U16>::new_from_slice(key)
        .map_err(|_| CryptoError::InvalidKeyLength(key.len()))?;
    let nonce = <&[u8; 16]>::try_from(iv).map_err(|_| CryptoError::InvalidGcmBlob(iv.len()))?;
    cipher
        .decrypt(nonce.into(), Payload { msg: ct_tag, aad })
        .map_err(|_| CryptoError::GcmAuthFailed)
}

fn gcm_seal<C>(key: &[u8], iv: &[u8], aad: &[u8], msg: &[u8]) -> Result<Vec<u8>, CryptoError>
where
    C: aes::cipher::BlockCipherEncrypt + aes::cipher::BlockSizeUser<BlockSize = U16> + KeyInit,
{
    let cipher = AesGcm::<C, U16>::new_from_slice(key)
        .map_err(|_| CryptoError::InvalidKeyLength(key.len()))?;
    let nonce = <&[u8; 16]>::try_from(iv).map_err(|_| CryptoError::InvalidGcmBlob(iv.len()))?;
    cipher
        .encrypt(nonce.into(), Payload { msg, aad })
        .map_err(|_| CryptoError::GcmAuthFailed)
}

/// AES-GCM with a 16-byte nonce; blob layout `iv(16) | aad(16) | ciphertext || tag(16)` (min 48 bytes).
pub fn gcm_decrypt16(key: &[u8], blob: &[u8]) -> Result<Vec<u8>, CryptoError> {
    if blob.len() < 48 {
        return Err(CryptoError::InvalidGcmBlob(blob.len()));
    }
    let (iv, rest) = blob.split_at(16);
    let (aad, ct_tag) = rest.split_at(16);
    match key.len() {
        16 => gcm_open::<Aes128>(key, iv, aad, ct_tag),
        24 => gcm_open::<Aes192>(key, iv, aad, ct_tag),
        32 => gcm_open::<Aes256>(key, iv, aad, ct_tag),
        n => Err(CryptoError::InvalidKeyLength(n)),
    }
}

/// AES-GCM encrypt returning `iv | aad | ciphertext || tag`; `iv` and `aad` must be 16 bytes.
pub fn gcm_encrypt16(
    key: &[u8],
    plaintext: &[u8],
    iv: &[u8],
    aad: &[u8],
) -> Result<Vec<u8>, CryptoError> {
    if iv.len() != 16 || aad.len() != 16 {
        return Err(CryptoError::InvalidGcmBlob(iv.len()));
    }
    let sealed = match key.len() {
        16 => gcm_seal::<Aes128>(key, iv, aad, plaintext)?,
        24 => gcm_seal::<Aes192>(key, iv, aad, plaintext)?,
        32 => gcm_seal::<Aes256>(key, iv, aad, plaintext)?,
        n => return Err(CryptoError::InvalidKeyLength(n)),
    };
    let mut out = Vec::with_capacity(32 + sealed.len());
    out.extend_from_slice(iv);
    out.extend_from_slice(aad);
    out.extend_from_slice(&sealed);
    Ok(out)
}

/// Decodes a `zpw_ws` frame `data` field by `encrypt` kind: 0 raw, 1 b64+inflate,
/// 2 percent+b64+GCM+inflate, 3 percent+b64+GCM.
pub fn decrypt_ws_frame(
    cipher_key: Option<&[u8]>,
    encrypt: u8,
    data_field: &str,
) -> Result<Vec<u8>, CryptoError> {
    fn key(k: Option<&[u8]>) -> Result<&[u8], CryptoError> {
        k.filter(|k| !k.is_empty())
            .ok_or(CryptoError::MissingCipherKey)
    }
    match encrypt {
        0 => Ok(data_field.as_bytes().to_vec()),
        1 => inflate_zlib_or_gzip(&decode_foundation_base64_ignoring_unknown(data_field)?),
        2 => {
            let key = key(cipher_key)?;
            let raw = decode_foundation_base64_ignoring_unknown(&percent_decode(data_field))?;
            inflate_zlib_or_gzip(&gcm_decrypt16(key, &raw)?)
        }
        3 => {
            let key = key(cipher_key)?;
            let raw = decode_foundation_base64_ignoring_unknown(&percent_decode(data_field))?;
            gcm_decrypt16(key, &raw)
        }
        other => Err(CryptoError::UnsupportedEncryption(other)),
    }
}
