//! Olaz `zpw_ws` realtime channel: pure state machine plus (feature `transport`) a tokio transport.
//!
//! Port of the logic in `ZaloWebSocket.swift` that does not need a live
//! connection: frame codec, event model, queue cursors, request/file waiter
//! bookkeeping, reconnect policy and URL building. See `ARCH.md`.

pub mod consts;
pub mod core;
pub mod event;
pub mod files;
pub mod frame;
pub mod json;
pub mod policy;
pub mod queue;
pub mod requests;

pub use crate::core::{
    CloseRequest, DecryptError, FrameDecryptor, FrameOutcome, PreparedRequest, ResolvedRequest,
    WsCore,
};
pub use crate::event::WsEvent;
pub use crate::files::{FileDone, FileWait, FileWaiters, FileWake, WaiterToken};
pub use crate::frame::{Frame, FrameError, decode_frame, encode_frame, encode_request_frame};
pub use crate::policy::{ReconnectPolicy, build_socket_url, connect_headers};
pub use crate::queue::{QueueCursors, WsQueue, WsQueueCursorSnapshot};
pub use crate::requests::RequestWaiters;

#[cfg(feature = "transport")]
pub mod transport;
#[cfg(feature = "transport")]
pub use crate::transport::{
    CryptoDecryptor, CursorMap, CursorObserver, WsClient, WsConfig, WsHandle, WsTimings,
};
