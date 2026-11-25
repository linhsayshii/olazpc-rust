//! Side effects returned by `reduce` and executed by [`crate::runner::EffectRunner`].

use std::fmt;
use std::time::Duration;

use olaz_api::PollState;
use olaz_net::{LoginAccount, QrTicket};
use olaz_store::StoredConversation;
use olaz_ws::CursorMap;
use serde_json::{Map, Value};

use crate::conversations::{ConversationActionResult, IdentityTable, PinBoard};
use crate::input::{HiddenPinSyncKind, SeenTarget, StoreToken};
use crate::reduce::classify::MobileSyncEvent;
use crate::typed_chat::TypedChatEnvelope;

/// Serial SQLite persistence operations executed by the core runner's store worker (U3).
#[derive(Clone)]
pub enum StoreOp {
    SaveConversations(Vec<StoredConversation>),
    SetConversationPinned {
        id: String,
        pinned: bool,
    },
    SetConversationUnread {
        id: String,
        unread: i64,
    },
    DeleteConversation {
        id: String,
    },
    SetPreferenceString {
        key: String,
        value: String,
    },
    SetPreferenceStrings {
        key: String,
        values: Vec<String>,
    },
    SetPreferenceData {
        key: String,
        data: Vec<u8>,
    },
    DeletePreference {
        key: String,
    },
    LoadMentionPreviewMessages {
        op_id: Option<u64>,
        group_ids: Vec<String>,
        my_uid: String,
    },
}

impl fmt::Debug for StoreOp {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::SaveConversations(rows) => f
                .debug_struct("SaveConversations")
                .field("count", &rows.len())
                .finish(),
            Self::SetConversationPinned { pinned, .. } => f
                .debug_struct("SetConversationPinned")
                .field("pinned", pinned)
                .finish(),
            Self::SetConversationUnread { unread, .. } => f
                .debug_struct("SetConversationUnread")
                .field("unread", unread)
                .finish(),
            Self::DeleteConversation { .. } => f.write_str("DeleteConversation"),
            Self::SetPreferenceString { key, .. } => f
                .debug_struct("SetPreferenceString")
                .field("key", key)
                .finish(),
            Self::SetPreferenceStrings { key, values } => f
                .debug_struct("SetPreferenceStrings")
                .field("key", key)
                .field("count", &values.len())
                .finish(),
            Self::SetPreferenceData { key, data } => f
                .debug_struct("SetPreferenceData")
                .field("key", key)
                .field("bytes", &data.len())
                .finish(),
            Self::DeletePreference { key } => f
                .debug_struct("DeletePreference")
                .field("key", key)
                .finish(),
            Self::LoadMentionPreviewMessages { group_ids, .. } => f
                .debug_struct("LoadMentionPreviewMessages")
                .field("group_count", &group_ids.len())
                .finish(),
        }
    }
}

/// Reply value resolved to an awaiting request-reply caller on [`crate::actor::CoreHandle`].
#[derive(Clone)]
pub enum OpResult {
    Unit,
    ActionResult(ConversationActionResult),
    PinBoard(Option<PinBoard>),
    HiddenSearch(Option<Vec<String>>),
    Bool(bool),
}

impl fmt::Debug for OpResult {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Unit => f.write_str("Unit"),
            Self::ActionResult(r) => f.debug_tuple("ActionResult").field(r).finish(),
            Self::PinBoard(b) => f.debug_tuple("PinBoard").field(b).finish(),
            Self::HiddenSearch(v) => f
                .debug_struct("HiddenSearch")
                .field("count", &v.as_ref().map(Vec::len))
                .finish(),
            Self::Bool(b) => f.debug_tuple("Bool").field(b).finish(),
        }
    }
}

