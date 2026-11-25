//! Inputs to the pure reducer: external commands and effect completions.

use std::collections::{BTreeMap, BTreeSet};
use std::fmt;

use olaz_api::{AutoDeleteFetchOutcome, HiddenConversationsSnapshot, PollState, SendMessageResult};
use olaz_net::{LoginAccount, NetError, QrScanResult, QrTicket, SessionStatus};
use olaz_store::StoredMessage;
use olaz_wire::{ChatMessage, Mention, ParsedWireEvent, TextStyle};
use olaz_ws::CursorMap;
use serde_json::{Map, Value};

use crate::actions::{MessageConfirmState, ReactFailure, RecallFailure};
use crate::conversations::{
    BatchApplyDelta, ConversationActionResult, ConversationPreview, ConversationSummary,
    IdentityTable, LocalAccountHydration, MessagePreviewInput,
};
use crate::effect::OpResult;
use crate::messages::{ContactsState, HistoryFreshness};
use crate::state::{CoreFailKind, FailReason, PersistedTransportState};
use crate::typed_chat::TypedChatEnvelope;

// U5-send
/// Quote metadata passed across the `send_e2ee_text` host boundary.
#[derive(Clone, PartialEq, Eq)]
pub struct E2eeQuoteArg {
    pub msg_id: String,
    pub cli_msg_id: String,
    pub sender_id: String,
    pub sender_name: String,
    pub text: String,
    pub ts_ms: i64,
}

impl fmt::Debug for E2eeQuoteArg {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("E2eeQuoteArg")
            .field("ts_ms", &self.ts_ms)
            .field("has_text", &!self.text.is_empty())
            .finish()
    }
}

/// Message metadata needed to send a read receipt (`sendSeenAPI`) on `mark_read`.
#[derive(Clone, PartialEq, Eq)]
pub struct SeenTarget {
    pub conv_id: String,
    pub msg_id: String,
    pub cli_msg_id: String,
    pub sender_id: String,
}

impl fmt::Debug for SeenTarget {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("SeenTarget")
            .field("has_conv_id", &!self.conv_id.is_empty())
            .field("has_msg_id", &!self.msg_id.is_empty())
            .finish()
    }
}

/// Identifies which hidden-PIN flow invoked `syncAndPersistHiddenPin`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HiddenPinSyncKind {
    HideNewPin { conv_id: String },
    SetPin { changed: bool },
}

// U4-bootstrap
/// Failure category of `/api/alias/list` during launch bootstrap step 1.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BootstrapAliasesError {
    /// Auth error (code 600 or -102): aborts bootstrap and expires the session.
    Auth,
    /// Non-auth error: logged/ignored and bootstrap proceeds.
    Other,
}

/// Commands sent from Swift (or test scripts) into the actor.
#[derive(Clone)]
pub enum Command {
    Start,
    RefreshQr,
    LogOut,
    SessionExpired {
        reason: String,
    },
    ApplyAccountProfile(LoginAccount),
    DrainChatPolling {
        max_batches: u32,
        notify_incoming: bool,
    },

    // --- Launch bootstrap domain (U4-bootstrap) ---
    Bootstrap {
        now_ms: i64,
    },

    // --- Conversations & conversation actions domain (U3) ---
    UpdateIdentities(IdentityTable),
    ApplyBatchDelta(BatchApplyDelta),
    UpdateConversationOnMessage {
        msg: MessagePreviewInput,
        increment_unread: bool,
    },
    EnsureKnownContacts,
    ResolveMissingNames,
    RefreshMentionPreviews,
    SetOpenConversation {
        id: Option<String>,
    },
    PinConversation {
        id: String,
    },
    UnpinConversation {
        id: String,
    },
    RequestPinBoard {
        id: String,
    },
    PinReplacing {
        unpin_ids: Vec<String>,
        pin_id: String,
    },
    MoveConversation {
        id: String,
        to_other: bool,
    },
    RequestDeleteConversation {
        id: String,
    },
    ConfirmDeleteConversation {
        id: String,
        last_cli_msg_id: String,
    },
    DismissConversationPrompt,
    SetConversationPrompt(Option<crate::conversations::ConversationPrompt>),
    MarkConversationRead {
        id: String,
        seen_target: Option<SeenTarget>,
    },
    MarkConversationUnread {
        id: String,
    },
    HideConversation {
        id: String,
        pin: String,
    },
    HideConversationNewPin {
        id: String,
        pin: String,
    },
    UnhideConversation {
        id: String,
        pin: Option<String>,
    },
    SetHiddenPin {
        pin: String,
        changed: bool,
    },
    ResetHiddenPin,
    SyncHiddenConversations,
    ApplyServerHiddenConversations {
        pin: String,
        thread_ids: Vec<String>,
    },
    HiddenSearch {
        query: String,
    },
    UnlockFromPinSearch {
        id: String,
    },
    UnlockHiddenConversation {
        id: String,
    },
    DropHiddenUnlock,
    RelockHidden,
    HandleConversationActions {
        state: Map<String, Value>,
    },
    HandleConversationExtras {
        state: Map<String, Value>,
    },
    SetConversationFilter {
        filter_type: i32,
        label_ids: Vec<String>,
    },
    SetConversationLabel {
        conversation_id: String,
        label_id: Option<String>,
    },
    CreateConversationLabel {
        name: String,
        color_hex: String,
        conversation_ids: Vec<String>,
        now_ms: i64,
        rand4: String,
    },
    UpdateConversationLabel {
        id: String,
        name: String,
        color_hex: String,
    },
    DeleteConversationLabel {
        id: String,
    },
    ReorderConversationLabels {
        ids: Vec<String>,
    },
    SyncConversationLabels,
    ReportConversationActionResult(ConversationActionResult),
    CheckHiddenPin {
        pin: String,
    },
    SyncConversationsSnapshot(Vec<ConversationSummary>),
    RebuildConversationExtras,
    RepublishConversationActions,
    ResetConversationActions,
    PersistConversations,
    ApplyBootstrapPinArchive {
        pinned_ids: Option<Vec<String>>,
        archived_ids: Option<Vec<String>>,
    },
    RemoveLocalConversation {
        id: String,
    },

