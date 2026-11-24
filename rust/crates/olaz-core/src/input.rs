//! Inputs to the pure reducer: external commands and effect completions.

use std::collections::BTreeMap;
use std::fmt;

use olaz_api::{HiddenConversationsSnapshot, PollState};
use olaz_net::{LoginAccount, NetError, QrScanResult, QrTicket, SessionStatus};
use olaz_ws::CursorMap;
use serde_json::{Map, Value};

use crate::conversations::{
    BatchApplyDelta, ConversationActionResult, ConversationSummary, IdentityTable,
    LocalAccountHydration, MessagePreviewInput,
};
use crate::effect::OpResult;
use crate::state::{CoreFailKind, FailReason, PersistedTransportState};
use crate::typed_chat::TypedChatEnvelope;

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
