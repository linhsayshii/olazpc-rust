use crate::cipher::{PARAM_CIPHER_KEY, encode_aes, encode_aes_hex_upper};
use crate::{CryptoError, md5_hex, random_hex, sha256_hex_upper};
use serde_json::Value;
use std::collections::BTreeMap;

/// Prefix mixed into the password-cipher key derivation.
pub const PASSWORD_KEY_PREFIX: &str = "9fc5vEW3";

/// `getSignKey(tag, params)` = `md5("zsecure" + tag + values joined in ascending key order)`.
///
/// Keys sort by byte order (Swift sorts by Unicode scalars; identical for ASCII keys).
pub fn sign_key(tag: &str, params: &BTreeMap<String, String>) -> String {
    let mut buffer = format!("zsecure{tag}");
    for value in params.values() {
        buffer.push_str(value);
    }
    md5_hex(buffer)
}

fn even_chars(s: &str) -> Vec<char> {
    s.chars().step_by(2).collect()
}

fn odd_chars(s: &str) -> Vec<char> {
    s.chars().skip(1).step_by(2).collect()
}

/// Encrypts a login password: AES-CBC of `salt + reverse(password)` under a key derived from
/// `SHA256_UPPER("9fc5vEW3-phone-imei-salt")`, Base64 encoded.
pub fn encrypt_password(
    phone: &str,
    imei: &str,
    password: &str,
    salt: &str,
) -> Result<String, CryptoError> {
    let hex = sha256_hex_upper(format!("{PASSWORD_KEY_PREFIX}-{phone}-{imei}-{salt}"));
    let even = even_chars(&hex);
    let odd = odd_chars(&hex);
    let enk: String = even
        .iter()
        .take(16)
        .chain(odd.iter().rev().take(16))
        .collect();
    let reversed: String = password.chars().rev().collect();
    encode_aes(enk.as_bytes(), &format!("{salt}{reversed}"))
}

/// ParamCipher v2: encrypts request `params` and signs the request.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParamCipher {
    zcid: String,
    zcid_ext: String,
    encrypt_key: String,
}

impl ParamCipher {
    /// Builds a cipher with a random `zcid_ext` (10 hex chars).
    pub fn new(api_type: &str, imei: &str, first_launch_time_ms: i64) -> Result<Self, CryptoError> {
        Self::with_zcid_ext(api_type, imei, first_launch_time_ms, random_hex(10))
    }

    /// Builds a cipher with a caller-supplied `zcid_ext` (deterministic, for tests).
    pub fn with_zcid_ext(
        api_type: &str,
        imei: &str,
        first_launch_time_ms: i64,
        zcid_ext: String,
    ) -> Result<Self, CryptoError> {
        let plain = format!("{api_type},{imei},{first_launch_time_ms}");
        let zcid = encode_aes_hex_upper(PARAM_CIPHER_KEY, &plain)?;
        let md5_upper = md5_hex(&zcid_ext).to_uppercase();
        let n_even = even_chars(&md5_upper);
        let a_even = even_chars(&zcid);
        let a_odd = odd_chars(&zcid);
        let encrypt_key: String = n_even
            .iter()
            .take(8)
            .chain(a_even.iter().take(12))
            .chain(a_odd.iter().rev().take(12))
            .collect();
        Ok(Self {
            zcid,
            zcid_ext,
            encrypt_key,
        })
    }

    /// Uppercase-hex AES of `apiType,imei,firstLaunchTimeMs`.
    pub fn zcid(&self) -> &str {
        &self.zcid
    }

    /// Per-session random hex suffix sent as `zcid_ext`.
    pub fn zcid_ext(&self) -> &str {
        &self.zcid_ext
    }

    /// Derived 32-char AES-256 key (as text).
    pub fn encrypt_key(&self) -> &str {
        &self.encrypt_key
    }

    /// Derived key bytes.
    pub fn key_data(&self) -> &[u8] {
        self.encrypt_key.as_bytes()
    }

    /// AES-CBC (zero IV) + Base64 of a JSON text.
    pub fn encrypt_payload_str(&self, payload_json: &str) -> Result<String, CryptoError> {
        encode_aes(self.key_data(), payload_json)
    }

    /// Serializes `payload` compactly (object keys sorted, `/` not escaped) then encrypts it.
    pub fn encrypt_payload(&self, payload: &Value) -> Result<String, CryptoError> {
        let json = serde_json::to_string(payload).map_err(|e| CryptoError::Json(e.to_string()))?;
        self.encrypt_payload_str(&json)
    }

    /// Builds the signed request params (`zcid`, `zcid_ext`, `enc_ver`, `params`, `type`,
    /// `client_version`, `signkey`).
    pub fn build_signed_params(
        &self,
        api_type: &str,
        client_version: &str,
        payload: &Value,
        tag: &str,
    ) -> Result<BTreeMap<String, String>, CryptoError> {
        let mut map = BTreeMap::from([
            ("zcid".to_owned(), self.zcid.clone()),
            ("zcid_ext".to_owned(), self.zcid_ext.clone()),
            ("enc_ver".to_owned(), "v2".to_owned()),
            ("params".to_owned(), self.encrypt_payload(payload)?),
            ("type".to_owned(), api_type.to_owned()),
            ("client_version".to_owned(), client_version.to_owned()),
        ]);
        let signkey = sign_key(tag, &map);
        map.insert("signkey".to_owned(), signkey);
        Ok(map)
    }
}