    // --- Messages domain (U4) ---
    OpenConversation {
        id: String,
        preloaded: Vec<ChatMessage>,
        skip_local_read: bool,
    },
    CloseConversation,
    LoadOlderMessages {
        id: String,
    },
    ApplyBatchDirect {
        payload: Map<String, Value>,
        default_cmd: u16,
        fallback_conv_id: Option<String>,
        is_group_hint: Option<bool>,
        increment_unread: bool,
        notify_incoming: bool,
        persist_conversations: bool,
        probe_freshness: bool,
        now_ms: Option<i64>,
    },
    ApplyParsedEventsDirect {
        events: Vec<ParsedWireEvent>,
        increment_unread: bool,
        notify_incoming: bool,
        persist_conversations: bool,
    },
    WriteThroughUpsertMessage {
        msg: Box<ChatMessage>,
        replacing_client_id: Option<String>,
    },
    WriteThroughRemoveMessages {
        conv_id: String,
        ids: Vec<String>,
    },
    WriteThroughReplaceWindow {
        conv_id: String,
        messages: Vec<ChatMessage>,
    },
    WriteThroughSetHasMore {
        conv_id: String,
        has_more: bool,
    },
    WriteThroughRemoveWindow {
        conv_id: String,
    },
    RefreshReactionNames {
        conv_id: Option<String>,
    },
    SeedHistoryFreshness(BTreeMap<String, HistoryFreshness>),
    SeedContacts(Box<ContactsState>),
    // U5
    HandleTyping {
        state: Map<String, Value>,
    },
    NotifyTyping {
        conv_id: String,
        now_ms: i64,
    },
    ResetOutgoingTyping {
        conv_id: String,
    },
    SetSendTypingEnabled {
        enabled: bool,
    },
    // U5-send
    /// Sends a text message (plain API or E2EE host boundary) with optimistic row insertion.
    SendText {
        conv_id: String,
        text: String,
        quote_id: Option<String>,
        mentions: Vec<Mention>,
        styles: Vec<TextStyle>,
        urgency: i64,
        client_id: i64,
        now_ms: i64,
        is_e2ee: Option<bool>,
        ttl_ms: Option<i64>,
    },
    /// Marks a conversation read using the core-owned message window for `seen_target`.
    MarkRead {
        id: String,
    },
    /// Replaces the set of 1-1 peer UIDs with active E2EE sessions.
    SetE2eeThreads(BTreeSet<String>),
    /// Updates a single conversation's auto-delete TTL in milliseconds (`0` disables).
    SetAutoDeleteTtl {
        conv_id: String,
        ttl_ms: i64,
    },

    // U6
    React {
        conv_id: String,
        msg_id: String,
        emoji: String,
        remove_all: bool,
        now_ms: i64,
    },
    Recall {
        conv_id: String,
        msg_id: String,
        is_e2ee_thread: Option<bool>,
        now_ms: i64,
    },
    RecallMany {
        conv_id: String,
        msg_ids: Vec<String>,
        confirm: bool,
        now_ms: i64,
    },
    DeleteForMe {
        conv_id: String,
        msg_id: String,
        confirmed: bool,
        now_ms: i64,
    },
    DeleteMany {
        conv_id: String,
        msg_ids: Vec<String>,
        confirm: bool,
        now_ms: i64,
    },
    AnswerMessageConfirm {
        ok: bool,
        now_ms: i64,
    },
    AskMessageConfirm {
        confirm: Box<MessageConfirmState>,
    },
    SetStarred {
        conv_id: String,
        msg_id: String,
        on: bool,
    },
    UndoDelete,
    DismissDeleteUndo,
    LoadAutoDelete,
    SetAutoDelete {
        conv_id: String,
        ttl: i64,
        now_ms: i64,
    },
    PruneExpiredMessages {
        conv_id: String,
        now_ms: i64,
    },
    RecordSeenReactionKeys {
        keys: Vec<String>,
        persist: bool,
    },
}

