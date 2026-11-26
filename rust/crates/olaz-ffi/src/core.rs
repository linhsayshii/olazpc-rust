//! `CoreEngine` & `CoreHost`: UniFFI export for the `olaz-core` actor and change stream (ADR-016).
//!
//! Credentials and user-facing personal data never reach `Debug` output or error messages (ADR-008).

use std::collections::BTreeMap;
use std::fmt;
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use olaz_api::{PollState, SendMessageResult};
use olaz_core::changes::{DirtyKey, snapshot_message_meta};
use olaz_core::conversations::{BatchApplyDelta, ConversationSummary, sort_conversations};
use olaz_core::input::E2eeQuoteArg;
use olaz_core::messages::{HistoryFreshness, MuteEntry};
use olaz_core::reduce::classify::{MobileSyncEvent, Route, classify};
use olaz_core::reduce::reduce;
use olaz_core::runner::{BatchHookOutcome, ParsedEventsHookOutcome, SharedStoreSlot, WsDriver};
use olaz_core::state::PersistedTransportState;
use olaz_core::typed_chat::{TypedChatEnvelope, WirePayloadHandle};
use olaz_core::{
    Command, ComposerSendOutcome, CoreChanges, CoreFailKind, CoreHandle, CoreState,
    DeleteUndoSnapshot, FailReason, FileResolutionOutcome, ForwardOutcome, ForwardRequest, Host,
    Input, LegacyCookie, LoginState, LoginStep, MediaResolutionOutcome, MessageConfirmAction,
    MessageConfirmState, Phase, Profile, SessionEffectRunner, SessionSnapshot,
};
use olaz_json::to_swift_json_string;
use olaz_net::{LoginAccount, NetworkErrorKind, ReqwestTransport, SessionClient};
use olaz_wire::{ChatMessage, NameLookup};
use olaz_ws::CursorMap;
use serde_json::{Map, Value};

use crate::api::PollStateRecord;
use crate::chat::{ChatMessageRecord, MessageMention, TextStyleRecord};
use crate::conversations::{
    CachedProfileEntry, ConvPreviewOverrideRecord, ConversationActionResultRecord,
    ConversationActionUiRecord, ConversationActionsRecord, ConversationExtrasRecord,
    ConversationPromptRecord, ConversationSummaryRecord, IdentityTableRecord,
    MessagePreviewInputRecord, PinBoardRecord, PromptUpdateRecord, RankEntry, SeenTargetRecord,
};
use crate::error::{CoreError, NetworkKind};
use crate::messages::{
    ContactsStateRecord, FreshnessMapEntry, MessageMetaRecord, MuteEntryRecord, WindowDeltaRecord,
    records_to_chat_messages,
};
use crate::notify::{
    AliasEntryRecord, CardActionOutcomeRecord, ContactCardStateRecord, ContactProfileRecord,
    FriendRequestOriginRecord, FriendRequestPrepRecord, GroupInvitePreviewRecord, GroupJoinRecord,
    NotifAuthorizationRecord, NotificationSettingsRecord, NotifyBannerPayloadRecord,
    PinReminderRefRecord, ReminderRespondersRecord, ReminderSnapshotRecord, RespondReminderRecord,
    SaveAliasRecord, SubmitFriendRecord, SuggestedStickerRecord, alias_map_to_records,
    default_failed_respond_reminder_record, default_unsupported_card_record,
};
use crate::polls::{
    BoardPinListRecord, PollActionOutcomeRecord, PollCapabilitiesOutcomeRecord, PollConfigRecord,
    PollCreateDraftRecord, PollDetailRecord, PollMessageNoticeRecord, PollPinActionOutcomeRecord,
    PollPinStateOutcomeRecord, PollVoteDraftRecord, PollVotersOutcomeRecord, PollsMirrorRecord,
    parse_raw_topics_json,
};
use crate::runtime::{run, runtime};
use crate::session::CoreSession;
use crate::store::CoreStore;
use crate::wire::{
    NameEntry, WireEvent, convert as convert_wire_event, unconvert as unconvert_wire_event,
};
use crate::ws::{CursorEntry, to_entries as cursors_to_entries, to_map as cursors_to_map};

/// Core/transport error kind rendered by Swift via `RustCore.mapError(...).localizedDescription`.
#[derive(Clone, PartialEq, Eq, uniffi::Enum)]
pub enum CoreFailKindRecord {
    Network {
        kind: NetworkKind,
    },
    Session {
        code: i64,
        message: String,
        url: String,
    },
    Http {
        status: u16,
    },
    InvalidJson,
    NotAuthenticated,
    Crypto {
        message: String,
    },
}

impl fmt::Debug for CoreFailKindRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Network { kind } => f.debug_struct("Network").field("kind", kind).finish(),
            Self::Session { code, .. } => f.debug_struct("Session").field("code", code).finish(),
            Self::Http { status } => f.debug_struct("Http").field("status", status).finish(),
            Self::InvalidJson => f.write_str("InvalidJson"),
            Self::NotAuthenticated => f.write_str("NotAuthenticated"),
            Self::Crypto { .. } => f.write_str("Crypto(<redacted>)"),
        }
    }
}

impl From<CoreFailKind> for CoreFailKindRecord {
    fn from(kind: CoreFailKind) -> Self {
        match kind {
            CoreFailKind::Network(k) => Self::Network {
                kind: match k {
                    NetworkErrorKind::Timeout => NetworkKind::Timeout,
                    NetworkErrorKind::ConnectionLost => NetworkKind::ConnectionLost,
                    NetworkErrorKind::Other => NetworkKind::Other,
                },
            },
            CoreFailKind::Session { code, message, url } => Self::Session { code, message, url },
            CoreFailKind::Http { status } => Self::Http { status },
            CoreFailKind::InvalidJson => Self::InvalidJson,
            CoreFailKind::NotAuthenticated => Self::NotAuthenticated,
            CoreFailKind::Crypto(message) => Self::Crypto { message },
        }
    }
}

/// Typed failure reason for `LoginStepRecord::Failed`.
#[derive(Clone, PartialEq, Eq, uniffi::Enum)]
pub enum FailReasonRecord {
    Text { message: String },
    Core { kind: CoreFailKindRecord },
}

impl fmt::Debug for FailReasonRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Text { message } => f.debug_struct("Text").field("len", &message.len()).finish(),
            Self::Core { kind } => f.debug_struct("Core").field("kind", kind).finish(),
        }
    }
}

impl From<FailReason> for FailReasonRecord {
    fn from(reason: FailReason) -> Self {
        match reason {
            FailReason::Text(message) => Self::Text { message },
            FailReason::Core(kind) => Self::Core { kind: kind.into() },
        }
    }
}

/// Sub-state of `PhaseRecord::Login`.
#[derive(Clone, PartialEq, Eq, uniffi::Enum)]
pub enum LoginStepRecord {
    Generating,
    WaitingScan,
    WaitingConfirm {
        name: String,
        avatar: Option<String>,
    },
    Expired,
    Failed {
        reason: FailReasonRecord,
    },
}

impl fmt::Debug for LoginStepRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Generating => f.write_str("Generating"),
            Self::WaitingScan => f.write_str("WaitingScan"),
            Self::WaitingConfirm { avatar, .. } => f
                .debug_struct("WaitingConfirm")
                .field("has_avatar", &avatar.is_some())
                .finish(),
            Self::Expired => f.write_str("Expired"),
            Self::Failed { reason } => f.debug_struct("Failed").field("reason", reason).finish(),
        }
    }
}

impl From<LoginStep> for LoginStepRecord {
    fn from(step: LoginStep) -> Self {
        match step {
            LoginStep::Generating => Self::Generating,
            LoginStep::WaitingScan => Self::WaitingScan,
            LoginStep::WaitingConfirm { name, avatar } => Self::WaitingConfirm { name, avatar },
            LoginStep::Expired => Self::Expired,
            LoginStep::Failed(reason) => Self::Failed {
                reason: reason.into(),
            },
        }
    }
}

/// QR login state delivered to Swift (`ZaloEngine.LoginState`).
#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct LoginStateRecord {
    pub step: LoginStepRecord,
    pub qr_payload: Option<String>,
    pub qr_png: Option<Vec<u8>>,
}

impl fmt::Debug for LoginStateRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("LoginStateRecord")
            .field("step", &self.step)
            .field("has_qr_payload", &self.qr_payload.is_some())
            .field("qr_png_bytes", &self.qr_png.as_ref().map_or(0, Vec::len))
            .finish()
    }
}

impl From<LoginState> for LoginStateRecord {
    fn from(state: LoginState) -> Self {
        Self {
            step: state.step.into(),
            qr_payload: state.qr_payload,
            qr_png: state.qr_png,
        }
    }
}

/// Top-level engine phase (`ZaloEngine.Phase`).
#[derive(Clone, PartialEq, Eq, uniffi::Enum)]
pub enum PhaseRecord {
    Starting,
    Login { state: LoginStateRecord },
    SigningIn,
    Ready,
}

impl fmt::Debug for PhaseRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Starting => f.write_str("Starting"),
            Self::Login { state } => f.debug_struct("Login").field("state", state).finish(),
            Self::SigningIn => f.write_str("SigningIn"),
            Self::Ready => f.write_str("Ready"),
        }
    }
}

impl From<Phase> for PhaseRecord {
    fn from(phase: Phase) -> Self {
        match phase {
            Phase::Starting => Self::Starting,
            Phase::Login(state) => Self::Login {
                state: state.into(),
            },
            Phase::SigningIn => Self::SigningIn,
            Phase::Ready => Self::Ready,
        }
    }
}

/// Signed-in account profile (`ZaloEngine.Profile`).
#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct ProfileRecord {
    pub user_id: String,
    pub display_name: String,
    pub avatar: Option<String>,
    pub phone: Option<String>,
}

impl fmt::Debug for ProfileRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ProfileRecord")
            .field("has_user_id", &!self.user_id.is_empty())
            .field("has_display_name", &!self.display_name.is_empty())
            .field("has_avatar", &self.avatar.is_some())
            .field("has_phone", &self.phone.is_some())
            .finish()
    }
}

impl From<Profile> for ProfileRecord {
    fn from(profile: Profile) -> Self {
        Self {
            user_id: profile.user_id,
            display_name: profile.display_name,
            avatar: profile.avatar,
            phone: profile.phone,
        }
    }
}

/// Account record crossing FFI for `prepare_store` and `apply_account_profile`.
/// Contains credentials (`zpw_enk`, `zpw_sek`); `Debug` is redacted.
#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct LoginAccountRecord {
    pub user_id: String,
    pub display_name: String,
    pub avatar: String,
    pub phone: String,
    pub send2me_id: String,
    pub dkey: String,
    pub zpw_enk: String,
    pub zpw_sek: String,
    pub need_sync_msg: Option<bool>,
}

impl fmt::Debug for LoginAccountRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("LoginAccountRecord")
            .field("has_user_id", &!self.user_id.is_empty())
            .field("has_display_name", &!self.display_name.is_empty())
            .field("has_zpw_enk", &!self.zpw_enk.is_empty())
            .field("has_zpw_sek", &!self.zpw_sek.is_empty())
            .field("need_sync_msg", &self.need_sync_msg)
            .finish()
    }
}

impl From<LoginAccount> for LoginAccountRecord {
    fn from(a: LoginAccount) -> Self {
        Self {
            user_id: a.user_id,
            display_name: a.display_name,
            avatar: a.avatar,
            phone: a.phone,
            send2me_id: a.send2me_id,
            dkey: a.dkey,
            zpw_enk: a.zpw_enk,
            zpw_sek: a.zpw_sek,
            need_sync_msg: a.need_sync_msg,
        }
    }
}

impl From<LoginAccountRecord> for LoginAccount {
    fn from(a: LoginAccountRecord) -> Self {
        Self {
            user_id: a.user_id,
            display_name: a.display_name,
            avatar: a.avatar,
            phone: a.phone,
            send2me_id: a.send2me_id,
            dkey: a.dkey,
            zpw_enk: a.zpw_enk,
            zpw_sek: a.zpw_sek,
            need_sync_msg: a.need_sync_msg,
        }
    }
}

/// Legacy WKWebView/HTTPCookieStorage credentials loaded by Swift on cold boot.
/// Contains `zpw_sek`; `Debug` is redacted.
#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct LegacyCookieRecord {
    pub zpw_sek: String,
    pub imei: Option<String>,
}

impl fmt::Debug for LegacyCookieRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("LegacyCookieRecord")
            .field("has_zpw_sek", &!self.zpw_sek.is_empty())
            .field("has_imei", &self.imei.is_some())
            .finish()
    }
}

impl From<LegacyCookieRecord> for LegacyCookie {
    fn from(c: LegacyCookieRecord) -> Self {
        Self {
            zpw_sek: c.zpw_sek,
            imei: c.imei,
        }
    }
}

/// Session-domain state mirror snapshot delivered inside [`CoreChangesRecord`].
#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct SessionStateRecord {
    pub phase: PhaseRecord,
    pub profile: Option<ProfileRecord>,
    pub sign_out_notice: Option<String>,
    pub self_conversation_id: Option<String>,
}

impl fmt::Debug for SessionStateRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("SessionStateRecord")
            .field("phase", &self.phase)
            .field("has_profile", &self.profile.is_some())
            .field("has_sign_out_notice", &self.sign_out_notice.is_some())
            .field("has_self_conv", &self.self_conversation_id.is_some())
            .finish()
    }
}

impl From<SessionSnapshot> for SessionStateRecord {
    fn from(s: SessionSnapshot) -> Self {
        Self {
            phase: s.phase.into(),
            profile: s.profile.map(Into::into),
            sign_out_notice: s.sign_out_notice,
            self_conversation_id: s.self_conversation_id,
        }
    }
}

/// Active incoming typing indicator for one conversation (U5).
#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct TypingEntryRecord {
    pub conv_id: String,
    pub name: String,
    pub on_pc: bool,
}

impl fmt::Debug for TypingEntryRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("TypingEntryRecord")
            .field("has_conv_id", &!self.conv_id.is_empty())
            .field("has_name", &!self.name.is_empty())
            .field("on_pc", &self.on_pc)
            .finish()
    }
}

/// Quote metadata passed to Swift's `send_e2ee_text` host boundary (U5).
#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct E2eeQuoteArgRecord {
    pub msg_id: String,
    pub cli_msg_id: String,
    pub sender_id: String,
    pub sender_name: String,
    pub text: String,
    pub ts_ms: i64,
}

impl fmt::Debug for E2eeQuoteArgRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("E2eeQuoteArgRecord")
            .field("ts_ms", &self.ts_ms)
            .field("has_text", &!self.text.is_empty())
            .finish()
    }
}

impl From<E2eeQuoteArg> for E2eeQuoteArgRecord {
    fn from(q: E2eeQuoteArg) -> Self {
        Self {
            msg_id: q.msg_id,
            cli_msg_id: q.cli_msg_id,
            sender_id: q.sender_id,
            sender_name: q.sender_name,
            text: q.text,
            ts_ms: q.ts_ms,
        }
    }
}

/// Outcome returned by Swift's `send_e2ee_text` host callback (U5).
#[derive(Clone, PartialEq, Eq, uniffi::Enum)]
pub enum E2eeSendOutcomeRecord {
    Sent {
        msg_id: String,
        cli_msg_id: String,
        ts_ms: i64,
    },
    /// Error thrown by E2EE send: core logs `sendText failed: <message>` and removes optimistic row.
    Failed { message: String },
    /// Pre-flight guard already logged by Swift: core removes optimistic row without extra log.
    Aborted,
}

impl fmt::Debug for E2eeSendOutcomeRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Sent { ts_ms, .. } => f.debug_struct("Sent").field("ts_ms", ts_ms).finish(),
            Self::Failed { message } => f
                .debug_struct("Failed")
                .field("msg_len", &message.len())
                .finish(),
            Self::Aborted => f.write_str("Aborted"),
        }
    }
}

/// Return value of [`CoreEngine::send_text`] carrying both send status and mirror revision (U5).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SendTextOutcomeRecord {
    pub ok: bool,
    pub version: u64,
}

/// Active forward picker request mirrored from `olaz-core` (U8).
#[derive(Clone, PartialEq, uniffi::Record)]
pub struct ForwardRequestRecord {
    pub id: u64,
    pub conversation_id: String,
    pub message: ChatMessageRecord,
    pub more: Vec<ChatMessageRecord>,
}

impl fmt::Debug for ForwardRequestRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ForwardRequestRecord")
            .field("id", &self.id)
            .field("more_count", &self.more.len())
            .finish()
    }
}

/// Active 5-second delete-for-me undo bar snapshot delivered via [`CoreChangesRecord`].
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct DeleteUndoSnapshotRecord {
    pub conv_id: String,
    pub count: u64,
    pub deadline_ms: i64,
}

impl From<DeleteUndoSnapshot> for DeleteUndoSnapshotRecord {
    fn from(s: DeleteUndoSnapshot) -> Self {
        Self {
            conv_id: s.conv_id,
            count: s.count as u64,
            deadline_ms: s.deadline_ms,
        }
    }
}

/// Wrapper for `Option<Option<DeleteUndoSnapshot>>` (UniFFI forbids nested `Option`).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct DeleteUndoUpdateRecord {
    pub undo: Option<DeleteUndoSnapshotRecord>,
}

/// Action kind carried by [`MessageConfirmRecord`].
#[derive(Clone, PartialEq, Eq, uniffi::Enum)]
pub enum MessageConfirmActionRecord {
    DeleteForMe {
        msg_id: String,
    },
    DeleteMany {
        msg_ids: Vec<String>,
    },
    RecallMany {
        msg_ids: Vec<String>,
    },
    Pin {
        msg_id: String,
        replacing_ref: Option<String>,
    },
    Unpin {
        topic_ref: String,
    },
}

