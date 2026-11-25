//! Pure state reducer (D9): `reduce(&mut CoreState, Input) -> ReduceOutput`.
//!
//! No I/O, no clock, and no randomness may live inside `reduce`.

pub mod classify;
pub mod conversations;
pub mod messages;
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

fn is_message_command(cmd: &Command) -> bool {
    matches!(
        cmd,
        Command::OpenConversation { .. }
            | Command::CloseConversation
            | Command::LoadOlderMessages { .. }
            | Command::Bootstrap { .. }
            | Command::ApplyBatchDirect { .. }
            | Command::ApplyParsedEventsDirect { .. }
            | Command::WriteThroughUpsertMessage { .. }
            | Command::WriteThroughRemoveMessages { .. }
            | Command::WriteThroughReplaceWindow { .. }
            | Command::WriteThroughSetHasMore { .. }
            | Command::WriteThroughRemoveWindow { .. }
            | Command::RefreshReactionNames { .. }
            | Command::SeedHistoryFreshness(_)
            | Command::SeedContacts(_)
    )
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

        Input::Command(ref cmd) if is_message_command(cmd) => {
            messages::reduce_messages(state, input, &mut out);
        }
        Input::OpRequest { ref cmd, .. } if is_message_command(cmd) => {
            messages::reduce_messages(state, input, &mut out);
        }
        Input::OpenLocalMessagesLoaded { .. }
        | Input::OpenHistoryPageFetched { .. }
        | Input::LoadOlderStoreRead { .. }
        | Input::LoadOlderPageFetched { .. }
        | Input::SenderProfilesChunkDone { .. }
        | Input::BootstrapFreshnessLoaded { .. }
        | Input::FreshnessProbed { .. }
        | Input::DecryptedEnvelopeReady { .. } => {
            messages::reduce_messages(state, input, &mut out);
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