impl fmt::Debug for Command {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Start => f.write_str("Start"),
            Self::RefreshQr => f.write_str("RefreshQr"),
            Self::LogOut => f.write_str("LogOut"),
            Self::SessionExpired { reason } => f
                .debug_struct("SessionExpired")
                .field("reason_len", &reason.len())
                .finish(),
            Self::ApplyAccountProfile(acc) => f
                .debug_struct("ApplyAccountProfile")
                .field("has_uid", &!acc.user_id.is_empty())
                .finish(),
            Self::DrainChatPolling {
                max_batches,
                notify_incoming,
            } => f
                .debug_struct("DrainChatPolling")
                .field("max_batches", max_batches)
                .field("notify_incoming", notify_incoming)
                .finish(),
            // U4-bootstrap
            Self::Bootstrap { now_ms } => {
                f.debug_struct("Bootstrap").field("now_ms", now_ms).finish()
            }
            Self::UpdateIdentities(tbl) => f.debug_tuple("UpdateIdentities").field(tbl).finish(),
            Self::ApplyBatchDelta(d) => f.debug_tuple("ApplyBatchDelta").field(d).finish(),
            Self::UpdateConversationOnMessage {
                msg,
                increment_unread,
            } => f
                .debug_struct("UpdateConversationOnMessage")
                .field("msg", msg)
                .field("increment_unread", increment_unread)
                .finish(),
            Self::EnsureKnownContacts => f.write_str("EnsureKnownContacts"),
            Self::ResolveMissingNames => f.write_str("ResolveMissingNames"),
            Self::RefreshMentionPreviews => f.write_str("RefreshMentionPreviews"),
            Self::SetOpenConversation { id } => f
                .debug_struct("SetOpenConversation")
                .field("has_id", &id.is_some())
                .finish(),
            Self::PinConversation { .. } => f.write_str("PinConversation"),
            Self::UnpinConversation { .. } => f.write_str("UnpinConversation"),
            Self::RequestPinBoard { .. } => f.write_str("RequestPinBoard"),
            Self::PinReplacing { unpin_ids, .. } => f
                .debug_struct("PinReplacing")
                .field("unpin_count", &unpin_ids.len())
                .finish(),
            Self::MoveConversation { to_other, .. } => f
                .debug_struct("MoveConversation")
                .field("to_other", to_other)
                .finish(),
            Self::RequestDeleteConversation { .. } => f.write_str("RequestDeleteConversation"),
            Self::ConfirmDeleteConversation { .. } => f.write_str("ConfirmDeleteConversation"),
            Self::DismissConversationPrompt => f.write_str("DismissConversationPrompt"),
            Self::SetConversationPrompt(p) => {
                f.debug_tuple("SetConversationPrompt").field(p).finish()
            }
            Self::MarkConversationRead { seen_target, .. } => f
                .debug_struct("MarkConversationRead")
                .field("has_seen", &seen_target.is_some())
                .finish(),
            Self::MarkConversationUnread { .. } => f.write_str("MarkConversationUnread"),
            Self::HideConversation { .. } => f.write_str("HideConversation"),
            Self::HideConversationNewPin { .. } => f.write_str("HideConversationNewPin"),
            Self::UnhideConversation { pin, .. } => f
                .debug_struct("UnhideConversation")
                .field("has_pin", &pin.is_some())
                .finish(),
            Self::SetHiddenPin { changed, .. } => f
                .debug_struct("SetHiddenPin")
                .field("changed", changed)
                .finish(),
            Self::ResetHiddenPin => f.write_str("ResetHiddenPin"),
            Self::SyncHiddenConversations => f.write_str("SyncHiddenConversations"),
            Self::ApplyServerHiddenConversations { pin, thread_ids } => f
                .debug_struct("ApplyServerHiddenConversations")
                .field("has_pin", &!pin.is_empty())
                .field("thread_count", &thread_ids.len())
                .finish(),
            Self::HiddenSearch { query } => f
                .debug_struct("HiddenSearch")
                .field("query_len", &query.len())
                .finish(),
            Self::UnlockFromPinSearch { .. } => f.write_str("UnlockFromPinSearch"),
            Self::UnlockHiddenConversation { .. } => f.write_str("UnlockHiddenConversation"),
            Self::DropHiddenUnlock => f.write_str("DropHiddenUnlock"),
            Self::RelockHidden => f.write_str("RelockHidden"),
            Self::HandleConversationActions { state } => f
                .debug_struct("HandleConversationActions")
                .field("keys", &state.len())
                .finish(),
            Self::HandleConversationExtras { state } => f
                .debug_struct("HandleConversationExtras")
                .field("keys", &state.len())
                .finish(),
            Self::SetConversationFilter {
                filter_type,
                label_ids,
            } => f
                .debug_struct("SetConversationFilter")
                .field("filter_type", filter_type)
                .field("label_count", &label_ids.len())
                .finish(),
            Self::SetConversationLabel { label_id, .. } => f
                .debug_struct("SetConversationLabel")
                .field("has_label", &label_id.is_some())
                .finish(),
            Self::CreateConversationLabel {
                conversation_ids, ..
            } => f
                .debug_struct("CreateConversationLabel")
                .field("conv_count", &conversation_ids.len())
                .finish(),
            Self::UpdateConversationLabel { .. } => f.write_str("UpdateConversationLabel"),
            Self::DeleteConversationLabel { .. } => f.write_str("DeleteConversationLabel"),
            Self::ReorderConversationLabels { ids } => f
                .debug_struct("ReorderConversationLabels")
                .field("count", &ids.len())
                .finish(),
            Self::SyncConversationLabels => f.write_str("SyncConversationLabels"),
            Self::ReportConversationActionResult(r) => f
                .debug_tuple("ReportConversationActionResult")
                .field(r)
                .finish(),
            Self::CheckHiddenPin { .. } => f.write_str("CheckHiddenPin"),
            Self::SyncConversationsSnapshot(list) => f
                .debug_struct("SyncConversationsSnapshot")
                .field("count", &list.len())
                .finish(),
            Self::RebuildConversationExtras => f.write_str("RebuildConversationExtras"),
            Self::RepublishConversationActions => f.write_str("RepublishConversationActions"),
            Self::ResetConversationActions => f.write_str("ResetConversationActions"),
            Self::PersistConversations => f.write_str("PersistConversations"),
            Self::ApplyBootstrapPinArchive {
                pinned_ids,
                archived_ids,
            } => f
                .debug_struct("ApplyBootstrapPinArchive")
                .field("pinned_count", &pinned_ids.as_ref().map(Vec::len))
                .field("archived_count", &archived_ids.as_ref().map(Vec::len))
                .finish(),
            Self::RemoveLocalConversation { .. } => f.write_str("RemoveLocalConversation"),
            Self::OpenConversation { preloaded, .. } => f
                .debug_struct("OpenConversation")
                .field("preloaded", &preloaded.len())
                .finish(),
            Self::CloseConversation => f.write_str("CloseConversation"),
            Self::LoadOlderMessages { .. } => f.write_str("LoadOlderMessages"),
            Self::ApplyBatchDirect { default_cmd, .. } => f
                .debug_struct("ApplyBatchDirect")
                .field("default_cmd", default_cmd)
                .finish(),
            Self::ApplyParsedEventsDirect { events, .. } => f
                .debug_struct("ApplyParsedEventsDirect")
                .field("count", &events.len())
                .finish(),
            Self::WriteThroughUpsertMessage { .. } => f.write_str("WriteThroughUpsertMessage"),
            Self::WriteThroughRemoveMessages { ids, .. } => f
                .debug_struct("WriteThroughRemoveMessages")
                .field("count", &ids.len())
                .finish(),
            Self::WriteThroughReplaceWindow { messages, .. } => f
                .debug_struct("WriteThroughReplaceWindow")
                .field("count", &messages.len())
                .finish(),
            Self::WriteThroughSetHasMore { has_more, .. } => f
                .debug_struct("WriteThroughSetHasMore")
                .field("has_more", has_more)
                .finish(),
            Self::WriteThroughRemoveWindow { .. } => f.write_str("WriteThroughRemoveWindow"),
            Self::RefreshReactionNames { .. } => f.write_str("RefreshReactionNames"),
            Self::SeedHistoryFreshness(m) => f
                .debug_struct("SeedHistoryFreshness")
                .field("count", &m.len())
                .finish(),
            Self::SeedContacts(c) => f.debug_tuple("SeedContacts").field(c).finish(),
            // U5
            Self::HandleTyping { state } => f
                .debug_struct("HandleTyping")
                .field("keys", &state.len())
                .finish(),
            Self::NotifyTyping { now_ms, .. } => f
                .debug_struct("NotifyTyping")
                .field("now_ms", now_ms)
                .finish(),
            Self::ResetOutgoingTyping { .. } => f.write_str("ResetOutgoingTyping"),
            Self::SetSendTypingEnabled { enabled } => f
                .debug_struct("SetSendTypingEnabled")
                .field("enabled", enabled)
                .finish(),
            // U5-send
            Self::SendText {
                quote_id,
                mentions,
                styles,
                urgency,
                now_ms,
                is_e2ee,
                ttl_ms,
                ..
            } => f
                .debug_struct("SendText")
                .field("has_quote", &quote_id.is_some())
                .field("mentions_count", &mentions.len())
                .field("styles_count", &styles.len())
                .field("urgency", urgency)
                .field("now_ms", now_ms)
                .field("is_e2ee_override", is_e2ee)
                .field("ttl_ms_override", ttl_ms)
                .finish(),
            Self::MarkRead { .. } => f.write_str("MarkRead"),
            Self::SetE2eeThreads(threads) => f
                .debug_struct("SetE2eeThreads")
                .field("count", &threads.len())
                .finish(),
            Self::SetAutoDeleteTtl { ttl_ms, .. } => f
                .debug_struct("SetAutoDeleteTtl")
                .field("ttl_ms", ttl_ms)
                .finish(),
            // U6
            Self::React {
                remove_all, now_ms, ..
            } => f
                .debug_struct("React")
                .field("remove_all", remove_all)
                .field("now_ms", now_ms)
                .finish(),
            Self::Recall {
                is_e2ee_thread,
                now_ms,
                ..
            } => f
                .debug_struct("Recall")
                .field("is_e2ee_thread", is_e2ee_thread)
                .field("now_ms", now_ms)
                .finish(),
            Self::RecallMany {
                msg_ids,
                confirm,
                now_ms,
                ..
            } => f
                .debug_struct("RecallMany")
                .field("count", &msg_ids.len())
                .field("confirm", confirm)
                .field("now_ms", now_ms)
                .finish(),
            Self::DeleteForMe {
                confirmed, now_ms, ..
            } => f
                .debug_struct("DeleteForMe")
                .field("confirmed", confirmed)
                .field("now_ms", now_ms)
                .finish(),
            Self::DeleteMany {
                msg_ids,
                confirm,
                now_ms,
                ..
            } => f
                .debug_struct("DeleteMany")
                .field("count", &msg_ids.len())
                .field("confirm", confirm)
                .field("now_ms", now_ms)
                .finish(),
            Self::AnswerMessageConfirm { ok, now_ms } => f
                .debug_struct("AnswerMessageConfirm")
                .field("ok", ok)
                .field("now_ms", now_ms)
                .finish(),
            Self::AskMessageConfirm { confirm } => {
                f.debug_tuple("AskMessageConfirm").field(confirm).finish()
            }
            Self::SetStarred { on, .. } => f.debug_struct("SetStarred").field("on", on).finish(),
            Self::UndoDelete => f.write_str("UndoDelete"),
            Self::DismissDeleteUndo => f.write_str("DismissDeleteUndo"),
            Self::LoadAutoDelete => f.write_str("LoadAutoDelete"),
            Self::SetAutoDelete { ttl, now_ms, .. } => f
                .debug_struct("SetAutoDelete")
                .field("ttl", ttl)
                .field("now_ms", now_ms)
                .finish(),
            Self::PruneExpiredMessages { now_ms, .. } => f
                .debug_struct("PruneExpiredMessages")
                .field("now_ms", now_ms)
                .finish(),
            Self::RecordSeenReactionKeys { keys, persist } => f
                .debug_struct("RecordSeenReactionKeys")
                .field("count", &keys.len())
                .field("persist", persist)
                .finish(),
        }
    }
}

