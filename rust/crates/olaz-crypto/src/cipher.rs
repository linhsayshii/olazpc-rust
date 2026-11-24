use crate::CryptoError;
use crate::lenient_base64::{decode_foundation_base64, decode_foundation_base64_ignoring_unknown};
use aes::{Aes128, Aes256};
use base64::{Engine as _, engine::general_purpose::STANDARD};
use cbc::cipher::{BlockModeDecrypt, BlockModeEncrypt, KeyIvInit, block_padding::Pkcs7};
use rand::RngExt as _;

/// `zsecureSecrets().getParamCipherKey()`: 32 ASCII chars used directly as an AES-256-CBC key.
pub const PARAM_CIPHER_KEY: &[u8; 32] = b"3FC4F0D2AB50057BCE0D90D9187A22B1";

/// All-zero 16-byte IV used by the Zalo request ciphers.
pub const ZERO_IV: [u8; 16] = [0; 16];

/// AES-128/256-CBC with PKCS#7 (strict on decrypt). Key must be 16 or 32 bytes, IV 16 bytes.
///
/// Decrypt rejects empty or non-block-aligned input with [`CryptoError::InvalidPadding`].
pub fn aes_cbc_crypt(
    input: &[u8],
    key: &[u8],
    iv: &[u8],
    encrypt: bool,
) -> Result<Vec<u8>, CryptoError> {
    if key.len() != 16 && key.len() != 32 {
        return Err(CryptoError::InvalidKeyLength(key.len()));
    }
    if iv.len() != 16 {
        return Err(CryptoError::InvalidIvLength(iv.len()));
    }
    if !encrypt && (input.is_empty() || !input.len().is_multiple_of(16)) {
        return Err(CryptoError::InvalidPadding);
    }
    // Lengths were validated above, so the constructors cannot fail.
    let bad_key = || CryptoError::InvalidKeyLength(key.len());
    if encrypt {
        Ok(if key.len() == 16 {
            cbc::Encryptor::<Aes128>::new_from_slices(key, iv)
                .map_err(|_| bad_key())?
                .encrypt_padded_vec::<Pkcs7>(input)
        } else {
            cbc::Encryptor::<Aes256>::new_from_slices(key, iv)
                .map_err(|_| bad_key())?
                .encrypt_padded_vec::<Pkcs7>(input)
        })
    } else if key.len() == 16 {
        cbc::Decryptor::<Aes128>::new_from_slices(key, iv)
            .map_err(|_| bad_key())?
            .decrypt_padded_vec::<Pkcs7>(input)
            .map_err(|_| CryptoError::InvalidPadding)
    } else {
        cbc::Decryptor::<Aes256>::new_from_slices(key, iv)
            .map_err(|_| bad_key())?
            .decrypt_padded_vec::<Pkcs7>(input)
            .map_err(|_| CryptoError::InvalidPadding)
    }
}

/// AES-CBC (zero IV, PKCS#7) of a UTF-8 string, Base64 encoded.
pub fn encode_aes(key: &[u8], plaintext: &str) -> Result<String, CryptoError> {
    encode_aes_data(key, plaintext.as_bytes())
}

/// AES-CBC (zero IV, PKCS#7) of raw bytes, Base64 encoded.
pub fn encode_aes_data(key: &[u8], data: &[u8]) -> Result<String, CryptoError> {
    Ok(STANDARD.encode(aes_cbc_crypt(data, key, &ZERO_IV, true)?))
}

/// AES-CBC (zero IV, PKCS#7) of a UTF-8 string, uppercase hex encoded.
pub fn encode_aes_hex_upper(key: &[u8], plaintext: &str) -> Result<String, CryptoError> {
    Ok(hex::encode_upper(aes_cbc_crypt(
        plaintext.as_bytes(),
        key,
        &ZERO_IV,
        true,
    )?))
}

/// Inverse of [`encode_aes`]; invalid UTF-8 is replaced with U+FFFD like Swift `String(decoding:)`.
pub fn decode_aes(key: &[u8], base64: &str) -> Result<String, CryptoError> {
    Ok(String::from_utf8_lossy(&decode_aes_data(key, base64)?).into_owned())
}

/// Trims whitespace, Base64-decodes ignoring unknown characters, then AES-CBC decrypts (zero IV).
pub fn decode_aes_data(key: &[u8], base64: &str) -> Result<Vec<u8>, CryptoError> {
    let raw = decode_foundation_base64_ignoring_unknown(base64.trim())?;
    aes_cbc_crypt(&raw, key, &ZERO_IV, false)
}

/// Parses `zpw_enk`: 16/32 raw ASCII bytes, else Base64 decoding to 16/32 bytes, else raw bytes.
pub fn parse_secret_key(zpw_enk: &str) -> Vec<u8> {
    let trimmed = zpw_enk.trim();
    if matches!(trimmed.len(), 16 | 32) {
        return trimmed.as_bytes().to_vec();
    }
    if let Ok(decoded) = decode_foundation_base64(trimmed)
        && matches!(decoded.len(), 16 | 32)
    {
        return decoded;
    }
    trimmed.as_bytes().to_vec()
}

/// Decodes a Base64 zCloud key (whitespace trimmed, unknown chars ignored); must be 16/32 bytes.
pub fn decode_cloud_key(base64_key: &str) -> Result<Vec<u8>, CryptoError> {
    let key = decode_foundation_base64_ignoring_unknown(base64_key.trim())?;
    if key.len() == 16 || key.len() == 32 {
        Ok(key)
    } else {
        Err(CryptoError::InvalidKeyLength(key.len()))
    }
}

/// zCloud encrypt: AES-CBC (PKCS#7) with a random IV, output `Base64(IV || ciphertext)`.
pub fn encode_cloud_aes(base64_key: &str, plaintext: &str) -> Result<String, CryptoError> {
    let mut iv = [0u8; 16];
    rand::rng().fill(&mut iv[..]);
    encode_cloud_aes_with_iv(base64_key, plaintext, &iv)
}

/// Same as [`encode_cloud_aes`] with a caller-supplied IV (deterministic, for tests).
pub fn encode_cloud_aes_with_iv(
    base64_key: &str,
    plaintext: &str,
    iv: &[u8; 16],
) -> Result<String, CryptoError> {
    let key = decode_cloud_key(base64_key)?;
    let cipher = aes_cbc_crypt(plaintext.as_bytes(), &key, iv, true)?;
    let mut blob = iv.to_vec();
    blob.extend_from_slice(&cipher);
    Ok(STANDARD.encode(blob))
}

/// zCloud decrypt of `Base64(IV(16) || ciphertext)`; needs more than 16 bytes in total.
pub fn decode_cloud_aes(base64_key: &str, base64_cipher: &str) -> Result<String, CryptoError> {
    let key = decode_cloud_key(base64_key)?;
    let raw = decode_foundation_base64_ignoring_unknown(base64_cipher.trim())?;
    if raw.len() <= 16 {
        return Err(CryptoError::InvalidPadding);
    }
    let (iv, cipher) = raw.split_at(16);
    let plain = aes_cbc_crypt(cipher, &key, iv, false)?;
    Ok(String::from_utf8_lossy(&plain).into_owned())
}
