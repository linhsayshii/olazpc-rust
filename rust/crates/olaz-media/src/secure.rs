//! Stream decryption the official main process applies to e2ee / Zalo Cloud downloads
//! (Swift `SecureStream`):
//!
//! * `aes-256-ctr` + block: every `block_size` bytes are decrypted with a fresh cipher (same key /
//!   iv); a trailing partial block passes through unchanged.
//! * `aes-256-ctr` + linear: one cipher over the whole stream.
//! * `aes-256-gcm` + linear: whole stream, authenticated with `tag` (16 bytes); a file is only
//!   published by the caller after the tag verified.
//!
//! Streaming GCM is supported for 96-bit IVs (CTR from `IV || 2` plus GHASH over the ciphertext,
//! NIST SP 800-38D, empty AAD). A 128-bit IV is decrypted one-shot (bounded by [`GCM_ONE_SHOT_CAP`]);
//! other IV lengths are rejected (Swift accepted any length >= 12, live data only uses 12).

use std::fs::{self, File};
use std::io::{Read, Write};
use std::path::Path;

use aes::Aes256;
use aes::cipher::{BlockCipherEncrypt, KeyInit, KeyIvInit, StreamCipher};
use aes_gcm::aead::AeadInOut;
use ghash::GHash;
use ghash::universal_hash::UniversalHash;

/// GCM with a non-12-byte IV cannot stream with our GHASH; such bodies are limited to this size.
pub const GCM_ONE_SHOT_CAP: u64 = 256 << 20;

type Ctr = ctr::Ctr128BE<Aes256>;

/// Cipher failure (bad key / iv / tag, authentication failure, I/O). Carries no details on purpose.
#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
#[error("secure stream decrypt failed")]
pub struct DecryptError;

impl From<std::io::Error> for DecryptError {
    fn from(_: std::io::Error) -> Self {
        Self
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Algorithm {
    Ctr,
    Gcm,
}

/// A parsed, usable cipher description (Swift `SecureStream`).
#[derive(Clone, PartialEq, Eq)]
pub struct SecureSpec {
    pub algorithm: Algorithm,
    pub key: Vec<u8>,
    pub iv: Vec<u8>,
    pub tag: Option<Vec<u8>>,
    pub block: bool,
    pub block_size: usize,
}

impl std::fmt::Debug for SecureSpec {
    // Never print key material.
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("SecureSpec")
            .field("algorithm", &self.algorithm)
            .finish_non_exhaustive()
    }
}

/// What the request asked for (Swift `SecureStream.Parsed`).
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub enum SecureChoice {
    /// Bytes are saved as received.
    #[default]
    None,
    Stream(SecureSpec),
    /// A decryptable `type` with unusable cryptography: the download must fail, never save ciphertext.
    Invalid,
}

fn ctr_cipher(key: &[u8], iv: &[u8]) -> Result<Ctr, DecryptError> {
    Ctr::new_from_slices(key, iv).map_err(|_| DecryptError)
}

/// Streaming GCM state for a 96-bit IV.
struct GcmStream {
    cipher: Ctr,
    ghash: GHash,
    tag_mask: [u8; 16],
    length: u64,
    pending: Vec<u8>,
}

impl GcmStream {
    fn new(key: &[u8], iv: &[u8]) -> Result<Self, DecryptError> {
        let aes = Aes256::new_from_slice(key).map_err(|_| DecryptError)?;
        let mut h = [0_u8; 16].into();
        aes.encrypt_block(&mut h);
        let mut j0 = [0_u8; 16];
        j0[..12].copy_from_slice(iv);
        j0[15] = 1;
        let mut mask = j0.into();
        aes.encrypt_block(&mut mask);
        j0[15] = 2;
        Ok(Self {
            cipher: ctr_cipher(key, &j0)?,
            ghash: GHash::new(&h),
            tag_mask: mask.into(),
            length: 0,
            pending: Vec::new(),
        })
    }

    /// Decrypts `chunk` in place and feeds the ciphertext to GHASH.
    fn update(&mut self, chunk: &mut [u8]) {
        self.length += chunk.len() as u64;
        self.pending.extend_from_slice(chunk);
        let whole = self.pending.len() - self.pending.len() % 16;
        if whole > 0 {
            self.ghash.update_padded(&self.pending[..whole]);
            self.pending.drain(..whole);
        }
        self.cipher.apply_keystream(chunk);
    }