/// Identifies which flow awaits `HostCall::PrepareStore`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StoreToken {
    Boot(u64),
    Qr(u64),
}

/// Legacy WKWebView / HTTPCookieStorage credentials returned by `Host::load_legacy_cookie`.
#[derive(Clone, PartialEq, Eq)]
pub struct LegacyCookie {
    pub zpw_sek: String,
    pub imei: Option<String>,
}

impl fmt::Debug for LegacyCookie {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("LegacyCookie")
            .field("has_sek", &!self.zpw_sek.is_empty())
            .field("has_imei", &self.imei.is_some())
            .finish()
    }
}

/// Result of `complete_login` in the effect runner.
#[derive(Clone)]
pub struct CompletedLogin {
    pub account: LoginAccount,
    pub ws_endpoints: Vec<String>,
    pub profile_synced: bool,
}

impl fmt::Debug for CompletedLogin {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("CompletedLogin")
            .field("has_uid", &!self.account.user_id.is_empty())
            .field("ws_count", &self.ws_endpoints.len())
            .field("profile_synced", &self.profile_synced)
            .finish()
    }
}

/// Result of one `fetch_chat_from_polling` HTTP call.
#[derive(Clone)]
pub struct PollBatchOutcome {
    pub payload: Map<String, Value>,
    pub next_state: PollState,
    pub more: bool,
}

impl fmt::Debug for PollBatchOutcome {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("PollBatchOutcome")
            .field("payload_keys", &self.payload.len())
            .field("more", &self.more)
            .finish()
    }
}

/// Failure category of one `fetch_chat_from_polling` HTTP call.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PollBatchError {
    /// Auth error (code 600 or -102): expires the session.
    Auth,
    /// Transient network / server / parse error: ends this tick and retries on the next tick.
    Other,
}

/// Typed failure produced by QR login effects.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SessionFailure {
    Cancelled,
    QrTimeout,
    Failed(FailReason),
}

impl From<NetError> for SessionFailure {
    fn from(err: NetError) -> Self {
        match err {
            NetError::Cancelled => Self::Cancelled,
            NetError::QrTimeout => Self::QrTimeout,
            NetError::QrFailed(msg) => Self::Failed(FailReason::Text(msg)),
            NetError::InvalidUrl(raw) => {
                Self::Failed(FailReason::Text(format!("URL không hợp lệ: {raw}")))
            }
            NetError::Session(s) => Self::Failed(FailReason::Core(CoreFailKind::Session {
                code: s.code,
                message: s.message,
                url: s.url,
            })),
            NetError::Http { status, .. } => {
                Self::Failed(FailReason::Core(CoreFailKind::Http { status }))
            }
            NetError::InvalidJson => Self::Failed(FailReason::Core(CoreFailKind::InvalidJson)),
            NetError::NotAuthenticated => {
                Self::Failed(FailReason::Core(CoreFailKind::NotAuthenticated))
            }
            NetError::Network { kind, .. } => {
                Self::Failed(FailReason::Core(CoreFailKind::Network(kind)))
            }
            NetError::Crypto(c) => {
                Self::Failed(FailReason::Core(CoreFailKind::Crypto(c.to_string())))
            }
        }
    }
}

/// Every event entering `reduce(&mut CoreState, Input)`.
#[derive(Clone)]
pub enum Input {
    Command(Command),
    /// Request-reply wrapper for any U3 command whose caller awaits completion.
    OpRequest {
        op_id: u64,
        cmd: Command,
    },
    SavedSessionLoaded {
        boot_gen: u64,
        restored: bool,
        account: Option<LoginAccount>,
        ws_endpoints: Vec<String>,
    },
    LegacyCookieResult {
        boot_gen: u64,
        account: Option<LoginAccount>,
        ws_endpoints: Vec<String>,
        profile_synced: bool,
    },
    PrepareStoreDone {
        token: StoreToken,
        transport_state: PersistedTransportState,
        local_hydration: Option<Box<LocalAccountHydration>>,
    },
    SessionStatusResult {
        boot_gen: u64,
        status: SessionStatus,
        updated_from_login_info: bool,
        ws_endpoints: Vec<String>,
    },
    SyncProfileMeDone {
        boot_gen: u64,
        profile_synced: bool,
        account: Option<LoginAccount>,
        ws_endpoints: Vec<String>,
    },
    QrRequested {
        qr_gen: u64,
        result: Result<QrTicket, SessionFailure>,
    },
    QrRotated {
        qr_gen: u64,
        ticket: QrTicket,
    },
    QrScanned {
        qr_gen: u64,
        result: Result<QrScanResult, SessionFailure>,
    },
    QrConfirmed {
        qr_gen: u64,
        result: Result<(), SessionFailure>,
    },
    LoginCompleted {
        qr_gen: u64,
        result: Result<CompletedLogin, SessionFailure>,
    },

