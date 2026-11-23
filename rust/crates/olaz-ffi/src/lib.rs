//! UniFFI bridge between the Olaz Rust core and the SwiftUI app (ADR-002).
//!
//! Exported surface (Swift module `OlazCore`, see `uniffi.toml`):
//!
//! | Area | Items |
//! |---|---|
//! | misc | [`core_version`] |
//! | store | [`CoreStore`] (+ [`ConversationRow`], [`MessageRow`], [`MessagesAroundRow`]) |
//! | session | [`CoreSession`] (restore/snapshot, QR login, status), [`QrListener`] |
//! | api | [`CoreApi`] over a shared [`CoreSession`], [`poll_state_initial`] |
//! | http | [`CoreHttp`]: generic signed GET / POST / multipart for every other endpoint |
//! | wire | [`parse_wire_event`], [`parse_wire_batch`] -> [`WireEvent`] |
//! | crypto | [`decrypt_ws_frame`], [`inflate`] |
//! | websocket | [`ws_start`] -> [`WsSession`], callbacks via [`WsListener`] |
//!
//! # Threading
//!
//! * One process-wide tokio multi-thread runtime (2 workers, see `runtime`) runs every async
//!   export. Async exports never need a tokio context on the caller: Swift awaits an executor-
//!   agnostic future that completes when the runtime task finishes, so they are safe to `await`
//!   from any actor (including `@MainActor`) without blocking it.
//! * Blocking SQLite work runs on tokio's blocking pool, never on a worker.
//! * `CoreSession` / `CoreApi` network calls are async and run on the same runtime; `restore`,
//!   `snapshot_json`, `mark_expired`, `clear_session` are sync and instant. [`QrListener`] callbacks
//!   follow the same blocking-pool rules as [`WsListener`] and have all returned before
//!   `wait_for_qr_scan` resolves.
//! * Pure functions (`parse_wire_event`, `decrypt_ws_frame`, `inflate`, `core_version`) are
//!   synchronous and run on the calling thread; they are microseconds-fast for single frames.
//!   Call them from a background task for very large batches.
//! * [`WsListener`] callbacks are invoked on tokio's blocking pool, one at a time and in order per
//!   session, never on a runtime worker and never concurrently with each other. They must return
//!   quickly: hand the value to an `AsyncStream` continuation or hop with `Task { @MainActor in }`
//!   and return. A slow callback only back-pressures that one session (the transport's bounded
//!   event channel fills up), it cannot stall the runtime.

mod api;
mod chat;
mod crypto;
mod error;
mod http;
mod runtime;
mod session;
mod store;
mod wire;
mod ws;

pub use api::{
    CoreApi, HistoryRecord, MentionRecord, PollOutcomeRecord, PollQueueRecord, PollStateRecord,
    SendResultRecord, SendTextRecord, poll_state_initial,
};
pub use chat::*;
pub use crypto::{decrypt_ws_frame, inflate};
pub use error::{CoreError, NetworkKind};
pub use http::{CoreHttp, HttpMethod, HttpRequestRecord, UploadPartRecord};
pub use session::{CoreSession, CoreSessionStatus, QrListener, QrScanRecord, QrTicketRecord};
pub use store::{
    ConversationRow, CoreStore, MessageRow, MessagesAroundRow, StoredChat, StoredChatAround,
};
pub use wire::{
    NameEntry, WireEvent, WireOptions, WireStored, parse_wire_batch, parse_wire_batch_bytes,
    parse_wire_event,
};
pub use ws::{
    CursorEntry, TypedEnvelope, WireParseProbe, WirePayload, WsConfigRecord, WsEventRecord,
    WsListener, WsSession, ws_start,
};

uniffi::setup_scaffolding!();

/// Version of the Rust core (the `olaz-ffi` crate version).
#[uniffi::export]
#[must_use]
pub fn core_version() -> String {
    env!("CARGO_PKG_VERSION").to_owned()
}

#[cfg(test)]
mod perf;
#[cfg(test)]
mod tests;
