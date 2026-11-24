//! Stateful protocol core for Olaz (ADR-016).
//!
//! Architecture:
//! - One tokio actor ([`actor`]) owns [`state::CoreState`]; inputs arrive over an mpsc channel.
//! - Domain logic is a pure reducer ([`reduce`]) with no I/O, clock, or randomness.
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

pub use actor::{ActorSink, CoreHandle};
pub use changes::{ChangeHub, CoreChanges, DirtyKey, DirtySet};
pub use effect::{Effect, HostCall};
pub use input::{Command, CompletedLogin, Input, LegacyCookie, SessionFailure, StoreToken};
pub use reduce::{ReduceOutput, reduce};
pub use runner::{EffectRunner, Host, SessionEffectRunner};
pub use state::{
    CoreFailKind, CoreState, FailReason, LoginState, LoginStep, Phase, Profile, SessionSnapshot,
    SessionState,
};