    // --- Transport domain (U2) ---
    WsEvent {
        ws_gen: u64,
        cmd: u16,
        payload: Map<String, Value>,
        now_unix_secs: i64,
    },
    WsTypedChat {
        ws_gen: u64,
        cmd: u16,
        envelope: TypedChatEnvelope,
    },
    WsAuthChanged {
        ws_gen: u64,
        authed: bool,
    },
    WsCursorsChanged {
        ws_gen: u64,
        cursors: CursorMap,
    },
    LpTick {
        lp_gen: u64,
    },
    DrainRequested {
        drain_id: u64,
        max_batches: u32,
        notify_incoming: bool,
    },
    PollBatchFetched {
        lp_gen: u64,
        drain_id: u64,
        result: Result<PollBatchOutcome, PollBatchError>,
        now_unix_secs: i64,
    },
    PollBatchApplied {
        lp_gen: u64,
        drain_id: u64,
        delta: BatchApplyDelta,
    },
    /// Completion of a WS `ApplyBatch` or `ApplyParsedEvents` host call carrying Swift-computed deltas.
    BatchDeltaApplied {
        delta: BatchApplyDelta,
    },

    // --- Conversations & conversation actions completions (U3) ---
    PinApiDone {
        id: String,
        pinned: bool,
        ok: bool,
        op_id: Option<u64>,
    },
    PinReplacingStepDone {
        op_id: Option<u64>,
        target_id: String,
        pinned: bool,
        unpin_remaining: Vec<String>,
        pin_id: String,
        ok: bool,
    },
    MoveApiDone {
        id: String,
        to_other: bool,
        ok: bool,
        op_id: Option<u64>,
    },
    DeleteApiDone {
        id: String,
        op_id: Option<u64>,
    },
    HiddenPinSyncDone {
        op_id: Option<u64>,
        kind: HiddenPinSyncKind,
        ok: bool,
        md5: Option<String>,
        sha256: String,
    },
    ResetHiddenPinApiDone {
        op_id: Option<u64>,
        ok: bool,
    },
    SyncHiddenFetched {
        op_id: Option<u64>,
        snapshot: Option<HiddenConversationsSnapshot>,
    },
    ResolveNamesChunkDone {
        op_id: Option<u64>,
        remaining_chunks: Vec<Vec<String>>,
        /// Raw `profilesMap` returned by `extract_profiles_map`.
        profiles_map: Map<String, Value>,
        profiles_cache_changed: bool,
    },
    MentionPreviewsLoaded {
        op_id: Option<u64>,
        messages: BTreeMap<String, MessagePreviewInput>,
    },
    SyncLabelsFetched {
        op_id: Option<u64>,
        payload: Option<Map<String, Value>>,
    },
    OpApiDone {
        op_id: u64,
        result: OpResult,
    },
    OpStoreFlushed {
        op_id: u64,
        result: OpResult,
    },

    // --- Launch bootstrap completions (U4-bootstrap) ---
    BootstrapAliasesDone {
        boot_gen: u64,
        result: Result<BTreeMap<String, String>, BootstrapAliasesError>,
    },
    BootstrapFreshnessLoaded {
        boot_gen: u64,
        last_refresh_pref: Option<String>,
    },
    BootstrapPamDone {
        boot_gen: u64,
        pinned_ids: Option<Vec<String>>,
        archived_ids: Option<Vec<String>>,
        mute_rows: Option<Vec<Map<String, Value>>>,
    },
    BootstrapLabelsDone {
        boot_gen: u64,
        payload: Option<Map<String, Value>>,
    },
    BootstrapHiddenDone {
        boot_gen: u64,
        snapshot: Option<HiddenConversationsSnapshot>,
    },
    BootstrapContactsDone {
        boot_gen: u64,
        friends_rows: Option<Vec<Map<String, Value>>>,
        groups_dict: Option<Map<String, Value>>,
        sent_rows: Option<Vec<Map<String, Value>>>,
        received_rows: Option<Vec<Map<String, Value>>>,
    },
    BootstrapPreloadDone {
        boot_gen: u64,
        is_overview: bool,
        payload: Option<Map<String, Value>>,
    },
    FreshnessProbed {
        boot_gen: Option<u64>,
        probes: Vec<(String, bool)>,
    },
    BootstrapSelfCloudDone {
        boot_gen: u64,
        conv_id: String,
        payload: Option<Map<String, Value>>,
    },
    BootstrapGroupWaveDone {
        boot_gen: u64,
        results: Vec<(String, Option<Map<String, Value>>)>,
    },
    BootstrapResolveNamesChunkDone {
        boot_gen: u64,
        remaining_chunks: Vec<Vec<String>>,
        profiles_map: Map<String, Value>,
        profiles_cache_changed: bool,
    },
    // --- Messages domain completions (U4) ---
    OpenLocalMessagesLoaded {
        open_seq: u64,
        conv_id: String,
        rows: Vec<StoredMessage>,
        op_id: Option<u64>,
    },
    OpenHistoryPageFetched {
        open_seq: u64,
        conv_id: String,
        page: Option<Map<String, Value>>,
        op_id: Option<u64>,
    },
    LoadOlderStoreRead {
        load_seq: u64,
        conv_id: String,
        rows: Vec<StoredMessage>,
        had_before_cursor: bool,
        op_id: Option<u64>,
    },
    LoadOlderPageFetched {
        load_seq: u64,
        conv_id: String,
        before_msg_id: Option<String>,
        page: Option<Map<String, Value>>,
        op_id: Option<u64>,
    },
    SenderProfilesChunkDone {
        resolve_id: u64,
        conv_id: String,
        remaining_chunks: Vec<Vec<String>>,
        profiles_map: Map<String, Value>,
        cache_updated: bool,
    },
    TypedEnvelopeReady {
        cmd: u16,
        increment_unread: bool,
        notify_incoming: bool,
        envelope: TypedChatEnvelope,
    },
    DecryptedEnvelopeReady {
        payload: Map<String, Value>,
        default_cmd: u16,
        fallback_conv_id: Option<String>,
        is_group_hint: Option<bool>,
        increment_unread: bool,
        notify_incoming: bool,
        persist_conversations: bool,
        probe_freshness: bool,
        poll_batch_done: Option<(u64, u64)>,
        op_id: Option<u64>,
    },
    // U5
    TypingExpired {
        conv_id: String,
        expiry_gen: u64,
    },
    // U5-send
    SendTextDone {
        send_id: u64,
        result: Result<SendMessageResult, String>,
    },

