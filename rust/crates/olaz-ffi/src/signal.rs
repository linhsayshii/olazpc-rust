//! `CoreSignal`: the Rust Signal store (`olaz-signal`, ADR-015) behind the 1-1 E2EE path.
//!
//! The object mirrors what `ZaloE2EE.pc.*` (`zalo-e2ee.js`) exposes to `ZaloE2EEManager`, over ONE
//! store that reads and writes the exact `zaloE2EEPCStoreV1` JSON the JS library persists:
//!
//! | JS (`ZaloE2EE.pc.`) | Rust |
//! |---|---|
//! | `initOrRestore(uid, saved)` | [`signal_init_or_restore`] -> [`CoreSignal`], `restored()`, `registration_id()`, `bundle_payload_json()`, `export_store_json()` |
//! | `exportStore` | [`CoreSignal::export_store_json`] |
//! | `refillPreKeys` | [`CoreSignal::refill_pre_keys`] |
//! | `decryptCipher` | [`CoreSignal::decrypt_cipher`] (raw plaintext bytes; text / uint32 framing stays in Swift) |
//! | `encryptCipher` / `encryptBatch` | [`CoreSignal::encrypt_cipher`] (the batch loop stays in Swift) |
//! | `hasSession` / `listSessions` | [`CoreSignal::has_session`] / [`CoreSignal::list_sessions`] |
//! | `processPreKeyBundle` | [`CoreSignal::process_prekey_bundle`] |
//!
//! [`signal_shadow_decrypt`] is the shadow-mode entry point: load a store snapshot, decrypt one
//! cipher, drop the store. Nothing is persisted.
//!
//! # Threading and cancellation
//!
//! The libsignal store traits are `?Send` futures that never actually suspend (in-memory
//! stores), so every export runs the work on tokio's blocking pool and drives the future with
//! `Handle::block_on` there. Calls on one object are serialised by a mutex. Each call is
//! milliseconds long (one X3DH or ratchet step), so ADR-014's explicit cancel token is not
//! needed: a dropped Swift task simply ignores the result.
//!
//! # Errors
//!
//! [`CoreError::Crypto`] / [`CoreError::Parse`] carry only a short class name (see
//! `SignalError::kind`), never uids, keys or ciphertext (ADR-008).

use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use olaz_signal::{SignalError, ZaloSignalStore};
use tokio::runtime::Handle;

use crate::error::CoreError;
use crate::runtime::{blocking, runtime};

fn map_err(e: SignalError) -> CoreError {
    let message = e.kind();
    match e {
        SignalError::Json(_)
        | SignalError::Base64(_)
        | SignalError::Proto(_)
        | SignalError::Format(_) => CoreError::Parse { message },
        SignalError::Protocol(_) | SignalError::Curve(_) => CoreError::Crypto { message },
    }
}

fn lock(m: &Mutex<ZaloSignalStore>) -> MutexGuard<'_, ZaloSignalStore> {
    m.lock().unwrap_or_else(PoisonError::into_inner)
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| i64::try_from(d.as_millis()).unwrap_or(0))
        .unwrap_or(0)
}

/// Result of an encrypt: what `encryptCipher` returns in JS.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SignalCipherRecord {
    /// base64 of `[type][libsignal message]`, the wire cipher.
    pub cipher: String,
    /// 3 = PreKeyWhisperMessage, 1 = WhisperMessage.
    pub message_type: u8,
    /// Remote registration id of the session used.
    pub registration_id: u32,
}

/// One open session of a peer (`listSessions` row).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SignalSessionRecord {
    pub device_id: u32,
    pub registration_id: u32,
}

/// A generated one-time prekey as uploaded in `opKeys`.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SignalPreKeyRecord {
    pub id: u32,
    /// base64 of the 33-byte public key.
    pub key: String,
}

/// The Zalo PC device's Signal store.
#[derive(uniffi::Object)]
pub struct CoreSignal {
    inner: Arc<Mutex<ZaloSignalStore>>,
    restored: bool,
    registration_id: u32,
}

impl CoreSignal {
    /// Runs `f` against the locked store on the blocking pool.
    async fn with<T, F>(&self, f: F) -> Result<T, CoreError>
    where
        T: Send + 'static,
        F: FnOnce(&mut ZaloSignalStore, &Handle) -> Result<T, SignalError> + Send + 'static,
    {
        let handle = runtime()?.handle().clone();
        let inner = Arc::clone(&self.inner);
        blocking(move || f(&mut lock(&inner), &handle))
            .await?
            .map_err(map_err)
    }
}

/// `initOrRestore`: loads the saved `zaloE2EEPCStoreV1` JSON (`""` for none, which generates a
/// fresh identity, signed prekey and 25 one-time prekeys). A non-empty value that does not parse
/// is an error (JS would silently regenerate the identity; see `ZaloSignalStore::init_or_restore`).
#[uniffi::export]
pub async fn signal_init_or_restore(saved_json: String) -> Result<Arc<CoreSignal>, CoreError> {
    let (store, restored) = blocking(move || {
        let mut rng = rand::rng();
        ZaloSignalStore::init_or_restore(&saved_json, &mut rng)
    })
    .await?
    .map_err(map_err)?;
    let registration_id = store.identity.registration_id;
    Ok(Arc::new(CoreSignal {
        inner: Arc::new(Mutex::new(store)),
        restored,
        registration_id,
    }))
}