impl fmt::Debug for MessageConfirmActionRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::DeleteForMe { .. } => f.write_str("DeleteForMe"),
            Self::DeleteMany { msg_ids } => f
                .debug_struct("DeleteMany")
                .field("count", &msg_ids.len())
                .finish(),
            Self::RecallMany { msg_ids } => f
                .debug_struct("RecallMany")
                .field("count", &msg_ids.len())
                .finish(),
            Self::Pin { .. } => f.write_str("Pin"),
            Self::Unpin { .. } => f.write_str("Unpin"),
        }
    }
}

impl From<MessageConfirmAction> for MessageConfirmActionRecord {
    fn from(a: MessageConfirmAction) -> Self {
        match a {
            MessageConfirmAction::DeleteForMe { msg_id } => Self::DeleteForMe { msg_id },
            MessageConfirmAction::DeleteMany { msg_ids } => Self::DeleteMany { msg_ids },
            MessageConfirmAction::RecallMany { msg_ids } => Self::RecallMany { msg_ids },
            MessageConfirmAction::Pin {
                msg_id,
                replacing_ref,
            } => Self::Pin {
                msg_id,
                replacing_ref,
            },
            MessageConfirmAction::Unpin { topic_ref } => Self::Unpin { topic_ref },
        }
    }
}

impl From<MessageConfirmActionRecord> for MessageConfirmAction {
    fn from(a: MessageConfirmActionRecord) -> Self {
        match a {
            MessageConfirmActionRecord::DeleteForMe { msg_id } => Self::DeleteForMe { msg_id },
            MessageConfirmActionRecord::DeleteMany { msg_ids } => Self::DeleteMany { msg_ids },
            MessageConfirmActionRecord::RecallMany { msg_ids } => Self::RecallMany { msg_ids },
            MessageConfirmActionRecord::Pin {
                msg_id,
                replacing_ref,
            } => Self::Pin {
                msg_id,
                replacing_ref,
            },
            MessageConfirmActionRecord::Unpin { topic_ref } => Self::Unpin { topic_ref },
        }
    }
}

/// Active message-action confirmation dialog state delivered via [`CoreChangesRecord`].
#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct MessageConfirmRecord {
    pub id: u64,
    pub conv_id: String,
    pub action: MessageConfirmActionRecord,
    pub title: String,
    pub message: String,
    pub ok: String,
    pub destructive: bool,
}

impl fmt::Debug for MessageConfirmRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("MessageConfirmRecord")
            .field("id", &self.id)
            .field("action", &self.action)
            .field("destructive", &self.destructive)
            .finish()
    }
}

impl From<ForwardRequest> for ForwardRequestRecord {
    fn from(r: ForwardRequest) -> Self {
        Self {
            id: r.id,
            conversation_id: r.conversation_id,
            message: ChatMessageRecord::from(r.message),
            more: r.more.into_iter().map(ChatMessageRecord::from).collect(),
        }
    }
}

impl From<MessageConfirmState> for MessageConfirmRecord {
    fn from(c: MessageConfirmState) -> Self {
        Self {
            id: c.id,
            conv_id: c.conv_id,
            action: c.action.into(),
            title: c.title,
            message: c.message,
            ok: c.ok,
            destructive: c.destructive,
        }
    }
}

/// Optional wrapper so UniFFI can distinguish "unchanged" from "cleared to None" (U8).
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ForwardRequestUpdateRecord {
    pub request: Option<ForwardRequestRecord>,
}

/// Outcome of `forward` / `forward_all` (U8).
#[derive(Clone, PartialEq, Eq, uniffi::Enum)]
pub enum ForwardOutcomeRecord {
    Done { text: Option<String> },
    Pending { text: String },
    Failed { text: String },
}

impl fmt::Debug for ForwardOutcomeRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Done { text } => f
                .debug_struct("Done")
                .field("has_text", &text.is_some())
                .finish(),
            Self::Pending { .. } => f.write_str("Pending"),
            Self::Failed { .. } => f.write_str("Failed"),
        }
    }
}

impl From<MessageConfirmRecord> for MessageConfirmState {
    fn from(c: MessageConfirmRecord) -> Self {
        Self {
            id: c.id,
            conv_id: c.conv_id,
            action: c.action.into(),
            title: c.title,
            message: c.message,
            ok: c.ok,
            destructive: c.destructive,
        }
    }
}

impl From<ForwardOutcome> for ForwardOutcomeRecord {
    fn from(o: ForwardOutcome) -> Self {
        match o {
            ForwardOutcome::Done(text) => Self::Done { text },
            ForwardOutcome::Pending(text) => Self::Pending { text },
            ForwardOutcome::Failed(text) => Self::Failed { text },
        }
    }
}

/// Return value of [`CoreEngine::forward`] and [`CoreEngine::forward_all`] (U8).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ForwardOpResultRecord {
    pub outcome: ForwardOutcomeRecord,
    pub version: u64,
}

/// Host return value for `resolve_media` (U8).
#[derive(Clone, PartialEq, Eq, uniffi::Enum)]
pub enum MediaResolutionRecord {
    File { path: String },
    Expired,
    Unsupported,
    Unavailable,
}

impl fmt::Debug for MediaResolutionRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::File { .. } => f.write_str("File"),
            Self::Expired => f.write_str("Expired"),
            Self::Unsupported => f.write_str("Unsupported"),
            Self::Unavailable => f.write_str("Unavailable"),
        }
    }
}

impl From<MediaResolutionRecord> for MediaResolutionOutcome {
    fn from(r: MediaResolutionRecord) -> Self {
        match r {
            MediaResolutionRecord::File { path } => Self::File(path),
            MediaResolutionRecord::Expired => Self::Expired,
            MediaResolutionRecord::Unsupported => Self::Unsupported,
            MediaResolutionRecord::Unavailable => Self::Unavailable,
        }
    }
}

/// Host return value for `resolve_file` (U8).
#[derive(Clone, PartialEq, Eq, uniffi::Enum)]
pub enum FileResolutionRecord {
    Ready { path: String },
    Expired,
    Failed { message: String },
}

impl fmt::Debug for FileResolutionRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Ready { .. } => f.write_str("Ready"),
            Self::Expired => f.write_str("Expired"),
            Self::Failed { .. } => f.write_str("Failed"),
        }
    }
}

impl From<FileResolutionRecord> for FileResolutionOutcome {
    fn from(r: FileResolutionRecord) -> Self {
        match r {
            FileResolutionRecord::Ready { path } => Self::Ready(path),
            FileResolutionRecord::Expired => Self::Expired,
            FileResolutionRecord::Failed { message } => Self::Failed(message),
        }
    }
}

/// Host return value for `send_media` / `send_files` (U8).
#[derive(Clone, PartialEq, Eq, uniffi::Enum)]
pub enum ComposerSendOutcomeRecord {
    Done,
    Cancelled,
    Pending { text: String },
    Failed { text: String },
}

impl fmt::Debug for ComposerSendOutcomeRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Done => f.write_str("Done"),
            Self::Cancelled => f.write_str("Cancelled"),
            Self::Pending { .. } => f.write_str("Pending"),
            Self::Failed { .. } => f.write_str("Failed"),
        }
    }
}

impl From<ComposerSendOutcomeRecord> for ComposerSendOutcome {
    fn from(r: ComposerSendOutcomeRecord) -> Self {
        match r {
            ComposerSendOutcomeRecord::Done => Self::Done,
            ComposerSendOutcomeRecord::Cancelled => Self::Cancelled,
            ComposerSendOutcomeRecord::Pending { text } => Self::Pending(text),
            ComposerSendOutcomeRecord::Failed { text } => Self::Failed(text),
        }
    }
}

/// Wrapper for `Option<Option<MessageConfirmState>>` (UniFFI forbids nested `Option`).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct MessageConfirmUpdateRecord {
    pub confirm: Option<MessageConfirmRecord>,
}

/// Single conversation auto-delete TTL entry (ms).
#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct AutoDeleteEntryRecord {
    pub conv_id: String,
    pub ttl_ms: i64,
}

impl fmt::Debug for AutoDeleteEntryRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("AutoDeleteEntryRecord")
            .field("ttl_ms", &self.ttl_ms)
            .finish()
    }
}

/// Wrapper for `Option<Option<BTreeMap<String, i64>>>` (`entries: None` = unloaded / cleared).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct AutoDeleteUpdateRecord {
    pub entries: Option<Vec<AutoDeleteEntryRecord>>,
}

/// Coalesced dirty-key change batch returned by [`CoreEngine::next_changes`].
#[derive(Clone, PartialEq, uniffi::Record)]
pub struct CoreChangesRecord {
    pub version: u64,
    pub session: Option<SessionStateRecord>,
    pub conversations: Option<Vec<ConversationSummaryRecord>>,
    pub conversation_flags: Option<ConversationActionsRecord>,
    pub conversation_extras: Option<ConversationExtrasRecord>,
    pub conversation_ui: Option<ConversationActionUiRecord>,
    pub conversation_prompt: Option<PromptUpdateRecord>,
    pub window_deltas: Vec<WindowDeltaRecord>,
    pub messages_reset_all: bool,
    pub message_meta: Option<MessageMetaRecord>,
    pub contacts: Option<ContactsStateRecord>,
    pub typing: Option<Vec<TypingEntryRecord>>,
    pub forward_request: Option<ForwardRequestUpdateRecord>,
    pub clear_selection: bool,
    pub delete_undo: Option<DeleteUndoUpdateRecord>,
    pub message_confirm: Option<MessageConfirmUpdateRecord>,
    pub auto_delete: Option<AutoDeleteUpdateRecord>,
    pub starred_ids: Option<Vec<String>>,
    pub cached_profiles: Option<Vec<CachedProfileEntry>>,
    // U16
    #[uniffi(default = None)]
    pub notification_settings: Option<NotificationSettingsRecord>,
    #[uniffi(default = None)]
    pub aliases: Option<Vec<AliasEntryRecord>>,
    // U12
    #[uniffi(default = None)]
    pub polls: Option<PollsMirrorRecord>,
}

impl fmt::Debug for CoreChangesRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("CoreChangesRecord")
            .field("version", &self.version)
            .field("session", &self.session)
            .field(
                "conversations_count",
                &self.conversations.as_ref().map(Vec::len),
            )
            .field("conversation_flags", &self.conversation_flags)
            .field("conversation_extras", &self.conversation_extras)
            .field("conversation_ui", &self.conversation_ui)
            .field("conversation_prompt", &self.conversation_prompt)
            .field("typing_count", &self.typing.as_ref().map(Vec::len))
            .field("has_forward_request", &self.forward_request.is_some())
            .field("clear_selection", &self.clear_selection)
            .field("polls", &self.polls)
            .finish()
    }
}

impl From<CoreChanges> for CoreChangesRecord {
    fn from(c: CoreChanges) -> Self {
        Self {
            version: c.version,
            session: c.session.map(Into::into),
            conversations: c
                .conversations
                .map(|list| list.into_iter().map(Into::into).collect()),
            conversation_flags: c.conversation_flags.map(Into::into),
            conversation_extras: c.conversation_extras.map(Into::into),
            conversation_ui: c.conversation_ui.map(Into::into),
            conversation_prompt: c.conversation_prompt.map(|p| PromptUpdateRecord {
                prompt: p.map(Into::into),
            }),
            window_deltas: c.window_deltas.into_iter().map(Into::into).collect(),
            messages_reset_all: c.messages_reset_all,
            message_meta: c.message_meta.map(Into::into),
            contacts: c.contacts.map(Into::into),
            typing: c.typing.map(|map| {
                map.into_iter()
                    .map(|(conv_id, status)| TypingEntryRecord {
                        conv_id,
                        name: status.name,
                        on_pc: status.on_pc,
                    })
                    .collect()
            }),
            forward_request: c.forward_request.map(|req| ForwardRequestUpdateRecord {
                request: req.map(Into::into),
            }),
            clear_selection: c.clear_selection,
            delete_undo: c.delete_undo.map(|u| DeleteUndoUpdateRecord {
                undo: u.map(Into::into),
            }),
            message_confirm: c.message_confirm.map(|m| MessageConfirmUpdateRecord {
                confirm: m.map(Into::into),
            }),
            auto_delete: c.auto_delete.map(|opt_map| AutoDeleteUpdateRecord {
                entries: opt_map.map(|map| {
                    map.into_iter()
                        .map(|(conv_id, ttl_ms)| AutoDeleteEntryRecord { conv_id, ttl_ms })
                        .collect()
                }),
            }),
            starred_ids: c.starred_ids.map(|set| set.into_iter().collect()),
            cached_profiles: c.cached_profiles.map(|map| {
                map.into_iter()
                    .map(|(uid, p)| CachedProfileEntry {
                        uid,
                        name: p.name,
                        avatar: p.avatar,
                    })
                    .collect()
            }),
            notification_settings: c.notification_settings.map(Into::into),
            aliases: c.aliases.map(alias_map_to_records),
            polls: c.polls.map(Into::into),
        }
    }
}

/// Persisted transport cursors loaded by Swift right after `prepare_store`.
#[derive(Debug, Clone, Default, PartialEq, Eq, uniffi::Record)]
pub struct PersistedTransportStateRecord {
    pub poll_state: Option<PollStateRecord>,
    pub ws_cursors: Vec<CursorEntry>,
}

impl From<PersistedTransportStateRecord> for PersistedTransportState {
    fn from(r: PersistedTransportStateRecord) -> Self {
        Self {
            poll_state: r.poll_state.map(Into::into).unwrap_or_default(),
            ws_cursors: cursors_to_map(r.ws_cursors),
        }
    }
}

/// Parsed mobile-sync control event delivered to Swift (`ZaloMobileSyncEvent`).
/// Contains sync tokens/URLs; `Debug` is redacted.
#[derive(Clone, PartialEq, Eq, uniffi::Enum)]
pub enum MobileSyncEventRecord {
    TransferAfterLogin {
        temp_key: String,
    },
    WaitingConfirmOnPhone {
        sync_id: String,
    },
    UserConfirmed,
    UserRejected,
    MobileBusy,
    UploadBatch {
        sync_id: String,
        url: String,
        batch_type: i64,
        idx: i64,
        is_last: bool,
    },
}

impl fmt::Debug for MobileSyncEventRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::TransferAfterLogin { temp_key } => f
                .debug_struct("TransferAfterLogin")
                .field("temp_key_len", &temp_key.len())
                .finish(),
            Self::WaitingConfirmOnPhone { sync_id } => f
                .debug_struct("WaitingConfirmOnPhone")
                .field("has_sync_id", &!sync_id.is_empty())
                .finish(),
            Self::UserConfirmed => f.write_str("UserConfirmed"),
            Self::UserRejected => f.write_str("UserRejected"),
            Self::MobileBusy => f.write_str("MobileBusy"),
            Self::UploadBatch {
                batch_type,
                idx,
                is_last,
                ..
            } => f
                .debug_struct("UploadBatch")
                .field("batch_type", batch_type)
                .field("idx", idx)
                .field("is_last", is_last)
                .finish(),
        }
    }
}

impl From<MobileSyncEvent> for MobileSyncEventRecord {
    fn from(e: MobileSyncEvent) -> Self {
        match e {
            MobileSyncEvent::TransferAfterLogin { temp_key } => {
                Self::TransferAfterLogin { temp_key }
            }
            MobileSyncEvent::WaitingConfirmOnPhone { sync_id } => {
                Self::WaitingConfirmOnPhone { sync_id }
            }
            MobileSyncEvent::UserConfirmed => Self::UserConfirmed,
            MobileSyncEvent::UserRejected => Self::UserRejected,
            MobileSyncEvent::MobileBusy => Self::MobileBusy,
            MobileSyncEvent::UploadBatch {
                sync_id,
                url,
                batch_type,
                idx,
                is_last,
            } => Self::UploadBatch {
                sync_id,
                url,
                batch_type,
                idx,
                is_last,
            },
        }
    }
}

/// Decrypted plain-chat envelope held Rust-side for zero-JSON-reencode typed delivery.
///
/// Mirrors `crate::ws::WirePayload`: Swift resolves contact names for `uids`, calls [`Self::resolve`],
/// and gets `None` (zero re-parse) when the core's name cache already matched.
#[derive(uniffi::Object)]
pub struct CoreWirePayload {
    inner: Arc<WirePayloadHandle>,
}

#[uniffi::export]
impl CoreWirePayload {
    /// Returns `None` when the delivered events already used this `my_uid`, `self_conv_id`, and
    /// `names`; otherwise re-parses and updates the core's per-session name cache.
    pub fn resolve(
        &self,
        my_uid: String,
        self_conv_id: Option<String>,
        names: Vec<NameEntry>,
    ) -> Option<Vec<WireEvent>> {
        let pairs: Vec<(String, NameLookup)> = names
            .into_iter()
            .map(|n| {
                (
                    n.uid,
                    NameLookup {
                        name: n.name,
                        avatar: n.avatar,
                    },
                )
            })
            .collect();
        self.inner
            .resolve(&my_uid, self_conv_id.as_deref(), &pairs)
            .map(|evts| evts.into_iter().map(convert_wire_event).collect())
    }

    /// Lossless JSON string of the decrypted payload (diagnostic / fallback).
    pub fn json_string(&self) -> String {
        self.inner.json_string()
    }
}