/// Activities handed to Swift-owned domains (the `host` list in Case format v1).
///
/// Host calls emitted by a `reduce` step always execute serially in emitted order.
/// Credential snapshots for `PersistSession` / `MarkExpired` are read from `SessionClient` by the
/// effect runner at dispatch time so no secret material sits inside reducer effects.
#[derive(Clone)]
pub enum HostCall {
    PrepareStore {
        token: StoreToken,
        user_id: String,
        account: Box<LoginAccount>,
        identities: Box<IdentityTable>,
    },
    StartBootstrap,
    OfferFirstLoginTransfer {
        force: bool,
    },
    ResetDomains,
    PersistSession,
    ClearSession,
    MarkExpired,

    // --- Transport domain (U2) ---
    PersistPollState {
        state: PollState,
    },
    PersistWsCursors {
        cursors: CursorMap,
    },
    ApplyBatch {
        /// `Some(cmd)` on the WS path, `None` on the long-poll path.
        cmd: Option<u16>,
        increment_unread: bool,
        notify_incoming: bool,
        payload: Map<String, Value>,
        /// Set on the long-poll path so the host worker notifies the actor with the applied delta
        /// once `apply_batch` completes, preserving strict batch-by-batch ordering.
        poll_batch_done: Option<(u64, u64)>,
    },
    ApplyParsedEvents {
        cmd: u16,
        increment_unread: bool,
        notify_incoming: bool,
        envelope: TypedChatEnvelope,
    },
    MobileSync {
        events: Vec<MobileSyncEvent>,
    },
    E2eeSignal {
        cmd: u16,
        payload: Map<String, Value>,
    },
    E2eeDeliverReports {
        cmd: u16,
        payload: Map<String, Value>,
    },
    E2eeConnected {
        uid: String,
    },
    E2eeDisconnected,
    VoipControl {
        act: String,
        raw_data: Value,
        data: Map<String, Value>,
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
        data: Map<String, Value>,
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

impl fmt::Debug for HostCall {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::PrepareStore { token, user_id, .. } => f
                .debug_struct("PrepareStore")
                .field("token", token)
                .field("has_uid", &!user_id.is_empty())
                .finish(),
            Self::StartBootstrap => f.write_str("StartBootstrap"),
            Self::OfferFirstLoginTransfer { force } => f
                .debug_struct("OfferFirstLoginTransfer")
                .field("force", force)
                .finish(),
            Self::ResetDomains => f.write_str("ResetDomains"),
            Self::PersistSession => f.write_str("PersistSession"),
            Self::ClearSession => f.write_str("ClearSession"),
            Self::MarkExpired => f.write_str("MarkExpired"),
            Self::PersistPollState { .. } => f.write_str("PersistPollState"),
            Self::PersistWsCursors { cursors } => f
                .debug_struct("PersistWsCursors")
                .field("cursors_count", &cursors.len())
                .finish(),
            Self::ApplyBatch {
                cmd,
                increment_unread,
                notify_incoming,
                payload,
                poll_batch_done,
            } => f
                .debug_struct("ApplyBatch")
                .field("cmd", cmd)
                .field("increment_unread", increment_unread)
                .field("notify_incoming", notify_incoming)
                .field("payload_keys", &payload.len())
                .field("is_poll", &poll_batch_done.is_some())
                .finish(),
            Self::ApplyParsedEvents {
                cmd,
                increment_unread,
                notify_incoming,
                envelope,
            } => f
                .debug_struct("ApplyParsedEvents")
                .field("cmd", cmd)
                .field("increment_unread", increment_unread)
                .field("notify_incoming", notify_incoming)
                .field("envelope", envelope)
                .finish(),
            Self::MobileSync { events } => f
                .debug_struct("MobileSync")
                .field("count", &events.len())
                .finish(),
            Self::E2eeSignal { cmd, payload } => f
                .debug_struct("E2eeSignal")
                .field("cmd", cmd)
                .field("payload_keys", &payload.len())
                .finish(),
            Self::E2eeDeliverReports { cmd, payload } => f
                .debug_struct("E2eeDeliverReports")
                .field("cmd", cmd)
                .field("payload_keys", &payload.len())
                .finish(),
            Self::E2eeConnected { uid } => f
                .debug_struct("E2eeConnected")
                .field("has_uid", &!uid.is_empty())
                .finish(),
            Self::E2eeDisconnected => f.write_str("E2eeDisconnected"),
            Self::VoipControl { act, data, .. } => f
                .debug_struct("VoipControl")
                .field("act", act)
                .field("data_keys", &data.len())
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
            Self::Mute { set, duration, .. } => f
                .debug_struct("Mute")
                .field("set", set)
                .field("duration", duration)
                .finish(),
        }
    }
}

