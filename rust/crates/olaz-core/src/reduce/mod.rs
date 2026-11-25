//! Pure state reducer (D9): `reduce(&mut CoreState, Input) -> ReduceOutput`.
//!
//! No I/O, no clock, and no randomness may live inside `reduce`.

// U4-bootstrap
pub mod bootstrap;
pub mod classify;
pub mod conversations;
pub mod session;
pub mod transport;

use crate::changes::DirtySet;
use crate::effect::Effect;
use crate::input::{Command, Input};
use crate::state::CoreState;

/// Effects to execute and keys dirtied by a single `reduce` call.
#[derive(Debug, Default)]
pub struct ReduceOutput {
    pub effects: Vec<Effect>,
    pub dirty: DirtySet,
}

/// Pure transition function for the entire core state.
pub fn reduce(state: &mut CoreState, input: Input) -> ReduceOutput {
    let mut out = ReduceOutput::default();
    match input {
        Input::Command(
            Command::Start
            | Command::RefreshQr
            | Command::LogOut
            | Command::SessionExpired { .. }
            | Command::ApplyAccountProfile(_),
        )
        | Input::SavedSessionLoaded { .. }
        | Input::LegacyCookieResult { .. }
        | Input::PrepareStoreDone { .. }
        | Input::SessionStatusResult { .. }
        | Input::SyncProfileMeDone { .. }
        | Input::QrRequested { .. }
        | Input::QrRotated { .. }
        | Input::QrScanned { .. }
        | Input::QrConfirmed { .. }
        | Input::LoginCompleted { .. } => session::reduce_session(state, input, &mut out),

        Input::Command(Command::DrainChatPolling { .. })
        | Input::DrainRequested { .. }
        | Input::WsEvent { .. }
        | Input::WsTypedChat { .. }
        | Input::WsAuthChanged { .. }
        | Input::WsCursorsChanged { .. }
        | Input::LpTick { .. }
        | Input::PollBatchFetched { .. }
        | Input::PollBatchApplied { .. } => transport::reduce_transport(state, input, &mut out),

        // U4-bootstrap
        Input::Command(Command::Bootstrap { .. })
        | Input::OpRequest {
            cmd: Command::Bootstrap { .. },
            ..
        }
        | Input::BootstrapAliasesDone { .. }
        | Input::BootstrapFreshnessLoaded { .. }
        | Input::BootstrapPamDone { .. }
        | Input::BootstrapLabelsDone { .. }
        | Input::BootstrapHiddenDone { .. }
        | Input::BootstrapContactsDone { .. }
        | Input::BootstrapPreloadDone { .. }
        | Input::FreshnessProbed { .. }
        | Input::BootstrapSelfCloudDone { .. }
        | Input::BootstrapGroupWaveDone { .. }
        | Input::BootstrapResolveNamesChunkDone { .. } => {
            bootstrap::reduce_bootstrap(state, input, &mut out);
        }

        Input::Command(_)
        | Input::OpRequest { .. }
        | Input::BatchDeltaApplied { .. }
        | Input::PinApiDone { .. }
        | Input::PinReplacingStepDone { .. }
        | Input::MoveApiDone { .. }
        | Input::DeleteApiDone { .. }
        | Input::HiddenPinSyncDone { .. }
        | Input::ResetHiddenPinApiDone { .. }
        | Input::SyncHiddenFetched { .. }
        | Input::ResolveNamesChunkDone { .. }
        | Input::MentionPreviewsLoaded { .. }
        | Input::SyncLabelsFetched { .. }
        | Input::OpApiDone { .. }
        | Input::OpStoreFlushed { .. } => {
            conversations::reduce_conversations(state, input, &mut out);
        }
    }
    out
}