    // U6
    MessageIdsResolved {
        resolve_id: u64,
        effective_msg_id: String,
        resolved_cli_id: String,
        upgraded_from_history: bool,
    },
    ReactDone {
        react_id: u64,
        final_react_client_id: String,
        error: Option<ReactFailure>,
    },
    RecallDone {
        recall_id: u64,
        retried_alt: bool,
        error: Option<RecallFailure>,
    },
    RemoteReactionApproved {
        conv_id: String,
        msg_id: String,
        cli_msg_id: String,
        sender_id: String,
        r_type: String,
        r_icon: String,
        event_id: String,
        react_client_id: String,
        sender_name: String,
        now_ms: i64,
    },
    RemoteRecallApproved {
        conv_id: String,
        msg_id: String,
        cli_msg_id: String,
        update_conversation_preview: bool,
        persist_conversations: bool,
        op_id: Option<u64>,
        recall_many_id: Option<u64>,
    },
    RemoteRecallSkipped {
        op_id: Option<u64>,
        recall_many_id: Option<u64>,
    },
    RemoteRecallStoreDone {
        conv_id: String,
        recalled_last: Option<(i64, bool)>,
        update_conversation_preview: bool,
        persist_conversations: bool,
        op_id: Option<u64>,
        recall_many_id: Option<u64>,
    },
    RemoteDeleteApproved {
        conv_id: String,
        msg_id: String,
        cli_msg_id: String,
        update_conversation_preview: bool,
        persist_conversations: bool,
    },
    RemoteDeleteStoreDone {
        conv_id: String,
        deleted_ts_ms: Option<i64>,
        mem_latest: Option<ConversationPreview>,
        store_latest: Option<ConversationPreview>,
        update_conversation_preview: bool,
        persist_conversations: bool,
    },
    DeleteUndoExpired {
        undo_gen: u64,
    },
    AutoDeleteLoaded {
        outcome: Option<AutoDeleteFetchOutcome>,
        op_id: Option<u64>,
    },
    AutoDeleteUpdated {
        conv_id: String,
        ttl: i64,
        now_ms: i64,
        error_type: Option<String>,
        op_id: Option<u64>,
    },
}