/// Shadow decrypt: loads `store_json` into a throw-away store, decrypts one cipher as
/// `decryptCipher(sender_uid, device, cipher)` would and returns the plaintext bytes. The store
/// is dropped afterwards; nothing is written anywhere.
#[uniffi::export]
pub async fn signal_shadow_decrypt(
    store_json: String,
    sender_uid: String,
    device: u32,
    cipher_b64: String,
) -> Result<Vec<u8>, CoreError> {
    let handle = runtime()?.handle().clone();
    blocking(move || {
        let mut store = ZaloSignalStore::from_js_json(&store_json, now_ms().unsigned_abs())?;
        let mut rng = rand::rng();
        handle.block_on(store.decrypt_cipher(&sender_uid, device, &cipher_b64, &mut rng))
    })
    .await?
    .map_err(map_err)
}

#[uniffi::export]
impl CoreSignal {
    /// True when the store came from saved JSON, false for a freshly generated identity.
    pub fn restored(&self) -> bool {
        self.restored
    }

    /// The local registration id (`iKey.id` of the bundle).
    pub fn registration_id(&self) -> u32 {
        self.registration_id
    }

    /// `buildSubmitBundlePayload` as JSON text.
    pub async fn bundle_payload_json(&self) -> Result<String, CoreError> {
        self.with(|s, _| Ok(s.bundle_payload()?.to_string())).await
    }

    /// The whole store as `zaloE2EEPCStoreV1` JSON (what `exportStore` returns).
    pub async fn export_store_json(&self) -> Result<String, CoreError> {
        self.with(|s, _| s.to_js_json(now_ms())).await
    }

    /// `refillPreKeys`: new one-time prekeys for the `opKeys` upload.
    pub async fn refill_pre_keys(&self, count: u32) -> Result<Vec<SignalPreKeyRecord>, CoreError> {
        self.with(move |s, _| {
            let mut rng = rand::rng();
            Ok(s.refill_pre_keys(count, &mut rng)
                .into_iter()
                .map(|(id, key)| SignalPreKeyRecord { id, key })
                .collect())
        })
        .await
    }

    /// `decryptCipher`: the raw plaintext of a wire cipher from `sender_uid` / `device`.
    pub async fn decrypt_cipher(
        &self,
        sender_uid: String,
        device: u32,
        cipher_b64: String,
    ) -> Result<Vec<u8>, CoreError> {
        self.with(move |s, h| {
            let mut rng = rand::rng();
            h.block_on(s.decrypt_cipher(&sender_uid, device, &cipher_b64, &mut rng))
        })
        .await
    }

    /// `encryptCipher`: encrypts `plaintext` for the open session with `remote_uid` / `device`.
    pub async fn encrypt_cipher(
        &self,
        remote_uid: String,
        device: u32,
        plaintext: Vec<u8>,
    ) -> Result<SignalCipherRecord, CoreError> {
        self.with(move |s, h| {
            let out = h.block_on(s.encrypt_cipher(&remote_uid, device, &plaintext))?;
            Ok(SignalCipherRecord {
                cipher: out.cipher,
                message_type: out.message_type,
                registration_id: out.registration_id,
            })
        })
        .await
    }

    /// `processPreKeyBundle`: starts a session from a server bundle (`bundle_json` is either
    /// shape the JS accepts: `{key:{preKey,opKeys}}` / `{preKey, opKey}` or the flat
    /// `{identityKey, signedPreKey, preKey}`). Retries once after dropping a changed identity pin,
    /// like the JS glue.
    pub async fn process_prekey_bundle(
        &self,
        remote_uid: String,
        device: u32,
        bundle_json: String,
    ) -> Result<(), CoreError> {
        self.with(move |s, h| {
            let bundle: serde_json::Value = serde_json::from_str(&bundle_json)?;
            let mut rng = rand::rng();
            h.block_on(s.process_bundle(&remote_uid, device, &bundle, &mut rng))
        })
        .await
    }

    /// `hasSession`.
    pub async fn has_session(&self, remote_uid: String, device: u32) -> Result<bool, CoreError> {
        self.with(move |s, h| Ok(h.block_on(s.has_session(&remote_uid, device))))
            .await
    }

    /// `listSessions`: open sessions of devices 0...3.
    pub async fn list_sessions(
        &self,
        remote_uid: String,
    ) -> Result<Vec<SignalSessionRecord>, CoreError> {
        self.with(move |s, h| {
            Ok(h.block_on(s.list_sessions(&remote_uid))
                .into_iter()
                .map(|(device_id, registration_id)| SignalSessionRecord {
                    device_id,
                    registration_id,
                })
                .collect())
        })
        .await
    }
}