    fn verify(mut self, tag: &[u8]) -> bool {
        if !self.pending.is_empty() {
            self.ghash.update_padded(&self.pending);
        }
        let mut lengths = [0_u8; 16];
        lengths[8..].copy_from_slice(&self.length.wrapping_mul(8).to_be_bytes());
        self.ghash.update_padded(&lengths);
        let digest: [u8; 16] = self.ghash.finalize().into();
        let mut difference = 0_u8;
        for i in 0..16 {
            difference |= (digest[i] ^ self.tag_mask[i]) ^ tag[i];
        }
        difference == 0
    }
}

impl SecureSpec {
    fn check(&self) -> Result<(), DecryptError> {
        if self.key.len() != 32 {
            return Err(DecryptError);
        }
        match self.algorithm {
            Algorithm::Ctr if self.iv.len() != 16 => Err(DecryptError),
            Algorithm::Gcm
                if self.block
                    || self.tag.as_ref().is_none_or(|t| t.len() != 16)
                    || self.iv.len() < 12 =>
            {
                Err(DecryptError)
            }
            _ => Ok(()),
        }
    }

    fn ctr_block(&self, data: &[u8]) -> Result<Vec<u8>, DecryptError> {
        let mut out = data.to_vec();
        if !self.block {
            ctr_cipher(&self.key, &self.iv)?.apply_keystream(&mut out);
            return Ok(out);
        }
        let size = self.block_size.max(16);
        let whole = data.len() - data.len() % size;
        for chunk in out[..whole].chunks_mut(size) {
            ctr_cipher(&self.key, &self.iv)?.apply_keystream(chunk);
        }
        Ok(out) // overflow passes through
    }

    fn gcm_one_shot(&self, data: &[u8]) -> Result<Vec<u8>, DecryptError> {
        use aes_gcm::aes::Aes256 as Aes;
        use aes_gcm::{AesGcm, KeyInit as _, Nonce, Tag, aead::consts::U16};
        let tag = self.tag.as_deref().ok_or(DecryptError)?;
        let mut buf = data.to_vec();
        let tag = Tag::<U16>::try_from(tag).map_err(|_| DecryptError)?;
        match self.iv.len() {
            12 => {
                let c = aes_gcm::Aes256Gcm::new_from_slice(&self.key).map_err(|_| DecryptError)?;
                let nonce = Nonce::try_from(self.iv.as_slice()).map_err(|_| DecryptError)?;
                c.decrypt_inout_detached(&nonce, b"", buf.as_mut_slice().into(), &tag)
                    .map_err(|_| DecryptError)?;
            }
            16 => {
                let c = AesGcm::<Aes, U16>::new_from_slice(&self.key).map_err(|_| DecryptError)?;
                let nonce = Nonce::<U16>::try_from(self.iv.as_slice()).map_err(|_| DecryptError)?;
                c.decrypt_inout_detached(&nonce, b"", buf.as_mut_slice().into(), &tag)
                    .map_err(|_| DecryptError)?;
            }
            _ => return Err(DecryptError),
        }
        Ok(buf)
    }

    /// Whole-buffer decryption (photos; bounded by the caller's photo cap).
    pub fn decrypt(&self, data: &[u8]) -> Result<Vec<u8>, DecryptError> {
        self.check()?;
        match self.algorithm {
            Algorithm::Ctr => self.ctr_block(data),
            Algorithm::Gcm => self.gcm_one_shot(data),
        }
    }

    /// Streams `source` to `destination` (created here, removed on any failure) in constant
    /// memory. For GCM the tag is verified before returning.
    pub fn decrypt_file(&self, source: &Path, destination: &Path) -> Result<(), DecryptError> {
        let result = self.decrypt_file_inner(source, destination);
        if result.is_err() {
            let _ = fs::remove_file(destination);
        }
        result
    }

