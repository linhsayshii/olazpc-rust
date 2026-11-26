use md5::{Digest as _, Md5};
use rand::RngExt as _;
use sha2::Sha256;

/// Lowercase hex MD5 of bytes or a string (UTF-8).
pub fn md5_hex(data: impl AsRef<[u8]>) -> String {
    hex::encode(Md5::digest(data.as_ref()))
}

/// Lowercase hex SHA-256 of bytes or a string (UTF-8).
pub fn sha256_hex(data: impl AsRef<[u8]>) -> String {
    hex::encode(Sha256::digest(data.as_ref()))
}

/// Uppercase hex SHA-256 of bytes or a string (UTF-8).
pub fn sha256_hex_upper(data: impl AsRef<[u8]>) -> String {
    hex::encode_upper(Sha256::digest(data.as_ref()))
}

/// Random lowercase hex string of exactly `length` characters ("" when `length` is 0).
pub fn random_hex(length: usize) -> String {
    if length == 0 {
        return String::new();
    }
    let mut bytes = vec![0u8; length.div_ceil(2)];
    rand::rng().fill(&mut bytes[..]);
    let mut s = hex::encode(bytes);
    s.truncate(length);
    s
}

/// Random string over `[0-9A-Za-z]` of `length` characters.
pub fn random_alphanumeric(length: usize) -> String {
    const ALPHABET: &[u8; 62] = b"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
    let mut bytes = vec![0u8; length];
    rand::rng().fill(&mut bytes[..]);
    bytes
        .into_iter()
        .map(|b| char::from(ALPHABET[usize::from(b) % ALPHABET.len()]))
        .collect()
}

/// Random salt over `[a-z0-9]` of `length` characters (Swift default is 8).
pub fn random_salt(length: usize) -> String {
    const ALPHABET: &[u8; 36] = b"abcdefghijklmnopqrstuvwxyz0123456789";
    let mut bytes = vec![0u8; length];
    rand::rng().fill(&mut bytes[..]);
    bytes
        .into_iter()
        .map(|b| char::from(ALPHABET[usize::from(b) % ALPHABET.len()]))
        .collect()
}
