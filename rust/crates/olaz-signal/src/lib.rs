//! Spike (wave 6b): libsignal over Zalo's persisted JS Signal state.
//!
//! Not wired into the app. The JS side (`libsignal-protocol.js` in JavaScriptCore) stays the
//! authority until the cutover wave; this crate proves a Rust implementation can read what JS
//! wrote, produce ciphertexts JS decrypts, and write records JS reads back (ADR-015).
//!
//! The pinned libsignal tag is patched (`rust/vendor/libsignal-protocol`, ZALO-PATCH.md): Zalo's
//! fork uses the KDF labels `ZaloText` / `ZaloRatchet` / `ZaloMessageKeys` and the version byte
//! `0x33`, where upstream uses `Whisper*` and `0x34`.

mod convert;
mod error;
mod js;
mod pb;
mod ratchet_ops;
mod store;

pub use convert::{
    ExportReport, ImportContext, ImportReport, SessionMeta, js_to_session, session_to_js,
};
pub use error::{Result, SignalError};
pub use js::{JsSessionRecord, JsStore};
pub use ratchet_ops::{CipherOut, zalo_address};
pub use store::{
    MemIdentityStore, MemPreKeyStore, MemSessionStore, MemSignedPreKeyStore, NoKyberStore,
    ZaloSignalStore,
};
