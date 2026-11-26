//! Side effects returned by `reduce` and executed by [`crate::runner::EffectRunner`].

use std::collections::BTreeMap;
use std::fmt;
use std::time::Duration;

use olaz_api::{
    CreateReminderParams, PollState, SendContactCardParams, SendStickerParams, SendTextParams,
};
use olaz_net::{LoginAccount, QrTicket};
use olaz_store::{StoredConversation, StoredMessage};
use olaz_wire::ChatMessage;
use olaz_ws::CursorMap;
use serde_json::{Map, Value};

use crate::actions::DeleteUndoItem;
use crate::composer::{ComposerOutcome, MyCardInfo, ReminderComposeInfo};
use crate::conversations::{
    ConversationActionResult, ConversationPreview, IdentityTable, PinBoard,
};
use crate::input::{E2eeQuoteArg, HiddenPinSyncKind, SeenTarget, StoreToken};
use crate::messages::{IdentitySnapshot, MuteEntry};
use crate::reduce::classify::MobileSyncEvent;
use crate::stickers::{CardActionOutcome, StickerEntry, StickerSuggestSetting, StickerTab};
use crate::typed_chat::TypedChatEnvelope;

/// Distinguishes which history-paging flow requested [`Effect::FetchHistoryPageApi`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HistoryFetchPurpose {
    Open { open_seq: u64, op_id: Option<u64> },
    LoadOlder { load_seq: u64, op_id: Option<u64> },
}

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
    SetConversationPreview {
        id: String,
        preview_text: String,
        preview_ts_ms: i64,
        preview_from_me: bool,
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
    SetPreferenceBool {
        key: String,
        value: bool,
    },
    SaveRecentSticker {
        sticker: StickerEntry,
    },
    DeletePreference {
        key: String,
    },
    LoadMentionPreviewMessages {
        op_id: Option<u64>,
        group_ids: Vec<String>,
        my_uid: String,
    },

    // --- Launch bootstrap & freshness persistence (U4-bootstrap) ---
    LoadPreferenceString {
        key: String,
        boot_gen: u64,
    },
    ProbeAndSaveMessages {
        probe_targets: BTreeMap<String, String>,
        rows: Vec<StoredMessage>,
        preserve_existing_reactions: bool,
        reply_boot_gen: Option<u64>,
    },
    SaveMessages {
        rows: Vec<StoredMessage>,
        preserve_existing_reactions: bool,
    },
    LoadOpenLocalMessages {
        open_seq: u64,
        conv_id: String,
        limit: usize,
        op_id: Option<u64>,
    },
    LoadOlderStoreMessages {
        load_seq: u64,
        conv_id: String,
        before_ts_ms: i64,
        limit: usize,
        op_id: Option<u64>,
    },
    // U6
    DeleteMessage {
        conv_id: String,
        id: String,
    },
    ApplyRemoteReactionInStore {
        conv_candidates: Vec<String>,
        msg_id: String,
        cli_msg_id: String,
        actor_uid: String,
        my_uid: String,
        is_me: bool,
        r_type: String,
        r_icon: String,
        allow_duplicate_same_user: bool,
        snap: Box<IdentitySnapshot>,
    },
    MarkRecalledAndCheckLatest {
        conv_id: String,
        target_id: String,
        cli_msg_id: String,
        found_in_memory: bool,
        recalled_last: Option<(i64, bool)>,
        update_conversation_preview: bool,
        persist_conversations: bool,
        op_id: Option<u64>,
        recall_many_id: Option<u64>,
    },
    DeleteMessageAndCheckLatest {
        conv_id: String,
        msg_id: String,
        cli_msg_id: String,
        deleted_ts_ms: Option<i64>,
        mem_latest: Option<ConversationPreview>,
        update_conversation_preview: bool,
        persist_conversations: bool,
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
            Self::SetConversationPreview {
                preview_text,
                preview_ts_ms,
                preview_from_me,
                ..
            } => f
                .debug_struct("SetConversationPreview")
                .field("text_len", &preview_text.len())
                .field("preview_ts_ms", preview_ts_ms)
                .field("preview_from_me", preview_from_me)
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
            Self::SetPreferenceBool { key, value } => f
                .debug_struct("SetPreferenceBool")
                .field("key", key)
                .field("value", value)
                .finish(),
            Self::SaveRecentSticker { sticker } => f
                .debug_struct("SaveRecentSticker")
                .field("sticker", sticker)
                .finish(),
            Self::DeletePreference { key } => f
                .debug_struct("DeletePreference")
                .field("key", key)
                .finish(),
            Self::LoadMentionPreviewMessages { group_ids, .. } => f
                .debug_struct("LoadMentionPreviewMessages")
                .field("group_count", &group_ids.len())
                .finish(),
            // U4-bootstrap
            Self::LoadPreferenceString { key, boot_gen } => f
                .debug_struct("LoadPreferenceString")
                .field("key", key)
                .field("boot_gen", boot_gen)
                .finish(),
            Self::ProbeAndSaveMessages {
                probe_targets,
                rows,
                preserve_existing_reactions,
                reply_boot_gen,
            } => f
                .debug_struct("ProbeAndSaveMessages")
                .field("probe_count", &probe_targets.len())
                .field("rows_count", &rows.len())
                .field("preserve_existing_reactions", preserve_existing_reactions)
                .field("reply_boot_gen", reply_boot_gen)
                .finish(),
            Self::SaveMessages {
                rows,
                preserve_existing_reactions,
            } => f
                .debug_struct("SaveMessages")
                .field("count", &rows.len())
                .field("preserve_reactions", preserve_existing_reactions)
                .finish(),
            Self::LoadOpenLocalMessages {
                open_seq, limit, ..
            } => f
                .debug_struct("LoadOpenLocalMessages")
                .field("open_seq", open_seq)
                .field("limit", limit)
                .finish(),
            Self::LoadOlderStoreMessages {
                load_seq,
                before_ts_ms,
                limit,
                ..
            } => f
                .debug_struct("LoadOlderStoreMessages")
                .field("load_seq", load_seq)
                .field("before_ts_ms", before_ts_ms)
                .field("limit", limit)
                .finish(),
            // U6
            Self::DeleteMessage { .. } => f.write_str("DeleteMessage"),
            Self::ApplyRemoteReactionInStore { r_type, .. } => f
                .debug_struct("ApplyRemoteReactionInStore")
                .field("r_type", r_type)
                .finish(),
            Self::MarkRecalledAndCheckLatest {
                found_in_memory,
                update_conversation_preview,
                persist_conversations,
                ..
            } => f
                .debug_struct("MarkRecalledAndCheckLatest")
                .field("found_in_memory", found_in_memory)
                .field("update_conversation_preview", update_conversation_preview)
                .field("persist_conversations", persist_conversations)
                .finish(),
            Self::DeleteMessageAndCheckLatest {
                update_conversation_preview,
                persist_conversations,
                ..
            } => f
                .debug_struct("DeleteMessageAndCheckLatest")
                .field("update_conversation_preview", update_conversation_preview)
                .field("persist_conversations", persist_conversations)
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
    Int(i64),
    OptI64(Option<i64>),
    // U13
    StickerTabs(Option<Vec<StickerTab>>),
    StickerEntries(Option<Vec<StickerEntry>>),
    StickerSuggestSetting(Option<StickerSuggestSetting>),
    CardActionOutcome(CardActionOutcome),
    ComposerOutcome(ComposerOutcome),
    MyCard(Option<MyCardInfo>),
    ReminderComposeInfo(Option<ReminderComposeInfo>),
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
            Self::Int(n) => f.debug_tuple("Int").field(n).finish(),
            Self::OptI64(n) => f.debug_tuple("OptI64").field(n).finish(),
            // U13
            Self::StickerTabs(v) => f
                .debug_struct("StickerTabs")
                .field("count", &v.as_ref().map(Vec::len))
                .finish(),
            Self::StickerEntries(v) => f
                .debug_struct("StickerEntries")
                .field("count", &v.as_ref().map(Vec::len))
                .finish(),
            Self::StickerSuggestSetting(s) => {
                f.debug_tuple("StickerSuggestSetting").field(s).finish()
            }
            Self::CardActionOutcome(o) => f.debug_tuple("CardActionOutcome").field(o).finish(),
            Self::ComposerOutcome(o) => f.debug_tuple("ComposerOutcome").field(o).finish(),
            Self::MyCard(c) => f.debug_tuple("MyCard").field(c).finish(),
            Self::ReminderComposeInfo(r) => f.debug_tuple("ReminderComposeInfo").field(r).finish(),
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

    // --- Launch bootstrap host calls (U4-bootstrap) ---
    ApplyMutes {
        mutes: Vec<MuteEntry>,
    },
    RefreshCloud,
    OnOpenConversationSync {
        conv_id: String,
        changed: bool,
    },
    OnCloseConversation,
    RefreshBoardPins {
        conv_id: String,
    },
    MarkReadBoundary {
        conv_id: String,
        seen_target: Option<SeenTarget>,
    },
    ApplyRemoteReaction {
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
    ApplyRemoteRecall {
        conv_id: String,
        msg_id: String,
        cli_msg_id: String,
        update_conversation_preview: bool,
        persist_conversations: bool,
        op_id: Option<u64>,
        recall_many_id: Option<u64>,
    },
    ApplyRemoteDelete {
        conv_id: String,
        msg_id: String,
        cli_msg_id: String,
        update_conversation_preview: bool,
        persist_conversations: bool,
    },
    DecryptEnvelope {
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
    MarkE2eeConversations {
        conv_ids: Vec<String>,
    },
    NotePollMessages {
        messages: Vec<ChatMessage>,
    },
    NotifyIncomingMessages {
        messages: Vec<ChatMessage>,
    },
    ShowBatchTyping {
        conv_id: String,
        sender_id: String,
    },
    /// Fires after a transport-originated batch/parsed-events ingestion and all Pass 2 host jobs complete.
    TransportBatchSettled,
    // U5-send
    SendE2eeText {
        send_id: u64,
        conv_id: String,
        text: String,
        client_id: String,
        quote: Option<E2eeQuoteArg>,
    },
    // U6
    ShowCard {
        conv_id: String,
        text: String,
    },
    // U13
    SendE2eeSticker {
        send_id: u64,
        conv_id: String,
        cate_id: i64,
        sticker_id: i64,
        client_id: String,
    },
    SendE2eeContactCard {
        card_send_id: u64,
        conv_id: String,
        client_id: String,
        contact_uid: String,
        title: String,
        phone: String,
        avatar: String,
        qr_code_url: String,
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
            // U4-bootstrap
            Self::ApplyMutes { mutes } => f
                .debug_struct("ApplyMutes")
                .field("count", &mutes.len())
                .finish(),
            Self::RefreshCloud => f.write_str("RefreshCloud"),
            Self::OnOpenConversationSync { changed, .. } => f
                .debug_struct("OnOpenConversationSync")
                .field("changed", changed)
                .finish(),
            Self::OnCloseConversation => f.write_str("OnCloseConversation"),
            Self::RefreshBoardPins { .. } => f.write_str("RefreshBoardPins"),
            Self::MarkReadBoundary { seen_target, .. } => f
                .debug_struct("MarkReadBoundary")
                .field("has_seen", &seen_target.is_some())
                .finish(),
            Self::ApplyRemoteReaction { r_type, .. } => f
                .debug_struct("ApplyRemoteReaction")
                .field("r_type", r_type)
                .finish(),
            Self::ApplyRemoteRecall { .. } => f.write_str("ApplyRemoteRecall"),
            Self::ApplyRemoteDelete { .. } => f.write_str("ApplyRemoteDelete"),
            Self::DecryptEnvelope { default_cmd, .. } => f
                .debug_struct("DecryptEnvelope")
                .field("default_cmd", default_cmd)
                .finish(),
            Self::MarkE2eeConversations { conv_ids } => f
                .debug_struct("MarkE2eeConversations")
                .field("count", &conv_ids.len())
                .finish(),
            Self::NotePollMessages { messages } => f
                .debug_struct("NotePollMessages")
                .field("count", &messages.len())
                .finish(),
            Self::NotifyIncomingMessages { messages } => f
                .debug_struct("NotifyIncomingMessages")
                .field("count", &messages.len())
                .finish(),
            Self::ShowBatchTyping { .. } => f.write_str("ShowBatchTyping"),
            Self::TransportBatchSettled => f.write_str("TransportBatchSettled"),
            // U5-send
            Self::SendE2eeText { send_id, quote, .. } => f
                .debug_struct("SendE2eeText")
                .field("send_id", send_id)
                .field("has_quote", &quote.is_some())
                .finish(),
            // U6
            Self::ShowCard { text, .. } => f
                .debug_struct("ShowCard")
                .field("text_len", &text.len())
                .finish(),
            // U13
            Self::SendE2eeSticker {
                send_id,
                cate_id,
                sticker_id,
                ..
            } => f
                .debug_struct("SendE2eeSticker")
                .field("send_id", send_id)
                .field("cate_id", cate_id)
                .field("sticker_id", sticker_id)
                .finish(),
            Self::SendE2eeContactCard { card_send_id, .. } => f
                .debug_struct("SendE2eeContactCard")
                .field("card_send_id", card_send_id)
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
    LoadSavedSession {
        boot_gen: u64,
    },
    /// Reads the legacy cookie via `Host::load_legacy_cookie` and runs `complete_login` if present.
    LoadLegacyCookie {
        boot_gen: u64,
    },
    /// Validates the restored session against the server (`session_status_detailed`).
    CheckSessionStatus {
        boot_gen: u64,
    },
    /// Refreshes the signed-in user's profile (`sync_profile_me`).
    SyncProfileMe {
        boot_gen: u64,
    },
    /// Requests a fresh QR login ticket (`request_qr`).
    RequestQr {
        qr_gen: u64,
        language: String,
    },
    /// Long-polls until the phone scans the QR code (rotations arrive as `Input::QrRotated`).
    WaitQrScan {
        qr_gen: u64,
        ticket: QrTicket,
    },
    /// Long-polls until the phone confirms the login.
    WaitQrConfirm {
        qr_gen: u64,
        ticket: QrTicket,
    },
    /// Finishes login (`getLoginInfo` + `syncProfileMe`).
    CompleteLogin {
        qr_gen: u64,
    },
    /// Clears the in-memory `SessionClient` credentials and domains before `HostCall::ClearSession`.
    ClearCoreSession,
    /// Marks `expired_at` on the in-memory `SessionClient` before `HostCall::MarkExpired`.
    MarkCoreSessionExpired,
    /// Writes a session-domain preference to the opened store (storage primitive, not in `hostTrace`).
    SetPref {
        key: String,
        value: String,
    },

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
    StopWs {
        reset_cursors: bool,
    },
    /// Records a `file_done` / `video_done` completion on the active WebSocket client.
    RecordFileDone {
        file_id: String,
        url: String,
    },
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
    CompleteDrain {
        drain_id: u64,
        total_events: u32,
    },
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
    SetUnreadMarkApi {
        conv_id: String,
        unread: bool,
    },
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
    ResetHiddenPinApi {
        op_id: Option<u64>,
    },
    /// Calls `ZaloApi::fetch_hidden_conversations` if authenticated.
    FetchHiddenConversationsApi {
        op_id: Option<u64>,
    },
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
    FetchConversationLabelsApi {
        op_id: Option<u64>,
    },

    // --- Launch bootstrap network effects (U4-bootstrap) ---
    /// Aborts any in-flight bootstrap HTTP tasks.
    CancelBootstrapTasks,
    /// Step 1: fetches `/api/alias/list` (distinguishes auth vs other errors).
    BootstrapFetchAliasesApi {
        boot_gen: u64,
    },
    /// Step 3: concurrently fetches pinned conversations, archived chats, and mute list.
    BootstrapFetchPamApi {
        boot_gen: u64,
    },
    /// Step 4a: fetches `/api/convlabel/get`.
    BootstrapFetchLabelsApi {
        boot_gen: u64,
    },
    /// Step 4b: fetches hidden conversations snapshot.
    BootstrapFetchHiddenApi {
        boot_gen: u64,
    },
    /// Step 4c: concurrently fetches friends, groups list, sent requests, and received requests.
    BootstrapFetchContactsApi {
        boot_gen: u64,
    },
    /// Step 5: fetches `/api/preloadconvers/get-last-msgs` (overview or 25-ID chunk).
    BootstrapFetchPreloadApi {
        boot_gen: u64,
        thread_ids: Vec<String>,
        is_overview: bool,
    },
    /// Step 6: fetches recent history for self-cloud (`is_old = Some(false)`).
    BootstrapFetchHistoryApi {
        boot_gen: u64,
        conv_id: String,
        count: i64,
    },
    /// Step 7: fetches one wave of up to 6 group histories concurrently, returning in `gids` order.
    BootstrapFetchGroupWaveApi {
        boot_gen: u64,
        gids: Vec<String>,
        count: i64,
    },
    /// Step 8: resolves one chunk of up to 50 missing-name UIDs during bootstrap finalize.
    BootstrapFetchProfilesChunkApi {
        boot_gen: u64,
        chunk: Vec<String>,
        remaining_chunks: Vec<Vec<String>>,
        profiles_cache_changed: bool,
    },

    /// Calls `ZaloApi::fetch_history` for `Open` or `LoadOlder`.
    FetchHistoryPageApi {
        conv_id: String,
        before_msg_id: Option<String>,
        count: i64,
        is_old: Option<bool>,
        purpose: HistoryFetchPurpose,
    },
    /// Calls `ZaloApi::fetch_profiles` for one chunk of up to 50 sender/reactor UIDs.
    FetchSenderProfilesChunkApi {
        resolve_id: u64,
        conv_id: String,
        chunk: Vec<String>,
        remaining_chunks: Vec<Vec<String>>,
        cache_updated: bool,
    },

    // U5
    /// Calls `ZaloApi::send_typing` when `SessionClient::is_authenticated()` is true.
    SendTypingApi {
        conv_id: String,
    },
    /// Starts or resets the incoming typing expiry timer for `conv_id`.
    StartTypingExpiry {
        conv_id: String,
        expiry_gen: u64,
        delay: Duration,
    },
    /// Cancels any active incoming typing expiry timer for `conv_id`.
    CancelTypingExpiry {
        conv_id: String,
    },
    // U5-send
    /// Calls `ZaloApi::send_text` for a plain-text send and returns [`Input::SendTextDone`].
    SendTextApi {
        send_id: u64,
        params: SendTextParams,
    },

    // U6
    /// Resolves server `msg_id` and `cli_msg_id` via SQLite + `fetch_history(count=30)`.
    ResolveMessageIds {
        resolve_id: u64,
        conv_id: String,
        msg_id: String,
        cli_msg_id: String,
    },
    /// Calls `ZaloApi::send_reaction` (with non-auth `msg_type != 1` retry) and reports `Input::ReactDone`.
    SendReactionApi {
        react_id: u64,
        conv_id: String,
        msg_id: String,
        cli_msg_id: String,
        r_icon: String,
        r_type: i64,
        msg_type: i64,
    },
    /// Calls `ZaloApi::recall_message` (with `code == 112` alt-route retry) and reports `Input::RecallDone`.
    RecallMessageApi {
        recall_id: u64,
        conv_id: String,
        msg_id: String,
        cli_msg_id: String,
        primary_is_e2ee: bool,
        can_try_alt: bool,
    },
    /// Arms the 5 s delete-for-me undo expiry timer.
    StartDeleteUndoExpiry {
        undo_gen: u64,
        delay: Duration,
    },
    /// Cancels any active delete-for-me undo expiry timer.
    CancelDeleteUndoExpiry,
    /// Commits a delete-for-me batch (`delete_message_for_me` API + SQLite delete per item).
    CommitDeleteBatch {
        items: Vec<DeleteUndoItem>,
    },
    /// Calls `ZaloApi::fetch_auto_delete` and reports `Input::AutoDeleteLoaded`.
    FetchAutoDeleteApi {
        op_id: Option<u64>,
    },
    /// Calls `ZaloApi::update_auto_delete` and reports `Input::AutoDeleteUpdated`.
    UpdateAutoDeleteApi {
        conv_id: String,
        ttl: i64,
        now_ms: i64,
        op_id: Option<u64>,
    },

    // U13
    FetchStickerCategories {
        op_id: Option<u64>,
    },
    LoadRecentStickersForTabs {
        op_id: Option<u64>,
    },
    LoadRecentStickers {
        op_id: Option<u64>,
    },
    FetchStickerCategoryDetail {
        op_id: Option<u64>,
        cate_id: i64,
    },
    SearchStickersApi {
        op_id: Option<u64>,
        keyword: String,
        limit: i64,
    },
    SuggestStickersApi {
        op_id: Option<u64>,
        keyword: String,
    },
    SendStickerApi {
        send_id: u64,
        params: SendStickerParams,
    },
    LoadStickerSuggestPref {
        op_id: Option<u64>,
    },
    SendContactCardApi {
        card_send_id: u64,
        params: SendContactCardParams,
    },
    CreateReminderApi {
        op_id: Option<u64>,
        params: CreateReminderParams,
    },
    StartConfirmPromoteDelay {
        confirm_gen: u64,
        delay: Duration,
    },
    CancelConfirmPromoteDelay,

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
            // U4-bootstrap
            Self::CancelBootstrapTasks => f.write_str("CancelBootstrapTasks"),
            Self::BootstrapFetchAliasesApi { boot_gen } => f
                .debug_struct("BootstrapFetchAliasesApi")
                .field("boot_gen", boot_gen)
                .finish(),
            Self::BootstrapFetchPamApi { boot_gen } => f
                .debug_struct("BootstrapFetchPamApi")
                .field("boot_gen", boot_gen)
                .finish(),
            Self::BootstrapFetchLabelsApi { boot_gen } => f
                .debug_struct("BootstrapFetchLabelsApi")
                .field("boot_gen", boot_gen)
                .finish(),
            Self::BootstrapFetchHiddenApi { boot_gen } => f
                .debug_struct("BootstrapFetchHiddenApi")
                .field("boot_gen", boot_gen)
                .finish(),
            Self::BootstrapFetchContactsApi { boot_gen } => f
                .debug_struct("BootstrapFetchContactsApi")
                .field("boot_gen", boot_gen)
                .finish(),
            Self::BootstrapFetchPreloadApi {
                boot_gen,
                thread_ids,
                is_overview,
            } => f
                .debug_struct("BootstrapFetchPreloadApi")
                .field("boot_gen", boot_gen)
                .field("thread_count", &thread_ids.len())
                .field("is_overview", is_overview)
                .finish(),
            Self::BootstrapFetchHistoryApi {
                boot_gen, count, ..
            } => f
                .debug_struct("BootstrapFetchHistoryApi")
                .field("boot_gen", boot_gen)
                .field("count", count)
                .finish(),
            Self::BootstrapFetchGroupWaveApi {
                boot_gen,
                gids,
                count,
            } => f
                .debug_struct("BootstrapFetchGroupWaveApi")
                .field("boot_gen", boot_gen)
                .field("gids_count", &gids.len())
                .field("count", count)
                .finish(),
            Self::BootstrapFetchProfilesChunkApi {
                boot_gen,
                chunk,
                remaining_chunks,
                ..
            } => f
                .debug_struct("BootstrapFetchProfilesChunkApi")
                .field("boot_gen", boot_gen)
                .field("chunk_len", &chunk.len())
                .field("remaining_chunks", &remaining_chunks.len())
                .finish(),
            Self::FetchHistoryPageApi { count, purpose, .. } => f
                .debug_struct("FetchHistoryPageApi")
                .field("count", count)
                .field("purpose", purpose)
                .finish(),
            Self::FetchSenderProfilesChunkApi {
                resolve_id,
                chunk,
                remaining_chunks,
                ..
            } => f
                .debug_struct("FetchSenderProfilesChunkApi")
                .field("resolve_id", resolve_id)
                .field("chunk_len", &chunk.len())
                .field("remaining", &remaining_chunks.len())
                .finish(),
            // U5
            Self::SendTypingApi { .. } => f.write_str("SendTypingApi"),
            Self::StartTypingExpiry {
                expiry_gen, delay, ..
            } => f
                .debug_struct("StartTypingExpiry")
                .field("expiry_gen", expiry_gen)
                .field("delay_ms", &delay.as_millis())
                .finish(),
            Self::CancelTypingExpiry { .. } => f.write_str("CancelTypingExpiry"),
            // U5-send
            Self::SendTextApi { send_id, params } => f
                .debug_struct("SendTextApi")
                .field("send_id", send_id)
                .field("params", params)
                .finish(),
            // U6
            Self::ResolveMessageIds { resolve_id, .. } => f
                .debug_struct("ResolveMessageIds")
                .field("resolve_id", resolve_id)
                .finish(),
            Self::SendReactionApi {
                react_id,
                r_type,
                msg_type,
                ..
            } => f
                .debug_struct("SendReactionApi")
                .field("react_id", react_id)
                .field("r_type", r_type)
                .field("msg_type", msg_type)
                .finish(),
            Self::RecallMessageApi {
                recall_id,
                primary_is_e2ee,
                can_try_alt,
                ..
            } => f
                .debug_struct("RecallMessageApi")
                .field("recall_id", recall_id)
                .field("primary_is_e2ee", primary_is_e2ee)
                .field("can_try_alt", can_try_alt)
                .finish(),
            Self::StartDeleteUndoExpiry { undo_gen, delay } => f
                .debug_struct("StartDeleteUndoExpiry")
                .field("undo_gen", undo_gen)
                .field("delay_ms", &delay.as_millis())
                .finish(),
            Self::CancelDeleteUndoExpiry => f.write_str("CancelDeleteUndoExpiry"),
            Self::CommitDeleteBatch { items } => f
                .debug_struct("CommitDeleteBatch")
                .field("count", &items.len())
                .finish(),
            Self::FetchAutoDeleteApi { op_id } => f
                .debug_struct("FetchAutoDeleteApi")
                .field("op_id", op_id)
                .finish(),
            Self::UpdateAutoDeleteApi {
                ttl, now_ms, op_id, ..
            } => f
                .debug_struct("UpdateAutoDeleteApi")
                .field("ttl", ttl)
                .field("now_ms", now_ms)
                .field("op_id", op_id)
                .finish(),
            // U13
            Self::FetchStickerCategories { op_id } => f
                .debug_struct("FetchStickerCategories")
                .field("op_id", op_id)
                .finish(),
            Self::LoadRecentStickersForTabs { op_id } => f
                .debug_struct("LoadRecentStickersForTabs")
                .field("op_id", op_id)
                .finish(),
            Self::LoadRecentStickers { op_id } => f
                .debug_struct("LoadRecentStickers")
                .field("op_id", op_id)
                .finish(),
            Self::FetchStickerCategoryDetail { op_id, cate_id } => f
                .debug_struct("FetchStickerCategoryDetail")
                .field("op_id", op_id)
                .field("cate_id", cate_id)
                .finish(),
            Self::SearchStickersApi { op_id, limit, .. } => f
                .debug_struct("SearchStickersApi")
                .field("op_id", op_id)
                .field("limit", limit)
                .finish(),
            Self::SuggestStickersApi { op_id, .. } => f
                .debug_struct("SuggestStickersApi")
                .field("op_id", op_id)
                .finish(),
            Self::SendStickerApi { send_id, params } => f
                .debug_struct("SendStickerApi")
                .field("send_id", send_id)
                .field("params", params)
                .finish(),
            Self::LoadStickerSuggestPref { op_id } => f
                .debug_struct("LoadStickerSuggestPref")
                .field("op_id", op_id)
                .finish(),
            Self::SendContactCardApi {
                card_send_id,
                params,
            } => f
                .debug_struct("SendContactCardApi")
                .field("card_send_id", card_send_id)
                .field("params", params)
                .finish(),
            Self::CreateReminderApi { op_id, params } => f
                .debug_struct("CreateReminderApi")
                .field("op_id", op_id)
                .field("params", params)
                .finish(),
            Self::StartConfirmPromoteDelay { confirm_gen, delay } => f
                .debug_struct("StartConfirmPromoteDelay")
                .field("confirm_gen", confirm_gen)
                .field("delay_ms", &delay.as_millis())
                .finish(),
            Self::CancelConfirmPromoteDelay => f.write_str("CancelConfirmPromoteDelay"),
            Self::Host(call) => f.debug_tuple("Host").field(call).finish(),
        }
    }
}
