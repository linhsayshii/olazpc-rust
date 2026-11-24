//! Pure core state machine and single-actor runtime for Olaz (`olaz-core`).
//!
//! Architecture (see `rust-core-plan` D1/D9 and ADR-016):
//! - State lives in [`state::CoreState`] inside a single tokio actor ([`actor::CoreHandle`]).
//! - Every transition runs through the pure [`reduce::reduce`] function (no I/O, no clock).
//! - Effects execute asynchronously via [`runner::EffectRunner`]; host calls run serially in
//!   emitted order while network calls may run concurrently as cancellable tasks.
//! - Consumers pull coalesced state snapshots via [`changes::ChangeHub::next_changes`].

pub mod actor;
pub mod changes;
pub mod effect;
pub mod input;
pub mod reduce;
pub mod runner;
pub mod state;
pub mod typed_chat;

pub use actor::{ActorSink, CoreHandle};
pub use changes::{ChangeHub, CoreChanges, DirtyKey, DirtySet};
pub use effect::{Effect, HostCall};
pub use input::{
    Command, CompletedLogin, Input, LegacyCookie, PollBatchError, PollBatchOutcome, SessionFailure,
    StoreToken,
};
pub use reduce::classify::{MobileSyncEvent, Route, classify, classify_poll};
pub use reduce::{ReduceOutput, reduce};
pub use runner::{EffectRunner, Host, LiveWsDriver, SessionEffectRunner, WsDriver, WsStartParams};
pub use state::{
    CoreFailKind, CoreState, FailReason, LoginState, LoginStep, PersistedTransportState, Phase,
    Profile, SessionSnapshot, SessionState, TransportState, WsPhase,
};
pub use typed_chat::{
    ParseState, PlainChatParse, SharedParse, TypedChatEnvelope, WirePayloadHandle,
    new_shared_parse, try_parse_plain_chat,
};