/// Every side effect `reduce` can request.
#[derive(Clone)]
pub enum Effect {
    /// Aborts any in-flight QR / boot network tasks.
    CancelSessionTasks,
    /// Loads and restores the saved session via `Host::load_saved_session` + `SessionClient::restore`.
    LoadSavedSession { boot_gen: u64 },
    /// Reads the legacy cookie via `Host::load_legacy_cookie` and runs `complete_login` if present.
    LoadLegacyCookie { boot_gen: u64 },
    /// Validates the restored session against the server (`session_status_detailed`).
    CheckSessionStatus { boot_gen: u64 },
    /// Refreshes the signed-in user's profile (`sync_profile_me`).
    SyncProfileMe { boot_gen: u64 },
    /// Requests a fresh QR login ticket (`request_qr`).
    RequestQr { qr_gen: u64, language: String },
    /// Long-polls until the phone scans the QR code (rotations arrive as `Input::QrRotated`).
    WaitQrScan { qr_gen: u64, ticket: QrTicket },
    /// Long-polls until the phone confirms the login.
    WaitQrConfirm { qr_gen: u64, ticket: QrTicket },
    /// Finishes login (`getLoginInfo` + `syncProfileMe`).
    CompleteLogin { qr_gen: u64 },
    /// Clears the in-memory `SessionClient` credentials and domains before `HostCall::ClearSession`.
    ClearCoreSession,
    /// Marks `expired_at` on the in-memory `SessionClient` before `HostCall::MarkExpired`.
    MarkCoreSessionExpired,
    /// Writes a session-domain preference to the opened store (storage primitive, not in `hostTrace`).
    SetPref { key: String, value: String },

    // --- Transport domain (U2) ---
    /// Starts the core-owned WebSocket client and emits the serial `start_ws` replay trace marker.
    StartWs {
        ws_gen: u64,
        endpoints: Vec<String>,
        seed_cursors: CursorMap,
        my_uid: String,
        self_conv_id: Option<String>,
    },
    /// Stops the core-owned WebSocket client (optionally resetting cursors).
    StopWs { reset_cursors: bool },
    /// Records a `file_done` / `video_done` completion on the active WebSocket client.
    RecordFileDone { file_id: String, url: String },
    /// Arms the long-poll timer (`delay` = 4 s). When `initial` is true, also emits the serial
    /// `start_long_poll` replay trace marker on the host FIFO.
    StartLpTimer {
        lp_gen: u64,
        initial: bool,
        delay: Duration,
    },
    /// Cancels any active long-poll timer and in-flight poll HTTP request.
    StopLongPoll,
    /// Executes one `ZaloApi::fetch_chat_from_polling` request.
    FetchPollBatch {
        lp_gen: u64,
        drain_id: u64,
        poll_state: PollState,
    },
    /// Resolves a `drain_chat_polling` waiter with `total_events` (handled directly by the actor).
    CompleteDrain { drain_id: u64, total_events: u32 },
    /// Shape-only diagnostic log line routed via `tracing` (`olaz_core::engine_log`).
    EngineLog(String),

