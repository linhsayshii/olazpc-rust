//! Pure state reducer (D9): `reduce(&mut CoreState, Input) -> ReduceOutput`.
//!
//! No I/O, no clock, and no randomness may live inside `reduce`.

pub mod bootstrap;
pub mod classify;
pub mod conversations;
pub mod messages;
pub mod search;
pub mod send;
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

fn is_action_command(cmd: &Command) -> bool {
    matches!(
        cmd,
        Command::React { .. }
            | Command::Recall { .. }
            | Command::RecallMany { .. }
            | Command::DeleteForMe { .. }
            | Command::DeleteMany { .. }
            | Command::AnswerMessageConfirm { .. }
            | Command::AskMessageConfirm { .. }
            | Command::UndoDelete
            | Command::DismissDeleteUndo
            | Command::SetStarred { .. }
            | Command::LoadAutoDelete
            | Command::SetAutoDelete { .. }
            | Command::PruneExpiredMessages { .. }
            | Command::RecordSeenReactionKeys { .. }
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
        | Input::BootstrapSelfCloudDone { .. }
        | Input::BootstrapGroupWaveDone { .. }
        | Input::BootstrapResolveNamesChunkDone { .. }
        | Input::FreshnessProbed {
            boot_gen: Some(_), ..
        } => {
            bootstrap::reduce_bootstrap(state, input, &mut out);
        }

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
        | Input::FreshnessProbed { boot_gen: None, .. }
        | Input::TypedEnvelopeReady { .. }
        | Input::DecryptedEnvelopeReady { .. } => {
            messages::reduce_messages(state, input, &mut out);
        }
        // U5
        Input::Command(
            Command::HandleTyping { .. }
            | Command::NotifyTyping { .. }
            | Command::ResetOutgoingTyping { .. }
            | Command::SetSendTypingEnabled { .. },
        )
        | Input::OpRequest {
            cmd:
                Command::HandleTyping { .. }
                | Command::NotifyTyping { .. }
                | Command::ResetOutgoingTyping { .. }
                | Command::SetSendTypingEnabled { .. },
            ..
        }
        | Input::TypingExpired { .. } => crate::typing::reduce_typing(state, input, &mut out),
        // U5-send
        Input::Command(
            Command::SendText { .. }
            | Command::MarkRead { .. }
            | Command::SetE2eeThreads(_)
            | Command::SetAutoDeleteTtl { .. },
        )
        | Input::OpRequest {
            cmd:
                Command::SendText { .. }
                | Command::MarkRead { .. }
                | Command::SetE2eeThreads(_)
                | Command::SetAutoDeleteTtl { .. },
            ..
        }
        | Input::SendTextDone { .. } => send::reduce_send(state, input, &mut out),
        // U14
        Input::Command(
            Command::SearchMessages { .. }
            | Command::EnsureMessageLoaded { .. }
            | Command::LoadQuotedMessage { .. },
        )
        | Input::OpRequest {
            cmd:
                Command::SearchMessages { .. }
                | Command::EnsureMessageLoaded { .. }
                | Command::LoadQuotedMessage { .. },
            ..
        }
        | Input::SearchMessagesPageLoaded { .. }
        | Input::EnsureMessageWindowLoaded { .. }
        | Input::QuotedLookupDone { .. }
        | Input::LegacyQuotedLookupDone { .. } => search::reduce_search(state, input, &mut out),

        // U6
        Input::Command(ref cmd) if is_action_command(cmd) => {
            crate::actions::reduce_actions(state, input, &mut out);
        }
        Input::OpRequest { ref cmd, .. } if is_action_command(cmd) => {
            crate::actions::reduce_actions(state, input, &mut out);
        }
        Input::MessageIdsResolved { .. }
        | Input::ReactDone { .. }
        | Input::RecallDone { .. }
        | Input::RemoteReactionApproved { .. }
        | Input::RemoteRecallApproved { .. }
        | Input::RemoteRecallSkipped { .. }
        | Input::RemoteRecallStoreDone { .. }
        | Input::RemoteDeleteApproved { .. }
        | Input::RemoteDeleteStoreDone { .. }
        | Input::DeleteUndoExpired { .. }
        | Input::AutoDeleteLoaded { .. }
        | Input::AutoDeleteUpdated { .. } => crate::actions::reduce_actions(state, input, &mut out),

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