/// Control routing decision returned by [`classify_control_envelope`] (pure FFI helper for
/// direct Swift unit tests of `ZaloEngine.processControlEnvelope`).
#[derive(Clone, PartialEq, Eq, uniffi::Enum)]
pub enum ControlRouteRecord {
    RecordFileDone {
        file_id: String,
        url: String,
    },
    LogUndecodedControl {
        cmd: u16,
        encrypt: i64,
        data_is_string: bool,
    },
    VoipControl {
        act: String,
        raw_data_json: String,
        data_json: String,
    },
    LogTypingShape {
        shape: String,
    },
    ShowTyping {
        conv_id: String,
        uid: String,
        on_pc: bool,
    },
    PinTopic {
        conv_id: String,
    },
    GroupNotice {
        act: String,
        data_json: String,
        ts: i64,
    },
    Mute {
        conv_id: String,
        set: bool,
        start: i64,
        start_explicit: bool,
        duration: i64,
    },
}

impl fmt::Debug for ControlRouteRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::RecordFileDone { file_id, url } => f
                .debug_struct("RecordFileDone")
                .field("has_file_id", &!file_id.is_empty())
                .field("has_url", &!url.is_empty())
                .finish(),
            Self::LogUndecodedControl {
                cmd,
                encrypt,
                data_is_string,
            } => f
                .debug_struct("LogUndecodedControl")
                .field("cmd", cmd)
                .field("encrypt", encrypt)
                .field("data_is_string", data_is_string)
                .finish(),
            Self::VoipControl { act, .. } => {
                f.debug_struct("VoipControl").field("act", act).finish()
            }
            Self::LogTypingShape { shape } => f
                .debug_struct("LogTypingShape")
                .field("shape", shape)
                .finish(),
            Self::ShowTyping { on_pc, .. } => {
                f.debug_struct("ShowTyping").field("on_pc", on_pc).finish()
            }
            Self::PinTopic { .. } => f.write_str("PinTopic"),
            Self::GroupNotice { act, ts, .. } => f
                .debug_struct("GroupNotice")
                .field("act", act)
                .field("ts", ts)
                .finish(),
            Self::Mute {
                set,
                start,
                duration,
                ..
            } => f
                .debug_struct("Mute")
                .field("set", set)
                .field("start", start)
                .field("duration", duration)
                .finish(),
        }
    }
}

/// Pure control-envelope classifier backed by `olaz_core::reduce::classify::classify`.
/// Used by `ZaloEngine.processControlEnvelope` so Swift holds zero duplicate control parsing logic.
#[uniffi::export]
pub fn classify_control_envelope(
    cmd: u16,
    payload_json: String,
    my_uid: String,
    now_unix_secs: i64,
) -> Vec<ControlRouteRecord> {
    let Some(payload) = olaz_json::parse_object_str(&payload_json) else {
        return Vec::new();
    };
    classify(cmd, payload, &my_uid, now_unix_secs)
        .into_iter()
        .filter_map(|route| match route {
            Route::RecordFileDone { file_id, url } => {
                Some(ControlRouteRecord::RecordFileDone { file_id, url })
            }
            Route::LogUndecodedControl {
                cmd,
                encrypt,
                data_is_string,
            } => Some(ControlRouteRecord::LogUndecodedControl {
                cmd,
                encrypt,
                data_is_string,
            }),
            Route::VoipControl {
                act,
                raw_data,
                data,
            } => Some(ControlRouteRecord::VoipControl {
                act,
                raw_data_json: to_swift_json_string(&raw_data),
                data_json: to_swift_json_string(&Value::Object(data)),
            }),
            Route::LogTypingShape { shape } => Some(ControlRouteRecord::LogTypingShape { shape }),
            Route::ShowTyping {
                conv_id,
                uid,
                on_pc,
            } => Some(ControlRouteRecord::ShowTyping {
                conv_id,
                uid,
                on_pc,
            }),
            Route::PinTopic { conv_id } => Some(ControlRouteRecord::PinTopic { conv_id }),
            Route::GroupNotice { act, data, ts } => Some(ControlRouteRecord::GroupNotice {
                act,
                data_json: to_swift_json_string(&Value::Object(data)),
                ts,
            }),
            Route::Mute {
                conv_id,
                set,
                start,
                start_explicit,
                duration,
            } => Some(ControlRouteRecord::Mute {
                conv_id,
                set,
                start,
                start_explicit,
                duration,
            }),
            Route::SessionExpired { .. }
            | Route::E2eeSignal { .. }
            | Route::E2eeDeliverReports { .. }
            | Route::LogSyncAck { .. }
            | Route::MobileSync(_)
            | Route::ApplyBatch { .. } => None,
        })
        .collect()
}

/// Pure conversation list ordering backed by `olaz_core::conversations::sort_conversations`.
#[uniffi::export]
pub fn sort_conversations_order(
    items: Vec<ConversationSummaryRecord>,
    activity_ranks: Vec<RankEntry>,
) -> Vec<ConversationSummaryRecord> {
    let mut list: Vec<ConversationSummary> = items.into_iter().map(Into::into).collect();
    let mut ranks = BTreeMap::new();
    for entry in activity_ranks {
        ranks.insert(entry.conv_id, entry.rank);
    }
    sort_conversations(&mut list, &ranks);
    list.into_iter().map(Into::into).collect()
}

/// Pure synchronous wrapper around `olaz_core::reduce::reduce` for offline unit tests where
/// `ZaloEngine` is constructed without calling `start()` (never allocated when `CoreEngine` runs).
#[derive(uniffi::Object)]
pub struct CoreOfflineConversations {
    inner: Mutex<(CoreState, u64)>,
}

impl CoreOfflineConversations {
    fn apply_cmd(&self, cmd: Command) -> CoreChangesRecord {
        let mut guard = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
        let (state, version) = &mut *guard;
        let out = reduce(state, Input::Command(cmd));
        if !out.dirty.is_empty() {
            *version = version.saturating_add(1);
        }
        let _ = state.messages.take_pending_window_ops();
        let mut rec = CoreChangesRecord {
            version: *version,
            session: None,
            conversations: None,
            conversation_flags: None,
            conversation_extras: None,
            conversation_ui: None,
            conversation_prompt: None,
            window_deltas: Vec::new(),
            messages_reset_all: false,
            message_meta: None,
            contacts: None,
            typing: None,
            forward_request: None,
            clear_selection: false,
            delete_undo: None,
            message_confirm: None,
            auto_delete: None,
            starred_ids: None,
            cached_profiles: None,
            notification_settings: None,
            aliases: None,
            polls: None,
        };
        for key in out.dirty {
            match key {
                DirtyKey::Session => rec.session = Some(state.session.snapshot().into()),
                DirtyKey::Conversations => {
                    rec.conversations = Some(
                        state
                            .conversations
                            .conversations
                            .iter()
                            .cloned()
                            .map(Into::into)
                            .collect(),
                    );
                }
                DirtyKey::ConversationFlags => {
                    rec.conversation_flags = Some(state.conversations.actions.clone().into());
                }
                DirtyKey::ConversationExtras => {
                    rec.conversation_extras = Some(state.conversations.extras.clone().into());
                }
                DirtyKey::ConversationUi => {
                    rec.conversation_ui = Some(state.conversations.ui.clone().into());
                }
                DirtyKey::ConversationPrompt => {
                    rec.conversation_prompt = Some(PromptUpdateRecord {
                        prompt: state.conversations.prompt.clone().map(Into::into),
                    });
                }
                DirtyKey::Messages => {}
                DirtyKey::MessageMeta => {
                    rec.message_meta = Some(snapshot_message_meta(state).into());
                }
                DirtyKey::MessagesResetAll => {
                    rec.messages_reset_all = true;
                }
                DirtyKey::Contacts => {
                    rec.contacts = Some(state.contacts.clone().into());
                }
                DirtyKey::Typing => {
                    rec.typing = Some(
                        state
                            .typing
                            .active
                            .iter()
                            .map(|(conv_id, status)| TypingEntryRecord {
                                conv_id: conv_id.clone(),
                                name: status.name.clone(),
                                on_pc: status.on_pc,
                            })
                            .collect(),
                    );
                }
                DirtyKey::ForwardRequest => {
                    rec.forward_request = Some(ForwardRequestUpdateRecord {
                        request: state.forward.request.clone().map(Into::into),
                    });
                }
                DirtyKey::ForwardClearSelection => {
                    rec.clear_selection = true;
                }
                // U6 (wired to FFI once U4+U6 cut over Swift)
                DirtyKey::DeleteUndo
                | DirtyKey::MessageConfirm
                | DirtyKey::AutoDelete
                | DirtyKey::StarredIds
                | DirtyKey::CachedProfiles
                | DirtyKey::NotificationSettings
                | DirtyKey::Aliases => {}
                DirtyKey::Polls => {
                    rec.polls = Some(state.polls.clone().into());
                }
            }
        }
        rec
    }
}

#[uniffi::export]
impl CoreOfflineConversations {
    #[uniffi::constructor]
    pub fn new() -> Arc<Self> {
        Arc::new(Self {
            inner: Mutex::new((CoreState::default(), 0)),
        })
    }

    pub fn sync_context(
        &self,
        identities: IdentityTableRecord,
        my_uid: String,
        my_avatar: Option<String>,
        self_conv_id: Option<String>,
        open_conv_id: Option<String>,
    ) {
        let mut guard = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
        let (state, _) = &mut *guard;
        state.conversations.identities = identities.into();
        state.conversations.open_conversation_id = open_conv_id;
        state.session.self_conversation_id = self_conv_id;
        if !my_uid.is_empty() {
            state.session.profile = Some(Profile {
                user_id: my_uid,
                display_name: String::new(),
                avatar: my_avatar,
                phone: None,
            });
        }
    }

    pub fn sync_conversations(&self, list: Vec<ConversationSummaryRecord>) {
        let mut guard = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
        guard.0.conversations.conversations = list.into_iter().map(Into::into).collect();
    }

    pub fn update_conversation_on_message(
        &self,
        msg: MessagePreviewInputRecord,
        increment_unread: bool,
    ) -> CoreChangesRecord {
        self.apply_cmd(Command::UpdateConversationOnMessage {
            msg: msg.into(),
            increment_unread,
        })
    }

    pub fn apply_preview_override(
        &self,
        override_rec: ConvPreviewOverrideRecord,
        persist_conversations: bool,
    ) -> CoreChangesRecord {
        self.apply_cmd(Command::ApplyBatchDelta(BatchApplyDelta {
            applied_count: 0,
            updates: Vec::new(),
            preview_overrides: vec![override_rec.into()],
            persist_conversations,
        }))
    }

    pub fn ensure_known_contacts(&self) -> CoreChangesRecord {
        self.apply_cmd(Command::EnsureKnownContacts)
    }

    pub fn rebuild_conversation_extras(&self) -> CoreChangesRecord {
        self.apply_cmd(Command::RebuildConversationExtras)
    }

    pub fn republish_conversation_actions(&self) -> CoreChangesRecord {
        self.apply_cmd(Command::RepublishConversationActions)
    }

    pub fn handle_conversation_actions(&self, state_json: String) -> CoreChangesRecord {
        let map = olaz_json::parse_object_str(&state_json).unwrap_or_default();
        self.apply_cmd(Command::HandleConversationActions { state: map })
    }

    pub fn handle_conversation_extras(&self, state_json: String) -> CoreChangesRecord {
        let map = olaz_json::parse_object_str(&state_json).unwrap_or_default();
        self.apply_cmd(Command::HandleConversationExtras { state: map })
    }

    pub fn set_conversation_filter(
        &self,
        filter_type: i32,
        label_ids: Vec<String>,
    ) -> CoreChangesRecord {
        self.apply_cmd(Command::SetConversationFilter {
            filter_type,
            label_ids,
        })
    }

    pub fn report_conversation_action_result(
        &self,
        result: ConversationActionResultRecord,
    ) -> CoreChangesRecord {
        self.apply_cmd(Command::ReportConversationActionResult(result.into()))
    }

    pub fn reset_conversation_actions(&self) -> CoreChangesRecord {
        self.apply_cmd(Command::ResetConversationActions)
    }

    pub fn set_conversation_prompt(
        &self,
        prompt: Option<ConversationPromptRecord>,
    ) -> CoreChangesRecord {
        self.apply_cmd(Command::SetConversationPrompt(prompt.map(Into::into)))
    }
}

/// Platform host callbacks implemented by Swift (`ZaloEngineCoreHost`).
///
/// Called serially in emitted order on the core's host worker; never invoked concurrently.
/// `snapshot_json` in `persist_session` / `mark_expired` contains credentials and must never be
/// logged.
#[uniffi::export(with_foreign)]
#[async_trait::async_trait]
pub trait CoreHost: Send + Sync {
    async fn load_saved_session(&self) -> Option<String>;
    async fn load_legacy_cookie(&self) -> Option<LegacyCookieRecord>;
    async fn load_transport_state(&self) -> PersistedTransportStateRecord;
    async fn set_pref(&self, key: String, value: String);
    async fn prepare_store(&self, user_id: String, account: LoginAccountRecord);
    /// Return `true` to connect WebSocket, `false` to suppress (used by session/transport recorders).
    async fn on_ws_started(&self, endpoints: Vec<String>) -> bool;
    /// Return `true` to start periodic long-poll ticks, `false` to suppress.
    async fn on_long_poll_started(&self) -> bool;
    async fn on_bootstrap_started(&self) -> bool;
    async fn apply_mutes(&self, mutes: Vec<MuteEntryRecord>);
    async fn refresh_cloud(&self);
    async fn on_batch_received(
        &self,
        cmd: Option<u16>,
        increment_unread: bool,
        notify_incoming: bool,
        payload_json: String,
    ) -> Option<String>;
    async fn on_parsed_events_received(
        &self,
        cmd: u16,
        increment_unread: bool,
        notify_incoming: bool,
        events: Vec<WireEvent>,
        uids: Vec<String>,
        payload: Arc<CoreWirePayload>,
    ) -> bool;
    async fn on_open_conversation_sync(&self, conv_id: String, changed: bool);
    async fn on_close_conversation(&self);
    async fn refresh_board_pins(&self, conv_id: String);
    async fn mark_read_boundary(&self, conv_id: String, seen_target: Option<SeenTargetRecord>);
    #[expect(
        clippy::too_many_arguments,
        reason = "Matches apply_remote_reaction case schema fields 1-for-1"
    )]
    async fn apply_remote_reaction(
        &self,
        conv_id: String,
        msg_id: String,
        cli_msg_id: String,
        sender_id: String,
        r_type: String,
        r_icon: String,
        event_id: String,
        react_client_id: String,
        sender_name: String,
    ) -> bool;
    async fn apply_remote_recall(
        &self,
        conv_id: String,
        msg_id: String,
        cli_msg_id: String,
        update_conversation_preview: bool,
        persist_conversations: bool,
    ) -> bool;
    async fn apply_remote_delete(
        &self,
        conv_id: String,
        msg_id: String,
        cli_msg_id: String,
        update_conversation_preview: bool,
        persist_conversations: bool,
    ) -> bool;
    async fn decrypt_envelope(&self, payload_json: String) -> String;
    async fn mark_e2ee_conversations(&self, conv_ids: Vec<String>);
    async fn note_poll_messages(&self, messages: Vec<ChatMessageRecord>);
    async fn notify_incoming_messages(&self, messages: Vec<ChatMessageRecord>);
    async fn show_batch_typing(&self, conv_id: String, sender_id: String);
    async fn transport_batch_settled(&self);
    async fn engine_log(&self, message: String);
    async fn offer_first_login_transfer(&self, force: bool);
    async fn reset_domains(&self);
    async fn persist_session(&self, snapshot_json: String);
    async fn clear_session(&self);
    async fn mark_expired(&self, snapshot_json: String);

    // --- Transport domain callbacks (U2 / U3) ---
    async fn persist_poll_state(&self, state: PollStateRecord);
    async fn persist_ws_cursors(&self, cursors: Vec<CursorEntry>);
    async fn mobile_sync(&self, events: Vec<MobileSyncEventRecord>);
    async fn e2ee_signal(&self, cmd: u16, payload_json: String);
    async fn e2ee_deliver_reports(&self, cmd: u16, payload_json: String);
    async fn e2ee_connected(&self, uid: String);
    async fn e2ee_disconnected(&self);
    async fn voip_control(&self, act: String, raw_data_json: String, data_json: String);
    async fn show_typing(&self, conv_id: String, uid: String, on_pc: bool);
    async fn pin_topic(&self, conv_id: String);
    async fn group_notice(&self, act: String, data_json: String, ts: i64);
    async fn mute(
        &self,
        conv_id: String,
        set: bool,
        start: i64,
        start_explicit: bool,
        duration: i64,
    );
    async fn send_e2ee_text(
        &self,
        conv_id: String,
        text: String,
        client_id: String,
        quote: Option<E2eeQuoteArgRecord>,
    ) -> E2eeSendOutcomeRecord;

    // --- Forward domain callbacks (U8) ---
    async fn show_card(&self, conv_id: Option<String>, text: String);
    async fn resolve_media(
        &self,
        conv_id: String,
        msg_id: String,
        kind: String,
    ) -> MediaResolutionRecord;
    async fn resolve_file(
        &self,
        conv_id: String,
        msg_id: String,
        name: String,
        url: Option<String>,
    ) -> FileResolutionRecord;
    async fn fetch_media_data(&self, url: String) -> Option<String>;
    async fn send_media(
        &self,
        conv_id: String,
        paths: Vec<String>,
        cleanup_after: bool,
    ) -> ComposerSendOutcomeRecord;
    async fn send_files(&self, conv_id: String, paths: Vec<String>) -> ComposerSendOutcomeRecord;

    // --- Group polls domain callbacks (U12) ---
    async fn arm_poll_debounce(&self, poll_id: String, seq: u64, delay_ms: u64) -> bool;
    async fn cancel_all_poll_debounces(&self);

    // --- U16 notification & card-action host callbacks ---
    async fn notify_banners(&self, banners: Vec<NotifyBannerPayloadRecord>);
    async fn request_notif_auth(&self) -> NotifAuthorizationRecord;
    async fn start_call(&self, uid: String, video: bool);
    async fn send_category_sticker(
        &self,
        conv_id: String,
        cate_id: i32,
        sticker_id: i32,
    ) -> CardActionOutcomeRecord;
    async fn refresh_contacts(&self);
    async fn arm_reminder_watch_timer(&self, waiter_id: u64, delay_secs: f64) -> bool;
    async fn cancel_reminder_watch_timer(&self, waiter_id: u64);
}