    // --- Conversations & conversation actions domain (U3) ---
    /// Serial SQLite persistence operation executed on the runner's store worker.
    Store(StoreOp),
    /// Drains queued `StoreOp`s and detaches the shared SQLite handle (before logout/reset).
    DetachStore,
    /// Resolves a request-reply waiter on the actor (if `after_store`, waits for prior store ops).
    CompleteOp {
        op_id: u64,
        result: OpResult,
        after_store: bool,
    },
    /// Calls `ZaloApi::update_pinned_conversation`.
    UpdatePinnedConversationApi {
        id: String,
        pinned: bool,
        op_id: Option<u64>,
    },
    /// Calls `ZaloApi::update_pinned_conversation` as one step of `pin_replacing`.
    PinReplacingApi {
        op_id: Option<u64>,
        target_id: String,
        pinned: bool,
        unpin_remaining: Vec<String>,
        pin_id: String,
    },
    /// Calls `ZaloApi::update_archived_chat`.
    UpdateArchivedChatApi {
        id: String,
        archived: bool,
        op_id: Option<u64>,
    },
    /// Calls `ZaloApi::delete_conversation` (best-effort, completes via `DeleteApiDone`).
    DeleteConversationApi {
        id: String,
        last_cli_msg_id: String,
        op_id: Option<u64>,
    },
    /// Calls `ZaloApi::set_unread_mark` (best-effort fire-and-forget).
    SetUnreadMarkApi { conv_id: String, unread: bool },
    /// Calls `ZaloApi::send_seen` (best-effort fire-and-forget).
    SendSeenApi(SeenTarget),
    /// Calls `ZaloApi::set_hidden_conversation` (best-effort, optional op completion).
    SetHiddenConversationApi {
        conv_id: String,
        hidden: bool,
        op_id: Option<u64>,
        result: Option<ConversationActionResult>,
    },
    /// Calls `ZaloApi::update_hidden_pin` if authenticated and returns MD5/SHA256 digests.
    UpdateHiddenPinApi {
        pin: String,
        kind: HiddenPinSyncKind,
        op_id: Option<u64>,
    },
    /// Calls `ZaloApi::reset_hidden_pin` if authenticated.
    ResetHiddenPinApi { op_id: Option<u64> },
    /// Calls `ZaloApi::fetch_hidden_conversations` if authenticated.
    FetchHiddenConversationsApi { op_id: Option<u64> },
    /// Calls `ZaloApi::fetch_profiles` for one chunk of up to 50 missing-name UIDs.
    FetchProfilesChunkApi {
        op_id: Option<u64>,
        chunk: Vec<String>,
        remaining_chunks: Vec<Vec<String>>,
        profiles_cache_changed: bool,
    },
    /// Calls `ZaloApi::update_conversation_labels` (best-effort).
    UpdateConversationLabelsApi {
        label_data_json: String,
        op_id: Option<u64>,
    },
    /// Calls `ZaloApi::fetch_conversation_labels`.
    FetchConversationLabelsApi { op_id: Option<u64> },

    /// Domain activity delegated to Swift via `CoreHost`.
    Host(HostCall),
}

