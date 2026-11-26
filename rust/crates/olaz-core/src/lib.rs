//! Pure core state machine and single-actor runtime for Olaz (`olaz-core`).
//!
//! Architecture (see `rust-core-plan` D1/D9 and ADR-016):
//! - State lives in [`state::CoreState`] inside a single tokio actor ([`actor::CoreHandle`]).
//! - Every transition runs through the pure [`reduce::reduce`] function (no I/O, no clock).
//! - Effects execute asynchronously via [`runner::EffectRunner`]; host calls run serially in
//!   emitted order while network calls may run concurrently as cancellable tasks.
//! - Consumers pull coalesced state snapshots via [`changes::ChangeHub::next_changes`].

pub mod actions;
pub mod actor;
pub mod changes;
pub mod conversations;
pub mod effect;
pub mod input;
pub mod messages;
// U12
pub mod polls;
pub mod reduce;
pub mod runner;
pub mod state;
pub mod typed_chat;
pub mod typing;

// U6
pub use actions::{
    AUTO_DELETE_FAILED_CARD_TEXT, ActionsState, AutoDeleteSystemNotice, DELETE_UNDO_DURATION,
    DELETE_UNDO_DURATION_MS, DeleteUndoItem, DeleteUndoSnapshot, DeleteUndoState,
    MessageConfirmAction, MessageConfirmState, PENDING_LOCAL_REACTION_TTL_MS,
    PREF_SEEN_REACTION_EVENT_IDS, PREF_STARRED_IDS, PendingLocalReaction, PendingLocalReactions,
    RECALL_OVER_24H_CARD_TEXT, RECALL_WINDOW_MS, REMOTE_DELETE_MATCH_POLICY,
    RESTORE_SUCCESS_CARD_TEXT, ReactFailure, ReactionMutation, RecallFailure,
    RemoteDeleteMatchPolicy, SEEN_REACTION_CAP, SeenReactionKeys, auto_delete_system_notice,
    dedupe_conv_id, find_server_msg_id, is_over_recall_window, local_reaction_seen_keys,
    mutate_reactions, reaction_dedupe_keys, recall_error_card_text, recall_error_log_line,
    remote_delete_matches, remote_delete_store_ids, swift_error_type_name,
};
pub use actor::{ActorSink, CoreHandle};
pub use changes::{
    ChangeHub, CoreChanges, DirtyKey, DirtySet, MessageMetaSnapshot, snapshot_message_meta,
};
pub use conversations::{
    BatchApplyDelta, CachedGroup, CachedProfile, ConvMessageDelta, ConvPreviewOverride,
    ConversationActionResult, ConversationActionUI, ConversationActionsState, ConversationExtras,
    ConversationLabel, ConversationLeaveType, ConversationPreview, ConversationPrompt,
    ConversationRemoval, ConversationSummary, ConversationToast, ConversationsState,
    FriendIdentity, GroupIdentity, IdentityTable, LocalAccountHydration, MessagePreviewInput,
    PinBoard, StrangerBox, ToastKind, message_preview_label, to_wire_stored,
};
pub use effect::{
    Effect, HistoryFetchPurpose, HostCall, OpResult, PollBoardContinuation, PollDetailPurpose,
    StoreOp,
};
pub use input::{
    BootstrapAliasesError, Command, CompletedLogin, E2eeQuoteArg, HiddenPinSyncKind, Input,
    LegacyCookie, PollBatchError, PollBatchOutcome, SeenTarget, SessionFailure, StoreToken,
};
pub use messages::{
    BatchPass1Outcome, BlockedUserState, BootstrapFlowState, ContactNotice, ContactSearchState,
    ContactSearchStatus, ContactsState, DeleteWindowOutcome, FULL_HISTORY_REFRESH_INTERVAL_SECS,
    FULL_HISTORY_REFRESH_PREF_KEY, FoundUserEntry, FriendEntry, FriendRequestEntry, GroupEntry,
    HistoryFreshness, HistoryPagePass1Outcome, IdentitySnapshot, LoadOlderFlowState, MessagesState,
    MuteEntry, OpenFlowState, PendingWindowOp, RecallWindowOutcome, SaveAliasOutcome,
    SenderResolveFollowup, WindowChange, WindowDelta, apply_batch_pass1, apply_fetched_contacts,
    coalesce_window_op, collect_missing_sender_uids, contact_fold, decode_db_stored,
    fold_contact_str, format_swift_double, is_valid_url_str, localized_standard_cmp,
    newest_message_ids, numeric_msg_cursor, parse_batch_events, preferred_contact_name,
    serialize_cached_groups_json, serialize_cached_profiles_json, to_db_stored,
};
// U12
pub use polls::{
    AddedPollOption, BoardPinItem, BoardPinList, BoardRawTopics, MAX_SEEN_POLL_MESSAGES,
    MAX_WATCHED_POLLS, MergedGroupMetadataPersistence, POLL_DEBOUNCE_DELAY_MS,
    POLL_MESSAGE_MAX_AGE_MS, PollAction, PollActionResult, PollCapabilities, PollClock, PollConfig,
    PollCreateDraft, PollCreateIssue, PollDetail, PollMessageNotice, PollOption, PollPinConfirm,
    PollPinOutcome, PollPinState, PollVoteDraft, PollVoterGroup, PollVoterUser, PollVoters,
    PollsState, UNKNOWN_POLL_USER_NAME, WATCH_POLL_THROTTLE_MS, build_pin_limit_confirm,
    build_poll_voters, clamped_int64, is_group_admin_or_creator, map_create_poll_net_error,
    map_poll_pin_net_error, map_poll_pin_session_error, merge_fetched_group_metadata,
    normalize_poll_detail, normalize_poll_uid, refresh_poll_pin_state, resolve_poll_group_id,
};
pub use reduce::classify::{MobileSyncEvent, Route, classify, classify_poll};
pub use reduce::contacts::apply_contacts_adapter_state;
pub use reduce::polls::{DEFAULT_BOARD_PIN_LIMIT, apply_pins_state_event};
pub use reduce::send::SendState;
pub use reduce::{ReduceOutput, reduce};
pub use runner::{
    EffectRunner, Host, LiveWsDriver, SessionEffectRunner, SharedStoreSlot, WsDriver, WsStartParams,
};
pub use state::{
    CoreFailKind, CoreSnapshot, CoreState, FailReason, LoginState, LoginStep,
    PersistedTransportState, Phase, Profile, SessionSnapshot, SessionState, TransportState,
    WsPhase,
};
pub use typed_chat::{
    ParseState, PlainChatParse, SharedParse, TypedChatEnvelope, WirePayloadHandle,
    new_shared_parse, try_parse_plain_chat,
};
pub use typing::{
    DEFAULT_TYPING_NAME, OUTGOING_TYPING_THROTTLE_MS, TYPING_DISPLAY_DURATION, TypingState,
    TypingStatus, clear_typing, set_typing,
};