struct FfiHostBridge(Arc<dyn CoreHost>);

#[async_trait::async_trait]
impl Host for FfiHostBridge {
    async fn load_saved_session(&self) -> Option<String> {
        self.0.load_saved_session().await
    }

    async fn load_legacy_cookie(&self) -> Option<LegacyCookie> {
        self.0.load_legacy_cookie().await.map(Into::into)
    }

    async fn load_transport_state(&self) -> PersistedTransportState {
        self.0.load_transport_state().await.into()
    }

    async fn set_pref(&self, key: String, value: String) {
        self.0.set_pref(key, value).await;
    }

    async fn prepare_store(&self, user_id: String, account: LoginAccount) {
        self.0.prepare_store(user_id, account.into()).await;
    }

    async fn on_ws_started(&self, endpoints: Vec<String>) -> bool {
        self.0.on_ws_started(endpoints).await
    }

    async fn on_long_poll_started(&self) -> bool {
        self.0.on_long_poll_started().await
    }

    async fn start_bootstrap(&self) {
        let _ = self.0.on_bootstrap_started().await;
    }

    async fn on_bootstrap_started(&self) -> bool {
        self.0.on_bootstrap_started().await
    }

    async fn apply_mutes(&self, mutes: Vec<MuteEntry>) {
        self.0
            .apply_mutes(mutes.into_iter().map(Into::into).collect())
            .await;
    }

    async fn refresh_cloud(&self) {
        self.0.refresh_cloud().await;
    }

    async fn on_batch_received(
        &self,
        cmd: Option<u16>,
        increment_unread: bool,
        notify_incoming: bool,
        payload: Map<String, Value>,
    ) -> BatchHookOutcome {
        let payload_json = to_swift_json_string(&Value::Object(payload.clone()));
        match self
            .0
            .on_batch_received(cmd, increment_unread, notify_incoming, payload_json)
            .await
        {
            Some(decrypted_json) => BatchHookOutcome::IngestInCore(
                olaz_json::parse_object_str(&decrypted_json).unwrap_or(payload),
            ),
            None => BatchHookOutcome::Suppressed,
        }
    }

    async fn on_parsed_events_received(
        &self,
        cmd: u16,
        increment_unread: bool,
        notify_incoming: bool,
        envelope: &TypedChatEnvelope,
    ) -> ParsedEventsHookOutcome {
        let events = envelope
            .events
            .iter()
            .cloned()
            .map(convert_wire_event)
            .collect();
        let payload = Arc::new(CoreWirePayload {
            inner: Arc::clone(&envelope.payload),
        });
        if self
            .0
            .on_parsed_events_received(
                cmd,
                increment_unread,
                notify_incoming,
                events,
                envelope.uids.clone(),
                payload,
            )
            .await
        {
            ParsedEventsHookOutcome::IngestInCore
        } else {
            ParsedEventsHookOutcome::Suppressed
        }
    }

    async fn on_open_conversation_sync(&self, conv_id: String, changed: bool) {
        self.0.on_open_conversation_sync(conv_id, changed).await;
    }

    async fn on_close_conversation(&self) {
        self.0.on_close_conversation().await;
    }

    async fn refresh_board_pins(&self, conv_id: String) {
        self.0.refresh_board_pins(conv_id).await;
    }

    async fn mark_read_boundary(
        &self,
        conv_id: String,
        seen_target: Option<olaz_core::input::SeenTarget>,
    ) {
        let rec = seen_target.map(|t| SeenTargetRecord {
            conv_id: t.conv_id,
            msg_id: t.msg_id,
            cli_msg_id: t.cli_msg_id,
            sender_id: t.sender_id,
        });
        self.0.mark_read_boundary(conv_id, rec).await;
    }

    async fn apply_remote_reaction(
        &self,
        conv_id: String,
        msg_id: String,
        cli_msg_id: String,
        sender_id: String,
        r_type: String,
        r_icon: String,
        event_id: String,
        react_client_id: String,
        sender_name: String,
    ) -> bool {
        self.0
            .apply_remote_reaction(
                conv_id,
                msg_id,
                cli_msg_id,
                sender_id,
                r_type,
                r_icon,
                event_id,
                react_client_id,
                sender_name,
            )
            .await
    }

    async fn apply_remote_recall(
        &self,
        conv_id: String,
        msg_id: String,
        cli_msg_id: String,
        update_conversation_preview: bool,
        persist_conversations: bool,
    ) -> bool {
        self.0
            .apply_remote_recall(
                conv_id,
                msg_id,
                cli_msg_id,
                update_conversation_preview,
                persist_conversations,
            )
            .await
    }

    async fn apply_remote_delete(
        &self,
        conv_id: String,
        msg_id: String,
        cli_msg_id: String,
        update_conversation_preview: bool,
        persist_conversations: bool,
    ) -> bool {
        self.0
            .apply_remote_delete(
                conv_id,
                msg_id,
                cli_msg_id,
                update_conversation_preview,
                persist_conversations,
            )
            .await
    }

    async fn decrypt_envelope(&self, payload: Map<String, Value>) -> Map<String, Value> {
        let payload_json = to_swift_json_string(&Value::Object(payload.clone()));
        let decrypted_json = self.0.decrypt_envelope(payload_json).await;
        olaz_json::parse_object_str(&decrypted_json).unwrap_or(payload)
    }

    async fn mark_e2ee_conversations(&self, conv_ids: Vec<String>) {
        self.0.mark_e2ee_conversations(conv_ids).await;
    }

    async fn note_poll_messages(&self, messages: Vec<ChatMessage>) {
        self.0
            .note_poll_messages(messages.into_iter().map(Into::into).collect())
            .await;
    }

    async fn notify_incoming_messages(&self, messages: Vec<ChatMessage>) {
        self.0
            .notify_incoming_messages(messages.into_iter().map(Into::into).collect())
            .await;
    }

    async fn show_batch_typing(&self, conv_id: String, sender_id: String) {
        self.0.show_batch_typing(conv_id, sender_id).await;
    }

    async fn transport_batch_settled(&self) {
        self.0.transport_batch_settled().await;
    }

    async fn engine_log(&self, message: String) {
        self.0.engine_log(message).await;
    }

    async fn offer_first_login_transfer(&self, force: bool) {
        self.0.offer_first_login_transfer(force).await;
    }

    async fn reset_domains(&self) {
        self.0.reset_domains().await;
    }

    async fn persist_session(&self, snapshot_json: String) {
        self.0.persist_session(snapshot_json).await;
    }

    async fn clear_session(&self) {
        self.0.clear_session().await;
    }

    async fn mark_expired(&self, snapshot_json: String) {
        self.0.mark_expired(snapshot_json).await;
    }

    async fn persist_poll_state(&self, state: PollState) {
        self.0
            .persist_poll_state(PollStateRecord::from(&state))
            .await;
    }

    async fn persist_ws_cursors(&self, cursors: CursorMap) {
        self.0
            .persist_ws_cursors(cursors_to_entries(&cursors))
            .await;
    }

    async fn apply_batch(
        &self,
        _cmd: Option<u16>,
        _increment_unread: bool,
        _notify_incoming: bool,
        _payload: Map<String, Value>,
    ) -> BatchApplyDelta {
        BatchApplyDelta::default()
    }

    async fn apply_parsed_events(
        &self,
        _cmd: u16,
        _increment_unread: bool,
        _notify_incoming: bool,
        _envelope: TypedChatEnvelope,
    ) -> BatchApplyDelta {
        BatchApplyDelta::default()
    }

    async fn mobile_sync(&self, events: Vec<MobileSyncEvent>) {
        self.0
            .mobile_sync(events.into_iter().map(Into::into).collect())
            .await;
    }

    async fn e2ee_signal(&self, cmd: u16, payload: Map<String, Value>) {
        let payload_json = to_swift_json_string(&Value::Object(payload));
        self.0.e2ee_signal(cmd, payload_json).await;
    }

    async fn e2ee_deliver_reports(&self, cmd: u16, payload: Map<String, Value>) {
        let payload_json = to_swift_json_string(&Value::Object(payload));
        self.0.e2ee_deliver_reports(cmd, payload_json).await;
    }

    async fn e2ee_connected(&self, uid: String) {
        self.0.e2ee_connected(uid).await;
    }

    async fn e2ee_disconnected(&self) {
        self.0.e2ee_disconnected().await;
    }

    async fn voip_control(&self, act: String, raw_data: Value, data: Map<String, Value>) {
        let raw_data_json = to_swift_json_string(&raw_data);
        let data_json = to_swift_json_string(&Value::Object(data));
        self.0.voip_control(act, raw_data_json, data_json).await;
    }

    async fn show_typing(&self, conv_id: String, uid: String, on_pc: bool) {
        self.0.show_typing(conv_id, uid, on_pc).await;
    }

    async fn pin_topic(&self, conv_id: String) {
        self.0.pin_topic(conv_id).await;
    }

    async fn group_notice(&self, act: String, data: Map<String, Value>, ts: i64) {
        let data_json = to_swift_json_string(&Value::Object(data));
        self.0.group_notice(act, data_json, ts).await;
    }

    async fn mute(
        &self,
        conv_id: String,
        set: bool,
        start: i64,
        start_explicit: bool,
        duration: i64,
    ) {
        self.0
            .mute(conv_id, set, start, start_explicit, duration)
            .await;
    }

    async fn send_e2ee_text(
        &self,
        conv_id: String,
        text: String,
        client_id: String,
        quote: Option<E2eeQuoteArg>,
    ) -> Result<SendMessageResult, String> {
        match self
            .0
            .send_e2ee_text(conv_id, text, client_id, quote.map(Into::into))
            .await
        {
            E2eeSendOutcomeRecord::Sent {
                msg_id,
                cli_msg_id,
                ts_ms,
            } => Ok(SendMessageResult {
                msg_id,
                cli_msg_id,
                ts_ms,
            }),
            E2eeSendOutcomeRecord::Failed { message } => Err(message),
            E2eeSendOutcomeRecord::Aborted => Err(String::new()),
        }
    }

    async fn arm_poll_debounce(&self, poll_id: String, seq: u64, delay_ms: u64) -> bool {
        self.0.arm_poll_debounce(poll_id, seq, delay_ms).await
    }

    async fn cancel_all_poll_debounces(&self) {
        self.0.cancel_all_poll_debounces().await;
    }

    async fn show_card(&self, conv_id: Option<String>, text: String) {
        self.0.show_card(conv_id, text).await;
    }

    async fn resolve_media(
        &self,
        conv_id: String,
        msg_id: String,
        kind: String,
    ) -> MediaResolutionOutcome {
        self.0.resolve_media(conv_id, msg_id, kind).await.into()
    }

    async fn resolve_file(
        &self,
        conv_id: String,
        msg_id: String,
        name: String,
        url: Option<String>,
    ) -> FileResolutionOutcome {
        self.0.resolve_file(conv_id, msg_id, name, url).await.into()
    }

    async fn fetch_media_data(&self, url: String) -> Option<String> {
        self.0.fetch_media_data(url).await
    }

    async fn send_media(
        &self,
        conv_id: String,
        paths: Vec<String>,
        cleanup_after: bool,
    ) -> ComposerSendOutcome {
        self.0
            .send_media(conv_id, paths, cleanup_after)
            .await
            .into()
    }

    async fn send_files(&self, conv_id: String, paths: Vec<String>) -> ComposerSendOutcome {
        self.0.send_files(conv_id, paths).await.into()
    }

    async fn notify_banners(&self, banners: Vec<olaz_core::NotifyBannerPayload>) {
        self.0
            .notify_banners(banners.into_iter().map(Into::into).collect())
            .await;
    }

    async fn request_notif_auth(&self) -> olaz_core::NotifAuthorization {
        self.0.request_notif_auth().await.into()
    }

    async fn start_call(&self, uid: String, video: bool) {
        self.0.start_call(uid, video).await;
    }

    async fn send_category_sticker(
        &self,
        conv_id: String,
        cate_id: i32,
        sticker_id: i32,
    ) -> olaz_core::CardActionOutcomeData {
        self.0
            .send_category_sticker(conv_id, cate_id, sticker_id)
            .await
            .into()
    }

    async fn refresh_contacts(&self) {
        self.0.refresh_contacts().await;
    }

    async fn arm_reminder_watch_timer(&self, waiter_id: u64, delay_secs: f64) -> bool {
        self.0.arm_reminder_watch_timer(waiter_id, delay_secs).await
    }

    async fn cancel_reminder_watch_timer(&self, waiter_id: u64) {
        self.0.cancel_reminder_watch_timer(waiter_id).await;
    }
}

fn parse_inner_json(json: &str) -> Result<Map<String, Value>, CoreError> {
    if json.trim().is_empty() {
        return Ok(Map::new());
    }
    olaz_json::parse_object_str(json).ok_or_else(|| CoreError::Parse {
        message: "request data is not a JSON object".to_owned(),
    })
}

/// The `olaz-core` actor handle exported to Swift.
///
/// Owns session, transport, and conversations/conversation-actions state (boot, QR login, expiry,
/// logout, WebSocket lifecycle, long-poll loop, event routing, conversation list/filters/labels,
/// pin/archive/delete/unread/hidden actions) over the shared [`CoreSession`] and [`CoreStore`].
/// Swift pushes commands via sync/async methods and pulls coalesced updates via [`Self::next_changes`].
#[derive(uniffi::Object)]
pub struct CoreEngine {
    handle: Arc<CoreHandle>,
    runner: Arc<SessionEffectRunner<ReqwestTransport>>,
    session_client: Arc<SessionClient<ReqwestTransport>>,
    ws_driver: Arc<dyn WsDriver>,
    shared_store: SharedStoreSlot,
}

#[uniffi::export]
impl CoreEngine {
    /// Starts the `olaz-core` actor on the shared tokio runtime.
    #[uniffi::constructor]
    pub fn new(session: Arc<CoreSession>, host: Arc<dyn CoreHost>) -> Result<Arc<Self>, CoreError> {
        let rt_handle = runtime()?.handle().clone();
        let session_client = Arc::clone(&session.client);
        let runner = Arc::new(SessionEffectRunner::with_default_domains(
            Arc::clone(&session_client),
            Arc::new(FfiHostBridge(host)),
            rt_handle.clone(),
            session.default_domains.clone(),
        ));
        let ws_driver = Arc::clone(runner.ws_driver());
        let shared_store = runner.shared_store_slot();
        let runner_dyn: Arc<dyn olaz_core::EffectRunner> =
            Arc::clone(&runner) as Arc<dyn olaz_core::EffectRunner>;
        let handle = CoreHandle::start(runner_dyn, rt_handle);
        Ok(Arc::new(Self {
            handle: Arc::new(handle),
            runner,
            session_client,
            ws_driver,
            shared_store,
        }))
    }

    /// Attaches the account's opened [`CoreStore`] so `olaz-core` can hydrate local conversation
    /// state and run serial SQLite persistence directly without Swift hops.
    pub fn attach_store(&self, store: Arc<CoreStore>) {
        *self
            .shared_store
            .lock()
            .unwrap_or_else(PoisonError::into_inner) = Some(store.shared_store());
    }

    /// Detaches any attached [`CoreStore`] handle.
    pub fn detach_store(&self) {
        *self
            .shared_store
            .lock()
            .unwrap_or_else(PoisonError::into_inner) = None;
    }

    /// Starts the engine (idempotent; subsequent calls are no-ops).
    pub fn start(&self) {
        self.handle.send(Command::Start);
    }

    /// Cancels any active QR attempt and requests a fresh QR code.
    pub fn refresh_qr(&self) {
        self.handle.send(Command::RefreshQr);
    }

    /// Clears session credentials, resets Swift domains, and starts fresh QR login.
    pub fn log_out(&self) {
        self.handle.send(Command::LogOut);
    }

    /// Handles a server-reported session expiry (`600` / `-102`) from any domain.
    pub fn handle_session_expired_notice(&self, reason: String) {
        self.handle.send(Command::SessionExpired { reason });
    }

    /// Applies an account profile update and returns the monotonic change revision once reduced.
    /// Swift awaits this revision in its `next_changes()` mirror before returning from
    /// `async func applyAccountProfile(_:)`.
    pub async fn apply_account_profile(
        &self,
        account: LoginAccountRecord,
    ) -> Result<u64, CoreError> {
        let handle = Arc::clone(&self.handle);
        let rev = run(async move {
            handle
                .send_and_ack(Command::ApplyAccountProfile(account.into()))
                .await
                .unwrap_or(0)
        })
        .await?;
        Ok(rev)
    }

    /// Runs up to `max_batches` HTTP long-poll fetches serially (ADR-018) and returns the total
    /// number of events applied across those batches.
    pub async fn drain_chat_polling(
        &self,
        max_batches: u32,
        notify_incoming: bool,
    ) -> Result<u32, CoreError> {
        let handle = Arc::clone(&self.handle);
        let count = run(async move {
            handle
                .drain_chat_polling(max_batches, notify_incoming)
                .await
        })
        .await?;
        Ok(count)
    }

    // --- Conversations & conversation actions domain (U3) ---