impl fmt::Debug for Input {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Command(c) => f.debug_tuple("Command").field(c).finish(),
            Self::OpRequest { op_id, cmd } => f
                .debug_struct("OpRequest")
                .field("op_id", op_id)
                .field("cmd", cmd)
                .finish(),
            Self::SavedSessionLoaded {
                boot_gen,
                restored,
                account,
                ws_endpoints,
            } => f
                .debug_struct("SavedSessionLoaded")
                .field("boot_gen", boot_gen)
                .field("restored", restored)
                .field("has_account", &account.is_some())
                .field("ws_count", &ws_endpoints.len())
                .finish(),
            Self::LegacyCookieResult {
                boot_gen,
                account,
                ws_endpoints,
                profile_synced,
            } => f
                .debug_struct("LegacyCookieResult")
                .field("boot_gen", boot_gen)
                .field("has_account", &account.is_some())
                .field("ws_count", &ws_endpoints.len())
                .field("profile_synced", profile_synced)
                .finish(),
            Self::PrepareStoreDone {
                token,
                transport_state,
                local_hydration,
            } => f
                .debug_struct("PrepareStoreDone")
                .field("token", token)
                .field("transport_state", transport_state)
                .field("has_hydration", &local_hydration.is_some())
                .finish(),
            Self::SessionStatusResult {
                boot_gen,
                status,
                updated_from_login_info,
                ws_endpoints,
            } => f
                .debug_struct("SessionStatusResult")
                .field("boot_gen", boot_gen)
                .field("status", status)
                .field("updated_from_login_info", updated_from_login_info)
                .field("ws_count", &ws_endpoints.len())
                .finish(),
            Self::SyncProfileMeDone {
                boot_gen,
                profile_synced,
                account,
                ws_endpoints,
            } => f
                .debug_struct("SyncProfileMeDone")
                .field("boot_gen", boot_gen)
                .field("profile_synced", profile_synced)
                .field("has_account", &account.is_some())
                .field("ws_count", &ws_endpoints.len())
                .finish(),
            Self::QrRequested { qr_gen, result } => f
                .debug_struct("QrRequested")
                .field("qr_gen", qr_gen)
                .field("ok", &result.is_ok())
                .finish(),
            Self::QrRotated { qr_gen, .. } => {
                f.debug_struct("QrRotated").field("qr_gen", qr_gen).finish()
            }
            Self::QrScanned { qr_gen, result } => f
                .debug_struct("QrScanned")
                .field("qr_gen", qr_gen)
                .field("ok", &result.is_ok())
                .finish(),
            Self::QrConfirmed { qr_gen, result } => f
                .debug_struct("QrConfirmed")
                .field("qr_gen", qr_gen)
                .field("ok", &result.is_ok())
                .finish(),
            Self::LoginCompleted { qr_gen, result } => f
                .debug_struct("LoginCompleted")
                .field("qr_gen", qr_gen)
                .field("ok", &result.is_ok())
                .finish(),
            Self::WsEvent {
                ws_gen,
                cmd,
                payload,
                ..
            } => f
                .debug_struct("WsEvent")
                .field("ws_gen", ws_gen)
                .field("cmd", cmd)
                .field("payload_keys", &payload.len())
                .finish(),
            Self::WsTypedChat {
                ws_gen,
                cmd,
                envelope,
            } => f
                .debug_struct("WsTypedChat")
                .field("ws_gen", ws_gen)
                .field("cmd", cmd)
                .field("envelope", envelope)
                .finish(),
            Self::WsAuthChanged { ws_gen, authed } => f
                .debug_struct("WsAuthChanged")
                .field("ws_gen", ws_gen)
                .field("authed", authed)
                .finish(),
            Self::WsCursorsChanged { ws_gen, cursors } => f
                .debug_struct("WsCursorsChanged")
                .field("ws_gen", ws_gen)
                .field("cursors_count", &cursors.len())
                .finish(),
            Self::LpTick { lp_gen } => f.debug_struct("LpTick").field("lp_gen", lp_gen).finish(),
            Self::DrainRequested {
                drain_id,
                max_batches,
                notify_incoming,
            } => f
                .debug_struct("DrainRequested")
                .field("drain_id", drain_id)
                .field("max_batches", max_batches)
                .field("notify_incoming", notify_incoming)
                .finish(),
            Self::PollBatchFetched {
                lp_gen,
                drain_id,
                result,
                ..
            } => f
                .debug_struct("PollBatchFetched")
                .field("lp_gen", lp_gen)
                .field("drain_id", drain_id)
                .field("result", result)
                .finish(),
            Self::PollBatchApplied {
                lp_gen,
                drain_id,
                delta,
            } => f
                .debug_struct("PollBatchApplied")
                .field("lp_gen", lp_gen)
                .field("drain_id", drain_id)
                .field("delta", delta)
                .finish(),
            Self::BatchDeltaApplied { delta } => f
                .debug_struct("BatchDeltaApplied")
                .field("delta", delta)
                .finish(),
            Self::PinApiDone { pinned, ok, .. } => f
                .debug_struct("PinApiDone")
                .field("pinned", pinned)
                .field("ok", ok)
                .finish(),
            Self::PinReplacingStepDone {
                pinned,
                unpin_remaining,
                ok,
                ..
            } => f
                .debug_struct("PinReplacingStepDone")
                .field("pinned", pinned)
                .field("remaining", &unpin_remaining.len())
                .field("ok", ok)
                .finish(),
            Self::MoveApiDone { to_other, ok, .. } => f
                .debug_struct("MoveApiDone")
                .field("to_other", to_other)
                .field("ok", ok)
                .finish(),
            Self::DeleteApiDone { .. } => f.write_str("DeleteApiDone"),
            Self::HiddenPinSyncDone { kind, ok, md5, .. } => f
                .debug_struct("HiddenPinSyncDone")
                .field("kind", kind)
                .field("ok", ok)
                .field("has_md5", &md5.is_some())
                .finish(),
            Self::ResetHiddenPinApiDone { ok, .. } => f
                .debug_struct("ResetHiddenPinApiDone")
                .field("ok", ok)
                .finish(),
            Self::SyncHiddenFetched { snapshot, .. } => f
                .debug_struct("SyncHiddenFetched")
                .field("has_snapshot", &snapshot.is_some())
                .finish(),
            Self::ResolveNamesChunkDone {
                remaining_chunks,
                profiles_map,
                profiles_cache_changed,
                ..
            } => f
                .debug_struct("ResolveNamesChunkDone")
                .field("remaining_chunks", &remaining_chunks.len())
                .field("profiles_count", &profiles_map.len())
                .field("cache_changed", profiles_cache_changed)
                .finish(),
            Self::MentionPreviewsLoaded { messages, .. } => f
                .debug_struct("MentionPreviewsLoaded")
                .field("messages_count", &messages.len())
                .finish(),
            Self::SyncLabelsFetched { payload, .. } => f
                .debug_struct("SyncLabelsFetched")
                .field("has_payload", &payload.is_some())
                .finish(),
            Self::OpApiDone { op_id, result } => f
                .debug_struct("OpApiDone")
                .field("op_id", op_id)
                .field("result", result)
                .finish(),
            Self::OpStoreFlushed { op_id, result } => f
                .debug_struct("OpStoreFlushed")
                .field("op_id", op_id)
                .field("result", result)
                .finish(),
            // U4-bootstrap
            Self::BootstrapAliasesDone { boot_gen, result } => f
                .debug_struct("BootstrapAliasesDone")
                .field("boot_gen", boot_gen)
                .field("ok", &result.is_ok())
                .field("count", &result.as_ref().map(BTreeMap::len))
                .finish(),
            Self::BootstrapFreshnessLoaded {
                boot_gen,
                last_refresh_pref,
            } => f
                .debug_struct("BootstrapFreshnessLoaded")
                .field("boot_gen", boot_gen)
                .field("has_pref", &last_refresh_pref.is_some())
                .finish(),
            Self::BootstrapPamDone {
                boot_gen,
                pinned_ids,
                archived_ids,
                mute_rows,
            } => f
                .debug_struct("BootstrapPamDone")
                .field("boot_gen", boot_gen)
                .field("pinned_count", &pinned_ids.as_ref().map(Vec::len))
                .field("archived_count", &archived_ids.as_ref().map(Vec::len))
                .field("mute_count", &mute_rows.as_ref().map(Vec::len))
                .finish(),
            Self::BootstrapLabelsDone { boot_gen, payload } => f
                .debug_struct("BootstrapLabelsDone")
                .field("boot_gen", boot_gen)
                .field("has_payload", &payload.is_some())
                .finish(),
            Self::BootstrapHiddenDone { boot_gen, snapshot } => f
                .debug_struct("BootstrapHiddenDone")
                .field("boot_gen", boot_gen)
                .field("has_snapshot", &snapshot.is_some())
                .finish(),
            Self::BootstrapContactsDone {
                boot_gen,
                friends_rows,
                groups_dict,
                sent_rows,
                received_rows,
            } => f
                .debug_struct("BootstrapContactsDone")
                .field("boot_gen", boot_gen)
                .field("friends_count", &friends_rows.as_ref().map(Vec::len))
                .field("has_groups", &groups_dict.is_some())
                .field("sent_count", &sent_rows.as_ref().map(Vec::len))
                .field("received_count", &received_rows.as_ref().map(Vec::len))
                .finish(),
            Self::BootstrapPreloadDone {
                boot_gen,
                is_overview,
                payload,
            } => f
                .debug_struct("BootstrapPreloadDone")
                .field("boot_gen", boot_gen)
                .field("is_overview", is_overview)
                .field("has_payload", &payload.is_some())
                .finish(),
            Self::FreshnessProbed { boot_gen, probes } => f
                .debug_struct("FreshnessProbed")
                .field("boot_gen", boot_gen)
                .field("probes_count", &probes.len())
                .finish(),
            Self::BootstrapSelfCloudDone {
                boot_gen, payload, ..
            } => f
                .debug_struct("BootstrapSelfCloudDone")
                .field("boot_gen", boot_gen)
                .field("has_payload", &payload.is_some())
                .finish(),
            Self::BootstrapGroupWaveDone { boot_gen, results } => f
                .debug_struct("BootstrapGroupWaveDone")
                .field("boot_gen", boot_gen)
                .field("count", &results.len())
                .finish(),
            Self::BootstrapResolveNamesChunkDone {
                boot_gen,
                remaining_chunks,
                profiles_map,
                profiles_cache_changed,
            } => f
                .debug_struct("BootstrapResolveNamesChunkDone")
                .field("boot_gen", boot_gen)
                .field("remaining_chunks", &remaining_chunks.len())
                .field("profiles_count", &profiles_map.len())
                .field("cache_changed", profiles_cache_changed)
                .finish(),
            Self::OpenLocalMessagesLoaded { open_seq, rows, .. } => f
                .debug_struct("OpenLocalMessagesLoaded")
                .field("open_seq", open_seq)
                .field("rows", &rows.len())
                .finish(),
            Self::OpenHistoryPageFetched { open_seq, page, .. } => f
                .debug_struct("OpenHistoryPageFetched")
                .field("open_seq", open_seq)
                .field("has_page", &page.is_some())
                .finish(),
            Self::LoadOlderStoreRead { load_seq, rows, .. } => f
                .debug_struct("LoadOlderStoreRead")
                .field("load_seq", load_seq)
                .field("rows", &rows.len())
                .finish(),
            Self::LoadOlderPageFetched { load_seq, page, .. } => f
                .debug_struct("LoadOlderPageFetched")
                .field("load_seq", load_seq)
                .field("has_page", &page.is_some())
                .finish(),
            Self::SenderProfilesChunkDone {
                resolve_id,
                remaining_chunks,
                profiles_map,
                cache_updated,
                ..
            } => f
                .debug_struct("SenderProfilesChunkDone")
                .field("resolve_id", resolve_id)
                .field("remaining", &remaining_chunks.len())
                .field("profiles", &profiles_map.len())
                .field("cache_updated", cache_updated)
                .finish(),
            Self::TypedEnvelopeReady { cmd, envelope, .. } => f
                .debug_struct("TypedEnvelopeReady")
                .field("cmd", cmd)
                .field("envelope", envelope)
                .finish(),
            Self::DecryptedEnvelopeReady { default_cmd, .. } => f
                .debug_struct("DecryptedEnvelopeReady")
                .field("default_cmd", default_cmd)
                .finish(),
            // U5
            Self::TypingExpired { expiry_gen, .. } => f
                .debug_struct("TypingExpired")
                .field("expiry_gen", expiry_gen)
                .finish(),
            // U5-send
            Self::SendTextDone { send_id, result } => f
                .debug_struct("SendTextDone")
                .field("send_id", send_id)
                .field("ok", &result.is_ok())
                .finish(),
            // U6
            Self::MessageIdsResolved {
                resolve_id,
                upgraded_from_history,
                ..
            } => f
                .debug_struct("MessageIdsResolved")
                .field("resolve_id", resolve_id)
                .field("upgraded_from_history", upgraded_from_history)
                .finish(),
            Self::ReactDone {
                react_id, error, ..
            } => f
                .debug_struct("ReactDone")
                .field("react_id", react_id)
                .field("ok", &error.is_none())
                .finish(),
            Self::RecallDone {
                recall_id,
                retried_alt,
                error,
            } => f
                .debug_struct("RecallDone")
                .field("recall_id", recall_id)
                .field("retried_alt", retried_alt)
                .field("ok", &error.is_none())
                .finish(),
            Self::RemoteReactionApproved { r_type, now_ms, .. } => f
                .debug_struct("RemoteReactionApproved")
                .field("r_type", r_type)
                .field("now_ms", now_ms)
                .finish(),
            Self::RemoteRecallApproved {
                update_conversation_preview,
                persist_conversations,
                op_id,
                recall_many_id,
                ..
            } => f
                .debug_struct("RemoteRecallApproved")
                .field("update_conversation_preview", update_conversation_preview)
                .field("persist_conversations", persist_conversations)
                .field("op_id", op_id)
                .field("recall_many_id", recall_many_id)
                .finish(),
            Self::RemoteRecallSkipped {
                op_id,
                recall_many_id,
            } => f
                .debug_struct("RemoteRecallSkipped")
                .field("op_id", op_id)
                .field("recall_many_id", recall_many_id)
                .finish(),
            Self::RemoteRecallStoreDone {
                recalled_last,
                update_conversation_preview,
                persist_conversations,
                op_id,
                recall_many_id,
                ..
            } => f
                .debug_struct("RemoteRecallStoreDone")
                .field("has_recalled_last", &recalled_last.is_some())
                .field("update_conversation_preview", update_conversation_preview)
                .field("persist_conversations", persist_conversations)
                .field("op_id", op_id)
                .field("recall_many_id", recall_many_id)
                .finish(),
            Self::RemoteDeleteApproved {
                update_conversation_preview,
                persist_conversations,
                ..
            } => f
                .debug_struct("RemoteDeleteApproved")
                .field("update_conversation_preview", update_conversation_preview)
                .field("persist_conversations", persist_conversations)
                .finish(),
            Self::RemoteDeleteStoreDone {
                deleted_ts_ms,
                update_conversation_preview,
                persist_conversations,
                ..
            } => f
                .debug_struct("RemoteDeleteStoreDone")
                .field("has_deleted_ts", &deleted_ts_ms.is_some())
                .field("update_conversation_preview", update_conversation_preview)
                .field("persist_conversations", persist_conversations)
                .finish(),
            Self::DeleteUndoExpired { undo_gen } => f
                .debug_struct("DeleteUndoExpired")
                .field("undo_gen", undo_gen)
                .finish(),
            Self::AutoDeleteLoaded { outcome, op_id } => f
                .debug_struct("AutoDeleteLoaded")
                .field("outcome", outcome)
                .field("op_id", op_id)
                .finish(),
            Self::AutoDeleteUpdated {
                ttl,
                now_ms,
                error_type,
                op_id,
                ..
            } => f
                .debug_struct("AutoDeleteUpdated")
                .field("ttl", ttl)
                .field("now_ms", now_ms)
                .field("error_type", error_type)
                .field("op_id", op_id)
                .finish(),
        }
    }
}