    fn decrypt_file_inner(&self, source: &Path, destination: &Path) -> Result<(), DecryptError> {
        self.check()?;
        let _ = fs::remove_file(destination);
        let mut input = File::open(source)?;
        let mut output = File::create(destination)?;
        const CHUNK: usize = 1 << 20;
        match self.algorithm {
            Algorithm::Ctr => {
                let size = self.block_size.max(16);
                let chunk = if self.block {
                    size * (CHUNK / size).max(1)
                } else {
                    CHUNK
                };
                let mut linear = if self.block {
                    None
                } else {
                    Some(ctr_cipher(&self.key, &self.iv)?)
                };
                let mut buf = vec![0_u8; chunk];
                loop {
                    let n = read_full(&mut input, &mut buf)?;
                    if n == 0 {
                        break;
                    }
                    match linear.as_mut() {
                        Some(cipher) => {
                            cipher.apply_keystream(&mut buf[..n]);
                            output.write_all(&buf[..n])?;
                        }
                        None => output.write_all(&self.ctr_block(&buf[..n])?)?,
                    }
                }
            }
            Algorithm::Gcm => {
                let tag = self.tag.as_deref().ok_or(DecryptError)?;
                if self.iv.len() == 12 {
                    let mut gcm = GcmStream::new(&self.key, &self.iv)?;
                    let mut buf = vec![0_u8; CHUNK];
                    loop {
                        let n = read_full(&mut input, &mut buf)?;
                        if n == 0 {
                            break;
                        }
                        gcm.update(&mut buf[..n]);
                        output.write_all(&buf[..n])?;
                    }
                    if !gcm.verify(tag) {
                        return Err(DecryptError);
                    }
                } else {
                    let size = input.metadata()?.len();
                    if size > GCM_ONE_SHOT_CAP {
                        return Err(DecryptError);
                    }
                    let mut data = Vec::new();
                    input.read_to_end(&mut data)?;
                    output.write_all(&self.gcm_one_shot(&data)?)?;
                }
            }
        }
        output.sync_all()?;
        Ok(())
    }
}

/// Reads until `buf` is full or EOF (so block-mode chunks stay multiples of the block size).
fn read_full(input: &mut File, buf: &mut [u8]) -> std::io::Result<usize> {
    let mut filled = 0;
    while filled < buf.len() {
        let n = input.read(&mut buf[filled..])?;
        if n == 0 {
            break;
        }
        filled += n;
    }
    Ok(filled)
}

/// Linear AES-256-GCM encryption (Swift `SecureStream.encryptE2EEFile`): returns the ciphertext
/// and the 60-byte `key(32) + iv(12) + tag(16)` session token. `key` / `iv` are caller-provided
/// random bytes so the function stays deterministic and testable.
pub fn encrypt_e2ee_file(
    plaintext: &[u8],
    key: &[u8; 32],
    iv: &[u8; 12],
) -> Result<(Vec<u8>, Vec<u8>), DecryptError> {
    let cipher = aes_gcm::Aes256Gcm::new_from_slice(key).map_err(|_| DecryptError)?;
    let nonce = aes_gcm::Nonce::try_from(iv.as_slice()).map_err(|_| DecryptError)?;
    let mut buf = plaintext.to_vec();
    let tag = cipher
        .encrypt_inout_detached(&nonce, b"", buf.as_mut_slice().into())
        .map_err(|_| DecryptError)?;
    let mut token = Vec::with_capacity(60);
    token.extend_from_slice(key);
    token.extend_from_slice(iv);
    token.extend_from_slice(tag.as_slice());
    Ok((buf, token))
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used)]

    use super::*;

    fn pattern(len: usize) -> Vec<u8> {
        (0..len).map(|i| (i * 7 + 3) as u8).collect()
    }

    fn gcm_spec(key: &[u8; 32], iv: &[u8; 12], tag: &[u8]) -> SecureSpec {
        SecureSpec {
            algorithm: Algorithm::Gcm,
            key: key.to_vec(),
            iv: iv.to_vec(),
            tag: Some(tag.to_vec()),
            block: false,
            block_size: 4096,
        }
    }

    #[test]
    fn gcm_roundtrip_one_shot_and_streaming_agree() {
        let key = [9_u8; 32];
        let iv = [4_u8; 12];
        for len in [0, 1, 15, 16, 17, 4095, 4096, 100_003, (1 << 20) + 5] {
            let plain = pattern(len);
            let (ct, token) = encrypt_e2ee_file(&plain, &key, &iv).unwrap();
            assert_eq!(token.len(), 60);
            let spec = gcm_spec(&key, &iv, &token[44..]);
            assert_eq!(spec.decrypt(&ct).unwrap(), plain, "one-shot len {len}");
            let dir = tempfile::tempdir().unwrap();
            let (src, dst) = (dir.path().join("s"), dir.path().join("d"));
            fs::write(&src, &ct).unwrap();
            spec.decrypt_file(&src, &dst).unwrap();
            assert_eq!(fs::read(&dst).unwrap(), plain, "stream len {len}");
        }
    }

    #[test]
    fn gcm_tamper_fails_and_leaves_no_file() {
        let key = [1_u8; 32];
        let iv = [2_u8; 12];
        let plain = pattern(5000);
        let (mut ct, token) = encrypt_e2ee_file(&plain, &key, &iv).unwrap();
        let spec = gcm_spec(&key, &iv, &token[44..]);
        ct[100] ^= 1;
        assert!(spec.decrypt(&ct).is_err());
        let dir = tempfile::tempdir().unwrap();
        let (src, dst) = (dir.path().join("s"), dir.path().join("d"));
        fs::write(&src, &ct).unwrap();
        assert!(spec.decrypt_file(&src, &dst).is_err());
        assert!(!dst.exists());
        let bad_tag = gcm_spec(&key, &iv, &[0_u8; 16]);
        assert!(bad_tag.decrypt(&ct).is_err());
    }

    /// RFC / NIST GCM test case 14 (AES-256, zero key, zero iv, 16 zero bytes).
    #[test]
    fn gcm_nist_vector() {
        let ct = hex("cea7403d4d606b6e074ec5d3baf39d18");
        let tag = hex("d0d1c8a799996bf0265b98b5d48ab919");
        let spec = SecureSpec {
            algorithm: Algorithm::Gcm,
            key: vec![0; 32],
            iv: vec![0; 12],
            tag: Some(tag),
            block: false,
            block_size: 4096,
        };
        assert_eq!(spec.decrypt(&ct).unwrap(), vec![0_u8; 16]);
        let dir = tempfile::tempdir().unwrap();
        let (src, dst) = (dir.path().join("s"), dir.path().join("d"));
        fs::write(&src, &ct).unwrap();
        spec.decrypt_file(&src, &dst).unwrap();
        assert_eq!(fs::read(&dst).unwrap(), vec![0_u8; 16]);
    }

    /// NIST SP 800-38A F.5.5 CTR-AES256 (first two blocks, linear mode).
    #[test]
    fn ctr_nist_vector_linear() {
        let spec = SecureSpec {
            algorithm: Algorithm::Ctr,
            key: hex("603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4"),
            iv: hex("f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff"),
            tag: None,
            block: false,
            block_size: 4096,
        };
        let ct = hex("601ec313775789a5b7a7f504bbf3d228f443e3ca4d62b59aca84e990cacaf5c5");
        assert_eq!(
            spec.decrypt(&ct).unwrap(),
            hex("6bc1bee22e409f96e93d7e117393172aae2d8a571e03ac9c9eb76fac45af8e51")
        );
    }

    #[test]
    fn ctr_block_mode_restarts_per_block_and_passes_overflow() {
        let key = vec![5_u8; 32];
        let iv = vec![6_u8; 16];
        let block = SecureSpec {
            algorithm: Algorithm::Ctr,
            key: key.clone(),
            iv: iv.clone(),
            tag: None,
            block: true,
            block_size: 32,
        };
        let linear = SecureSpec {
            block: false,
            ..block.clone()
        };
        let data = pattern(32 * 3 + 10);
        let out = block.decrypt(&data).unwrap();
        // Each 32-byte block is the linear decryption of that block alone.
        for i in 0..3 {
            let piece = &data[i * 32..(i + 1) * 32];
            assert_eq!(
                &out[i * 32..(i + 1) * 32],
                linear.decrypt(piece).unwrap().as_slice()
            );
        }
        assert_eq!(
            &out[96..],
            &data[96..],
            "trailing partial block passes through"
        );
        // File streaming over several chunks equals one-shot.
        let big = pattern(3 * (1 << 20) + 1234);
        let dir = tempfile::tempdir().unwrap();
        let (src, dst) = (dir.path().join("s"), dir.path().join("d"));
        fs::write(&src, &big).unwrap();
        let block4k = SecureSpec {
            block_size: 4096,
            ..block
        };
        block4k.decrypt_file(&src, &dst).unwrap();
        assert_eq!(fs::read(&dst).unwrap(), block4k.decrypt(&big).unwrap());
        let linear2 = SecureSpec {
            block_size: 4096,
            ..linear
        };
        linear2.decrypt_file(&src, &dst).unwrap();
        assert_eq!(fs::read(&dst).unwrap(), linear2.decrypt(&big).unwrap());
    }

    #[test]
    fn invalid_specs_are_rejected() {
        let spec = SecureSpec {
            algorithm: Algorithm::Ctr,
            key: vec![0; 31],
            iv: vec![0; 16],
            tag: None,
            block: false,
            block_size: 4096,
        };
        assert!(spec.decrypt(b"x").is_err());
        let short_iv = SecureSpec {
            key: vec![0; 32],
            iv: vec![0; 12],
            ..spec.clone()
        };
        assert!(short_iv.decrypt(b"x").is_err());
        let gcm_block = SecureSpec {
            algorithm: Algorithm::Gcm,
            key: vec![0; 32],
            iv: vec![0; 12],
            tag: Some(vec![0; 16]),
            block: true,
            block_size: 4096,
        };
        assert!(gcm_block.decrypt(b"x").is_err());
    }

    fn hex(s: &str) -> Vec<u8> {
        (0..s.len() / 2)
            .map(|i| u8::from_str_radix(&s[2 * i..2 * i + 2], 16).unwrap())
            .collect()
    }
}