    /// Synchronously enqueues an updated identity table (FIFO-ordered before any later command).
    pub fn update_identities(&self, table: IdentityTableRecord) {
        self.handle.send(Command::UpdateIdentities(table.into()));
    }

    /// Synchronously seeds the conversation list in core (used when tests assign `conversations`).
    pub fn sync_conversations_snapshot(&self, list: Vec<ConversationSummaryRecord>) {
        self.handle.send(Command::SyncConversationsSnapshot(
            list.into_iter().map(Into::into).collect(),
        ));
    }

    /// Applies a standalone recall/delete [`ConvPreviewOverrideRecord`] and awaits store persistence.
    pub async fn apply_preview_override(
        &self,
        override_rec: ConvPreviewOverrideRecord,
        persist_conversations: bool,
    ) -> Result<u64, CoreError> {
        let handle = Arc::clone(&self.handle);
        let runner = Arc::clone(&self.runner);
        run(async move {
            handle
                .request_unit(Command::ApplyBatchDelta(BatchApplyDelta {
                    applied_count: 0,
                    updates: Vec::new(),
                    preview_overrides: vec![override_rec.into()],
                    persist_conversations,
                }))
                .await;
            if persist_conversations {
                runner.flush_store().await;
            }
            handle.current_version()
        })
        .await
    }

    /// Synchronously enqueues a single-message conversation preview/unread update.
    pub fn update_conversation_on_message(
        &self,
        msg: MessagePreviewInputRecord,
        increment_unread: bool,
    ) {
        self.handle.send(Command::UpdateConversationOnMessage {
            msg: msg.into(),
            increment_unread,
        });
    }

    /// Synchronously enqueues `EnsureKnownContacts`.
    pub fn ensure_known_contacts(&self) {
        self.handle.send(Command::EnsureKnownContacts);
    }

    /// Resolves missing conversation display names in 50-UID chunks via `get_profiles`.
    pub async fn resolve_missing_names(&self) -> Result<u64, CoreError> {
        let handle = Arc::clone(&self.handle);
        run(async move {
            handle.request_unit(Command::ResolveMissingNames).await;
            handle.current_version()
        })
        .await
    }

    /// Refreshes group `@mention` previews from the attached SQLite store.
    pub async fn refresh_mention_previews(&self) -> Result<u64, CoreError> {
        let handle = Arc::clone(&self.handle);
        run(async move {
            handle.request_unit(Command::RefreshMentionPreviews).await;
            handle.current_version()
        })
        .await
    }

    /// Synchronously enqueues the currently open conversation ID (or `None`).
    pub fn set_open_conversation(&self, id: Option<String>) {
        self.handle.send(Command::SetOpenConversation { id });
    }

    /// Persists the current conversation list to SQLite and awaits completion.
    pub async fn persist_conversations(&self) -> Result<u64, CoreError> {
        let handle = Arc::clone(&self.handle);
        run(async move {
            handle.request_unit(Command::PersistConversations).await;
            handle.current_version()
        })
        .await
    }

    /// Pins a conversation (or opens the `PinBoard` prompt when at the 10-pin limit).
    pub fn pin_conversation(&self, id: String) {
        self.handle.send(Command::PinConversation { id });
    }

    /// Unpins a conversation.
    pub fn unpin_conversation(&self, id: String) {
        self.handle.send(Command::UnpinConversation { id });
    }

    /// Computes the current [`PinBoardRecord`] for replacing pins.
    pub async fn request_pin_board(&self, id: String) -> Result<Option<PinBoardRecord>, CoreError> {
        let handle = Arc::clone(&self.handle);
        let board = run(async move { handle.request_pin_board(id).await }).await?;
        Ok(board.map(Into::into))
    }

    /// Unpins `unpin_ids` in order, then pins `pin_id`.
    pub async fn pin_replacing(
        &self,
        unpin_ids: Vec<String>,
        pin_id: String,
    ) -> Result<ConversationActionResultRecord, CoreError> {
        let handle = Arc::clone(&self.handle);
        let res = run(async move {
            handle
                .request_action(Command::PinReplacing { unpin_ids, pin_id })
                .await
        })
        .await?;
        Ok(res.into())
    }

    /// Moves a conversation between Focus (`to_other = false`) and Other (`to_other = true`).
    pub fn move_conversation(&self, id: String, to_other: bool) {
        self.handle.send(Command::MoveConversation { id, to_other });
    }

    /// Opens the delete confirmation prompt for `id`.
    pub fn request_delete_conversation(&self, id: String) {
        self.handle.send(Command::RequestDeleteConversation { id });
    }

    /// Deletes a conversation on the server, in SQLite, and in memory.
    pub fn confirm_delete_conversation(&self, id: String, last_cli_msg_id: String) {
        self.handle.send(Command::ConfirmDeleteConversation {
            id,
            last_cli_msg_id,
        });
    }

    /// Clears the active conversation prompt.
    pub fn dismiss_conversation_prompt(&self) {
        self.handle.send(Command::DismissConversationPrompt);
    }

    /// Sets or clears the active conversation prompt.
    pub fn set_conversation_prompt(&self, prompt: Option<ConversationPromptRecord>) {
        self.handle
            .send(Command::SetConversationPrompt(prompt.map(Into::into)));
    }

    /// Marks a conversation read (clears unread count & manual unread mark, optional read receipt).
    pub fn mark_conversation_read(&self, id: String, seen_target: Option<SeenTargetRecord>) {
        self.handle.send(Command::MarkConversationRead {
            id,
            seen_target: seen_target.map(Into::into),
        });
    }

    /// Adds a manual unread mark to `id`.
    pub fn mark_conversation_unread(&self, id: String) {
        self.handle.send(Command::MarkConversationUnread { id });
    }

    /// Checks whether `pin` matches the stored hidden-chat PIN digest (MD5 or offline SHA-256).
    pub async fn check_hidden_pin(&self, pin: String) -> Result<bool, CoreError> {
        let handle = Arc::clone(&self.handle);
        run(async move { handle.request_bool(Command::CheckHiddenPin { pin }).await }).await
    }

    /// Hides a conversation after verifying the existing PIN.
    pub async fn hide_conversation(
        &self,
        id: String,
        pin: String,
    ) -> Result<ConversationActionResultRecord, CoreError> {
        let handle = Arc::clone(&self.handle);
        let res = run(async move {
            handle
                .request_action(Command::HideConversation { id, pin })
                .await
        })
        .await?;
        Ok(res.into())
    }

    /// Sets a new hidden-chat PIN and hides `id`.
    pub async fn hide_conversation_new_pin(
        &self,
        id: String,
        pin: String,
    ) -> Result<ConversationActionResultRecord, CoreError> {
        let handle = Arc::clone(&self.handle);
        let res = run(async move {
            handle
                .request_action(Command::HideConversationNewPin { id, pin })
                .await
        })
        .await?;
        Ok(res.into())
    }

    /// Unhides `id`, verifying `pin` when provided.
    pub async fn unhide_conversation(
        &self,
        id: String,
        pin: Option<String>,
    ) -> Result<ConversationActionResultRecord, CoreError> {
        let handle = Arc::clone(&self.handle);
        let res = run(async move {
            handle
                .request_action(Command::UnhideConversation { id, pin })
                .await
        })
        .await?;
        Ok(res.into())
    }

    /// Sets or changes the hidden-chat PIN.
    pub async fn set_hidden_pin(
        &self,
        pin: String,
        changed: bool,
    ) -> Result<ConversationActionResultRecord, CoreError> {
        let handle = Arc::clone(&self.handle);
        let res = run(async move {
            handle
                .request_action(Command::SetHiddenPin { pin, changed })
                .await
        })
        .await?;
        Ok(res.into())
    }

    /// Resets the hidden-chat PIN and unhides all hidden conversations.
    pub async fn reset_hidden_pin(&self) -> Result<ConversationActionResultRecord, CoreError> {
        let handle = Arc::clone(&self.handle);
        let res = run(async move { handle.request_action(Command::ResetHiddenPin).await }).await?;
        Ok(res.into())
    }

    /// Syncs hidden conversations and PIN digest from the server.
    pub async fn sync_hidden_conversations(&self) -> Result<u64, CoreError> {
        let handle = Arc::clone(&self.handle);
        run(async move {
            handle.request_unit(Command::SyncHiddenConversations).await;
            handle.current_version()
        })
        .await
    }

    /// Applies an already-fetched server hidden-conversations snapshot.
    pub async fn apply_server_hidden_conversations(
        &self,
        pin: String,
        thread_ids: Vec<String>,
    ) -> Result<u64, CoreError> {
        let handle = Arc::clone(&self.handle);
        run(async move {
            handle
                .request_unit(Command::ApplyServerHiddenConversations { pin, thread_ids })
                .await;
            handle.current_version()
        })
        .await
    }

    /// Matches a 4-digit search query against the hidden PIN and populates `pin_search_ids`.
    pub async fn hidden_search(&self, query: String) -> Result<Option<Vec<String>>, CoreError> {
        let handle = Arc::clone(&self.handle);
        run(async move { handle.request_hidden_search(query).await }).await
    }

    /// Unlocks `id` if it is in the current PIN search results.
    pub fn unlock_from_pin_search(&self, id: String) {
        self.handle.send(Command::UnlockFromPinSearch { id });
    }

    /// Unlocks a hidden conversation directly (after PIN verification).
    pub fn unlock_hidden_conversation(&self, id: String) {
        self.handle.send(Command::UnlockHiddenConversation { id });
    }

    /// Drops the active single-conversation hidden unlock.
    pub fn drop_hidden_unlock(&self) {
        self.handle.send(Command::DropHiddenUnlock);
    }

    /// Relocks all hidden conversations and clears PIN search results.
    pub fn relock_hidden(&self) {
        self.handle.send(Command::RelockHidden);
    }

    /// Applies a `convActions` JSON state payload.
    pub fn handle_conversation_actions(&self, state_json: String) {
        let state = olaz_json::parse_object_str(&state_json).unwrap_or_default();
        self.handle
            .send(Command::HandleConversationActions { state });
    }

    /// Applies a `conversationExtras` JSON state payload.
    pub fn handle_conversation_extras(&self, state_json: String) {
        let state = olaz_json::parse_object_str(&state_json).unwrap_or_default();
        self.handle
            .send(Command::HandleConversationExtras { state });
    }

    /// Updates the sidebar type/label filter and recomputes `list_ids`.
    pub fn set_conversation_filter(&self, filter_type: i32, label_ids: Vec<String>) {
        self.handle.send(Command::SetConversationFilter {
            filter_type,
            label_ids,
        });
    }

    /// Assigns (or removes when `label_id` is `None`) a label on `conversation_id`.
    pub fn set_conversation_label(&self, conversation_id: String, label_id: Option<String>) {
        self.handle.send(Command::SetConversationLabel {
            conversation_id,
            label_id,
        });
    }

    /// Creates a new conversation label using caller-supplied `now_ms` and `rand4` for deterministic IDs.
    pub fn create_conversation_label(
        &self,
        name: String,
        color_hex: String,
        conversation_ids: Vec<String>,
        now_ms: i64,
        rand4: String,
    ) {
        self.handle.send(Command::CreateConversationLabel {
            name,
            color_hex,
            conversation_ids,
            now_ms,
            rand4,
        });
    }

    /// Renames or recolors an existing conversation label.
    pub fn update_conversation_label(&self, id: String, name: String, color_hex: String) {
        self.handle.send(Command::UpdateConversationLabel {
            id,
            name,
            color_hex,
        });
    }

    /// Deletes a conversation label.
    pub fn delete_conversation_label(&self, id: String) {
        self.handle.send(Command::DeleteConversationLabel { id });
    }

    /// Reorders conversation labels to match `ids` (preserving any omitted labels after).
    pub fn reorder_conversation_labels(&self, ids: Vec<String>) {
        self.handle.send(Command::ReorderConversationLabels { ids });
    }

    /// Fetches and applies conversation labels from the server.
    pub async fn sync_conversation_labels(&self) -> Result<u64, CoreError> {
        let handle = Arc::clone(&self.handle);
        run(async move {
            handle.request_unit(Command::SyncConversationLabels).await;
            handle.current_version()
        })
        .await
    }

    /// Shows a toast for a conversation action result.
    pub fn report_conversation_action_result(&self, result: ConversationActionResultRecord) {
        self.handle
            .send(Command::ReportConversationActionResult(result.into()));
    }

    /// Rebuilds conversation extras (`stranger_box`, `list_ids`, etc.) using latest identities.
    pub fn rebuild_conversation_extras(&self) {
        self.handle.send(Command::RebuildConversationExtras);
    }

    /// Rebuilds and republishes conversation action flags.
    pub fn republish_conversation_actions(&self) {
        self.handle.send(Command::RepublishConversationActions);
    }

    /// Resets conversation actions, prompt, hidden PIN caches, and UI state.
    pub fn reset_conversation_actions(&self) {
        self.handle.send(Command::ResetConversationActions);
    }

    /// Applies server-fetched pinned and archived conversation ID sets during bootstrap sync.
    pub async fn apply_bootstrap_pin_archive(
        &self,
        pinned_ids: Option<Vec<String>>,
        archived_ids: Option<Vec<String>>,
    ) -> Result<u64, CoreError> {
        let handle = Arc::clone(&self.handle);
        run(async move {
            handle
                .request_unit(Command::ApplyBootstrapPinArchive {
                    pinned_ids,
                    archived_ids,
                })
                .await;
            handle.current_version()
        })
        .await
    }

    /// Removes a conversation locally (e.g. after leaving a group) and persists the removal.
    pub async fn remove_local_conversation(&self, id: String) -> Result<u64, CoreError> {
        let handle = Arc::clone(&self.handle);
        run(async move {
            handle
                .request_unit(Command::RemoveLocalConversation { id })
                .await;
            handle.current_version()
        })
        .await
    }

    // --- Messages, history freshness, bootstrap, and contacts domain (U4) ---

    pub fn open_conversation(&self, id: String, preloaded: Vec<ChatMessageRecord>) {
        self.handle.send(Command::OpenConversation {
            id,
            preloaded: records_to_chat_messages(preloaded),
            skip_local_read: false,
        });
    }

    pub async fn open_conversation_and_wait(
        &self,
        id: String,
        preloaded: Vec<ChatMessageRecord>,
    ) -> Result<u64, CoreError> {
        let handle = Arc::clone(&self.handle);
        let runner = Arc::clone(&self.runner);
        let msgs = records_to_chat_messages(preloaded);
        run(async move {
            handle
                .request_unit(Command::OpenConversation {
                    id,
                    preloaded: msgs,
                    skip_local_read: false,
                })
                .await;
            runner.flush_host().await;
            runner.flush_store().await;
            handle
                .settle()
                .await
                .unwrap_or_else(|| handle.current_version())
        })
        .await
    }

    pub fn close_conversation(&self) {
        self.handle.send(Command::CloseConversation);
    }

    pub fn load_older_messages(&self, id: String) {
        self.handle.send(Command::LoadOlderMessages { id });
    }

    pub async fn load_older_messages_and_wait(&self, id: String) -> Result<u64, CoreError> {
        let handle = Arc::clone(&self.handle);
        run(async move {
            handle.request_unit(Command::LoadOlderMessages { id }).await;
            handle.current_version()
        })
        .await
    }

    pub async fn bootstrap(&self, now_ms: i64) -> Result<u64, CoreError> {
        let handle = Arc::clone(&self.handle);
        run(async move {
            handle.request_unit(Command::Bootstrap { now_ms }).await;
            handle.current_version()
        })
        .await
    }