#[cfg(test)]
mod tests {
    use olaz_net::{NetworkErrorKind, ZaloSessionError};

    use super::*;

    #[test]
    fn net_error_mapping_preserves_swift_strings_and_typed_core_errors() {
        assert_eq!(
            SessionFailure::from(NetError::Cancelled),
            SessionFailure::Cancelled
        );
        assert_eq!(
            SessionFailure::from(NetError::QrTimeout),
            SessionFailure::QrTimeout
        );
        assert_eq!(
            SessionFailure::from(NetError::QrFailed(
                "Máy chủ không trả về dữ liệu QR.".into()
            )),
            SessionFailure::Failed(FailReason::Text("Máy chủ không trả về dữ liệu QR.".into()))
        );
        assert_eq!(
            SessionFailure::from(NetError::Session(ZaloSessionError {
                code: -1,
                message: "Không tạo được mã QR".into(),
                url: "/api/login/reqqr".into(),
            })),
            SessionFailure::Failed(FailReason::Core(CoreFailKind::Session {
                code: -1,
                message: "Không tạo được mã QR".into(),
                url: "/api/login/reqqr".into(),
            }))
        );
        assert_eq!(
            SessionFailure::from(NetError::network(NetworkErrorKind::Other, "refused")),
            SessionFailure::Failed(FailReason::Core(CoreFailKind::Network(
                NetworkErrorKind::Other
            )))
        );
    }
}