impl fmt::Debug for Effect {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::CancelSessionTasks => f.write_str("CancelSessionTasks"),
            Self::LoadSavedSession { boot_gen } => f
                .debug_struct("LoadSavedSession")
                .field("boot_gen", boot_gen)
                .finish(),
            Self::LoadLegacyCookie { boot_gen } => f
                .debug_struct("LoadLegacyCookie")
                .field("boot_gen", boot_gen)
                .finish(),
            Self::CheckSessionStatus { boot_gen } => f
                .debug_struct("CheckSessionStatus")
                .field("boot_gen", boot_gen)
                .finish(),
            Self::SyncProfileMe { boot_gen } => f
                .debug_struct("SyncProfileMe")
                .field("boot_gen", boot_gen)
                .finish(),
            Self::RequestQr { qr_gen, language } => f
                .debug_struct("RequestQr")
                .field("qr_gen", qr_gen)
                .field("language", language)
                .finish(),
            Self::WaitQrScan { qr_gen, .. } => f
                .debug_struct("WaitQrScan")
                .field("qr_gen", qr_gen)
                .finish(),
            Self::WaitQrConfirm { qr_gen, .. } => f
                .debug_struct("WaitQrConfirm")
                .field("qr_gen", qr_gen)
                .finish(),
            Self::CompleteLogin { qr_gen } => f
                .debug_struct("CompleteLogin")
                .field("qr_gen", qr_gen)
                .finish(),
            Self::ClearCoreSession => f.write_str("ClearCoreSession"),
            Self::MarkCoreSessionExpired => f.write_str("MarkCoreSessionExpired"),
            Self::SetPref { key, .. } => f.debug_struct("SetPref").field("key", key).finish(),
            Self::StartWs {
                ws_gen,
                endpoints,
                seed_cursors,
                ..
            } => f
                .debug_struct("StartWs")
                .field("ws_gen", ws_gen)
                .field("endpoints_count", &endpoints.len())
                .field("seed_cursors_count", &seed_cursors.len())
                .finish(),
            Self::StopWs { reset_cursors } => f
                .debug_struct("StopWs")
                .field("reset_cursors", reset_cursors)
                .finish(),
            Self::RecordFileDone { .. } => f.write_str("RecordFileDone"),
            Self::StartLpTimer {
                lp_gen,
                initial,
                delay,
            } => f
                .debug_struct("StartLpTimer")
                .field("lp_gen", lp_gen)
                .field("initial", initial)
                .field("delay_ms", &delay.as_millis())
                .finish(),
            Self::StopLongPoll => f.write_str("StopLongPoll"),
            Self::FetchPollBatch {
                lp_gen, drain_id, ..
            } => f
                .debug_struct("FetchPollBatch")
                .field("lp_gen", lp_gen)
                .field("drain_id", drain_id)
                .finish(),
            Self::CompleteDrain {
                drain_id,
                total_events,
            } => f
                .debug_struct("CompleteDrain")
                .field("drain_id", drain_id)
                .field("total_events", total_events)
                .finish(),
            Self::EngineLog(_) => f.write_str("EngineLog"),
            Self::Store(op) => f.debug_tuple("Store").field(op).finish(),
            Self::DetachStore => f.write_str("DetachStore"),
            Self::CompleteOp {
                op_id,
                result,
                after_store,
            } => f
                .debug_struct("CompleteOp")
                .field("op_id", op_id)
                .field("result", result)
                .field("after_store", after_store)
                .finish(),
            Self::UpdatePinnedConversationApi { pinned, .. } => f
                .debug_struct("UpdatePinnedConversationApi")
                .field("pinned", pinned)
                .finish(),
            Self::PinReplacingApi {
                pinned,
                unpin_remaining,
                ..
            } => f
                .debug_struct("PinReplacingApi")
                .field("pinned", pinned)
                .field("remaining", &unpin_remaining.len())
                .finish(),
            Self::UpdateArchivedChatApi { archived, .. } => f
                .debug_struct("UpdateArchivedChatApi")
                .field("archived", archived)
                .finish(),
            Self::DeleteConversationApi { .. } => f.write_str("DeleteConversationApi"),
            Self::SetUnreadMarkApi { unread, .. } => f
                .debug_struct("SetUnreadMarkApi")
                .field("unread", unread)
                .finish(),
            Self::SendSeenApi(t) => f.debug_tuple("SendSeenApi").field(t).finish(),
            Self::SetHiddenConversationApi { hidden, .. } => f
                .debug_struct("SetHiddenConversationApi")
                .field("hidden", hidden)
                .finish(),
            Self::UpdateHiddenPinApi { kind, .. } => f
                .debug_struct("UpdateHiddenPinApi")
                .field("kind", kind)
                .finish(),
            Self::ResetHiddenPinApi { .. } => f.write_str("ResetHiddenPinApi"),
            Self::FetchHiddenConversationsApi { .. } => f.write_str("FetchHiddenConversationsApi"),
            Self::FetchProfilesChunkApi {
                chunk,
                remaining_chunks,
                ..
            } => f
                .debug_struct("FetchProfilesChunkApi")
                .field("chunk_len", &chunk.len())
                .field("remaining_chunks", &remaining_chunks.len())
                .finish(),
            Self::UpdateConversationLabelsApi { .. } => f.write_str("UpdateConversationLabelsApi"),
            Self::FetchConversationLabelsApi { .. } => f.write_str("FetchConversationLabelsApi"),
            Self::Host(call) => f.debug_tuple("Host").field(call).finish(),
        }
    }
}