    #[expect(
        clippy::too_many_arguments,
        reason = "Mirrors Swift applyBatchResponse signature 1-for-1"
    )]
    pub async fn apply_batch_direct(
        &self,
        payload_json: String,
        default_cmd: u16,
        fallback_conv_id: Option<String>,
        is_group_hint: Option<bool>,
        increment_unread: bool,
        notify_incoming: bool,
        persist_conversations: bool,
        probe_freshness: bool,
        now_ms: Option<i64>,
    ) -> Result<i64, CoreError> {
        let payload = olaz_json::parse_object_str(&payload_json).unwrap_or_default();
        let handle = Arc::clone(&self.handle);
        let runner = Arc::clone(&self.runner);
        run(async move {
            let n = match handle
                .request(Command::ApplyBatchDirect {
                    payload,
                    default_cmd,
                    fallback_conv_id,
                    is_group_hint,
                    increment_unread,
                    notify_incoming,
                    persist_conversations,
                    probe_freshness,
                    now_ms,
                })
                .await
            {
                Some(olaz_core::OpResult::Int(n)) => n,
                _ => 0,
            };
            runner.flush_host().await;
            let _ = handle.settle().await;
            runner.flush_store().await;
            let _ = handle.settle().await;
            runner.flush_store().await;
            let _ = handle.settle().await;
            n
        })
        .await
    }

    pub async fn apply_parsed_events_direct(
        &self,
        events: Vec<WireEvent>,
        increment_unread: bool,
        notify_incoming: bool,
        persist_conversations: bool,
    ) -> Result<i64, CoreError> {
        let parsed: Vec<olaz_wire::ParsedWireEvent> =
            events.into_iter().map(unconvert_wire_event).collect();
        let handle = Arc::clone(&self.handle);
        let runner = Arc::clone(&self.runner);
        run(async move {
            let n = match handle
                .request(Command::ApplyParsedEventsDirect {
                    events: parsed,
                    increment_unread,
                    notify_incoming,
                    persist_conversations,
                })
                .await
            {
                Some(olaz_core::OpResult::Int(n)) => n,
                _ => 0,
            };
            runner.flush_host().await;
            let _ = handle.settle().await;
            runner.flush_store().await;
            let _ = handle.settle().await;
            runner.flush_store().await;
            let _ = handle.settle().await;
            n
        })
        .await
    }

    pub fn write_through_upsert_message(
        &self,
        msg: ChatMessageRecord,
        replacing_client_id: Option<String>,
    ) {
        let chat: ChatMessage = (&msg).into();
        self.handle.send(Command::WriteThroughUpsertMessage {
            msg: Box::new(chat),
            replacing_client_id,
        });
    }

    pub fn write_through_remove_messages(&self, conv_id: String, ids: Vec<String>) {
        self.handle
            .send(Command::WriteThroughRemoveMessages { conv_id, ids });
    }

    pub fn write_through_replace_window(&self, conv_id: String, messages: Vec<ChatMessageRecord>) {
        self.handle.send(Command::WriteThroughReplaceWindow {
            conv_id,
            messages: records_to_chat_messages(messages),
        });
    }

    pub fn write_through_set_has_more(&self, conv_id: String, has_more: bool) {
        self.handle
            .send(Command::WriteThroughSetHasMore { conv_id, has_more });
    }

    pub fn write_through_remove_window(&self, conv_id: String) {
        self.handle
            .send(Command::WriteThroughRemoveWindow { conv_id });
    }

    pub fn refresh_reaction_names(&self, conv_id: Option<String>) {
        self.handle.send(Command::RefreshReactionNames { conv_id });
    }

    pub fn seed_history_freshness(&self, entries: Vec<FreshnessMapEntry>) {
        let mut map = BTreeMap::new();
        for entry in entries {
            let f: HistoryFreshness = entry.freshness.into();
            map.insert(entry.conv_id, f);
        }
        self.handle.send(Command::SeedHistoryFreshness(map));
    }

    pub fn seed_contacts(&self, contacts: ContactsStateRecord) {
        self.handle
            .send(Command::SeedContacts(Box::new(contacts.into())));
    }

    pub async fn flush_all(&self) -> Result<u64, CoreError> {
        let handle = Arc::clone(&self.handle);
        let runner = Arc::clone(&self.runner);
        run(async move {
            runner.flush_host().await;
            let _ = handle.settle().await;
            runner.flush_store().await;
            let _ = handle.settle().await;
            runner.flush_store().await;
            handle
                .settle()
                .await
                .unwrap_or_else(|| handle.current_version())
        })
        .await
    }

    pub fn shared_api(&self) -> Arc<crate::api::CoreApi> {
        crate::api::CoreApi::from_shared_api(Arc::clone(self.runner.api()))
    }

    // --- Send text, seen/mark_read, and typing domain (U5) ---

    /// Allocates the next strictly increasing client message id from the shared `SessionClient`.
    pub fn next_client_id(&self) -> i64 {
        self.session_client.next_client_id()
    }

    /// Sends a text message (plain API or E2EE host boundary) with core-owned optimistic row,
    /// echo/ack reconciliation, persistence, and conversation preview update.
    #[expect(
        clippy::too_many_arguments,
        reason = "Mirrors Swift sendText arguments plus deterministic clock/client_id overrides"
    )]
    pub async fn send_text(
        &self,
        conv_id: String,
        text: String,
        quote_id: Option<String>,
        mentions: Vec<MessageMention>,
        styles: Vec<TextStyleRecord>,
        urgency: i64,
        client_id: i64,
        now_ms: i64,
        is_e2ee: Option<bool>,
        ttl_ms: Option<i64>,
    ) -> Result<SendTextOutcomeRecord, CoreError> {
        let wire_mentions: Vec<olaz_wire::Mention> = mentions
            .into_iter()
            .map(|m| olaz_wire::Mention {
                uid: m.uid,
                pos: m.pos,
                len: m.len,
                is_all: m.is_all,
            })
            .collect();
        let wire_styles: Vec<olaz_wire::TextStyle> = styles
            .into_iter()
            .map(|s| olaz_wire::TextStyle {
                start: s.start,
                len: s.len,
                st: s.st,
            })
            .collect();
        let handle = Arc::clone(&self.handle);
        let runner = Arc::clone(&self.runner);
        run(async move {
            let ok = matches!(
                handle
                    .request(Command::SendText {
                        conv_id,
                        text,
                        quote_id,
                        mentions: wire_mentions,
                        styles: wire_styles,
                        urgency,
                        client_id,
                        now_ms,
                        is_e2ee,
                        ttl_ms,
                    })
                    .await,
                Some(olaz_core::OpResult::Bool(true))
            );
            runner.flush_host().await;
            let version = handle
                .settle()
                .await
                .unwrap_or_else(|| handle.current_version());
            SendTextOutcomeRecord { ok, version }
        })
        .await
    }

    /// Opens the forward picker for a single message (or emits a blocked `show_card`).
    pub fn request_forward(&self, message: ChatMessageRecord) {
        let chat: ChatMessage = (&message).into();
        self.handle.send(Command::RequestForward {
            message: Box::new(chat),
        });
    }

    /// Opens the forward picker for Swift's current multi-message selection (oldest first).
    pub fn forward_selection(&self, messages: Vec<ChatMessageRecord>) {
        self.handle.send(Command::ForwardSelection {
            messages: records_to_chat_messages(messages),
        });
    }

    /// Dismisses the active forward picker request (e.g. sheet closed by user).
    pub fn clear_forward_request(&self) {
        self.handle.send(Command::ClearForwardRequest);
    }

    /// Forwards one message to `targets`, returning the outcome and settled mirror revision.
    pub async fn forward(
        &self,
        message: ChatMessageRecord,
        targets: Vec<String>,
        now_ms: i64,
    ) -> Result<ForwardOpResultRecord, CoreError> {
        let chat: ChatMessage = (&message).into();
        let handle = Arc::clone(&self.handle);
        let runner = Arc::clone(&self.runner);
        run(async move {
            let outcome = handle
                .request_forward_outcome(Command::Forward {
                    message: Box::new(chat),
                    targets,
                    now_ms,
                })
                .await;
            runner.flush_host().await;
            let version = handle
                .settle()
                .await
                .unwrap_or_else(|| handle.current_version());
            ForwardOpResultRecord {
                outcome: outcome.into(),
                version,
            }
        })
        .await
    }

    /// Forwards all messages in the active `forward_request` to `targets`, returning the outcome
    /// and settled mirror revision (after `show_card`, request clear, and `clear_selection`).
    pub async fn forward_all(
        &self,
        targets: Vec<String>,
        now_ms: i64,
    ) -> Result<ForwardOpResultRecord, CoreError> {
        let handle = Arc::clone(&self.handle);
        let runner = Arc::clone(&self.runner);
        run(async move {
            let outcome = handle
                .request_forward_outcome(Command::ForwardAll { targets, now_ms })
                .await;
            runner.flush_host().await;
            let version = handle
                .settle()
                .await
                .unwrap_or_else(|| handle.current_version());
            ForwardOpResultRecord {
                outcome: outcome.into(),
                version,
            }
        })
        .await
    }

    /// Marks a conversation read using core's own message window for the `send_seen` target.
    pub fn mark_read(&self, id: String) {
        self.handle.send(Command::MarkRead { id });
    }

    /// Triggers an outgoing typing ping subject to core's 10 s per-conversation throttle,
    /// `Phase::Ready` gate, and `olaz.sendTyping` preference.
    pub fn notify_typing(&self, conv_id: String, now_ms: i64) {
        self.handle.send(Command::NotifyTyping { conv_id, now_ms });
    }

    /// Clears the outgoing typing throttle for `conv_id`.
    pub fn reset_outgoing_typing(&self, conv_id: String) {
        self.handle.send(Command::ResetOutgoingTyping { conv_id });
    }

    /// Routes a `handleTyping(state:)` JSON dictionary into core's incoming typing state.
    pub fn handle_typing(&self, state_json: String) {
        let state = olaz_json::parse_object_str(&state_json).unwrap_or_default();
        self.handle.send(Command::HandleTyping { state });
    }

    /// Sets or refreshes an incoming typing indicator directly in core (10 s expiry timer).
    pub fn show_typing_indicator(&self, conv_id: String, name: String, on_pc: bool) {
        let mut inner = Map::new();
        inner.insert("convId".to_owned(), Value::String(conv_id));
        inner.insert("name".to_owned(), Value::String(name));
        inner.insert("isPC".to_owned(), Value::Bool(on_pc));
        let mut state = Map::new();
        state.insert("typing".to_owned(), Value::Object(inner));
        self.handle.send(Command::HandleTyping { state });
    }

    /// Updates core's `olaz.sendTyping` preference mirror.
    pub fn set_send_typing_enabled(&self, enabled: bool) {
        self.handle.send(Command::SetSendTypingEnabled { enabled });
    }

    /// Replaces the set of 1-1 peer UIDs with active E2EE sessions in core.
    pub fn set_e2ee_threads(&self, threads: Vec<String>) {
        self.handle
            .send(Command::SetE2eeThreads(threads.into_iter().collect()));
    }

    /// Updates a single conversation's auto-delete TTL in milliseconds (`0` disables).
    pub fn set_auto_delete_ttl(&self, conv_id: String, ttl_ms: i64) {
        self.handle
            .send(Command::SetAutoDeleteTtl { conv_id, ttl_ms });
    }

    // --- U6 message actions ---

    /// Adds, toggles, or clears (`remove_all = true`) the current user's reaction on a message.
    /// Returns the settled core mirror version after the API + store + host callbacks finish.
    pub async fn react(
        &self,
        conv_id: String,
        msg_id: String,
        emoji: String,
        remove_all: bool,
        now_ms: i64,
    ) -> Result<u64, CoreError> {
        let handle = Arc::clone(&self.handle);
        let runner = Arc::clone(&self.runner);
        run(async move {
            handle
                .request_unit(Command::React {
                    conv_id,
                    msg_id,
                    emoji,
                    remove_all,
                    now_ms,
                })
                .await;
            runner.flush_host().await;
            runner.flush_store().await;
            handle
                .settle()
                .await
                .unwrap_or_else(|| handle.current_version())
        })
        .await
    }

    /// Recalls a single message for everyone and awaits completion of the API, local/store update,
    /// and host callbacks. Returns the settled core mirror version.
    pub async fn recall(
        &self,
        conv_id: String,
        msg_id: String,
        is_e2ee_thread: Option<bool>,
        now_ms: i64,
    ) -> Result<u64, CoreError> {
        let handle = Arc::clone(&self.handle);
        let runner = Arc::clone(&self.runner);
        run(async move {
            handle
                .request_unit(Command::Recall {
                    conv_id,
                    msg_id,
                    is_e2ee_thread,
                    now_ms,
                })
                .await;
            runner.flush_host().await;
            let _ = handle.settle().await;
            runner.flush_store().await;
            let _ = handle.settle().await;
            runner.flush_store().await;
            handle
                .settle()
                .await
                .unwrap_or_else(|| handle.current_version())
        })
        .await
    }

    /// Recalls a selection of messages (shows confirm when `confirm = true`, else executes).
    pub fn recall_many(&self, conv_id: String, msg_ids: Vec<String>, confirm: bool, now_ms: i64) {
        self.handle.send(Command::RecallMany {
            conv_id,
            msg_ids,
            confirm,
            now_ms,
        });
    }

    /// Recalls a selection of messages directly (`confirm = false`) and awaits completion.
    pub async fn recall_many_async(
        &self,
        conv_id: String,
        msg_ids: Vec<String>,
        now_ms: i64,
    ) -> Result<u64, CoreError> {
        let handle = Arc::clone(&self.handle);
        let runner = Arc::clone(&self.runner);
        run(async move {
            handle
                .request_unit(Command::RecallMany {
                    conv_id,
                    msg_ids,
                    confirm: false,
                    now_ms,
                })
                .await;
            runner.flush_host().await;
            let _ = handle.settle().await;
            runner.flush_store().await;
            let _ = handle.settle().await;
            runner.flush_store().await;
            handle
                .settle()
                .await
                .unwrap_or_else(|| handle.current_version())
        })
        .await
    }

    /// Deletes a single message only for the current user (shows confirm when `!confirmed` and
    /// `menu.delete == forMe`, else removes optimistically and starts the 5 s undo bar).
    pub fn delete_for_me(&self, conv_id: String, msg_id: String, confirmed: bool, now_ms: i64) {
        self.handle.send(Command::DeleteForMe {
            conv_id,
            msg_id,
            confirmed,
            now_ms,
        });
    }

    /// Deletes multiple selected messages only for the current user.
    pub fn delete_many(&self, conv_id: String, msg_ids: Vec<String>, confirm: bool, now_ms: i64) {
        self.handle.send(Command::DeleteMany {
            conv_id,
            msg_ids,
            confirm,
            now_ms,
        });
    }

    /// Cancels the active 5 s delete-undo bar, restores messages, and shows the restore card.
    pub fn undo_delete(&self) {
        self.handle.send(Command::UndoDelete);
    }

    /// Dismisses the active 5 s delete-undo bar and commits the pending delete immediately.
    pub fn dismiss_delete_undo(&self) {
        self.handle.send(Command::DismissDeleteUndo);
    }

    /// Answers the active message-action confirmation dialog (`ok = true` executes, `false` cancels).
    pub fn answer_message_confirm(&self, ok: bool, now_ms: i64) {
        self.handle
            .send(Command::AnswerMessageConfirm { ok, now_ms });
    }

    /// Presents a host-originated confirmation dialog (e.g. pin / unpin) in core's confirm slot.
    pub fn ask_message_confirm(&self, confirm: MessageConfirmRecord) {
        self.handle.send(Command::AskMessageConfirm {
            confirm: Box::new(confirm.into()),
        });
    }

    /// Toggles starred state on a message (updates window, `starredIds` pref, and SQLite row).
    pub fn set_starred(&self, conv_id: String, msg_id: String, on: bool) {
        self.handle.send(Command::SetStarred {
            conv_id,
            msg_id,
            on,
        });
    }

    /// Fetches per-conversation auto-delete TTLs from Zalo and awaits the mirror update.
    pub async fn load_auto_delete(&self) -> Result<u64, CoreError> {
        let handle = Arc::clone(&self.handle);
        let runner = Arc::clone(&self.runner);
        run(async move {
            handle.request_unit(Command::LoadAutoDelete).await;
            runner.flush_host().await;
            handle
                .settle()
                .await
                .unwrap_or_else(|| handle.current_version())
        })
        .await
    }

    /// Updates a conversation's auto-delete TTL on Zalo, inserts the system notice, and persists.
    pub async fn set_auto_delete(
        &self,
        conv_id: String,
        ttl: i64,
        now_ms: i64,
    ) -> Result<u64, CoreError> {
        let handle = Arc::clone(&self.handle);
        let runner = Arc::clone(&self.runner);
        run(async move {
            handle
                .request_unit(Command::SetAutoDelete {
                    conv_id,
                    ttl,
                    now_ms,
                })
                .await;
            runner.flush_host().await;
            runner.flush_store().await;
            handle
                .settle()
                .await
                .unwrap_or_else(|| handle.current_version())
        })
        .await
    }

    /// Prunes expired messages from `conv_id` in core memory and SQLite (fire-and-forget).
    pub fn prune_expired_messages(&self, conv_id: String, now_ms: i64) {
        self.handle
            .send(Command::PruneExpiredMessages { conv_id, now_ms });
    }

    /// Seeds previously loaded seen-reaction dedup keys into core without writing back to SQLite.
    pub fn seed_seen_reaction_keys(&self, keys: Vec<String>) {
        if keys.is_empty() {
            return;
        }
        self.handle.send(Command::RecordSeenReactionKeys {
            keys,
            persist: false,
        });
    }

    /// Records seen-reaction dedup keys in core and flushes `"seenReactionEventIds"` to SQLite.
    pub async fn record_seen_reaction_keys(&self, keys: Vec<String>) -> Result<(), CoreError> {
        if keys.is_empty() {
            return Ok(());
        }
        let handle = Arc::clone(&self.handle);
        let runner = Arc::clone(&self.runner);
        run(async move {
            handle
                .request_unit(Command::RecordSeenReactionKeys {
                    keys,
                    persist: true,
                })
                .await;
            runner.flush_store().await;
        })
        .await
    }

    // --- U16 notifications, card actions, invites, reminders, and sticker suggestions ---

    pub fn set_initial_notification_auth(&self, auth: NotifAuthorizationRecord) {
        self.handle
            .send(Command::SetNotifAuthorization { auth: auth.into() });
    }

    pub fn set_notifications_enabled(&self, enabled: bool) {
        self.handle
            .send(Command::SetNotificationsEnabled { enabled });
    }

    pub async fn set_notifications_enabled_and_wait(
        &self,
        enabled: bool,
    ) -> Result<u64, CoreError> {
        let handle = Arc::clone(&self.handle);
        let runner = Arc::clone(&self.runner);
        run(async move {
            handle
                .request_unit(Command::SetNotificationsEnabled { enabled })
                .await;
            runner.flush_host().await;
            runner.flush_store().await;
            handle
                .settle()
                .await
                .unwrap_or_else(|| handle.current_version())
        })
        .await
    }

    pub fn set_notification_sound(&self, enabled: bool) {
        self.handle.send(Command::SetNotificationSound { enabled });
    }

    pub async fn set_notification_sound_and_wait(&self, enabled: bool) -> Result<u64, CoreError> {
        let handle = Arc::clone(&self.handle);
        let runner = Arc::clone(&self.runner);
        run(async move {
            handle
                .request_unit(Command::SetNotificationSound { enabled })
                .await;
            runner.flush_store().await;
            handle
                .settle()
                .await
                .unwrap_or_else(|| handle.current_version())
        })
        .await
    }

    pub fn set_message_preview(&self, shown: bool) {
        self.handle.send(Command::SetMessagePreview { shown });
    }

    pub fn mute_conversation(&self, conv_id: String, duration_secs: i64, now_ms: i64) {
        self.handle.send(Command::MuteConversation {
            conv_id,
            duration_secs,
            now_ms,
        });
    }

    pub async fn mute_conversation_and_wait(
        &self,
        conv_id: String,
        duration_secs: i64,
        now_ms: i64,
    ) -> Result<u64, CoreError> {
        let handle = Arc::clone(&self.handle);
        let runner = Arc::clone(&self.runner);
        run(async move {
            handle
                .request_unit(Command::MuteConversation {
                    conv_id,
                    duration_secs,
                    now_ms,
                })
                .await;
            runner.flush_host().await;
            runner.flush_store().await;
            handle
                .settle()
                .await
                .unwrap_or_else(|| handle.current_version())
        })
        .await
    }

    pub fn unmute_conversation(&self, conv_id: String, now_ms: i64) {
        self.handle
            .send(Command::UnmuteConversation { conv_id, now_ms });
    }

    pub async fn unmute_conversation_and_wait(
        &self,
        conv_id: String,
        now_ms: i64,
    ) -> Result<u64, CoreError> {
        let handle = Arc::clone(&self.handle);
        let runner = Arc::clone(&self.runner);
        run(async move {
            handle
                .request_unit(Command::UnmuteConversation { conv_id, now_ms })
                .await;
            runner.flush_host().await;
            runner.flush_store().await;
            handle
                .settle()
                .await
                .unwrap_or_else(|| handle.current_version())
        })
        .await
    }

    pub fn handle_notification_settings_payload(&self, payload_json: String) {
        let payload = olaz_json::parse_object_str(&payload_json).unwrap_or_default();
        self.handle
            .send(Command::HandleNotificationSettingsPayload { payload });
    }

    pub async fn load_notification_preferences(&self) -> Result<u64, CoreError> {
        let handle = Arc::clone(&self.handle);
        let runner = Arc::clone(&self.runner);
        run(async move {
            handle
                .request_unit(Command::LoadNotificationPreferences)
                .await;
            runner.flush_store().await;
            handle
                .settle()
                .await
                .unwrap_or_else(|| handle.current_version())
        })
        .await
    }

    pub async fn notify_incoming_batch(
        &self,
        messages: Vec<ChatMessageRecord>,
        now_ms: i64,
    ) -> Result<u64, CoreError> {
        let handle = Arc::clone(&self.handle);
        let runner = Arc::clone(&self.runner);
        let msgs = records_to_chat_messages(messages);
        run(async move {
            handle
                .request_unit(Command::NotifyIncomingBatch {
                    messages: msgs,
                    now_ms,
                })
                .await;
            runner.flush_host().await;
            runner.flush_store().await;
            handle
                .settle()
                .await
                .unwrap_or_else(|| handle.current_version())
        })
        .await
    }

    pub async fn perform_card_action(
        &self,
        conv_id: String,
        msg_id: String,
        action_ref: String,
    ) -> Result<CardActionOutcomeRecord, CoreError> {
        let handle = Arc::clone(&self.handle);
        let runner = Arc::clone(&self.runner);
        run(async move {
            let out = match handle
                .request(Command::PerformCardAction {
                    conv_id,
                    msg_id,
                    action_ref,
                })
                .await
            {
                Some(olaz_core::OpResult::CardAction(d)) => d.into(),
                _ => default_unsupported_card_record(),
            };
            runner.flush_host().await;
            runner.flush_store().await;
            out
        })
        .await
    }

    pub async fn suggested_stickers(
        &self,
        conv_id: String,
        msg_id: String,
    ) -> Result<Vec<SuggestedStickerRecord>, CoreError> {
        let handle = Arc::clone(&self.handle);
        run(async move {
            match handle
                .request(Command::SuggestedStickers { conv_id, msg_id })
                .await
            {
                Some(olaz_core::OpResult::SuggestedStickers(list)) => {
                    list.into_iter().map(Into::into).collect()
                }
                _ => Vec::new(),
            }
        })
        .await
    }

    pub async fn contact_card_state(
        &self,
        uid: String,
    ) -> Result<ContactCardStateRecord, CoreError> {
        let handle = Arc::clone(&self.handle);
        run(async move {
            match handle.request(Command::ContactCardState { uid }).await {
                Some(olaz_core::OpResult::ContactCardState(s)) => s.into(),
                _ => ContactCardStateRecord {
                    is_self: false,
                    is_friend: false,
                },
            }
        })
        .await
    }

    pub async fn contact_profile(
        &self,
        uid: String,
    ) -> Result<Option<ContactProfileRecord>, CoreError> {
        let handle = Arc::clone(&self.handle);
        let runner = Arc::clone(&self.runner);
        run(async move {
            let out = match handle.request(Command::ContactProfile { uid }).await {
                Some(olaz_core::OpResult::ContactProfile(opt)) => opt.map(Into::into),
                _ => None,
            };
            runner.flush_store().await;
            out
        })
        .await
    }

    pub async fn prepare_friend_request(
        &self,
        uid: String,
        conv_id: String,
        via: FriendRequestOriginRecord,
    ) -> Result<FriendRequestPrepRecord, CoreError> {
        let handle = Arc::clone(&self.handle);
        run(async move {
            match handle
                .request(Command::PrepareFriendRequest {
                    uid,
                    conv_id,
                    via: via.into(),
                })
                .await
            {
                Some(olaz_core::OpResult::FriendRequestPrep(p)) => p.into(),
                _ => FriendRequestPrepRecord {
                    state: "none".to_owned(),
                    default_message: String::new(),
                    max_message: 150,
                },
            }
        })
        .await
    }

    pub async fn submit_friend_request(
        &self,
        uid: String,
        message: String,
    ) -> Result<SubmitFriendRecord, CoreError> {
        let handle = Arc::clone(&self.handle);
        let runner = Arc::clone(&self.runner);
        run(async move {
            let out = match handle
                .request(Command::SubmitFriendRequest { uid, message })
                .await
            {
                Some(olaz_core::OpResult::SubmitFriend(r)) => r.into(),
                _ => SubmitFriendRecord {
                    ok: false,
                    text: "Không gửi được lời mời kết bạn.".to_owned(),
                    pending: false,
                },
            };
            runner.flush_host().await;
            out
        })
        .await
    }

    pub async fn save_alias(
        &self,
        uid: String,
        name: String,
    ) -> Result<SaveAliasRecord, CoreError> {
        let handle = Arc::clone(&self.handle);
        let runner = Arc::clone(&self.runner);
        run(async move {
            let out = match handle.request(Command::SaveAlias { uid, name }).await {
                Some(olaz_core::OpResult::SaveAlias(r)) => r.into(),
                _ => SaveAliasRecord {
                    ok: false,
                    text: "Không lưu được tên gợi nhớ.".to_owned(),
                },
            };
            runner.flush_store().await;
            let _ = handle.settle().await;
            out
        })
        .await
    }

    pub async fn group_invite_preview(
        &self,
        url: String,
    ) -> Result<GroupInvitePreviewRecord, CoreError> {
        let handle = Arc::clone(&self.handle);
        run(async move {
            match handle.request(Command::GroupInvitePreview { url }).await {
                Some(olaz_core::OpResult::GroupInvitePreview(p)) => p.into(),
                _ => GroupInvitePreviewRecord::from(olaz_core::GroupInvitePreviewResult::default()),
            }
        })
        .await
    }

    pub async fn join_group(
        &self,
        url: String,
        preview_group_id: Option<String>,
    ) -> Result<GroupJoinRecord, CoreError> {
        let handle = Arc::clone(&self.handle);
        let runner = Arc::clone(&self.runner);
        run(async move {
            let out = match handle
                .request(Command::JoinGroup {
                    url,
                    preview_group_id,
                })
                .await
            {
                Some(olaz_core::OpResult::JoinGroup(r)) => r.into(),
                _ => GroupJoinRecord {
                    state: "error".to_owned(),
                    group_id: String::new(),
                    text: "Vào nhóm không thành công.".to_owned(),
                },
            };
            runner.flush_host().await;
            out
        })
        .await
    }

    pub fn sync_pin_reminder_refs(&self, conv_id: String, items: Vec<PinReminderRefRecord>) {
        self.handle.send(Command::SyncPinReminderRefs {
            conv_id,
            refs: items.into_iter().map(Into::into).collect(),
        });
    }

    pub async fn reminder_watch(
        &self,
        conv_id: String,
        msg_id: String,
        signature: String,
    ) -> Result<Option<ReminderSnapshotRecord>, CoreError> {
        let handle = Arc::clone(&self.handle);
        run(async move {
            match handle
                .request(Command::ReminderWatch {
                    conv_id,
                    msg_id,
                    signature,
                })
                .await
            {
                Some(olaz_core::OpResult::ReminderSnapshot(opt)) => opt.map(Into::into),
                _ => None,
            }
        })
        .await
    }

    pub async fn respond_reminder(
        &self,
        conv_id: String,
        msg_id: String,
        accept: bool,
    ) -> Result<RespondReminderRecord, CoreError> {
        let handle = Arc::clone(&self.handle);
        run(async move {
            match handle
                .request(Command::RespondReminder {
                    conv_id,
                    msg_id,
                    accept,
                })
                .await
            {
                Some(olaz_core::OpResult::RespondReminder(r)) => r.into(),
                _ => default_failed_respond_reminder_record(),
            }
        })
        .await
    }

    pub async fn reminder_responders(
        &self,
        conv_id: String,
        msg_id: String,
    ) -> Result<Option<ReminderRespondersRecord>, CoreError> {
        let handle = Arc::clone(&self.handle);
        let runner = Arc::clone(&self.runner);
        run(async move {
            let out = match handle
                .request(Command::ReminderResponders { conv_id, msg_id })
                .await
            {
                Some(olaz_core::OpResult::ReminderResponders(opt)) => opt.map(Into::into),
                _ => None,
            };
            runner.flush_store().await;
            out
        })
        .await
    }

    pub fn reset_card_state(&self) {
        self.handle.send(Command::ResetCardState);
    }

    pub fn fire_reminder_watch_timer(&self, waiter_id: u64) {
        self.handle
            .send(Command::FireReminderWatchTimer { waiter_id });
    }

    // --- Core-owned WebSocket pass-throughs for Swift feature domains ---

    /// Sends a raw WebSocket frame. `false` unless authenticated and the write succeeded.
    pub async fn ws_send_frame(
        &self,
        cmd: u16,
        sub_cmd: u8,
        version: u8,
        payload_json: Option<String>,
    ) -> Result<bool, CoreError> {
        let ws = Arc::clone(&self.ws_driver);
        run(async move {
            ws.send_frame_versioned(cmd, sub_cmd, version, payload_json.map(String::into_bytes))
                .await
        })
        .await
    }

    /// Sends a `requestAsyncV2` request frame on the core's WebSocket and awaits its reply.
    pub async fn ws_send_request(
        &self,
        cmd: u16,
        sub_cmd: u8,
        version: u8,
        req_id: Option<String>,
        inner_data_json: String,
        timeout_secs: f64,
    ) -> Result<Option<String>, CoreError> {
        let inner = parse_inner_json(&inner_data_json)?;
        let timeout = Duration::try_from_secs_f64(timeout_secs).unwrap_or(Duration::from_secs(10));
        let ws = Arc::clone(&self.ws_driver);
        let out = run(async move {
            ws.send_request(cmd, sub_cmd, version, req_id, inner, timeout)
                .await
        })
        .await?;
        Ok(out.map(|m| to_swift_json_string(&Value::Object(m))))
    }

    /// Waits up to `timeout_secs` for upload `file_id` to complete on the core's WebSocket.
    pub async fn ws_wait_for_file_done(
        &self,
        file_id: String,
        timeout_secs: f64,
    ) -> Result<Option<String>, CoreError> {
        let timeout = Duration::try_from_secs_f64(timeout_secs).unwrap_or(Duration::from_secs(12));
        let ws = Arc::clone(&self.ws_driver);
        run(async move { ws.wait_for_file_done(file_id, timeout).await }).await
    }

    /// Records a `file_done` completion discovered outside the core's WS frame loop.
    pub fn ws_record_file_done(&self, file_id: String, url: String) {
        self.ws_driver.record_file_done(file_id, url);
    }

    /// Returns whether the core's WebSocket is currently authenticated.
    pub async fn ws_is_authed(&self) -> Result<bool, CoreError> {
        let ws = Arc::clone(&self.ws_driver);
        run(async move { ws.is_authed().await }).await
    }

    /// Returns the core's current WebSocket queue cursors.
    pub async fn ws_current_cursors(&self) -> Result<Vec<CursorEntry>, CoreError> {
        let ws = Arc::clone(&self.ws_driver);
        let map = run(async move { ws.current_cursors().await }).await?;
        Ok(cursors_to_entries(&map))
    }

    /// Seeds the core's WebSocket queue cursors.
    pub async fn ws_seed_cursors(&self, cursors: Vec<CursorEntry>) -> Result<(), CoreError> {
        let ws = Arc::clone(&self.ws_driver);
        let map = cursors_to_map(cursors);
        run(async move { ws.seed_cursors(map).await }).await
    }

    /// Pulls the next coalesced batch of dirty domain snapshots, or `None` after [`Self::stop`].
    pub async fn next_changes(&self) -> Result<Option<CoreChangesRecord>, CoreError> {
        let handle = Arc::clone(&self.handle);
        let batch = run(async move { handle.next_changes().await }).await?;
        Ok(batch.map(Into::into))
    }

    /// Returns the latest monotonic revision published to the change stream.
    pub fn current_version(&self) -> u64 {
        self.handle.current_version()
    }

    /// Enqueues barriers across the actor mailbox, serial host worker, and serial SQLite store
    /// worker until all pending host/store jobs and the inputs they feed back into the actor have
    /// been reduced and published (`0` if already stopped).
    pub async fn settle(&self) -> Result<u64, CoreError> {
        let handle = Arc::clone(&self.handle);
        let runner = Arc::clone(&self.runner);
        let version = run(async move {
            let mut version = 0;
            for _ in 0..8 {
                if handle.settle().await.is_none() {
                    return 0;
                }
                let host_before = runner.host_dispatched();
                runner.flush_host().await;
                if handle.settle().await.is_none() {
                    return 0;
                }
                let store_before = runner.store_dispatched();
                runner.flush_store().await;
                let Some(v) = handle.settle().await else {
                    return 0;
                };
                version = v;
                if runner.host_dispatched() == host_before
                    && runner.store_dispatched() == store_before
                {
                    break;
                }
            }
            version
        })
        .await?;
        Ok(version)
    }

    /// Waits until no actor inputs or tracked effects (including serial SQLite writes and API
    /// requests) remain in flight, then returns the latest change revision.
    pub async fn wait_idle(&self) -> Result<u64, CoreError> {
        let handle = Arc::clone(&self.handle);
        run(async move {
            handle.wait_idle().await;
            handle.current_version()
        })
        .await
    }

    // --- Group polls domain (U12) ---

    pub fn watch_poll(&self, id: String, conv_id: String, now_ms: i64) {
        self.handle.send(Command::WatchPoll {
            id,
            conv_id,
            now_ms,
        });
    }

    pub fn retry_poll(&self, id: String, conv_id: String, now_ms: i64) {
        self.handle.send(Command::RetryPoll {
            id,
            conv_id,
            now_ms,
        });
    }

    pub fn rewatch_polls(&self, now_ms: i64) {
        self.handle.send(Command::RewatchPolls { now_ms });
    }

    pub fn refresh_poll(&self, id: String, now_ms: i64) {
        self.handle.send(Command::RefreshPoll { id, now_ms });
    }

    pub async fn poll_voters(&self, id: String) -> Result<PollVotersOutcomeRecord, CoreError> {
        let handle = Arc::clone(&self.handle);
        run(async move {
            let voters = handle.request_poll_voters(id).await;
            let version = handle.current_version();
            PollVotersOutcomeRecord {
                voters: voters.map(Into::into),
                version,
            }
        })
        .await
    }

    pub async fn refresh_poll_pin(
        &self,
        id: String,
        conv_id: String,
    ) -> Result<PollPinStateOutcomeRecord, CoreError> {
        let handle = Arc::clone(&self.handle);
        let runner = Arc::clone(&self.runner);
        run(async move {
            let state = handle.request_poll_pin_state(id, conv_id).await;
            runner.flush_host().await;
            let version = handle
                .settle()
                .await
                .unwrap_or_else(|| handle.current_version());
            PollPinStateOutcomeRecord {
                state: state.into(),
                version,
            }
        })
        .await
    }

    pub async fn pin_poll(
        &self,
        id: String,
        conv_id: String,
        confirming: Option<String>,
    ) -> Result<PollPinActionOutcomeRecord, CoreError> {
        let handle = Arc::clone(&self.handle);
        let runner = Arc::clone(&self.runner);
        run(async move {
            let outcome = handle
                .request_poll_pin_outcome(id, conv_id, confirming)
                .await;
            runner.flush_host().await;
            let version = handle
                .settle()
                .await
                .unwrap_or_else(|| handle.current_version());
            PollPinActionOutcomeRecord {
                outcome: outcome.into(),
                version,
            }
        })
        .await
    }

    pub async fn unpin_poll(
        &self,
        id: String,
        conv_id: String,
    ) -> Result<PollActionOutcomeRecord, CoreError> {
        let handle = Arc::clone(&self.handle);
        let runner = Arc::clone(&self.runner);
        run(async move {
            let result = handle
                .request_poll_action(Command::UnpinPoll { id, conv_id })
                .await;
            runner.flush_host().await;
            let version = handle
                .settle()
                .await
                .unwrap_or_else(|| handle.current_version());
            PollActionOutcomeRecord {
                result: result.into(),
                version,
            }
        })
        .await
    }

    pub async fn poll_capabilities(
        &self,
        conv_id: String,
    ) -> Result<PollCapabilitiesOutcomeRecord, CoreError> {
        let handle = Arc::clone(&self.handle);
        run(async move {
            let caps = handle.request_poll_capabilities(conv_id).await;
            let version = handle.current_version();
            PollCapabilitiesOutcomeRecord {
                capabilities: caps.into(),
                version,
            }
        })
        .await
    }

    pub async fn vote_poll(
        &self,
        id: String,
        conv_id: String,
        draft: PollVoteDraftRecord,
        detail: Option<PollDetailRecord>,
        now_ms: i64,
    ) -> Result<PollActionOutcomeRecord, CoreError> {
        let handle = Arc::clone(&self.handle);
        let runner = Arc::clone(&self.runner);
        run(async move {
            let result = handle
                .request_poll_action(Command::VotePoll {
                    id,
                    conv_id,
                    draft: draft.into(),
                    detail: detail.map(Into::into),
                    now_ms,
                })
                .await;
            runner.flush_host().await;
            let version = handle
                .settle()
                .await
                .unwrap_or_else(|| handle.current_version());
            PollActionOutcomeRecord {
                result: result.into(),
                version,
            }
        })
        .await
    }

    pub async fn lock_poll(
        &self,
        id: String,
        conv_id: String,
        now_ms: i64,
    ) -> Result<PollActionOutcomeRecord, CoreError> {
        let handle = Arc::clone(&self.handle);
        let runner = Arc::clone(&self.runner);
        run(async move {
            let result = handle
                .request_poll_action(Command::LockPoll {
                    id,
                    conv_id,
                    now_ms,
                })
                .await;
            runner.flush_host().await;
            let version = handle
                .settle()
                .await
                .unwrap_or_else(|| handle.current_version());
            PollActionOutcomeRecord {
                result: result.into(),
                version,
            }
        })
        .await
    }

    pub async fn share_poll(
        &self,
        id: String,
        conv_id: String,
    ) -> Result<PollActionOutcomeRecord, CoreError> {
        let handle = Arc::clone(&self.handle);
        let runner = Arc::clone(&self.runner);
        run(async move {
            let result = handle
                .request_poll_action(Command::SharePoll { id, conv_id })
                .await;
            runner.flush_host().await;
            let version = handle
                .settle()
                .await
                .unwrap_or_else(|| handle.current_version());
            PollActionOutcomeRecord {
                result: result.into(),
                version,
            }
        })
        .await
    }

    pub async fn create_poll(
        &self,
        conv_id: String,
        draft: PollCreateDraftRecord,
        config: PollConfigRecord,
        can_pin: bool,
    ) -> Result<PollActionOutcomeRecord, CoreError> {
        let handle = Arc::clone(&self.handle);
        let runner = Arc::clone(&self.runner);
        run(async move {
            let result = handle
                .request_poll_action(Command::CreatePoll {
                    conv_id,
                    draft: draft.into(),
                    config: config.into(),
                    can_pin,
                })
                .await;
            runner.flush_host().await;
            let version = handle
                .settle()
                .await
                .unwrap_or_else(|| handle.current_version());
            PollActionOutcomeRecord {
                result: result.into(),
                version,
            }
        })
        .await
    }

    pub fn note_poll_messages(
        &self,
        notices: Vec<PollMessageNoticeRecord>,
        now_ms: i64,
        host_already_armed: bool,
    ) {
        self.handle.send(Command::NotePollMessages {
            notices: notices.into_iter().map(Into::into).collect(),
            now_ms,
            host_already_armed,
        });
    }

    pub fn fire_poll_debounce(&self, poll_id: String, seq: u64, now_ms: i64) {
        self.handle.send(Command::FirePollDebounce {
            poll_id,
            seq,
            now_ms,
        });
    }

    pub fn handle_poll_state(&self, state_json: String) {
        let state = olaz_json::parse_object_str(&state_json).unwrap_or_default();
        self.handle.send(Command::HandlePollState { state });
    }

    pub fn reset_polls(&self, sync_epoch: u64) {
        self.handle.send(Command::ResetPolls { sync_epoch });
    }

    pub fn seed_polls(&self, polls: PollsMirrorRecord) {
        self.handle.send(Command::SeedPolls {
            polls: Box::new(polls.into()),
        });
    }

    // U7: temporary write-throughs from Swift board pins until U7 lands.
    pub fn sync_board_pins(&self, conv_id: String, list: Option<BoardPinListRecord>) {
        self.handle.send(Command::SyncBoardPins {
            conv_id,
            list: list.map(Into::into),
        });
    }

    // U7: temporary write-through from Swift raw board topics until U7 lands.
    pub fn sync_board_raw_topics(
        &self,
        conv_id: String,
        version: i64,
        topics_json: Option<String>,
    ) {
        let raw = topics_json.map(|json| olaz_core::polls::BoardRawTopics {
            version,
            topics: parse_raw_topics_json(&json),
        });
        self.handle
            .send(Command::SyncBoardRawTopics { conv_id, raw });
    }

    // U7: temporary write-through for `pins_state` WebContent/test events until U7 lands.
    pub fn handle_pins_state(&self, state_json: String) {
        let state = olaz_json::parse_object_str(&state_json).unwrap_or_default();
        self.handle.send(Command::HandlePinsState { state });
    }

    // U7: temporary clear on `resetMessageActions()` until U7 lands.
    pub fn clear_board_caches(&self) {
        self.handle.send(Command::ClearBoardCaches);
    }

    /// Stops the actor, aborts in-flight session & transport tasks, and closes `next_changes()`.
    pub fn stop(&self) {
        self.handle.stop();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::conversations::ConversationPreviewRecord;

    struct NoopCoreHost;

    #[async_trait::async_trait]
    impl CoreHost for NoopCoreHost {
        async fn load_saved_session(&self) -> Option<String> {
            None
        }
        async fn load_legacy_cookie(&self) -> Option<LegacyCookieRecord> {
            None
        }
        async fn load_transport_state(&self) -> PersistedTransportStateRecord {
            PersistedTransportStateRecord::default()
        }
        async fn set_pref(&self, _key: String, _value: String) {}
        async fn prepare_store(&self, _user_id: String, _account: LoginAccountRecord) {}
        async fn on_ws_started(&self, _endpoints: Vec<String>) -> bool {
            false
        }
        async fn on_long_poll_started(&self) -> bool {
            false
        }
        async fn on_bootstrap_started(&self) -> bool {
            false
        }
        async fn apply_mutes(&self, _mutes: Vec<MuteEntryRecord>) {}
        async fn refresh_cloud(&self) {}
        async fn on_batch_received(
            &self,
            _cmd: Option<u16>,
            _increment_unread: bool,
            _notify_incoming: bool,
            _payload_json: String,
        ) -> Option<String> {
            None
        }
        async fn on_parsed_events_received(
            &self,
            _cmd: u16,
            _increment_unread: bool,
            _notify_incoming: bool,
            _events: Vec<WireEvent>,
            _uids: Vec<String>,
            _payload: Arc<CoreWirePayload>,
        ) -> bool {
            false
        }
        async fn on_open_conversation_sync(&self, _conv_id: String, _changed: bool) {}
        async fn on_close_conversation(&self) {}
        async fn refresh_board_pins(&self, _conv_id: String) {}
        async fn mark_read_boundary(
            &self,
            _conv_id: String,
            _seen_target: Option<SeenTargetRecord>,
        ) {
        }
        async fn apply_remote_reaction(
            &self,
            _conv_id: String,
            _msg_id: String,
            _cli_msg_id: String,
            _sender_id: String,
            _r_type: String,
            _r_icon: String,
            _event_id: String,
            _react_client_id: String,
            _sender_name: String,
        ) -> bool {
            true
        }
        async fn apply_remote_recall(
            &self,
            _conv_id: String,
            _msg_id: String,
            _cli_msg_id: String,
            _update_conversation_preview: bool,
            _persist_conversations: bool,
        ) -> bool {
            true
        }
        async fn apply_remote_delete(
            &self,
            _conv_id: String,
            _msg_id: String,
            _cli_msg_id: String,
            _update_conversation_preview: bool,
            _persist_conversations: bool,
        ) -> bool {
            true
        }
        async fn decrypt_envelope(&self, payload_json: String) -> String {
            payload_json
        }
        async fn mark_e2ee_conversations(&self, _conv_ids: Vec<String>) {}
        async fn note_poll_messages(&self, _messages: Vec<ChatMessageRecord>) {}
        async fn notify_incoming_messages(&self, _messages: Vec<ChatMessageRecord>) {}
        async fn show_batch_typing(&self, _conv_id: String, _sender_id: String) {}
        async fn transport_batch_settled(&self) {}
        async fn engine_log(&self, _message: String) {}
        async fn offer_first_login_transfer(&self, _force: bool) {}
        async fn reset_domains(&self) {}
        async fn persist_session(&self, _snapshot_json: String) {}
        async fn clear_session(&self) {}
        async fn mark_expired(&self, _snapshot_json: String) {}
        async fn persist_poll_state(&self, _state: PollStateRecord) {}
        async fn persist_ws_cursors(&self, _cursors: Vec<CursorEntry>) {}
        async fn mobile_sync(&self, _events: Vec<MobileSyncEventRecord>) {}
        async fn e2ee_signal(&self, _cmd: u16, _payload_json: String) {}
        async fn e2ee_deliver_reports(&self, _cmd: u16, _payload_json: String) {}
        async fn e2ee_connected(&self, _uid: String) {}
        async fn e2ee_disconnected(&self) {}
        async fn voip_control(&self, _act: String, _raw_data_json: String, _data_json: String) {}
        async fn show_typing(&self, _conv_id: String, _uid: String, _on_pc: bool) {}
        async fn pin_topic(&self, _conv_id: String) {}
        async fn group_notice(&self, _act: String, _data_json: String, _ts: i64) {}
        async fn mute(
            &self,
            _conv_id: String,
            _set: bool,
            _start: i64,
            _start_explicit: bool,
            _duration: i64,
        ) {
        }
        async fn send_e2ee_text(
            &self,
            _conv_id: String,
            _text: String,
            _client_id: String,
            _quote: Option<E2eeQuoteArgRecord>,
        ) -> E2eeSendOutcomeRecord {
            E2eeSendOutcomeRecord::Aborted
        }
        async fn show_card(&self, _conv_id: Option<String>, _text: String) {}
        async fn resolve_media(
            &self,
            _conv_id: String,
            _msg_id: String,
            _kind: String,
        ) -> MediaResolutionRecord {
            MediaResolutionRecord::Unavailable
        }
        async fn resolve_file(
            &self,
            _conv_id: String,
            _msg_id: String,
            _name: String,
            _url: Option<String>,
        ) -> FileResolutionRecord {
            FileResolutionRecord::Expired
        }
        async fn fetch_media_data(&self, _url: String) -> Option<String> {
            None
        }
        async fn send_media(
            &self,
            _conv_id: String,
            _paths: Vec<String>,
            _cleanup_after: bool,
        ) -> ComposerSendOutcomeRecord {
            ComposerSendOutcomeRecord::Cancelled
        }
        async fn send_files(
            &self,
            _conv_id: String,
            _paths: Vec<String>,
        ) -> ComposerSendOutcomeRecord {
            ComposerSendOutcomeRecord::Cancelled
        }
        async fn arm_poll_debounce(&self, _poll_id: String, _seq: u64, _delay_ms: u64) -> bool {
            false
        }
        async fn cancel_all_poll_debounces(&self) {}
        async fn notify_banners(&self, _banners: Vec<NotifyBannerPayloadRecord>) {}
        async fn request_notif_auth(&self) -> NotifAuthorizationRecord {
            NotifAuthorizationRecord::Unavailable
        }
        async fn start_call(&self, _uid: String, _video: bool) {}
        async fn send_category_sticker(
            &self,
            _conv_id: String,
            _cate_id: i32,
            _sticker_id: i32,
        ) -> CardActionOutcomeRecord {
            default_unsupported_card_record()
        }
        async fn refresh_contacts(&self) {}
        async fn arm_reminder_watch_timer(&self, _waiter_id: u64, _delay_secs: f64) -> bool {
            false
        }
        async fn cancel_reminder_watch_timer(&self, _waiter_id: u64) {}
    }

    #[test]
    fn ffi_records_redact_sensitive_fields_in_debug() {
        let acc = LoginAccountRecord {
            user_id: "123456".to_owned(),
            display_name: "SECRET_NAME".to_owned(),
            avatar: "https://secret.example/avt.jpg".to_owned(),
            phone: "+84909999999".to_owned(),
            send2me_id: "123456".to_owned(),
            dkey: "SECRET_DKEY".to_owned(),
            zpw_enk: "SECRET_ENK".to_owned(),
            zpw_sek: "SECRET_SEK".to_owned(),
            need_sync_msg: Some(false),
        };
        let acc_dbg = format!("{acc:?}");
        for secret in [
            "123456",
            "SECRET_NAME",
            "secret.example",
            "84909999999",
            "SECRET_DKEY",
            "SECRET_ENK",
            "SECRET_SEK",
        ] {
            assert!(!acc_dbg.contains(secret), "leaked {secret}: {acc_dbg}");
        }

        let cookie = LegacyCookieRecord {
            zpw_sek: "SECRET_COOKIE".to_owned(),
            imei: Some("SECRET_IMEI".to_owned()),
        };
        let cookie_dbg = format!("{cookie:?}");
        assert!(!cookie_dbg.contains("SECRET_COOKIE"));
        assert!(!cookie_dbg.contains("SECRET_IMEI"));

        let conv = ConversationSummaryRecord {
            id: "CONV_SECRET_ID".to_owned(),
            is_group: false,
            name: "SECRET_CONV_NAME".to_owned(),
            avatar: Some("https://secret.example/c.jpg".to_owned()),
            pinned: false,
            members: 0,
            unread: 2,
            preview: Some(ConversationPreviewRecord {
                text: "SECRET_PREVIEW_TEXT".to_owned(),
                date_ms: Some(1_700_000_000_000),
                from_me: false,
            }),
        };
        let conv_dbg = format!("{conv:?}");
        for secret in [
            "CONV_SECRET_ID",
            "SECRET_CONV_NAME",
            "secret.example",
            "SECRET_PREVIEW_TEXT",
        ] {
            assert!(!conv_dbg.contains(secret), "leaked {secret}: {conv_dbg}");
        }
    }

    #[tokio::test]
    async fn core_engine_apply_account_profile_delivers_changes_and_stops() -> Result<(), CoreError>
    {
        let session = CoreSession::with_config("imei-1".to_owned(), "Mac".to_owned(), None)?;
        let engine = CoreEngine::new(session, Arc::new(NoopCoreHost))?;
        let acc = LoginAccountRecord {
            user_id: "42".to_owned(),
            display_name: "Linh".to_owned(),
            avatar: "https://example.invalid/a.jpg".to_owned(),
            phone: String::new(),
            send2me_id: "42".to_owned(),
            dkey: String::new(),
            zpw_enk: String::new(),
            zpw_sek: String::new(),
            need_sync_msg: None,
        };
        let version = engine.apply_account_profile(acc).await?;
        assert_eq!(version, 1);

        let batch = engine.next_changes().await?;
        assert_eq!(batch.as_ref().map(|b| b.version), Some(1));
        let sess = batch.and_then(|b| b.session);
        assert_eq!(
            sess.as_ref()
                .and_then(|s| s.self_conversation_id.as_deref()),
            Some("42")
        );
        assert_eq!(
            sess.as_ref()
                .and_then(|s| s.profile.as_ref())
                .map(|p| p.display_name.as_str()),
            Some("Linh")
        );

        engine.stop();
        assert_eq!(engine.next_changes().await?, None);
        Ok(())
    }

    #[tokio::test]
    async fn core_engine_u3_message_and_hidden_pin_flow() -> Result<(), CoreError> {
        let session = CoreSession::with_config("imei-2".to_owned(), "Mac".to_owned(), None)?;
        let engine = CoreEngine::new(session, Arc::new(NoopCoreHost))?;

        engine.update_conversation_on_message(
            MessagePreviewInputRecord {
                conv_id: "u10".to_owned(),
                text: "Hello U3".to_owned(),
                mentions: Vec::new(),
                preview_label: "Hello U3".to_owned(),
                date_ms: 1_700_000_000_000,
                is_mine: false,
                sender_name: "An".to_owned(),
                sender_avatar: None,
            },
            true,
        );
        let ver = engine.wait_idle().await?;
        assert!(ver >= 1);

        let Some(batch) = engine.next_changes().await? else {
            return Err(CoreError::Parse {
                message: "expected batch".to_owned(),
            });
        };
        let Some(convs) = batch.conversations else {
            return Err(CoreError::Parse {
                message: "expected conversations".to_owned(),
            });
        };
        assert_eq!(convs.len(), 1);
        assert_eq!(convs[0].id, "u10");
        assert_eq!(convs[0].unread, 1);

        let pin_res = engine.set_hidden_pin("1234".to_owned(), false).await?;
        assert!(pin_res.ok);
        assert!(engine.check_hidden_pin("1234".to_owned()).await?);
        assert!(!engine.check_hidden_pin("9999".to_owned()).await?);

        engine.stop();
        Ok(())
    }

    #[test]
    fn with_config_rejects_invalid_domains_json() {
        let res = CoreSession::with_config(
            "imei-1".to_owned(),
            "Mac".to_owned(),
            Some("not json".to_owned()),
        );
        assert!(matches!(res, Err(CoreError::Parse { .. })));
    }
}
