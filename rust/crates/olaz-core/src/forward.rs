//! U8 forward domain state and value types.
//!
//! `ForwardRequest` is owned by the core (`state.forward.request`) and mirrored to Swift via
//! `DirtyKey::ForwardRequest`. Message multi-select remains Swift-owned (U6); `forwardSelection`
//! passes the ordered list of selected messages into `Command::ForwardSelection`, and `ForwardAll`
//! asks Swift to clear selection via `DirtyKey::ForwardClearSelection` when a multi-message
//! forward succeeds.

use std::collections::BTreeMap;
use std::fmt;

use olaz_wire::{ChatMessage, ContactCard};

use crate::effect::{Effect, OpResult};
use crate::reduce::ReduceOutput;

/// An active forward picker request (`ZaloEngine.forwardRequest`).
#[derive(Clone, PartialEq)]
pub struct ForwardRequest {
    pub id: u64,
    pub conversation_id: String,
    pub message: ChatMessage,
    /// Additional selected messages (oldest first) forwarded after `message`.
    pub more: Vec<ChatMessage>,
}

impl ForwardRequest {
    /// All messages carried by this request (`message` followed by `more`).
    #[must_use]
    pub fn all_messages(&self) -> Vec<ChatMessage> {
        let mut out = Vec::with_capacity(1 + self.more.len());
        out.push(self.message.clone());
        out.extend(self.more.iter().cloned());
        out
    }
}

impl fmt::Debug for ForwardRequest {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ForwardRequest")
            .field("id", &self.id)
            .field("more_count", &self.more.len())
            .finish()
    }
}

/// Result of a `forward` or `forward_all` command (subset of Swift `MessageActionOutcome`).
#[derive(Clone, PartialEq, Eq)]
pub enum ForwardOutcome {
    Done(Option<String>),
    Pending(String),
    Failed(String),
}

impl fmt::Debug for ForwardOutcome {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Done(t) => f
                .debug_struct("Done")
                .field("has_text", &t.is_some())
                .finish(),
            Self::Pending(_) => f.write_str("Pending"),
            Self::Failed(_) => f.write_str("Failed"),
        }
    }
}

/// Host return value for `HostCall::ResolveMedia` (Swift `MediaResolution`).
#[derive(Clone, PartialEq, Eq)]
pub enum MediaResolutionOutcome {
    File(String),
    Expired,
    Unsupported,
    Unavailable,
}

impl fmt::Debug for MediaResolutionOutcome {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::File(_) => f.write_str("File"),
            Self::Expired => f.write_str("Expired"),
            Self::Unsupported => f.write_str("Unsupported"),
            Self::Unavailable => f.write_str("Unavailable"),
        }
    }
}

/// Host return value for `HostCall::ResolveFile` (Swift `FileResolution`).
#[derive(Clone, PartialEq, Eq)]
pub enum FileResolutionOutcome {
    Ready(String),
    Expired,
    Failed(String),
}

impl fmt::Debug for FileResolutionOutcome {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Ready(_) => f.write_str("Ready"),
            Self::Expired => f.write_str("Expired"),
            Self::Failed(_) => f.write_str("Failed"),
        }
    }
}

/// Host return value for `HostCall::SendMedia` / `HostCall::SendFiles` (Swift `ComposerOutcome`).
#[derive(Clone, PartialEq, Eq)]
pub enum ComposerSendOutcome {
    Done,
    Cancelled,
    Pending(String),
    Failed(String),
}

impl fmt::Debug for ComposerSendOutcome {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Done => f.write_str("Done"),
            Self::Cancelled => f.write_str("Cancelled"),
            Self::Pending(_) => f.write_str("Pending"),
            Self::Failed(_) => f.write_str("Failed"),
        }
    }
}

/// Which client-id-consuming step is awaiting `Input::ForwardClientIdAllocated`.
#[derive(Clone)]
pub(crate) enum ForwardClientBody {
    Text(String),
    ContactCard(ContactCard),
}

/// Current async step of an in-flight forward operation.
#[derive(Clone)]
pub(crate) enum ForwardStep {
    Idle,
    AllocatingClientId {
        target: String,
        body: ForwardClientBody,
    },
    SendingText,
    SendingContactCard {
        target: String,
        card: ContactCard,
    },
    ResolvingPhoto {
        target: String,
        fallback_url: Option<String>,
    },
    SendingResolvedPhoto {
        target: String,
        fallback_url: Option<String>,
    },
    FetchingPhotoFallback {
        target: String,
    },
    SendingFallbackPhoto,
    ResolvingFile {
        target: String,
    },
    SendingResolvedFile,
}

/// Mode distinguishing `forward(message, to:)` from `forwardAll(to:)`.
#[derive(Clone)]
pub(crate) enum ForwardMode {
    Single,
    All {
        request_id: u64,
        request_conv_id: String,
        has_more: bool,
        overall_outcome: ForwardOutcome,
    },
}

/// In-flight `forward` or `forwardAll` state machine.
#[derive(Clone)]
pub(crate) struct ActiveForward {
    pub op_id: Option<u64>,
    pub mode: ForwardMode,
    pub messages: Vec<ChatMessage>,
    pub msg_idx: usize,
    pub targets: Vec<String>,
    pub target_idx: usize,
    pub msg_succeeded: usize,
    pub now_ms: i64,
    pub wrote_store: bool,
    pub step: ForwardStep,
}

/// Core-owned U8 forward state.
#[derive(Clone, Default)]
pub struct ForwardState {
    pub request: Option<ForwardRequest>,
    pub(crate) next_request_id: u64,
    pub(crate) next_forward_id: u64,
    pub(crate) in_flight: BTreeMap<u64, ActiveForward>,
}

impl ForwardState {
    pub(crate) fn alloc_request_id(&mut self) -> u64 {
        self.next_request_id = self.next_request_id.saturating_add(1);
        self.next_request_id
    }

    pub(crate) fn alloc_forward_id(&mut self) -> u64 {
        self.next_forward_id = self.next_forward_id.saturating_add(1);
        self.next_forward_id
    }

    /// Clears `self.request`, returning `true` if a request was present.
    pub(crate) fn clear_request(&mut self) -> bool {
        self.request.take().is_some()
    }

    /// Resets session-scoped forward state on logout/expiry and fails any in-flight ops.
    /// Returns `true` if `self.request` was cleared.
    pub(crate) fn reset(&mut self, out: &mut ReduceOutput) -> bool {
        let cleared = self.request.take().is_some();
        let pending = std::mem::take(&mut self.in_flight);
        for (_, flow) in pending {
            if let Some(op_id) = flow.op_id {
                out.effects.push(Effect::CompleteOp {
                    op_id,
                    result: OpResult::Forward(ForwardOutcome::Failed(
                        "Có lỗi khi chia sẻ tin nhắn".to_owned(),
                    )),
                    after_store: false,
                });
            }
        }
        cleared
    }
}

impl fmt::Debug for ForwardState {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ForwardState")
            .field("has_request", &self.request.is_some())
            .field("in_flight_count", &self.in_flight.len())
            .finish()
    }
}
