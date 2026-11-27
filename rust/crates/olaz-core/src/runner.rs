//! Effect execution: [`EffectRunner`] trait, [`Host`] callback trait, [`WsDriver`] abstraction,
//! and the concrete [`SessionEffectRunner`] backed by `olaz_net::SessionClient`, `olaz_api::ZaloApi`,
//! and `olaz_ws::WsClient`.

use std::collections::{BTreeMap, BTreeSet};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use async_trait::async_trait;
use olaz_api::{PollState, ZaloApi};
use olaz_net::{
    LoginAccount, SessionClient, SessionSnapshot as NetSessionSnapshot, Transport, ZaloDomains,
};
use olaz_store::{CloudMediaQuery, SaveOptions, Store};
use olaz_wire::{ChatMessage, decode_stored_message, extract_profiles_map};
use olaz_ws::{CryptoDecryptor, CursorMap, WsClient, WsConfig, WsHandle};
use serde_json::{Map, Value};
use tokio::runtime::Handle;
use tokio::sync::{mpsc, oneshot};
use tokio::task::AbortHandle;

use crate::actions::swift_error_type_name;
use crate::actor::{ActorSink, InFlightGuard};
use crate::cloud::CloudServerSnapshot;
use crate::conversations::{
    BatchApplyDelta, IdentityTable, MessagePreviewInput, hidden_pin_md5, hidden_pin_sha256,
    load_local_account_from_store, to_wire_stored,
};
use crate::effect::{Effect, HistoryFetchPurpose, HostCall, OpResult, StoreOp};
use crate::forward::{ComposerSendOutcome, FileResolutionOutcome, MediaResolutionOutcome};
// U15
use crate::input::{
    BootstrapAliasesError, Command, CompletedLogin, E2eeQuoteArg, Input, LegacyCookie,
    PollBatchError, PollBatchOutcome, SeenTarget, SessionFailure, SharedMediaLoadOutcome,
    StickerSendError, StoreToken,
};
use crate::media::{
    FileFetchOutcome, FileLoadError, MediaCacheHit, MediaFetchOutcome, MediaKind, OutgoingFileMode,
    OutgoingFileProbe, SharedMediaKind, SharedMediaPage, UploadFileError, UploadedFileResult,
    UploadedPhotoResult, UploadedVideoResult, VideoMetadata,
};
use crate::messages::{MuteEntry, decode_db_stored};
use crate::reduce::classify::MobileSyncEvent;
use crate::state::PersistedTransportState;
use crate::stickers::{parse_recent_stickers_bytes, update_recent_stickers_json};
use crate::typed_chat::{
    PlainChatParse, TypedChatEnvelope, new_shared_parse, try_parse_plain_chat,
};

/// Executes effects produced by `reduce` and feeds completion [`Input`]s back via [`ActorSink`].
pub trait EffectRunner: Send + Sync {
    fn dispatch(&self, effects: Vec<Effect>, sink: ActorSink);
    fn shutdown(&self);
}

/// Parameters passed to [`WsDriver::start`] when the core brings up the WebSocket transport.
#[derive(Debug, Clone)]
pub struct WsStartParams {
    pub ws_gen: u64,
    pub endpoints: Vec<String>,
    pub zpw_sek: String,
    pub seed_cursors: CursorMap,
    pub my_uid: String,
    pub self_conv_id: Option<String>,
}

/// Abstraction over the WebSocket transport owned by [`SessionEffectRunner`].
///
/// Production uses [`LiveWsDriver`] (backed by `olaz_ws::WsClient`); tests plug in a scripted
/// driver backed by `olaz_ws::WsCore`.
#[async_trait]
pub trait WsDriver: Send + Sync {
    fn start(&self, params: WsStartParams, sink: ActorSink, runtime: &Handle);
    fn stop(&self, reset_cursors: bool);
    fn record_file_done(&self, file_id: String, url: String);
    async fn send_frame(&self, cmd: u16, sub_cmd: u8, payload_json: Option<Vec<u8>>) -> bool;
    async fn send_frame_versioned(
        &self,
        cmd: u16,
        sub_cmd: u8,
        version: u8,
        payload_json: Option<Vec<u8>>,
    ) -> bool;
    async fn send_request(
        &self,
        cmd: u16,
        sub_cmd: u8,
        version: u8,
        req_id: Option<String>,
        inner_data: Map<String, Value>,
        timeout: Duration,
    ) -> Option<Map<String, Value>>;
    async fn wait_for_file_done(&self, file_id: String, timeout: Duration) -> Option<String>;
    async fn is_authed(&self) -> bool;
    async fn current_cursors(&self) -> CursorMap;
    async fn seed_cursors(&self, cursors: CursorMap);
}

struct LiveWsSession {
    handle: WsHandle,
    pump_abort: AbortHandle,
    runtime: Handle,
}

/// Production [`WsDriver`] driving `olaz_ws::WsClient` directly.
///
/// Uses a single `biased;` pump per generation that delivers `WsEvent` / `WsTypedChat` strictly
/// before any `WsCursorsChanged` caused by the same frame.
#[derive(Default)]
pub struct LiveWsDriver {
    active: Mutex<Option<LiveWsSession>>,
}

impl LiveWsDriver {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    fn current_handle(&self) -> Option<WsHandle> {
        self.active
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .as_ref()
            .map(|s| s.handle.clone())
    }
}

#[async_trait]
impl WsDriver for LiveWsDriver {
    fn start(&self, params: WsStartParams, sink: ActorSink, runtime: &Handle) {
        let prev = self
            .active
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .take();
        if let Some(old) = prev {
            old.pump_abort.abort();
            old.runtime.spawn(async move {
                let _ = old.handle.stop(false).await;
            });
        }

        let mut config = WsConfig::new(params.endpoints, params.zpw_sek);
        config.seed_cursors = params.seed_cursors;

        // `WsClient::start` spawns its transport task on the current tokio runtime.
        let _entered = runtime.enter();
        let (handle, mut events) = WsClient::start(config, Arc::new(CryptoDecryptor));
        drop(_entered);

        let mut authed = handle.watch_authed();
        let mut cursors = handle.watch_cursors();
        let parse_state = new_shared_parse(params.my_uid, params.self_conv_id);
        let ws_gen = params.ws_gen;

        let pump_abort = runtime
            .spawn(async move {
                let mut authed_open = true;
                let mut cursors_open = true;
                loop {
                    tokio::select! {
                        biased;
                        res = authed.changed(), if authed_open => {
                            if res.is_ok() {
                                let now_authed = *authed.borrow_and_update();
                                sink.send(Input::WsAuthChanged {
                                    ws_gen,
                                    authed: now_authed,
                                });
                            } else {
                                authed_open = false;
                            }
                        }
                        ev = events.recv() => {
                            let Some(ev) = ev else {
                                break;
                            };
                            match try_parse_plain_chat(ev.cmd, &ev.payload, &parse_state) {
                                PlainChatParse::Empty => {}
                                PlainChatParse::Typed(envelope) => {
                                    sink.send(Input::WsTypedChat {
                                        ws_gen,
                                        cmd: ev.cmd,
                                        envelope,
                                    });
                                }
                                PlainChatParse::NotPlain => {
                                    sink.send(Input::WsEvent {
                                        ws_gen,
                                        cmd: ev.cmd,
                                        payload: ev.payload,
                                        now_unix_secs: unix_now_secs(),
                                    });
                                }
                            }
                        }
                        res = cursors.changed(), if cursors_open => {
                            if res.is_ok() {
                                let snap = cursors.borrow_and_update().clone();
                                sink.send(Input::WsCursorsChanged {
                                    ws_gen,
                                    cursors: snap,
                                });
                            } else {
                                cursors_open = false;
                            }
                        }
                    }
                }
            })
            .abort_handle();

        *self.active.lock().unwrap_or_else(PoisonError::into_inner) = Some(LiveWsSession {
            handle,
            pump_abort,
            runtime: runtime.clone(),
        });
    }

    fn stop(&self, reset_cursors: bool) {
        let prev = self
            .active
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .take();
        if let Some(old) = prev {
            old.pump_abort.abort();
            old.runtime.spawn(async move {
                let _ = old.handle.stop(reset_cursors).await;
            });
        }
    }

    fn record_file_done(&self, file_id: String, url: String) {
        let info = self
            .active
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .as_ref()
            .map(|s| (s.handle.clone(), s.runtime.clone()));
        if let Some((handle, runtime)) = info {
            runtime.spawn(async move {
                handle.record_file_done(file_id, url).await;
            });
        }
    }

    async fn send_frame(&self, cmd: u16, sub_cmd: u8, payload_json: Option<Vec<u8>>) -> bool {
        let Some(handle) = self.current_handle() else {
            return false;
        };
        handle.send_frame(cmd, sub_cmd, payload_json).await
    }

    async fn send_frame_versioned(
        &self,
        cmd: u16,
        sub_cmd: u8,
        version: u8,
        payload_json: Option<Vec<u8>>,
    ) -> bool {
        let Some(handle) = self.current_handle() else {
            return false;
        };
        handle
            .send_frame_versioned(cmd, sub_cmd, version, payload_json)
            .await
    }

    async fn send_request(
        &self,
        cmd: u16,
        sub_cmd: u8,
        version: u8,
        req_id: Option<String>,
        inner_data: Map<String, Value>,
        timeout: Duration,
    ) -> Option<Map<String, Value>> {
        let handle = self.current_handle()?;
        handle
            .send_request_versioned_with_timeout(cmd, sub_cmd, version, req_id, inner_data, timeout)
            .await
    }

    async fn wait_for_file_done(&self, file_id: String, timeout: Duration) -> Option<String> {
        let handle = self.current_handle()?;
        handle
            .wait_for_file_done_with_timeout(&file_id, timeout)
            .await
    }

    async fn is_authed(&self) -> bool {
        let Some(handle) = self.current_handle() else {
            return false;
        };
        handle.is_authed().await
    }

    async fn current_cursors(&self) -> CursorMap {
        let Some(handle) = self.current_handle() else {
            return CursorMap::new();
        };
        handle.current_cursors().await
    }

    async fn seed_cursors(&self, cursors: CursorMap) {
        if let Some(handle) = self.current_handle() {
            handle.seed_cursors(cursors).await;
        }
    }
}

/// Platform / Swift host boundary called serially by [`SessionEffectRunner`].
///
/// Storage primitives (`load_saved_session`, `load_legacy_cookie`, `load_transport_state`,
/// `set_pref`) live here alongside domain calls that still belong to Swift until later units
/// (`prepare_store`, `start_bootstrap`, `apply_batch`, etc.).
/// Outcome of [`Host::on_batch_received`].
#[derive(Clone, Debug)]
pub enum BatchHookOutcome {
    /// Delegate to legacy `Host::apply_batch` (used by U2/U3 unit tests).
    DelegateToLegacy,
    /// Suppressed by `hostTrace` (skip ingestion, notify transport settle).
    Suppressed,
    /// Ingest natively in `olaz-core` using the (optionally decrypted) payload.
    IngestInCore(Map<String, Value>),
}

/// Outcome of [`Host::on_parsed_events_received`].
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ParsedEventsHookOutcome {
    /// Delegate to legacy `Host::apply_parsed_events` (used by U2/U3 unit tests).
    DelegateToLegacy,
    /// Suppressed by `hostTrace` (skip ingestion, notify transport settle).
    Suppressed,
    /// Ingest natively in `olaz-core`.
    IngestInCore,
}

#[async_trait]
pub trait Host: Send + Sync {
    async fn load_saved_session(&self) -> Option<String>;
    async fn load_legacy_cookie(&self) -> Option<LegacyCookie>;
    async fn load_transport_state(&self) -> PersistedTransportState {
        PersistedTransportState::default()
    }
    async fn set_pref(&self, key: String, value: String);
    async fn prepare_store(&self, user_id: String, account: LoginAccount);
    async fn start_bootstrap(&self);
    async fn offer_first_login_transfer(&self, force: bool);
    async fn reset_domains(&self);
    async fn persist_session(&self, snapshot_json: String);
    async fn clear_session(&self);
    async fn mark_expired(&self, snapshot_json: String);

    /// Host hook emitted when the core starts WebSocket. Return `false` to suppress connecting
    /// (used by session/transport recorders when `"ws"` is suppressed). Production returns `true`.
    async fn on_ws_started(&self, _endpoints: Vec<String>) -> bool {
        true
    }
    /// Host hook emitted when the core starts the long-poll loop. Return `false` to suppress
    /// periodic ticks (used by session/transport recorders when `"long_poll"` is suppressed).
    /// Production returns `true`.
    async fn on_long_poll_started(&self) -> bool {
        true
    }
    // U4-bootstrap
    /// Host hook emitted when the core signals launch bootstrap. Return `false` to suppress
    /// auto-dispatching `Command::Bootstrap` (used by case recorders that trigger `bootstrap`
    /// explicitly or test earlier domains in isolation). Production returns `true`.
    async fn on_bootstrap_started(&self) -> bool {
        self.start_bootstrap().await;
        true
    }
    /// Applies server mute entries fetched during launch bootstrap step 3.
    async fn apply_mutes(&self, _mutes: Vec<MuteEntry>) {}
    /// Requests the host to refresh cloud data once launch bootstrap finalizes.
    async fn refresh_cloud(&self) {}
    async fn on_open_conversation_sync(&self, _conv_id: String, _changed: bool) {}
    async fn on_close_conversation(&self) {}
    async fn refresh_board_pins(&self, _conv_id: String) {}
    async fn mark_read_boundary(&self, _conv_id: String, _seen_target: Option<SeenTarget>) {}
    #[expect(
        clippy::too_many_arguments,
        reason = "Matches apply_remote_reaction case schema fields 1-for-1"
    )]
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
    async fn decrypt_envelope(&self, payload: Map<String, Value>) -> Map<String, Value> {
        payload
    }
    async fn mark_e2ee_conversations(&self, _conv_ids: Vec<String>) {}
    async fn note_poll_messages(&self, _messages: Vec<ChatMessage>) {}
    async fn notify_incoming_messages(&self, _messages: Vec<ChatMessage>) {}
    async fn show_batch_typing(&self, _conv_id: String, _sender_id: String) {}

    // --- Transport domain callbacks (U2) ---
    async fn persist_poll_state(&self, state: PollState);
    async fn persist_ws_cursors(&self, cursors: CursorMap);
    async fn apply_batch(
        &self,
        cmd: Option<u16>,
        increment_unread: bool,
        notify_incoming: bool,
        payload: Map<String, Value>,
    ) -> BatchApplyDelta;
    async fn apply_parsed_events(
        &self,
        cmd: u16,
        increment_unread: bool,
        notify_incoming: bool,
        envelope: TypedChatEnvelope,
    ) -> BatchApplyDelta;
    /// Host hook emitted when transport delivers an `ApplyBatch` frame.
    /// Return `Some(decrypted_payload)` to have `olaz-core` ingest the batch natively
    /// (windows + SQLite + conversation deltas + Pass 2 events). Return `None` to fall back
    /// to legacy `Host::apply_batch`.
    async fn on_batch_received(
        &self,
        _cmd: Option<u16>,
        _increment_unread: bool,
        _notify_incoming: bool,
        _payload: Map<String, Value>,
    ) -> BatchHookOutcome {
        BatchHookOutcome::DelegateToLegacy
    }
    /// Host hook emitted when transport delivers a typed `ApplyParsedEvents` frame.
    /// Return `true` to have `olaz-core` ingest the typed envelope natively; return `false`
    /// to fall back to legacy `Host::apply_parsed_events`.
    async fn on_parsed_events_received(
        &self,
        _cmd: u16,
        _increment_unread: bool,
        _notify_incoming: bool,
        _envelope: &TypedChatEnvelope,
    ) -> ParsedEventsHookOutcome {
        ParsedEventsHookOutcome::DelegateToLegacy
    }
    async fn transport_batch_settled(&self) {}
    async fn engine_log(&self, _message: String) {}
    async fn mobile_sync(&self, events: Vec<MobileSyncEvent>);
    async fn e2ee_signal(&self, cmd: u16, payload: Map<String, Value>);
    async fn e2ee_deliver_reports(&self, cmd: u16, payload: Map<String, Value>);
    async fn e2ee_connected(&self, uid: String);
    async fn e2ee_disconnected(&self);
    async fn voip_control(&self, act: String, raw_data: Value, data: Map<String, Value>);
    async fn show_typing(&self, conv_id: String, uid: String, on_pc: bool);
    async fn pin_topic(&self, conv_id: String);
    async fn group_notice(&self, act: String, data: Map<String, Value>, ts: i64);
    async fn mute(
        &self,
        conv_id: String,
        set: bool,
        start: i64,
        start_explicit: bool,
        duration: i64,
    );

    // --- Send domain callbacks (U5-send) ---
    async fn send_e2ee_text(
        &self,
        _conv_id: String,
        _text: String,
        _client_id: String,
        _quote: Option<E2eeQuoteArg>,
    ) -> Result<olaz_api::SendMessageResult, String> {
        Err("send_e2ee_text not implemented by host".to_owned())
    }
    // --- Forward & message-action / cloud domain callbacks (U6/U8/U11) ---
    async fn show_card(&self, _conv_id: Option<String>, _text: String) {}
    async fn resolve_media(
        &self,
        _conv_id: String,
        _msg_id: String,
        _kind: String,
    ) -> MediaResolutionOutcome {
        MediaResolutionOutcome::Unavailable
    }
    async fn resolve_file(
        &self,
        _conv_id: String,
        _msg_id: String,
        _name: String,
        _url: Option<String>,
    ) -> FileResolutionOutcome {
        FileResolutionOutcome::Failed("resolve_file not implemented by host".to_owned())
    }
    async fn fetch_media_data(&self, _url: String) -> Option<String> {
        None
    }
    async fn send_media(
        &self,
        _conv_id: String,
        _paths: Vec<String>,
        _cleanup_after: bool,
    ) -> ComposerSendOutcome {
        ComposerSendOutcome::Failed("send_media not implemented by host".to_owned())
    }
    async fn send_files(&self, _conv_id: String, _paths: Vec<String>) -> ComposerSendOutcome {
        ComposerSendOutcome::Failed("send_files not implemented by host".to_owned())
    }

    // --- Group polls callbacks (U12) ---
    /// Arms a per-poll incoming-message debounce timer on the host. Return `true` when the host
    /// owns the sleep (e.g. Swift `ZaloEngine.pollDebounceSleep` seam) and will call back with
    /// `Command::FirePollDebounce`; return `false` (default) to sleep inside `SessionEffectRunner`
    /// on `tokio::time`.
    async fn arm_poll_debounce(&self, _poll_id: String, _seq: u64, _delay_ms: u64) -> bool {
        false
    }
    /// Cancels all pending host-owned poll debounce timers (`resetPolls` / `logOut` / `markExpired`).
    async fn cancel_all_poll_debounces(&self) {}

    // --- Stickers & composer E2EE callbacks (U13) ---
    async fn send_e2ee_sticker(
        &self,
        _conv_id: String,
        _cate_id: i64,
        _sticker_id: i64,
        _client_id: String,
    ) -> Result<olaz_api::SendMessageResult, StickerSendError> {
        Err(StickerSendError::E2eeFailed)
    }
    #[expect(
        clippy::too_many_arguments,
        reason = "Matches send_e2ee_contact_card host boundary args 1-for-1"
    )]
    async fn send_e2ee_contact_card(
        &self,
        _conv_id: String,
        _client_id: String,
        _contact_uid: String,
        _title: String,
        _phone: String,
        _avatar: String,
        _qr_code_url: String,
    ) -> Result<olaz_api::SendMessageResult, String> {
        Err("send_e2ee_contact_card not implemented by host".to_owned())
    }
    /// Waits for the composer-confirm promotion delay (default: real tokio sleep; tests can
    /// override with a deterministic virtual clock).
    async fn sleep_confirm_promote(&self, delay: Duration) {
        tokio::time::sleep(delay).await;
    }

    // --- Media domain callbacks (U15; executed concurrently on runtime.spawn) ---
    async fn media_read_outgoing_file(
        &self,
        _op_id: u64,
        _path: String,
        _name: String,
        _mode: OutgoingFileMode,
    ) -> OutgoingFileProbe {
        OutgoingFileProbe {
            exists: false,
            is_dir: false,
            readable: false,
            size: 0,
            media_type: None,
        }
    }
    async fn media_release_outgoing_file(&self, _op_id: u64) {}
    async fn media_image_dimensions(
        &self,
        _op_id: u64,
        _path: String,
        _name: String,
        _size: i64,
    ) -> (i64, i64) {
        (800, 600)
    }
    async fn media_video_metadata(
        &self,
        _op_id: u64,
        _path: String,
        _name: String,
        _size: i64,
    ) -> VideoMetadata {
        VideoMetadata::default()
    }
    async fn media_upload_photo(
        &self,
        _op_id: u64,
        _conv_id: String,
        _file_name: String,
        _size: i64,
        _width: i64,
        _height: i64,
    ) -> Result<UploadedPhotoResult, String> {
        Err("media_upload_photo not implemented by host".to_owned())
    }
    #[expect(
        clippy::too_many_arguments,
        reason = "Matches upload_video host boundary"
    )]
    async fn media_upload_video(
        &self,
        _op_id: u64,
        _conv_id: String,
        _file_name: String,
        _size: i64,
        _duration_ms: i64,
        _width: i64,
        _height: i64,
        _has_thumb: bool,
    ) -> Result<UploadedVideoResult, String> {
        Err("media_upload_video not implemented by host".to_owned())
    }
    async fn media_upload_file(
        &self,
        _op_id: u64,
        _conv_id: String,
        _file_name: String,
        _size: i64,
        _client_id: Option<String>,
        _is_e2ee: bool,
    ) -> Result<UploadedFileResult, UploadFileError> {
        Err(UploadFileError::Other(
            "media_upload_file not implemented by host".to_owned(),
        ))
    }
    async fn media_remove_own_local_file(&self, _path: String) {}
    async fn media_file_exists(&self, path: String) -> bool {
        std::path::Path::new(&path).exists()
    }
    async fn media_cache_lookup(
        &self,
        _key: String,
        _hash_prefix: String,
        _conv_id: String,
        _msg_id: String,
        _kind: MediaKind,
    ) -> Option<MediaCacheHit> {
        None
    }
    async fn media_check_local_file(&self, _url: String) -> (bool, String, bool) {
        (false, String::new(), false)
    }
    async fn media_loader_fetch_media(
        &self,
        _url: String,
        _kind: MediaKind,
        _hash_prefix: String,
        _force: bool,
    ) -> MediaFetchOutcome {
        MediaFetchOutcome::Transient
    }
    async fn media_video_poster(&self, _path: String) -> Option<String> {
        None
    }
    async fn media_loader_fetch_file(
        &self,
        _url: String,
        _force: bool,
        _request_token: u64,
    ) -> FileFetchOutcome {
        FileFetchOutcome::Error(FileLoadError::Other)
    }
    async fn media_stage_file(
        &self,
        _source_path: String,
        _stem: String,
        _ext: Option<String>,
    ) -> Option<String> {
        None
    }
}

enum HostJob {
    LoadSavedSession {
        boot_gen: u64,
        sink: ActorSink,
        _guard: InFlightGuard,
    },
    LoadLegacyCookie {
        boot_gen: u64,
        sink: ActorSink,
        _guard: InFlightGuard,
    },
    SetPref {
        key: String,
        value: String,
        _guard: InFlightGuard,
    },
    PrepareStore {
        token: StoreToken,
        user_id: String,
        account: Box<LoginAccount>,
        identities: Box<IdentityTable>,
        sink: ActorSink,
        _guard: InFlightGuard,
    },
    StartWs {
        params: WsStartParams,
        sink: ActorSink,
        _guard: InFlightGuard,
    },
    StartLpInitial {
        lp_gen: u64,
        delay: Duration,
        sink: ActorSink,
        _guard: InFlightGuard,
    },
    StartBootstrap {
        sink: ActorSink,
        _guard: InFlightGuard,
    },
    // U4-bootstrap
    ApplyMutes {
        mutes: Vec<MuteEntry>,
        _guard: InFlightGuard,
    },
    RefreshCloud {
        _guard: InFlightGuard,
    },
    OnOpenConversationSync {
        conv_id: String,
        changed: bool,
        _guard: InFlightGuard,
    },
    OnCloseConversation {
        _guard: InFlightGuard,
    },
    RefreshBoardPins {
        conv_id: String,
        _guard: InFlightGuard,
    },
    // U12
    RefreshBoardPinsThen {
        conv_id: String,
        continuation: crate::effect::PollBoardContinuation,
        sink: ActorSink,
        _guard: InFlightGuard,
    },
    CancelAllPollDebounces {
        _guard: InFlightGuard,
    },
    MarkReadBoundary {
        conv_id: String,
        seen_target: Option<SeenTarget>,
        _guard: InFlightGuard,
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
        sink: ActorSink,
        _guard: InFlightGuard,
    },
    ApplyRemoteRecall {
        conv_id: String,
        msg_id: String,
        cli_msg_id: String,
        update_conversation_preview: bool,
        persist_conversations: bool,
        op_id: Option<u64>,
        recall_many_id: Option<u64>,
        sink: ActorSink,
        _guard: InFlightGuard,
    },
    ApplyRemoteDelete {
        conv_id: String,
        msg_id: String,
        cli_msg_id: String,
        update_conversation_preview: bool,
        persist_conversations: bool,
        cloud_delete_op_id: Option<u64>,
        sink: ActorSink,
        _guard: InFlightGuard,
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
        sink: ActorSink,
        _guard: InFlightGuard,
    },
    MarkE2eeConversations {
        conv_ids: Vec<String>,
        _guard: InFlightGuard,
    },
    NotePollMessages {
        messages: Vec<ChatMessage>,
        _guard: InFlightGuard,
    },
    NotifyIncomingMessages {
        messages: Vec<ChatMessage>,
        _guard: InFlightGuard,
    },
    ShowBatchTyping {
        conv_id: String,
        sender_id: String,
        _guard: InFlightGuard,
    },
    TransportBatchSettled {
        _guard: InFlightGuard,
    },
    EngineLog {
        message: String,
        _guard: InFlightGuard,
    },
    OfferFirstLoginTransfer {
        force: bool,
        _guard: InFlightGuard,
    },
    DetachStore {
        _guard: InFlightGuard,
    },
    ResetDomains {
        _guard: InFlightGuard,
    },
    PersistSession {
        snapshot_json: String,
        _guard: InFlightGuard,
    },
    ClearSession {
        _guard: InFlightGuard,
    },
    MarkExpired {
        snapshot_json: String,
        _guard: InFlightGuard,
    },
    PersistPollState {
        state: PollState,
        _guard: InFlightGuard,
    },
    PersistWsCursors {
        cursors: CursorMap,
        _guard: InFlightGuard,
    },
    ApplyBatch {
        cmd: Option<u16>,
        increment_unread: bool,
        notify_incoming: bool,
        payload: Map<String, Value>,
        poll_batch_done: Option<(u64, u64)>,
        sink: ActorSink,
        _guard: InFlightGuard,
    },
    ApplyParsedEvents {
        cmd: u16,
        increment_unread: bool,
        notify_incoming: bool,
        envelope: TypedChatEnvelope,
        sink: ActorSink,
        _guard: InFlightGuard,
    },
    MobileSync {
        events: Vec<MobileSyncEvent>,
        _guard: InFlightGuard,
    },
    E2eeSignal {
        cmd: u16,
        payload: Map<String, Value>,
        _guard: InFlightGuard,
    },
    E2eeDeliverReports {
        cmd: u16,
        payload: Map<String, Value>,
        _guard: InFlightGuard,
    },
    E2eeConnected {
        uid: String,
        _guard: InFlightGuard,
    },
    E2eeDisconnected {
        _guard: InFlightGuard,
    },
    VoipControl {
        act: String,
        raw_data: Value,
        data: Map<String, Value>,
        _guard: InFlightGuard,
    },
    ShowTyping {
        conv_id: String,
        uid: String,
        on_pc: bool,
        _guard: InFlightGuard,
    },
    ShowCard {
        conv_id: Option<String>,
        text: String,
        _guard: InFlightGuard,
    },
    PinTopic {
        conv_id: String,
        _guard: InFlightGuard,
    },
    GroupNotice {
        act: String,
        data: Map<String, Value>,
        ts: i64,
        _guard: InFlightGuard,
    },
    Mute {
        conv_id: String,
        set: bool,
        start: i64,
        start_explicit: bool,
        duration: i64,
        _guard: InFlightGuard,
    },
    // U11
    CloudResolveMedia {
        op_id: u64,
        conv_id: String,
        msg_id: String,
        kind: String,
        sink: ActorSink,
        _guard: InFlightGuard,
    },
    CloudResolveFile {
        op_id: u64,
        conv_id: String,
        msg_id: String,
        name: String,
        url: Option<String>,
        sink: ActorSink,
        _guard: InFlightGuard,
    },
    // U13: queued behind earlier host calls without blocking the serial host worker on network I/O
    SendE2eeSticker {
        send_id: u64,
        conv_id: String,
        cate_id: i64,
        sticker_id: i64,
        client_id: String,
        sink: ActorSink,
        guard: InFlightGuard,
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
        sink: ActorSink,
        guard: InFlightGuard,
    },
    Drain(oneshot::Sender<()>),
}

/// Shared SQLite store slot attached during `prepare_store` and detached before `reset_domains`.
pub type SharedStoreSlot = Arc<Mutex<Option<Arc<Mutex<Store>>>>>;

enum StoreJob {
    Op {
        op: StoreOp,
        sink: ActorSink,
        _guard: InFlightGuard,
    },
    LoadRecentStickers {
        reply: oneshot::Sender<Vec<Value>>,
    },
    LoadStickerSuggestPref {
        reply: oneshot::Sender<bool>,
    },
    ResolveMessageIdsLookup {
        conv_id: String,
        msg_id: String,
        cli_msg_id: String,
        reply: oneshot::Sender<(String, String, bool)>,
    },
    UpgradeMessageId {
        conv_id: String,
        old_id: String,
        new_id: String,
        client_id: String,
        _guard: InFlightGuard,
    },
    FlushOp {
        op_id: u64,
        result: OpResult,
        sink: ActorSink,
        _guard: InFlightGuard,
    },
    // U11
    CloudRefreshQuery {
        op_id: Option<u64>,
        server_snapshot: Option<CloudServerSnapshot>,
        media_ids_by_conv: Vec<(String, Vec<String>)>,
        sink: ActorSink,
        _guard: InFlightGuard,
    },
    CloudListQuery {
        op_id: u64,
        conv_id: Option<String>,
        excluding_self: Option<String>,
        kind_tags: Vec<String>,
        sort_by_size: bool,
        ascending: bool,
        offset: i64,
        limit: i64,
        memory_media: Vec<(String, Vec<String>, Vec<String>)>,
        sink: ActorSink,
        _guard: InFlightGuard,
    },
    CloudLookupMessage {
        op_id: u64,
        conv_id: String,
        msg_id: String,
        sink: ActorSink,
        _guard: InFlightGuard,
    },
    // U15
    MediaLookupMessage {
        flight_id: u64,
        conv_id: String,
        msg_id: String,
        sink: ActorSink,
        _guard: InFlightGuard,
    },
    MediaLookupFileMessage {
        op_id: u64,
        conv_id: String,
        msg_id: String,
        sink: ActorSink,
        _guard: InFlightGuard,
    },
    MediaQuerySharedMedia {
        op_id: u64,
        conv_id: String,
        kind: SharedMediaKind,
        after_cursor: Option<String>,
        limit: usize,
        sink: ActorSink,
        _guard: InFlightGuard,
    },
    Drain(oneshot::Sender<()>),
}

/// Real effect runner backed by a shared `SessionClient<T>`, a [`WsDriver`], and a [`Host`].
///
/// Generic over `T: Transport` so production uses `ReqwestTransport` and `tests/cases.rs` plugs
/// in a scripted `Transport` over the exact same request-building code.
pub struct SessionEffectRunner<T: Transport + 'static> {
    client: Arc<SessionClient<T>>,
    api: Arc<ZaloApi<T>>,
    host: Arc<dyn Host>,
    ws_driver: Arc<dyn WsDriver>,
    default_domains: Option<ZaloDomains>,
    suppress_long_poll: bool,
    ws_active_gen: Arc<Mutex<Option<u64>>>,
    lp_active_gen: Arc<Mutex<Option<u64>>>,
    shared_store: SharedStoreSlot,
    host_tx: mpsc::UnboundedSender<HostJob>,
    store_tx: mpsc::UnboundedSender<StoreJob>,
    host_dispatched: AtomicU64,
    store_dispatched: AtomicU64,
    active_tasks: Arc<Mutex<Vec<AbortHandle>>>,
    bootstrap_tasks: Arc<Mutex<Vec<AbortHandle>>>,
    lp_timer_abort: Arc<Mutex<Option<AbortHandle>>>,
    lp_fetch_abort: Mutex<Option<AbortHandle>>,
    // U5: per-conversation incoming typing expiry timers (`conv_id -> (expiry_gen, AbortHandle)`).
    typing_expiry_aborts: Arc<Mutex<BTreeMap<String, (u64, AbortHandle)>>>,
    // U6: active delete-for-me undo bar expiry timer (`(undo_gen, AbortHandle)`).
    delete_undo_abort: Arc<Mutex<Option<(u64, AbortHandle)>>>,
    // U12: per-poll debounce timers (`poll_id -> (seq, AbortHandle)`).
    poll_debounce_aborts: Arc<Mutex<BTreeMap<String, (u64, AbortHandle)>>>,
    // U13: pending 300ms composer confirm promotion timer (`(confirm_gen, AbortHandle)`).
    confirm_promote_abort: Arc<Mutex<Option<(u64, AbortHandle)>>>,
    host_worker_abort: AbortHandle,
    store_worker_abort: AbortHandle,
    runtime: Handle,
}

impl<T: Transport + 'static> SessionEffectRunner<T> {
    /// Starts the runner's serial host worker on `runtime` with [`LiveWsDriver`].
    #[must_use]
    pub fn new(client: Arc<SessionClient<T>>, host: Arc<dyn Host>, runtime: Handle) -> Self {
        Self::with_options(
            client,
            host,
            Arc::new(LiveWsDriver::new()),
            runtime,
            None,
            false,
        )
    }

    /// Starts the runner with an optional domains override restored after `ClearCoreSession`
    /// (used by tests/case replay so QR login after `log_out` still targets the fake server).
    #[must_use]
    pub fn with_default_domains(
        client: Arc<SessionClient<T>>,
        host: Arc<dyn Host>,
        runtime: Handle,
        default_domains: Option<ZaloDomains>,
    ) -> Self {
        Self::with_options(
            client,
            host,
            Arc::new(LiveWsDriver::new()),
            runtime,
            default_domains,
            false,
        )
    }

    /// Full constructor allowing tests to inject a custom [`WsDriver`] and suppress periodic
    /// long-poll timer ticks (still emitting the `start_long_poll` trace marker).
    #[must_use]
    pub fn with_options(
        client: Arc<SessionClient<T>>,
        host: Arc<dyn Host>,
        ws_driver: Arc<dyn WsDriver>,
        runtime: Handle,
        default_domains: Option<ZaloDomains>,
        suppress_long_poll: bool,
    ) -> Self {
        let api = Arc::new(ZaloApi::from_shared(Arc::clone(&client)));
        let (host_tx, host_rx) = mpsc::unbounded_channel();
        let (store_tx, store_rx) = mpsc::unbounded_channel();
        let shared_store: SharedStoreSlot = Arc::new(Mutex::new(None));
        let active_tasks: Arc<Mutex<Vec<AbortHandle>>> = Arc::new(Mutex::new(Vec::new()));
        let bootstrap_tasks: Arc<Mutex<Vec<AbortHandle>>> = Arc::new(Mutex::new(Vec::new()));
        let ws_active_gen: Arc<Mutex<Option<u64>>> = Arc::new(Mutex::new(None));
        let lp_active_gen: Arc<Mutex<Option<u64>>> = Arc::new(Mutex::new(None));
        let lp_timer_abort: Arc<Mutex<Option<AbortHandle>>> = Arc::new(Mutex::new(None));
        let store_handle = runtime.spawn(run_store_worker(
            store_rx,
            Arc::clone(&shared_store),
            runtime.clone(),
        ));
        let worker_handle = runtime.spawn(run_host_worker(HostWorkerDeps {
            rx: host_rx,
            client: Arc::clone(&client),
            host: Arc::clone(&host),
            shared_store: Arc::clone(&shared_store),
            store_tx: store_tx.clone(),
            ws_driver: Arc::clone(&ws_driver),
            ws_active_gen: Arc::clone(&ws_active_gen),
            lp_active_gen: Arc::clone(&lp_active_gen),
            lp_timer_abort: Arc::clone(&lp_timer_abort),
            suppress_long_poll,
            active_tasks: Arc::clone(&active_tasks),
            runtime: runtime.clone(),
        }));
        Self {
            client,
            api,
            host,
            ws_driver,
            default_domains,
            suppress_long_poll,
            ws_active_gen,
            lp_active_gen,
            shared_store,
            host_tx,
            store_tx,
            host_dispatched: AtomicU64::new(0),
            store_dispatched: AtomicU64::new(0),
            active_tasks,
            bootstrap_tasks,
            lp_timer_abort,
            lp_fetch_abort: Mutex::new(None),
            typing_expiry_aborts: Arc::new(Mutex::new(BTreeMap::new())),
            delete_undo_abort: Arc::new(Mutex::new(None)),
            poll_debounce_aborts: Arc::new(Mutex::new(BTreeMap::new())),
            confirm_promote_abort: Arc::new(Mutex::new(None)),
            host_worker_abort: worker_handle.abort_handle(),
            store_worker_abort: store_handle.abort_handle(),
            runtime,
        }
    }

    /// Returns a reference to the runner's [`WsDriver`] (for FFI WS pass-throughs and tests).
    #[must_use]
    pub fn api(&self) -> &Arc<ZaloApi<T>> {
        &self.api
    }

    #[must_use]
    pub fn ws_driver(&self) -> &Arc<dyn WsDriver> {
        &self.ws_driver
    }

    /// Attaches the account's opened SQLite [`Store`] so the core runner can hydrate local state
    /// and execute serial persistence operations directly without Swift hops.
    pub fn attach_store(&self, store: Arc<Mutex<Store>>) {
        *self
            .shared_store
            .lock()
            .unwrap_or_else(PoisonError::into_inner) = Some(store);
    }

    fn send_host(&self, job: HostJob) {
        self.host_dispatched.fetch_add(1, Ordering::AcqRel);
        let _ = self.host_tx.send(job);
    }

    fn send_store(&self, job: StoreJob) {
        self.store_dispatched.fetch_add(1, Ordering::AcqRel);
        let _ = self.store_tx.send(job);
    }

    /// Monotonic count of real host jobs dispatched to the serial host worker.
    #[must_use]
    pub fn host_dispatched(&self) -> u64 {
        self.host_dispatched.load(Ordering::Acquire)
    }

    /// Monotonic count of real store jobs dispatched to the serial SQLite store worker.
    #[must_use]
    pub fn store_dispatched(&self) -> u64 {
        self.store_dispatched.load(Ordering::Acquire)
    }

    /// Waits until all previously queued serial host worker jobs have completed and posted any
    /// resulting inputs back to the actor.
    pub async fn flush_host(&self) {
        let (tx, rx) = oneshot::channel();
        if self.host_tx.send(HostJob::Drain(tx)).is_ok() {
            let _ = rx.await;
        }
    }

    /// Waits until all previously queued serial SQLite store jobs have completed.
    pub async fn flush_store(&self) {
        let (tx, rx) = oneshot::channel();
        if self.store_tx.send(StoreJob::Drain(tx)).is_ok() {
            let _ = rx.await;
        }
    }

    /// Detaches any attached SQLite [`Store`] handle.
    pub fn detach_store(&self) {
        *self
            .shared_store
            .lock()
            .unwrap_or_else(PoisonError::into_inner) = None;
    }

    /// Returns a handle to the shared SQLite store slot (used by test hosts).
    #[must_use]
    pub fn shared_store_slot(&self) -> SharedStoreSlot {
        Arc::clone(&self.shared_store)
    }

    fn cancel_active_tasks(&self) {
        let handles = {
            let mut list = self
                .active_tasks
                .lock()
                .unwrap_or_else(PoisonError::into_inner);
            std::mem::take(&mut *list)
        };
        for handle in handles {
            handle.abort();
        }
        self.cancel_typing_expiry(None);
        self.cancel_delete_undo_timer();
        self.cancel_confirm_promote_timer();
    }

    fn cancel_typing_expiry(&self, conv_id: Option<&str>) {
        let mut map = self
            .typing_expiry_aborts
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        match conv_id {
            Some(id) => {
                if let Some((_, abort)) = map.remove(id) {
                    abort.abort();
                }
            }
            None => {
                for (_, (_, abort)) in std::mem::take(&mut *map) {
                    abort.abort();
                }
            }
        }
    }

    // U12
    fn cancel_poll_debounces(&self, poll_id: Option<&str>) {
        let mut map = self
            .poll_debounce_aborts
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        match poll_id {
            Some(id) => {
                if let Some((_, abort)) = map.remove(id) {
                    abort.abort();
                }
            }
            None => {
                for (_, (_, abort)) in std::mem::take(&mut *map) {
                    abort.abort();
                }
            }
        }
    }

    fn cancel_delete_undo_timer(&self) {
        if let Some((_, handle)) = self
            .delete_undo_abort
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .take()
        {
            handle.abort();
        }
    }

    fn cancel_confirm_promote_timer(&self) {
        if let Some((_, handle)) = self
            .confirm_promote_abort
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .take()
        {
            handle.abort();
        }
    }

    fn cancel_long_poll(&self) {
        if let Some(h) = self
            .lp_timer_abort
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .take()
        {
            h.abort();
        }
        if let Some(h) = self
            .lp_fetch_abort
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .take()
        {
            h.abort();
        }
    }

    fn spawn_cancellable<F>(&self, fut: F)
    where
        F: std::future::Future<Output = ()> + Send + 'static,
    {
        let handle = self.runtime.spawn(fut).abort_handle();
        let mut list = self
            .active_tasks
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        list.retain(|h| !h.is_finished());
        list.push(handle);
    }

    // U4-bootstrap
    fn cancel_bootstrap_tasks(&self) {
        let handles = {
            let mut list = self
                .bootstrap_tasks
                .lock()
                .unwrap_or_else(PoisonError::into_inner);
            std::mem::take(&mut *list)
        };
        for handle in handles {
            handle.abort();
        }
    }

    fn spawn_bootstrap<F>(&self, fut: F)
    where
        F: std::future::Future<Output = ()> + Send + 'static,
    {
        let handle = self.runtime.spawn(fut).abort_handle();
        let mut list = self
            .bootstrap_tasks
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        list.retain(|h| !h.is_finished());
        list.push(handle);
    }

    fn snapshot_json(&self) -> String {
        serde_json::to_string(&self.client.snapshot()).unwrap_or_default()
    }
}

impl<T: Transport + 'static> EffectRunner for SessionEffectRunner<T> {
    fn dispatch(&self, effects: Vec<Effect>, sink: ActorSink) {
        for effect in effects {
            match effect {
                Effect::CancelSessionTasks => {
                    self.cancel_active_tasks();
                    self.cancel_bootstrap_tasks();
                    self.cancel_poll_debounces(None);
                }
                Effect::ClearCoreSession => {
                    self.api.reset_state();
                    let pre_clear_domains = self.client.domains();
                    self.client.clear_session();
                    let restore = if pre_clear_domains.isolated {
                        Some(pre_clear_domains)
                    } else {
                        self.default_domains
                            .as_ref()
                            .filter(|d| d.isolated)
                            .cloned()
                    };
                    if let Some(domains) = restore {
                        self.client.with_session(|s| s.domains = domains);
                    }
                }
                Effect::MarkCoreSessionExpired => {
                    self.client.mark_expired();
                }
                Effect::LoadSavedSession { boot_gen } => {
                    let guard = sink.track();
                    self.send_host(HostJob::LoadSavedSession {
                        boot_gen,
                        sink: sink.clone(),
                        _guard: guard,
                    });
                }
                Effect::LoadLegacyCookie { boot_gen } => {
                    let guard = sink.track();
                    self.send_host(HostJob::LoadLegacyCookie {
                        boot_gen,
                        sink: sink.clone(),
                        _guard: guard,
                    });
                }
                Effect::CheckSessionStatus { boot_gen } => {
                    let client = Arc::clone(&self.client);
                    let _api = Arc::clone(&self.api);
                    let sink = sink.clone();
                    let guard = sink.track();
                    self.spawn_cancellable(async move {
                        let (status, updated_from_login_info) =
                            client.session_status_detailed().await;
                        let ws_endpoints = client.domains().ws;
                        sink.send(Input::SessionStatusResult {
                            boot_gen,
                            status,
                            updated_from_login_info,
                            ws_endpoints,
                        });
                        drop(guard);
                    });
                }
                Effect::SyncProfileMe { boot_gen } => {
                    let client = Arc::clone(&self.client);
                    let _api = Arc::clone(&self.api);
                    let sink = sink.clone();
                    let guard = sink.track();
                    self.spawn_cancellable(async move {
                        let synced = client.sync_profile_me().await;
                        let profile_synced = synced.is_some();
                        let account = synced.or_else(|| client.account());
                        let ws_endpoints = client.domains().ws;
                        sink.send(Input::SyncProfileMeDone {
                            boot_gen,
                            profile_synced,
                            account,
                            ws_endpoints,
                        });
                        drop(guard);
                    });
                }
                Effect::RequestQr { qr_gen, language } => {
                    let client = Arc::clone(&self.client);
                    let _api = Arc::clone(&self.api);
                    let sink = sink.clone();
                    let guard = sink.track();
                    self.spawn_cancellable(async move {
                        let result = client
                            .request_qr(&language)
                            .await
                            .map_err(SessionFailure::from);
                        sink.send(Input::QrRequested { qr_gen, result });
                        drop(guard);
                    });
                }
                Effect::WaitQrScan { qr_gen, ticket } => {
                    let client = Arc::clone(&self.client);
                    let _api = Arc::clone(&self.api);
                    let sink = sink.clone();
                    let guard = sink.track();
                    self.spawn_cancellable(async move {
                        let rot_sink = sink.clone();
                        let mut on_rotated = move |rotated: &olaz_net::QrTicket| {
                            rot_sink.send(Input::QrRotated {
                                qr_gen,
                                ticket: rotated.clone(),
                            });
                        };
                        let result = client
                            .wait_for_qr_scan(&ticket, Some(&mut on_rotated))
                            .await
                            .map_err(SessionFailure::from);
                        sink.send(Input::QrScanned { qr_gen, result });
                        drop(guard);
                    });
                }
                Effect::WaitQrConfirm { qr_gen, ticket } => {
                    let client = Arc::clone(&self.client);
                    let _api = Arc::clone(&self.api);
                    let sink = sink.clone();
                    let guard = sink.track();
                    self.spawn_cancellable(async move {
                        let result = client
                            .wait_for_qr_confirm(&ticket)
                            .await
                            .map(|_| ())
                            .map_err(SessionFailure::from);
                        sink.send(Input::QrConfirmed { qr_gen, result });
                        drop(guard);
                    });
                }
                Effect::CompleteLogin { qr_gen } => {
                    let client = Arc::clone(&self.client);
                    let _api = Arc::clone(&self.api);
                    let sink = sink.clone();
                    let guard = sink.track();
                    self.spawn_cancellable(async move {
                        let result = client
                            .complete_login_detailed()
                            .await
                            .map(|(account, profile_synced)| CompletedLogin {
                                account,
                                ws_endpoints: client.domains().ws,
                                profile_synced,
                            })
                            .map_err(SessionFailure::from);
                        sink.send(Input::LoginCompleted { qr_gen, result });
                        drop(guard);
                    });
                }
                Effect::SetPref { key, value } => {
                    let guard = sink.track();
                    self.send_host(HostJob::SetPref {
                        key,
                        value,
                        _guard: guard,
                    });
                }
                Effect::StartWs {
                    ws_gen,
                    endpoints,
                    seed_cursors,
                    my_uid,
                    self_conv_id,
                } => {
                    *self
                        .ws_active_gen
                        .lock()
                        .unwrap_or_else(PoisonError::into_inner) = Some(ws_gen);
                    let zpw_sek = self.client.zpw_sek().unwrap_or_default();
                    let guard = sink.track();
                    self.send_host(HostJob::StartWs {
                        params: WsStartParams {
                            ws_gen,
                            endpoints,
                            zpw_sek,
                            seed_cursors,
                            my_uid,
                            self_conv_id,
                        },
                        sink: sink.clone(),
                        _guard: guard,
                    });
                }
                Effect::StopWs { reset_cursors } => {
                    *self
                        .ws_active_gen
                        .lock()
                        .unwrap_or_else(PoisonError::into_inner) = None;
                    self.ws_driver.stop(reset_cursors);
                }
                Effect::RecordFileDone { file_id, url } => {
                    self.ws_driver.record_file_done(file_id, url);
                }
                Effect::StartLpTimer {
                    lp_gen,
                    initial,
                    delay,
                } => {
                    if let Some(prev) = self
                        .lp_timer_abort
                        .lock()
                        .unwrap_or_else(PoisonError::into_inner)
                        .take()
                    {
                        prev.abort();
                    }
                    if initial {
                        *self
                            .lp_active_gen
                            .lock()
                            .unwrap_or_else(PoisonError::into_inner) = Some(lp_gen);
                        let guard = sink.track();
                        self.send_host(HostJob::StartLpInitial {
                            lp_gen,
                            delay,
                            sink: sink.clone(),
                            _guard: guard,
                        });
                    } else if !self.suppress_long_poll
                        && *self
                            .lp_active_gen
                            .lock()
                            .unwrap_or_else(PoisonError::into_inner)
                            == Some(lp_gen)
                    {
                        let timer_sink = sink.clone();
                        let handle = self
                            .runtime
                            .spawn(async move {
                                tokio::time::sleep(delay).await;
                                timer_sink.send(Input::LpTick { lp_gen });
                            })
                            .abort_handle();
                        *self
                            .lp_timer_abort
                            .lock()
                            .unwrap_or_else(PoisonError::into_inner) = Some(handle);
                    }
                }
                Effect::StopLongPoll => {
                    *self
                        .lp_active_gen
                        .lock()
                        .unwrap_or_else(PoisonError::into_inner) = None;
                    self.cancel_long_poll();
                }
                Effect::FetchPollBatch {
                    lp_gen,
                    drain_id,
                    poll_state,
                } => {
                    if let Some(prev) = self
                        .lp_fetch_abort
                        .lock()
                        .unwrap_or_else(PoisonError::into_inner)
                        .take()
                    {
                        prev.abort();
                    }
                    let _client = Arc::clone(&self.client);
                    let api = Arc::clone(&self.api);
                    let fetch_sink = sink.clone();
                    let guard = sink.track();
                    let handle = self
                        .runtime
                        .spawn(async move {
                            let result = match api.fetch_chat_from_polling(&poll_state).await {
                                Ok(outcome) => Ok(PollBatchOutcome {
                                    payload: outcome.response,
                                    next_state: outcome.next_state,
                                    more: outcome.more,
                                }),
                                Err(err) if err.is_auth_error() => Err(PollBatchError::Auth),
                                Err(_) => Err(PollBatchError::Other),
                            };
                            fetch_sink.send(Input::PollBatchFetched {
                                lp_gen,
                                drain_id,
                                result,
                                now_unix_secs: unix_now_secs(),
                            });
                            drop(guard);
                        })
                        .abort_handle();
                    *self
                        .lp_fetch_abort
                        .lock()
                        .unwrap_or_else(PoisonError::into_inner) = Some(handle);
                }
                Effect::CompleteDrain { .. } => {
                    // Handled directly by the actor before reaching EffectRunner.
                }
                Effect::EngineLog(msg) => {
                    tracing::info!(target: "olaz_core::engine_log", "{msg}");
                    self.send_host(HostJob::EngineLog {
                        message: msg,
                        _guard: sink.track(),
                    });
                }
                Effect::Store(op) => {
                    let guard = sink.track();
                    self.send_store(StoreJob::Op {
                        op,
                        sink: sink.clone(),
                        _guard: guard,
                    });
                }
                Effect::DetachStore => {
                    let guard = sink.track();
                    self.send_host(HostJob::DetachStore { _guard: guard });
                }
                Effect::CompleteOp {
                    op_id,
                    result,
                    after_store: true,
                } => {
                    let guard = sink.track();
                    self.send_store(StoreJob::FlushOp {
                        op_id,
                        result,
                        sink: sink.clone(),
                        _guard: guard,
                    });
                }
                Effect::CompleteOp {
                    after_store: false, ..
                } => {
                    // Handled directly by the actor before reaching EffectRunner.
                }
                Effect::UpdatePinnedConversationApi { id, pinned, op_id } => {
                    let _client = Arc::clone(&self.client);
                    let api = Arc::clone(&self.api);
                    let sink = sink.clone();
                    let guard = sink.track();
                    self.runtime.spawn(async move {
                        let ok = api.update_pinned_conversation(&id, pinned).await.is_ok();
                        sink.send(Input::PinApiDone {
                            id,
                            pinned,
                            ok,
                            op_id,
                        });
                        drop(guard);
                    });
                }
                Effect::PinReplacingApi {
                    op_id,
                    target_id,
                    pinned,
                    unpin_remaining,
                    pin_id,
                } => {
                    let _client = Arc::clone(&self.client);
                    let api = Arc::clone(&self.api);
                    let sink = sink.clone();
                    let guard = sink.track();
                    self.runtime.spawn(async move {
                        let ok = api
                            .update_pinned_conversation(&target_id, pinned)
                            .await
                            .is_ok();
                        sink.send(Input::PinReplacingStepDone {
                            op_id,
                            target_id,
                            pinned,
                            unpin_remaining,
                            pin_id,
                            ok,
                        });
                        drop(guard);
                    });
                }
                Effect::UpdateArchivedChatApi {
                    id,
                    archived,
                    op_id,
                } => {
                    let _client = Arc::clone(&self.client);
                    let api = Arc::clone(&self.api);
                    let sink = sink.clone();
                    let guard = sink.track();
                    self.runtime.spawn(async move {
                        let ok = api.update_archived_chat(&id, archived).await.is_ok();
                        sink.send(Input::MoveApiDone {
                            id,
                            to_other: archived,
                            ok,
                            op_id,
                        });
                        drop(guard);
                    });
                }
                Effect::DeleteConversationApi {
                    id,
                    last_cli_msg_id,
                    op_id,
                } => {
                    let _client = Arc::clone(&self.client);
                    let api = Arc::clone(&self.api);
                    let sink = sink.clone();
                    let guard = sink.track();
                    self.runtime.spawn(async move {
                        let _ = api.delete_conversation(&id, &last_cli_msg_id).await;
                        sink.send(Input::DeleteApiDone { id, op_id });
                        drop(guard);
                    });
                }
                Effect::SetUnreadMarkApi { conv_id, unread } => {
                    let _client = Arc::clone(&self.client);
                    let api = Arc::clone(&self.api);
                    let guard = sink.track();
                    self.runtime.spawn(async move {
                        let _ = api.set_unread_mark(&conv_id, unread).await;
                        drop(guard);
                    });
                }
                Effect::SendSeenApi(target) => {
                    let _client = Arc::clone(&self.client);
                    let api = Arc::clone(&self.api);
                    let guard = sink.track();
                    self.runtime.spawn(async move {
                        let _ = api
                            .send_seen(
                                &target.conv_id,
                                &target.msg_id,
                                &target.cli_msg_id,
                                &target.sender_id,
                            )
                            .await;
                        drop(guard);
                    });
                }
                Effect::SetHiddenConversationApi {
                    conv_id,
                    hidden,
                    op_id,
                    result,
                } => {
                    let _client = Arc::clone(&self.client);
                    let api = Arc::clone(&self.api);
                    let sink = sink.clone();
                    let guard = sink.track();
                    self.runtime.spawn(async move {
                        let _ = api.set_hidden_conversation(&conv_id, hidden).await;
                        if let (Some(id), Some(res)) = (op_id, result) {
                            sink.send(Input::OpApiDone {
                                op_id: id,
                                result: OpResult::ActionResult(res),
                            });
                        }
                        drop(guard);
                    });
                }
                Effect::UpdateHiddenPinApi { pin, kind, op_id } => {
                    let client = Arc::clone(&self.client);
                    let api = Arc::clone(&self.api);
                    let sink = sink.clone();
                    let guard = sink.track();
                    self.runtime.spawn(async move {
                        let md5 = if client.is_authenticated() {
                            if api.update_hidden_pin(&pin).await.is_err() {
                                sink.send(Input::HiddenPinSyncDone {
                                    op_id,
                                    kind,
                                    ok: false,
                                    md5: None,
                                    sha256: String::new(),
                                });
                                drop(guard);
                                return;
                            }
                            Some(hidden_pin_md5(&pin))
                        } else {
                            None
                        };
                        let sha256 = hidden_pin_sha256(&pin);
                        sink.send(Input::HiddenPinSyncDone {
                            op_id,
                            kind,
                            ok: true,
                            md5,
                            sha256,
                        });
                        drop(guard);
                    });
                }
                Effect::ResetHiddenPinApi { op_id } => {
                    let client = Arc::clone(&self.client);
                    let api = Arc::clone(&self.api);
                    let sink = sink.clone();
                    let guard = sink.track();
                    self.runtime.spawn(async move {
                        let ok = if client.is_authenticated() {
                            api.reset_hidden_pin().await.is_ok()
                        } else {
                            true
                        };
                        sink.send(Input::ResetHiddenPinApiDone { op_id, ok });
                        drop(guard);
                    });
                }
                Effect::FetchHiddenConversationsApi { op_id } => {
                    let client = Arc::clone(&self.client);
                    let api = Arc::clone(&self.api);
                    let sink = sink.clone();
                    let guard = sink.track();
                    self.runtime.spawn(async move {
                        let snapshot = if client.is_authenticated() {
                            api.fetch_hidden_conversations().await.ok()
                        } else {
                            None
                        };
                        sink.send(Input::SyncHiddenFetched { op_id, snapshot });
                        drop(guard);
                    });
                }
                Effect::FetchProfilesChunkApi {
                    op_id,
                    chunk,
                    remaining_chunks,
                    profiles_cache_changed,
                } => {
                    let _client = Arc::clone(&self.client);
                    let api = Arc::clone(&self.api);
                    let sink = sink.clone();
                    let guard = sink.track();
                    self.runtime.spawn(async move {
                        let profiles_map = match api.fetch_profiles(&chunk).await {
                            Ok(raw) => extract_profiles_map(&raw),
                            Err(_) => Map::new(),
                        };
                        sink.send(Input::ResolveNamesChunkDone {
                            op_id,
                            remaining_chunks,
                            profiles_map,
                            profiles_cache_changed,
                        });
                        drop(guard);
                    });
                }
                Effect::UpdateConversationLabelsApi {
                    label_data_json,
                    op_id,
                } => {
                    let _client = Arc::clone(&self.client);
                    let api = Arc::clone(&self.api);
                    let sink = sink.clone();
                    let guard = sink.track();
                    self.runtime.spawn(async move {
                        let _ = api.update_conversation_labels(&label_data_json).await;
                        if let Some(id) = op_id {
                            sink.send(Input::OpApiDone {
                                op_id: id,
                                result: OpResult::Unit,
                            });
                        }
                        drop(guard);
                    });
                }
                Effect::FetchConversationLabelsApi { op_id } => {
                    let _client = Arc::clone(&self.client);
                    let api = Arc::clone(&self.api);
                    let sink = sink.clone();
                    let guard = sink.track();
                    self.runtime.spawn(async move {
                        let payload = api.fetch_conversation_labels().await.ok();
                        sink.send(Input::SyncLabelsFetched { op_id, payload });
                        drop(guard);
                    });
                }
                // --- Launch bootstrap network effects (U4-bootstrap) ---
                Effect::CancelBootstrapTasks => {
                    self.cancel_bootstrap_tasks();
                }
                Effect::BootstrapFetchAliasesApi { boot_gen } => {
                    let _client = Arc::clone(&self.client);
                    let api = Arc::clone(&self.api);
                    let sink = sink.clone();
                    let guard = sink.track();
                    self.spawn_bootstrap(async move {
                        let result = match api.fetch_aliases().await {
                            Ok(aliases) => Ok(aliases),
                            Err(err) if err.is_auth_error() => Err(BootstrapAliasesError::Auth),
                            Err(_) => Err(BootstrapAliasesError::Other),
                        };
                        sink.send(Input::BootstrapAliasesDone { boot_gen, result });
                        drop(guard);
                    });
                }
                Effect::BootstrapFetchPamApi { boot_gen } => {
                    let _client = Arc::clone(&self.client);
                    let api = Arc::clone(&self.api);
                    let sink = sink.clone();
                    let guard = sink.track();
                    self.spawn_bootstrap(async move {
                        let (pinned_res, archived_res, mute_res) = tokio::join!(
                            api.fetch_pinned_conversations(),
                            api.fetch_archived_chats(),
                            api.fetch_mute_list(),
                        );
                        sink.send(Input::BootstrapPamDone {
                            boot_gen,
                            pinned_ids: pinned_res.ok(),
                            archived_ids: archived_res.ok(),
                            mute_rows: mute_res.ok(),
                        });
                        drop(guard);
                    });
                }
                Effect::BootstrapFetchLabelsApi { boot_gen } => {
                    let _client = Arc::clone(&self.client);
                    let api = Arc::clone(&self.api);
                    let sink = sink.clone();
                    let guard = sink.track();
                    self.spawn_bootstrap(async move {
                        let payload = api.fetch_conversation_labels().await.ok();
                        sink.send(Input::BootstrapLabelsDone { boot_gen, payload });
                        drop(guard);
                    });
                }
                Effect::BootstrapFetchHiddenApi { boot_gen } => {
                    let client = Arc::clone(&self.client);
                    let api = Arc::clone(&self.api);
                    let sink = sink.clone();
                    let guard = sink.track();
                    self.spawn_bootstrap(async move {
                        let snapshot = if client.is_authenticated() {
                            api.fetch_hidden_conversations().await.ok()
                        } else {
                            None
                        };
                        sink.send(Input::BootstrapHiddenDone { boot_gen, snapshot });
                        drop(guard);
                    });
                }
                Effect::BootstrapFetchContactsApi { boot_gen } => {
                    let _client = Arc::clone(&self.client);
                    let api = Arc::clone(&self.api);
                    let sink = sink.clone();
                    let guard = sink.track();
                    self.spawn_bootstrap(async move {
                        let (friends_res, groups_res, sent_res, received_res) = tokio::join!(
                            api.fetch_friends(1, 20000),
                            api.fetch_groups_list(),
                            api.fetch_sent_friend_requests(),
                            api.fetch_received_friend_requests(),
                        );
                        sink.send(Input::BootstrapContactsDone {
                            boot_gen,
                            friends_rows: friends_res.ok(),
                            groups_dict: groups_res.ok(),
                            sent_rows: sent_res.ok(),
                            received_rows: received_res.ok(),
                        });
                        drop(guard);
                    });
                }
                Effect::BootstrapFetchPreloadApi {
                    boot_gen,
                    thread_ids,
                    is_overview,
                } => {
                    let _client = Arc::clone(&self.client);
                    let api = Arc::clone(&self.api);
                    let sink = sink.clone();
                    let guard = sink.track();
                    self.spawn_bootstrap(async move {
                        let payload = api.fetch_preload_conversations(&thread_ids).await.ok();
                        sink.send(Input::BootstrapPreloadDone {
                            boot_gen,
                            is_overview,
                            payload,
                        });
                        drop(guard);
                    });
                }
                Effect::BootstrapFetchHistoryApi {
                    boot_gen,
                    conv_id,
                    count,
                } => {
                    let _client = Arc::clone(&self.client);
                    let api = Arc::clone(&self.api);
                    let sink = sink.clone();
                    let guard = sink.track();
                    self.spawn_bootstrap(async move {
                        let payload = api
                            .fetch_history(&conv_id, None, count, Some(false))
                            .await
                            .ok();
                        sink.send(Input::BootstrapSelfCloudDone {
                            boot_gen,
                            conv_id,
                            payload,
                        });
                        drop(guard);
                    });
                }
                Effect::BootstrapFetchGroupWaveApi {
                    boot_gen,
                    gids,
                    count,
                } => {
                    let client = Arc::clone(&self.client);
                    let _api = Arc::clone(&self.api);
                    let sink = sink.clone();
                    let guard = sink.track();
                    self.spawn_bootstrap(async move {
                        type WaveEntry = (String, Option<Map<String, Value>>);
                        let len = gids.len();
                        let mut set: tokio::task::JoinSet<(usize, WaveEntry)> =
                            tokio::task::JoinSet::new();
                        for (idx, gid) in gids.into_iter().enumerate() {
                            let task_client = Arc::clone(&client);
                            set.spawn(async move {
                                let api = ZaloApi::from_shared(task_client);
                                let payload =
                                    api.fetch_history(&gid, None, count, Some(false)).await.ok();
                                (idx, (gid, payload))
                            });
                        }
                        let mut slots: Vec<Option<WaveEntry>> = vec![None; len];
                        while let Some(joined) = set.join_next().await {
                            if let Ok((idx, entry)) = joined
                                && let Some(slot) = slots.get_mut(idx)
                            {
                                *slot = Some(entry);
                            }
                        }
                        let results: Vec<WaveEntry> = slots.into_iter().flatten().collect();
                        sink.send(Input::BootstrapGroupWaveDone { boot_gen, results });
                        drop(guard);
                    });
                }
                Effect::BootstrapFetchProfilesChunkApi {
                    boot_gen,
                    chunk,
                    remaining_chunks,
                    profiles_cache_changed,
                } => {
                    let _client = Arc::clone(&self.client);
                    let api = Arc::clone(&self.api);
                    let sink = sink.clone();
                    let guard = sink.track();
                    self.spawn_bootstrap(async move {
                        let profiles_map = match api.fetch_profiles(&chunk).await {
                            Ok(raw) => extract_profiles_map(&raw),
                            Err(_) => Map::new(),
                        };
                        sink.send(Input::BootstrapResolveNamesChunkDone {
                            boot_gen,
                            remaining_chunks,
                            profiles_map,
                            profiles_cache_changed,
                        });
                        drop(guard);
                    });
                }
                Effect::FetchHistoryPageApi {
                    conv_id,
                    before_msg_id,
                    count,
                    is_old,
                    purpose,
                } => {
                    let client = Arc::clone(&self.client);
                    let api = Arc::clone(&self.api);
                    let sink = sink.clone();
                    let guard = sink.track();
                    self.spawn_cancellable(async move {
                        let page = if client.is_authenticated() {
                            api.fetch_history(&conv_id, before_msg_id.as_deref(), count, is_old)
                                .await
                                .ok()
                        } else {
                            None
                        };
                        match purpose {
                            HistoryFetchPurpose::Open { open_seq, op_id } => {
                                sink.send(Input::OpenHistoryPageFetched {
                                    open_seq,
                                    conv_id,
                                    page,
                                    op_id,
                                });
                            }
                            HistoryFetchPurpose::LoadOlder { load_seq, op_id } => {
                                sink.send(Input::LoadOlderPageFetched {
                                    load_seq,
                                    conv_id,
                                    before_msg_id,
                                    page,
                                    op_id,
                                });
                            }
                        }
                        drop(guard);
                    });
                }
                Effect::FetchSenderProfilesChunkApi {
                    resolve_id,
                    conv_id,
                    chunk,
                    remaining_chunks,
                    cache_updated,
                } => {
                    let client = Arc::clone(&self.client);
                    let api = Arc::clone(&self.api);
                    let sink = sink.clone();
                    let guard = sink.track();
                    self.spawn_cancellable(async move {
                        let profiles_map = if client.is_authenticated() {
                            match api.fetch_profiles(&chunk).await {
                                Ok(raw) => extract_profiles_map(&raw),
                                Err(_) => Map::new(),
                            }
                        } else {
                            Map::new()
                        };
                        sink.send(Input::SenderProfilesChunkDone {
                            resolve_id,
                            conv_id,
                            remaining_chunks,
                            profiles_map,
                            cache_updated,
                        });
                        drop(guard);
                    });
                }
                // U5
                Effect::SendTypingApi { conv_id } => {
                    let client = Arc::clone(&self.client);
                    let api = Arc::clone(&self.api);
                    let guard = sink.track();
                    self.runtime.spawn(async move {
                        if client.is_authenticated() {
                            api.send_typing(&conv_id).await;
                        }
                        drop(guard);
                    });
                }
                Effect::StartTypingExpiry {
                    conv_id,
                    expiry_gen,
                    delay,
                } => {
                    let aborts = Arc::clone(&self.typing_expiry_aborts);
                    let timer_sink = sink.clone();
                    let conv_key = conv_id.clone();
                    let aborts_inner = Arc::clone(&aborts);
                    let handle = self
                        .runtime
                        .spawn(async move {
                            tokio::time::sleep(delay).await;
                            {
                                let mut map =
                                    aborts_inner.lock().unwrap_or_else(PoisonError::into_inner);
                                if map.get(&conv_key).is_some_and(|(g, _)| *g == expiry_gen) {
                                    map.remove(&conv_key);
                                }
                            }
                            timer_sink.send(Input::TypingExpired {
                                conv_id: conv_key,
                                expiry_gen,
                            });
                        })
                        .abort_handle();
                    let mut map = aborts.lock().unwrap_or_else(PoisonError::into_inner);
                    if let Some((_, prev)) = map.insert(conv_id, (expiry_gen, handle)) {
                        prev.abort();
                    }
                }
                Effect::CancelTypingExpiry { conv_id } => {
                    self.cancel_typing_expiry(Some(&conv_id));
                }
                // U5-send
                Effect::SendTextApi { send_id, params } => {
                    let api = Arc::clone(&self.api);
                    let sink = sink.clone();
                    let guard = sink.track();
                    self.runtime.spawn(async move {
                        let result = api
                            .send_text(&params.as_args())
                            .await
                            .map_err(|err| err.display_without_url());
                        sink.send(Input::SendTextDone { send_id, result });
                        drop(guard);
                    });
                }
                // U12
                Effect::FetchPollDetailApi {
                    op_id,
                    poll_id,
                    purpose,
                } => {
                    let client = Arc::clone(&self.client);
                    let api = Arc::clone(&self.api);
                    let sink = sink.clone();
                    let guard = sink.track();
                    self.spawn_cancellable(async move {
                        let payload = api.fetch_poll_detail(&poll_id).await.ok();
                        let is_authenticated = client.is_authenticated();
                        sink.send(Input::PollDetailFetched {
                            op_id,
                            poll_id,
                            purpose,
                            payload,
                            is_authenticated,
                        });
                        drop(guard);
                    });
                }
                Effect::FetchPollGroupDetailApi {
                    op_id,
                    poll_id,
                    group_id,
                    data_node,
                    now_ms,
                } => {
                    let api = Arc::clone(&self.api);
                    let sink = sink.clone();
                    let guard = sink.track();
                    self.spawn_cancellable(async move {
                        let group_info = api.fetch_group_detail(&group_id).await.ok();
                        sink.send(Input::PollGroupDetailFetched {
                            op_id,
                            poll_id,
                            group_id,
                            data_node,
                            group_info,
                            now_ms,
                        });
                        drop(guard);
                    });
                }
                Effect::RefreshBoardPinsForPoll {
                    conv_id,
                    require_auth,
                    continuation,
                } => {
                    if require_auth && !self.client.is_authenticated() {
                        sink.send(Input::PollBoardRefreshed {
                            conv_id,
                            continuation,
                        });
                    } else {
                        let guard = sink.track();
                        self.send_host(HostJob::RefreshBoardPinsThen {
                            conv_id,
                            continuation,
                            sink: sink.clone(),
                            _guard: guard,
                        });
                    }
                }
                Effect::UnpinThenPinPollApi {
                    op_id,
                    poll_id,
                    conv_id,
                    replace_ref,
                    for_create,
                } => {
                    let api = Arc::clone(&self.api);
                    let sink = sink.clone();
                    let guard = sink.track();
                    self.spawn_cancellable(async move {
                        let did_unpin_old =
                            if let Some((ref_id, raw_topic, board_version)) = replace_ref {
                                if let Err(err) = api
                                    .unpin_board_topic_api(
                                        &conv_id,
                                        &ref_id,
                                        raw_topic.as_ref(),
                                        board_version,
                                    )
                                    .await
                                {
                                    let olaz_api::ApiError::Net(ref net_err) = err;
                                    sink.send(Input::PollPinApiDone {
                                        op_id,
                                        poll_id,
                                        conv_id,
                                        for_create,
                                        step_result: Err(crate::polls::map_poll_pin_net_error(
                                            net_err, false,
                                        )),
                                    });
                                    drop(guard);
                                    return;
                                }
                                true
                            } else {
                                false
                            };
                        let step_result = api
                            .pin_board_item_api(&conv_id, &poll_id, 3)
                            .await
                            .map(|_| ())
                            .map_err(|olaz_api::ApiError::Net(ref net_err)| {
                                crate::polls::map_poll_pin_net_error(net_err, did_unpin_old)
                            });
                        sink.send(Input::PollPinApiDone {
                            op_id,
                            poll_id,
                            conv_id,
                            for_create,
                            step_result,
                        });
                        drop(guard);
                    });
                }
                Effect::UnpinPollApi {
                    op_id,
                    poll_id,
                    conv_id,
                    raw_topic,
                    board_version,
                } => {
                    let api = Arc::clone(&self.api);
                    let sink = sink.clone();
                    let guard = sink.track();
                    self.spawn_cancellable(async move {
                        let ok = api
                            .unpin_board_topic_api(
                                &conv_id,
                                &poll_id,
                                raw_topic.as_ref(),
                                board_version,
                            )
                            .await
                            .is_ok();
                        sink.send(Input::PollUnpinApiDone {
                            op_id,
                            poll_id,
                            conv_id,
                            ok,
                        });
                        drop(guard);
                    });
                }
                Effect::VotePollApi {
                    op_id,
                    poll_id,
                    new_options,
                    voted_ids,
                    now_ms,
                } => {
                    let api = Arc::clone(&self.api);
                    let sink = sink.clone();
                    let guard = sink.track();
                    self.spawn_cancellable(async move {
                        let ok = if !new_options.is_empty() {
                            api.add_poll_option_api(&poll_id, &new_options, &voted_ids)
                                .await
                                .is_ok()
                        } else {
                            api.vote_poll_api(&poll_id, &voted_ids).await.is_ok()
                        };
                        sink.send(Input::PollVoteApiDone {
                            op_id,
                            poll_id,
                            ok,
                            now_ms,
                        });
                        drop(guard);
                    });
                }
                Effect::LockPollApi {
                    op_id,
                    poll_id,
                    now_ms,
                } => {
                    let api = Arc::clone(&self.api);
                    let sink = sink.clone();
                    let guard = sink.track();
                    self.spawn_cancellable(async move {
                        let ok = api.lock_poll_api(&poll_id).await.is_ok();
                        sink.send(Input::PollLockApiDone {
                            op_id,
                            poll_id,
                            ok,
                            now_ms,
                        });
                        drop(guard);
                    });
                }
                Effect::SharePollApi { op_id, poll_id } => {
                    let api = Arc::clone(&self.api);
                    let sink = sink.clone();
                    let guard = sink.track();
                    self.spawn_cancellable(async move {
                        let ok = api.share_poll_api(&poll_id).await.is_ok();
                        sink.send(Input::PollShareApiDone { op_id, ok });
                        drop(guard);
                    });
                }
                Effect::CreatePollApi {
                    op_id,
                    conv_id,
                    question,
                    options,
                    expired_time_ms,
                    allow_multi,
                    allow_add,
                    hide_vote_preview,
                    is_anonymous,
                    should_pin,
                } => {
                    let api = Arc::clone(&self.api);
                    let sink = sink.clone();
                    let guard = sink.track();
                    self.spawn_cancellable(async move {
                        let result = api
                            .create_poll_api(
                                &conv_id,
                                &question,
                                &options,
                                expired_time_ms,
                                allow_multi,
                                allow_add,
                                hide_vote_preview,
                                is_anonymous,
                            )
                            .await
                            .map(|box_map| olaz_api::extract_created_poll_id(&box_map))
                            .map_err(|olaz_api::ApiError::Net(ref net_err)| {
                                crate::polls::map_create_poll_net_error(net_err)
                            });
                        sink.send(Input::PollCreateApiDone {
                            op_id,
                            conv_id,
                            should_pin,
                            result,
                        });
                        drop(guard);
                    });
                }
                Effect::ArmPollDebounce {
                    poll_id,
                    seq,
                    delay,
                } => {
                    let deadline = tokio::time::Instant::now() + delay;
                    let delay_ms = u64::try_from(delay.as_millis()).unwrap_or(u64::MAX);
                    let aborts = Arc::clone(&self.poll_debounce_aborts);
                    let aborts_inner = Arc::clone(&aborts);
                    let host = Arc::clone(&self.host);
                    let timer_sink = sink.clone();
                    let poll_key = poll_id.clone();
                    let arm_guard = sink.track();
                    let handle = self
                        .runtime
                        .spawn(async move {
                            let handled = host
                                .arm_poll_debounce(poll_key.clone(), seq, delay_ms)
                                .await;
                            drop(arm_guard);
                            if handled {
                                return;
                            }
                            tokio::time::sleep_until(deadline).await;
                            {
                                let mut map =
                                    aborts_inner.lock().unwrap_or_else(PoisonError::into_inner);
                                if map.get(&poll_key).is_some_and(|(s, _)| *s == seq) {
                                    map.remove(&poll_key);
                                }
                            }
                            timer_sink.send(Input::PollDebounceFired {
                                poll_id: poll_key,
                                seq,
                                now_ms: unix_now_ms(),
                            });
                        })
                        .abort_handle();
                    let mut map = aborts.lock().unwrap_or_else(PoisonError::into_inner);
                    if let Some((_, prev)) = map.insert(poll_id, (seq, handle)) {
                        prev.abort();
                    }
                }
                Effect::CancelAllPollDebounces => {
                    self.cancel_poll_debounces(None);
                    let guard = sink.track();
                    self.send_host(HostJob::CancelAllPollDebounces { _guard: guard });
                }
                Effect::Host(HostCall::SendE2eeText {
                    send_id,
                    conv_id,
                    text,
                    client_id,
                    quote,
                }) => {
                    let host = Arc::clone(&self.host);
                    let sink = sink.clone();
                    let guard = sink.track();
                    self.runtime.spawn(async move {
                        let result = host.send_e2ee_text(conv_id, text, client_id, quote).await;
                        sink.send(Input::SendTextDone { send_id, result });
                        drop(guard);
                    });
                }
                // U13
                Effect::FetchStickerCategories { op_id } => {
                    let api = Arc::clone(&self.api);
                    let store_tx = self.store_tx.clone();
                    let sink = sink.clone();
                    let guard = sink.track();
                    self.runtime.spawn(async move {
                        let res = match api.fetch_sticker_categories().await {
                            Ok(fetched) => {
                                let (tx, rx) = oneshot::channel();
                                let _ = store_tx.send(StoreJob::LoadRecentStickers { reply: tx });
                                let recents = rx.await.unwrap_or_default();
                                Ok((fetched, recents.len()))
                            }
                            Err(err) => Err(err.display_without_url()),
                        };
                        sink.send(Input::StickerCategoriesFetched { op_id, result: res });
                        drop(guard);
                    });
                }
                Effect::LoadRecentStickersForTabs { op_id } => {
                    let store_tx = self.store_tx.clone();
                    let sink = sink.clone();
                    let guard = sink.track();
                    self.runtime.spawn(async move {
                        let (tx, rx) = oneshot::channel();
                        let _ = store_tx.send(StoreJob::LoadRecentStickers { reply: tx });
                        let recents = rx.await.unwrap_or_default();
                        sink.send(Input::StickerTabsRecentsLoaded {
                            op_id,
                            recent_count: recents.len(),
                        });
                        drop(guard);
                    });
                }
                Effect::LoadRecentStickers { op_id } => {
                    let store_tx = self.store_tx.clone();
                    let sink = sink.clone();
                    let guard = sink.track();
                    self.runtime.spawn(async move {
                        let (tx, rx) = oneshot::channel();
                        let _ = store_tx.send(StoreJob::LoadRecentStickers { reply: tx });
                        let rows = rx.await.unwrap_or_default();
                        sink.send(Input::RecentStickersLoaded { op_id, rows });
                        drop(guard);
                    });
                }
                Effect::FetchStickerCategoryDetail { op_id, cate_id } => {
                    let api = Arc::clone(&self.api);
                    let sink = sink.clone();
                    let guard = sink.track();
                    self.runtime.spawn(async move {
                        let result = api
                            .fetch_sticker_category_detail(cate_id)
                            .await
                            .map_err(|err| err.display_without_url());
                        sink.send(Input::StickerCategoryDetailFetched {
                            op_id,
                            cate_id,
                            result,
                        });
                        drop(guard);
                    });
                }
                Effect::SearchStickersApi {
                    op_id,
                    keyword,
                    limit,
                } => {
                    let api = Arc::clone(&self.api);
                    let sink = sink.clone();
                    let guard = sink.track();
                    self.runtime.spawn(async move {
                        let result = api
                            .search_stickers(&keyword, limit)
                            .await
                            .map_err(|err| err.display_without_url());
                        sink.send(Input::StickerSearchFetched { op_id, result });
                        drop(guard);
                    });
                }
                Effect::SuggestStickersApi { op_id, keyword } => {
                    let api = Arc::clone(&self.api);
                    let sink = sink.clone();
                    let guard = sink.track();
                    self.runtime.spawn(async move {
                        let result = api
                            .suggest_stickers(&keyword)
                            .await
                            .map_err(|err| err.display_without_url());
                        sink.send(Input::StickerSuggestFetched { op_id, result });
                        drop(guard);
                    });
                }
                Effect::SendStickerApi { send_id, params } => {
                    let api = Arc::clone(&self.api);
                    let sink = sink.clone();
                    let guard = sink.track();
                    self.runtime.spawn(async move {
                        let result = api
                            .send_sticker(&params)
                            .await
                            .map_err(|err| StickerSendError::Api(err.display_without_url()));
                        sink.send(Input::SendStickerDone { send_id, result });
                        drop(guard);
                    });
                }
                Effect::Host(HostCall::SendE2eeSticker {
                    send_id,
                    conv_id,
                    cate_id,
                    sticker_id,
                    client_id,
                }) => {
                    let guard = sink.track();
                    self.send_host(HostJob::SendE2eeSticker {
                        send_id,
                        conv_id,
                        cate_id,
                        sticker_id,
                        client_id,
                        sink: sink.clone(),
                        guard,
                    });
                }
                Effect::LoadStickerSuggestPref { op_id } => {
                    let store_tx = self.store_tx.clone();
                    let sink = sink.clone();
                    let guard = sink.track();
                    self.runtime.spawn(async move {
                        let (tx, rx) = oneshot::channel();
                        let _ = store_tx.send(StoreJob::LoadStickerSuggestPref { reply: tx });
                        let enabled = rx.await.unwrap_or(true);
                        sink.send(Input::StickerSuggestPrefLoaded { op_id, enabled });
                        drop(guard);
                    });
                }
                Effect::SendContactCardApi {
                    card_send_id,
                    params,
                } => {
                    let api = Arc::clone(&self.api);
                    let sink = sink.clone();
                    let guard = sink.track();
                    self.runtime.spawn(async move {
                        let result = api
                            .send_contact_card(&params)
                            .await
                            .map_err(|err| err.display_without_url());
                        sink.send(Input::ContactCardSendDone {
                            card_send_id,
                            result,
                        });
                        drop(guard);
                    });
                }
                // U8
                Effect::AllocClientId { forward_id } => {
                    let client_id = self.client.next_client_id();
                    sink.send(Input::ForwardClientIdAllocated {
                        forward_id,
                        client_id,
                    });
                }
                Effect::Host(HostCall::ResolveMedia {
                    forward_id,
                    conv_id,
                    msg_id,
                    kind,
                }) => {
                    let host = Arc::clone(&self.host);
                    let sink = sink.clone();
                    let guard = sink.track();
                    self.runtime.spawn(async move {
                        let resolution = host.resolve_media(conv_id, msg_id, kind).await;
                        sink.send(Input::ForwardMediaResolved {
                            forward_id,
                            resolution,
                        });
                        drop(guard);
                    });
                }
                Effect::Host(HostCall::SendE2eeContactCard {
                    card_send_id,
                    conv_id,
                    client_id,
                    contact_uid,
                    title,
                    phone,
                    avatar,
                    qr_code_url,
                }) => {
                    let effective_cli = if client_id.is_empty() {
                        self.client.next_client_id().to_string()
                    } else {
                        client_id
                    };
                    let guard = sink.track();
                    self.send_host(HostJob::SendE2eeContactCard {
                        card_send_id,
                        conv_id,
                        client_id: effective_cli,
                        contact_uid,
                        title,
                        phone,
                        avatar,
                        qr_code_url,
                        sink: sink.clone(),
                        guard,
                    });
                }
                Effect::CreateReminderApi { op_id, params } => {
                    let api = Arc::clone(&self.api);
                    let sink = sink.clone();
                    let guard = sink.track();
                    self.runtime.spawn(async move {
                        let conv_id = params.conv_id.clone();
                        let pin = params.pin;
                        match api.create_reminder(&params).await {
                            Ok(resp) => {
                                let data_node = resp
                                    .get("data")
                                    .and_then(serde_json::Value::as_object)
                                    .unwrap_or(&resp);
                                let mut create_keys: Vec<String> =
                                    data_node.keys().cloned().collect();
                                create_keys.sort_unstable();
                                sink.send(Input::CreateReminderDone {
                                    op_id,
                                    conv_id,
                                    pin,
                                    ok: true,
                                    create_keys,
                                });
                            }
                            Err(_) => {
                                sink.send(Input::CreateReminderDone {
                                    op_id,
                                    conv_id,
                                    pin,
                                    ok: false,
                                    create_keys: Vec::new(),
                                });
                            }
                        }
                        drop(guard);
                    });
                }
                Effect::StartConfirmPromoteDelay { confirm_gen, delay } => {
                    // Untracked background timer (like StartDeleteUndoExpiry) so `wait_idle()`
                    // does not block on the 300 ms confirm promotion delay.
                    let timer_sink = sink.clone();
                    let host = Arc::clone(&self.host);
                    let aborts = Arc::clone(&self.confirm_promote_abort);
                    let aborts_inner = Arc::clone(&aborts);
                    let handle = self
                        .runtime
                        .spawn(async move {
                            host.sleep_confirm_promote(delay).await;
                            {
                                let mut slot =
                                    aborts_inner.lock().unwrap_or_else(PoisonError::into_inner);
                                if slot.as_ref().is_some_and(|(g, _)| *g == confirm_gen) {
                                    *slot = None;
                                }
                            }
                            timer_sink.send(Input::ConfirmPromoteExpired { confirm_gen });
                        })
                        .abort_handle();
                    let prev = {
                        let mut slot = aborts.lock().unwrap_or_else(PoisonError::into_inner);
                        slot.replace((confirm_gen, handle))
                    };
                    if let Some((_, prev_handle)) = prev {
                        prev_handle.abort();
                    }
                }
                Effect::CancelConfirmPromoteDelay => {
                    self.cancel_confirm_promote_timer();
                }
                // U15
                Effect::MediaReadOutgoingFile {
                    op_id,
                    path,
                    name,
                    mode,
                } => {
                    let host = Arc::clone(&self.host);
                    let sink = sink.clone();
                    let guard = sink.track();
                    self.runtime.spawn(async move {
                        let probe = host.media_read_outgoing_file(op_id, path, name, mode).await;
                        sink.send(Input::MediaOutgoingFileRead { op_id, probe });
                        drop(guard);
                    });
                }
                Effect::MediaReleaseOutgoingFile { op_id } => {
                    let host = Arc::clone(&self.host);
                    let guard = sink.track();
                    self.runtime.spawn(async move {
                        host.media_release_outgoing_file(op_id).await;
                        drop(guard);
                    });
                }
                Effect::MediaImageDimensions {
                    op_id,
                    path,
                    name,
                    size,
                } => {
                    let host = Arc::clone(&self.host);
                    let sink = sink.clone();
                    let guard = sink.track();
                    self.runtime.spawn(async move {
                        let (width, height) =
                            host.media_image_dimensions(op_id, path, name, size).await;
                        sink.send(Input::MediaImageDimensionsDone {
                            op_id,
                            width,
                            height,
                        });
                        drop(guard);
                    });
                }
                Effect::MediaVideoMetadata {
                    op_id,
                    path,
                    name,
                    size,
                } => {
                    let host = Arc::clone(&self.host);
                    let sink = sink.clone();
                    let guard = sink.track();
                    self.runtime.spawn(async move {
                        let meta = host.media_video_metadata(op_id, path, name, size).await;
                        sink.send(Input::MediaVideoMetadataDone { op_id, meta });
                        drop(guard);
                    });
                }
                Effect::MediaUploadPhoto {
                    op_id,
                    conv_id,
                    file_name,
                    size,
                    width,
                    height,
                } => {
                    let host = Arc::clone(&self.host);
                    let sink = sink.clone();
                    let guard = sink.track();
                    self.runtime.spawn(async move {
                        let result = host
                            .media_upload_photo(op_id, conv_id, file_name, size, width, height)
                            .await;
                        sink.send(Input::MediaUploadPhotoDone { op_id, result });
                        drop(guard);
                    });
                }
                Effect::MediaUploadVideo {
                    op_id,
                    conv_id,
                    file_name,
                    size,
                    duration_ms,
                    width,
                    height,
                    has_thumb,
                } => {
                    let host = Arc::clone(&self.host);
                    let sink = sink.clone();
                    let guard = sink.track();
                    self.runtime.spawn(async move {
                        let result = host
                            .media_upload_video(
                                op_id,
                                conv_id,
                                file_name,
                                size,
                                duration_ms,
                                width,
                                height,
                                has_thumb,
                            )
                            .await;
                        sink.send(Input::MediaUploadVideoDone { op_id, result });
                        drop(guard);
                    });
                }
                Effect::MediaAllocClientId { op_id } => {
                    let client_id = self.client.next_client_id();
                    sink.send(Input::MediaClientIdAllocated { op_id, client_id });
                }
                Effect::MediaUploadFile {
                    op_id,
                    conv_id,
                    file_name,
                    size,
                    client_id,
                    is_e2ee,
                } => {
                    let host = Arc::clone(&self.host);
                    let sink = sink.clone();
                    let guard = sink.track();
                    self.runtime.spawn(async move {
                        let result = host
                            .media_upload_file(op_id, conv_id, file_name, size, client_id, is_e2ee)
                            .await;
                        sink.send(Input::MediaUploadFileDone { op_id, result });
                        drop(guard);
                    });
                }
                Effect::MediaRemoveOwnLocalFile { path } => {
                    let host = Arc::clone(&self.host);
                    let guard = sink.track();
                    self.runtime.spawn(async move {
                        host.media_remove_own_local_file(path).await;
                        drop(guard);
                    });
                }
                Effect::MediaCheckFileExists { path, purpose } => {
                    let host = Arc::clone(&self.host);
                    let sink = sink.clone();
                    let guard = sink.track();
                    self.runtime.spawn(async move {
                        let exists = host.media_file_exists(path).await;
                        sink.send(Input::MediaFileExistsChecked { purpose, exists });
                        drop(guard);
                    });
                }
                Effect::MediaLookupMessageInStore {
                    flight_id,
                    conv_id,
                    msg_id,
                } => {
                    let guard = sink.track();
                    self.send_store(StoreJob::MediaLookupMessage {
                        flight_id,
                        conv_id,
                        msg_id,
                        sink: sink.clone(),
                        _guard: guard,
                    });
                }
                Effect::MediaCacheLookup {
                    flight_id,
                    key,
                    hash_prefix,
                    conv_id,
                    msg_id,
                    kind,
                } => {
                    let host = Arc::clone(&self.host);
                    let sink = sink.clone();
                    let guard = sink.track();
                    self.runtime.spawn(async move {
                        let hit = host
                            .media_cache_lookup(key, hash_prefix, conv_id, msg_id, kind)
                            .await;
                        sink.send(Input::MediaCacheLookupDone { flight_id, hit });
                        drop(guard);
                    });
                }
                Effect::MediaCheckLocalFile { flight_id, url } => {
                    let host = Arc::clone(&self.host);
                    let sink = sink.clone();
                    let guard = sink.track();
                    self.runtime.spawn(async move {
                        let (allowed, path, is_video) = host.media_check_local_file(url).await;
                        sink.send(Input::MediaLocalFileChecked {
                            flight_id,
                            allowed,
                            path,
                            is_video,
                        });
                        drop(guard);
                    });
                }
                Effect::MediaLoaderFetchMedia {
                    flight_id,
                    url,
                    kind,
                    hash_prefix,
                    force,
                } => {
                    let host = Arc::clone(&self.host);
                    let sink = sink.clone();
                    let guard = sink.track();
                    self.runtime.spawn(async move {
                        let outcome = host
                            .media_loader_fetch_media(url, kind, hash_prefix, force)
                            .await;
                        sink.send(Input::MediaLoaderFetchMediaDone { flight_id, outcome });
                        drop(guard);
                    });
                }
                Effect::MediaVideoPoster {
                    flight_id,
                    path,
                    from_cache,
                } => {
                    let host = Arc::clone(&self.host);
                    let sink = sink.clone();
                    let guard = sink.track();
                    self.runtime.spawn(async move {
                        let poster_path = host.media_video_poster(path).await;
                        sink.send(Input::MediaVideoPosterDone {
                            flight_id,
                            poster_path,
                            from_cache,
                        });
                        drop(guard);
                    });
                }
                Effect::MediaLookupFileMessageInStore {
                    op_id,
                    conv_id,
                    msg_id,
                } => {
                    let guard = sink.track();
                    self.send_store(StoreJob::MediaLookupFileMessage {
                        op_id,
                        conv_id,
                        msg_id,
                        sink: sink.clone(),
                        _guard: guard,
                    });
                }
                Effect::MediaLoaderFetchFile {
                    op_id,
                    url,
                    force,
                    request_token,
                } => {
                    let host = Arc::clone(&self.host);
                    let sink = sink.clone();
                    let guard = sink.track();
                    self.runtime.spawn(async move {
                        let outcome = host
                            .media_loader_fetch_file(url, force, request_token)
                            .await;
                        sink.send(Input::MediaLoaderFetchFileDone { op_id, outcome });
                        drop(guard);
                    });
                }
                Effect::MediaStageFile {
                    op_id,
                    source_path,
                    stem,
                    ext,
                } => {
                    let host = Arc::clone(&self.host);
                    let sink = sink.clone();
                    let guard = sink.track();
                    self.runtime.spawn(async move {
                        let staged_path = host.media_stage_file(source_path, stem, ext).await;
                        sink.send(Input::MediaFileStaged { op_id, staged_path });
                        drop(guard);
                    });
                }
                Effect::MediaQuerySharedMedia {
                    op_id,
                    conv_id,
                    kind,
                    after_cursor,
                    limit,
                } => {
                    let guard = sink.track();
                    self.send_store(StoreJob::MediaQuerySharedMedia {
                        op_id,
                        conv_id,
                        kind,
                        after_cursor,
                        limit,
                        sink: sink.clone(),
                        _guard: guard,
                    });
                }
                // U6
                Effect::StartDeleteUndoExpiry { undo_gen, delay } => {
                    // Untracked background timer (like StartTypingExpiry / StartLpTimer) so
                    // `wait_idle()` does not block on the 5 s undo window.
                    let timer_sink = sink.clone();
                    let aborts = Arc::clone(&self.delete_undo_abort);
                    let aborts_inner = Arc::clone(&aborts);
                    let handle = self
                        .runtime
                        .spawn(async move {
                            tokio::time::sleep(delay).await;
                            {
                                let mut slot =
                                    aborts_inner.lock().unwrap_or_else(PoisonError::into_inner);
                                if slot.as_ref().is_some_and(|(g, _)| *g == undo_gen) {
                                    *slot = None;
                                }
                            }
                            timer_sink.send(Input::DeleteUndoExpired { undo_gen });
                        })
                        .abort_handle();
                    let prev = {
                        let mut slot = aborts.lock().unwrap_or_else(PoisonError::into_inner);
                        slot.replace((undo_gen, handle))
                    };
                    if let Some((_, prev_handle)) = prev {
                        prev_handle.abort();
                    }
                }
                Effect::ResolveMessageIds {
                    resolve_id,
                    conv_id,
                    msg_id,
                    cli_msg_id,
                } => {
                    let api = Arc::clone(&self.api);
                    let store_tx = self.store_tx.clone();
                    let sink_inner = sink.clone();
                    let guard = sink.track();
                    self.runtime.spawn(async move {
                        let (tx, rx) = oneshot::channel();
                        let _ = store_tx.send(StoreJob::ResolveMessageIdsLookup {
                            conv_id: conv_id.clone(),
                            msg_id: msg_id.clone(),
                            cli_msg_id: cli_msg_id.clone(),
                            reply: tx,
                        });
                        let (mut effective_msg_id, resolved_cli_id, need_history) =
                            rx.await.unwrap_or_else(|_| {
                                let cli = cli_msg_id.trim();
                                let resolved_cli = if cli.is_empty() {
                                    msg_id.trim().to_owned()
                                } else {
                                    cli.to_owned()
                                };
                                let eff = msg_id.trim().to_owned();
                                let need = eff.is_empty() || eff == resolved_cli;
                                (eff, resolved_cli, need)
                            });
                        let mut upgraded_from_history = false;
                        if need_history
                            && let Ok(root_map) = api.fetch_history(&conv_id, None, 30, None).await
                            && let Some(resolved) = crate::actions::find_server_msg_id(
                                &Value::Object(root_map),
                                &resolved_cli_id,
                            )
                        {
                            effective_msg_id = resolved.clone();
                            upgraded_from_history = true;
                            let upgrade_guard = sink_inner.track();
                            let _ = store_tx.send(StoreJob::UpgradeMessageId {
                                conv_id: conv_id.clone(),
                                old_id: msg_id.clone(),
                                new_id: resolved,
                                client_id: resolved_cli_id.clone(),
                                _guard: upgrade_guard,
                            });
                        }
                        if effective_msg_id.is_empty() {
                            effective_msg_id = resolved_cli_id.clone();
                        }
                        sink_inner.send(Input::MessageIdsResolved {
                            resolve_id,
                            effective_msg_id,
                            resolved_cli_id,
                            upgraded_from_history,
                        });
                        drop(guard);
                    });
                }
                Effect::SendReactionApi {
                    react_id,
                    conv_id,
                    msg_id,
                    cli_msg_id,
                    r_icon,
                    r_type,
                    msg_type,
                } => {
                    let api = Arc::clone(&self.api);
                    let client = Arc::clone(&self.client);
                    let sink_inner = sink.clone();
                    let guard = sink.track();
                    self.runtime.spawn(async move {
                        let first_cli = client.next_client_id();
                        let mut final_cli = first_cli.to_string();
                        let res = match api
                            .send_reaction(
                                &conv_id,
                                &msg_id,
                                &cli_msg_id,
                                &r_icon,
                                r_type,
                                msg_type,
                                Some(first_cli),
                            )
                            .await
                        {
                            Ok(_) => Ok(()),
                            Err(err)
                                if matches!(
                                    err,
                                    olaz_api::ApiError::Net(olaz_net::NetError::Session(_))
                                ) && !err.is_auth_error()
                                    && msg_type != 1 =>
                            {
                                let retry_cli = client.next_client_id();
                                final_cli = retry_cli.to_string();
                                api.send_reaction(
                                    &conv_id,
                                    &msg_id,
                                    &cli_msg_id,
                                    &r_icon,
                                    r_type,
                                    1,
                                    Some(retry_cli),
                                )
                                .await
                                .map(|_| ())
                            }
                            Err(err) => Err(err),
                        };
                        let error = res
                            .err()
                            .map(|e| crate::actions::ReactFailure::from_api_error(&e));
                        sink_inner.send(Input::ReactDone {
                            react_id,
                            final_react_client_id: final_cli,
                            error,
                        });
                        drop(guard);
                    });
                }
                Effect::RecallMessageApi {
                    recall_id,
                    conv_id,
                    msg_id,
                    cli_msg_id,
                    primary_is_e2ee,
                    can_try_alt,
                } => {
                    let api = Arc::clone(&self.api);
                    let sink_inner = sink.clone();
                    let guard = sink.track();
                    self.runtime.spawn(async move {
                        let mut retried_alt = false;
                        let res = match api
                            .recall_message(&conv_id, &msg_id, &cli_msg_id, primary_is_e2ee)
                            .await
                        {
                            Ok(()) => Ok(()),
                            Err(olaz_api::ApiError::Net(olaz_net::NetError::Session(ref se)))
                                if se.code == 112 && can_try_alt =>
                            {
                                retried_alt = true;
                                api.recall_message(&conv_id, &msg_id, &cli_msg_id, !primary_is_e2ee)
                                    .await
                            }
                            Err(err) => Err(err),
                        };
                        let error = res
                            .err()
                            .map(|e| crate::actions::RecallFailure::from_api_error(&e));
                        sink_inner.send(Input::RecallDone {
                            recall_id,
                            retried_alt,
                            error,
                        });
                        drop(guard);
                    });
                }
                Effect::Host(HostCall::ResolveFile {
                    forward_id,
                    conv_id,
                    msg_id,
                    name,
                    url,
                }) => {
                    let host = Arc::clone(&self.host);
                    let sink = sink.clone();
                    let guard = sink.track();
                    self.runtime.spawn(async move {
                        let resolution = host.resolve_file(conv_id, msg_id, name, url).await;
                        sink.send(Input::ForwardFileResolved {
                            forward_id,
                            resolution,
                        });
                        drop(guard);
                    });
                }
                Effect::Host(HostCall::FetchMediaData { forward_id, url }) => {
                    let host = Arc::clone(&self.host);
                    let sink = sink.clone();
                    let guard = sink.track();
                    self.runtime.spawn(async move {
                        let temp_path = host.fetch_media_data(url).await;
                        sink.send(Input::ForwardFetchMediaDone {
                            forward_id,
                            temp_path,
                        });
                        drop(guard);
                    });
                }
                Effect::Host(HostCall::SendMedia {
                    forward_id,
                    conv_id,
                    paths,
                    cleanup_after,
                }) => {
                    let host = Arc::clone(&self.host);
                    let sink = sink.clone();
                    let guard = sink.track();
                    self.runtime.spawn(async move {
                        let outcome = host.send_media(conv_id, paths, cleanup_after).await;
                        sink.send(Input::ForwardSendMediaDone {
                            forward_id,
                            outcome,
                        });
                        drop(guard);
                    });
                }
                Effect::Host(HostCall::SendFiles {
                    forward_id,
                    conv_id,
                    paths,
                }) => {
                    let host = Arc::clone(&self.host);
                    let sink = sink.clone();
                    let guard = sink.track();
                    self.runtime.spawn(async move {
                        let outcome = host.send_files(conv_id, paths).await;
                        sink.send(Input::ForwardSendFilesDone {
                            forward_id,
                            outcome,
                        });
                        drop(guard);
                    });
                }
                Effect::CancelDeleteUndoExpiry => {
                    self.cancel_delete_undo_timer();
                    self.cancel_confirm_promote_timer();
                }
                Effect::CommitDeleteBatch { items } => {
                    let client = Arc::clone(&self.client);
                    let store_tx = self.store_tx.clone();
                    let sink_inner = sink.clone();
                    let guard = sink.track();
                    self.runtime.spawn(async move {
                        let api = ZaloApi::from_shared(client);
                        for item in items {
                            let resolved_cli = if item.cli_msg_id.is_empty() {
                                item.msg_id.as_str()
                            } else {
                                item.cli_msg_id.as_str()
                            };
                            let _ = api
                                .delete_message_for_me(
                                    &item.conv_id,
                                    &item.msg_id,
                                    resolved_cli,
                                    &item.sender_id,
                                )
                                .await;
                            let store_guard = sink_inner.track();
                            let _ = store_tx.send(StoreJob::Op {
                                op: StoreOp::DeleteMessage {
                                    conv_id: item.conv_id,
                                    id: item.msg_id,
                                },
                                sink: sink_inner.clone(),
                                _guard: store_guard,
                            });
                        }
                        drop(guard);
                    });
                }
                Effect::FetchAutoDeleteApi { op_id } => {
                    let client = Arc::clone(&self.client);
                    let sink = sink.clone();
                    let guard = sink.track();
                    self.runtime.spawn(async move {
                        let api = ZaloApi::from_shared(client);
                        let outcome = api.fetch_auto_delete().await.ok();
                        sink.send(Input::AutoDeleteLoaded { outcome, op_id });
                        drop(guard);
                    });
                }
                Effect::UpdateAutoDeleteApi {
                    conv_id,
                    ttl,
                    now_ms,
                    op_id,
                } => {
                    let client = Arc::clone(&self.client);
                    let sink = sink.clone();
                    let guard = sink.track();
                    self.runtime.spawn(async move {
                        let api = ZaloApi::from_shared(client);
                        let error_type = match api.update_auto_delete(&conv_id, ttl).await {
                            Ok(()) => None,
                            Err(err) => Some(swift_error_type_name(&err).to_owned()),
                        };
                        sink.send(Input::AutoDeleteUpdated {
                            conv_id,
                            ttl,
                            now_ms,
                            error_type,
                            op_id,
                        });
                        drop(guard);
                    });
                }
                // U11
                Effect::RefreshCloudData {
                    op_id,
                    media_ids_by_conv,
                    skip_api_if_no_store,
                } => {
                    let api = Arc::clone(&self.api);
                    let client = Arc::clone(&self.client);
                    let shared_store = Arc::clone(&self.shared_store);
                    let store_tx = self.store_tx.clone();
                    let sink = sink.clone();
                    let guard = sink.track();
                    self.runtime.spawn(async move {
                        let has_store = shared_store
                            .lock()
                            .unwrap_or_else(PoisonError::into_inner)
                            .is_some();
                        if skip_api_if_no_store && !has_store {
                            sink.send(Input::CloudRefreshLoaded {
                                op_id,
                                server_snapshot: None,
                                sql_summaries: Vec::new(),
                                existing_ids_by_conv: BTreeMap::new(),
                            });
                            drop(guard);
                            return;
                        }
                        let server_snapshot = if client.account().is_some() {
                            api.fetch_cloud_server_snapshot().await
                        } else {
                            None
                        };
                        let _ = store_tx.send(StoreJob::CloudRefreshQuery {
                            op_id,
                            server_snapshot,
                            media_ids_by_conv,
                            sink,
                            _guard: guard,
                        });
                    });
                }
                Effect::CloudListStore {
                    op_id,
                    conv_id,
                    excluding_self,
                    kind_tags,
                    sort_by_size,
                    ascending,
                    offset,
                    limit,
                    memory_media,
                } => {
                    let guard = sink.track();
                    self.send_store(StoreJob::CloudListQuery {
                        op_id,
                        conv_id,
                        excluding_self,
                        kind_tags,
                        sort_by_size,
                        ascending,
                        offset,
                        limit,
                        memory_media,
                        sink: sink.clone(),
                        _guard: guard,
                    });
                }
                Effect::CloudLookupMessage {
                    op_id,
                    conv_id,
                    msg_id,
                } => {
                    let guard = sink.track();
                    self.send_store(StoreJob::CloudLookupMessage {
                        op_id,
                        conv_id,
                        msg_id,
                        sink: sink.clone(),
                        _guard: guard,
                    });
                }
                Effect::CloudDeleteMessageApi {
                    op_id,
                    conv_id,
                    msg_id,
                    cli_msg_id,
                    sender_id,
                } => {
                    let api = Arc::clone(&self.api);
                    let sink = sink.clone();
                    let guard = sink.track();
                    self.runtime.spawn(async move {
                        let error = api
                            .delete_message_for_me(&conv_id, &msg_id, &cli_msg_id, &sender_id)
                            .await
                            .err()
                            .map(|err| err.display_without_url());
                        sink.send(Input::CloudDeleteMessageApiDone { op_id, error });
                        drop(guard);
                    });
                }
                Effect::ClearCloudViewerKey => {
                    self.api.clear_cloud_viewer_key();
                }
                Effect::Host(call) => {
                    let guard = sink.track();
                    let job = match call {
                        HostCall::PrepareStore {
                            token,
                            user_id,
                            account,
                            identities,
                        } => HostJob::PrepareStore {
                            token,
                            user_id,
                            account,
                            identities,
                            sink: sink.clone(),
                            _guard: guard,
                        },
                        HostCall::StartBootstrap => HostJob::StartBootstrap {
                            sink: sink.clone(),
                            _guard: guard,
                        },
                        HostCall::OfferFirstLoginTransfer { force } => {
                            HostJob::OfferFirstLoginTransfer {
                                force,
                                _guard: guard,
                            }
                        }
                        HostCall::ResetDomains => HostJob::ResetDomains { _guard: guard },
                        HostCall::PersistSession => HostJob::PersistSession {
                            snapshot_json: self.snapshot_json(),
                            _guard: guard,
                        },
                        HostCall::ClearSession => HostJob::ClearSession { _guard: guard },
                        HostCall::MarkExpired => HostJob::MarkExpired {
                            snapshot_json: self.snapshot_json(),
                            _guard: guard,
                        },
                        HostCall::PersistPollState { state } => HostJob::PersistPollState {
                            state,
                            _guard: guard,
                        },
                        HostCall::PersistWsCursors { cursors } => HostJob::PersistWsCursors {
                            cursors,
                            _guard: guard,
                        },
                        HostCall::ApplyBatch {
                            cmd,
                            increment_unread,
                            notify_incoming,
                            payload,
                            poll_batch_done,
                        } => HostJob::ApplyBatch {
                            cmd,
                            increment_unread,
                            notify_incoming,
                            payload,
                            poll_batch_done,
                            sink: sink.clone(),
                            _guard: guard,
                        },
                        HostCall::ApplyParsedEvents {
                            cmd,
                            increment_unread,
                            notify_incoming,
                            envelope,
                        } => HostJob::ApplyParsedEvents {
                            cmd,
                            increment_unread,
                            notify_incoming,
                            envelope,
                            sink: sink.clone(),
                            _guard: guard,
                        },
                        HostCall::MobileSync { events } => HostJob::MobileSync {
                            events,
                            _guard: guard,
                        },
                        HostCall::E2eeSignal { cmd, payload } => HostJob::E2eeSignal {
                            cmd,
                            payload,
                            _guard: guard,
                        },
                        HostCall::E2eeDeliverReports { cmd, payload } => {
                            HostJob::E2eeDeliverReports {
                                cmd,
                                payload,
                                _guard: guard,
                            }
                        }
                        HostCall::E2eeConnected { uid } => {
                            HostJob::E2eeConnected { uid, _guard: guard }
                        }
                        HostCall::E2eeDisconnected => HostJob::E2eeDisconnected { _guard: guard },
                        HostCall::VoipControl {
                            act,
                            raw_data,
                            data,
                        } => HostJob::VoipControl {
                            act,
                            raw_data,
                            data,
                            _guard: guard,
                        },
                        HostCall::ShowTyping {
                            conv_id,
                            uid,
                            on_pc,
                        } => HostJob::ShowTyping {
                            conv_id,
                            uid,
                            on_pc,
                            _guard: guard,
                        },
                        HostCall::PinTopic { conv_id } => HostJob::PinTopic {
                            conv_id,
                            _guard: guard,
                        },
                        HostCall::GroupNotice { act, data, ts } => HostJob::GroupNotice {
                            act,
                            data,
                            ts,
                            _guard: guard,
                        },
                        HostCall::Mute {
                            conv_id,
                            set,
                            start,
                            start_explicit,
                            duration,
                        } => HostJob::Mute {
                            conv_id,
                            set,
                            start,
                            start_explicit,
                            duration,
                            _guard: guard,
                        },
                        // U4-bootstrap
                        HostCall::ApplyMutes { mutes } => HostJob::ApplyMutes {
                            mutes,
                            _guard: guard,
                        },
                        HostCall::RefreshCloud => HostJob::RefreshCloud { _guard: guard },
                        HostCall::OnOpenConversationSync { conv_id, changed } => {
                            HostJob::OnOpenConversationSync {
                                conv_id,
                                changed,
                                _guard: guard,
                            }
                        }
                        HostCall::OnCloseConversation => {
                            HostJob::OnCloseConversation { _guard: guard }
                        }
                        HostCall::RefreshBoardPins { conv_id } => HostJob::RefreshBoardPins {
                            conv_id,
                            _guard: guard,
                        },
                        HostCall::MarkReadBoundary {
                            conv_id,
                            seen_target,
                        } => HostJob::MarkReadBoundary {
                            conv_id,
                            seen_target,
                            _guard: guard,
                        },
                        HostCall::ApplyRemoteReaction {
                            conv_id,
                            msg_id,
                            cli_msg_id,
                            sender_id,
                            r_type,
                            r_icon,
                            event_id,
                            react_client_id,
                            sender_name,
                            now_ms,
                        } => HostJob::ApplyRemoteReaction {
                            conv_id,
                            msg_id,
                            cli_msg_id,
                            sender_id,
                            r_type,
                            r_icon,
                            event_id,
                            react_client_id,
                            sender_name,
                            now_ms,
                            sink: sink.clone(),
                            _guard: guard,
                        },
                        HostCall::ApplyRemoteRecall {
                            conv_id,
                            msg_id,
                            cli_msg_id,
                            update_conversation_preview,
                            persist_conversations,
                            op_id,
                            recall_many_id,
                        } => HostJob::ApplyRemoteRecall {
                            conv_id,
                            msg_id,
                            cli_msg_id,
                            update_conversation_preview,
                            persist_conversations,
                            op_id,
                            recall_many_id,
                            sink: sink.clone(),
                            _guard: guard,
                        },
                        HostCall::ApplyRemoteDelete {
                            conv_id,
                            msg_id,
                            cli_msg_id,
                            update_conversation_preview,
                            persist_conversations,
                            cloud_delete_op_id,
                        } => HostJob::ApplyRemoteDelete {
                            conv_id,
                            msg_id,
                            cli_msg_id,
                            update_conversation_preview,
                            persist_conversations,
                            cloud_delete_op_id,
                            sink: sink.clone(),
                            _guard: guard,
                        },
                        HostCall::DecryptEnvelope {
                            payload,
                            default_cmd,
                            fallback_conv_id,
                            is_group_hint,
                            increment_unread,
                            notify_incoming,
                            persist_conversations,
                            probe_freshness,
                            poll_batch_done,
                            op_id,
                        } => HostJob::DecryptEnvelope {
                            payload,
                            default_cmd,
                            fallback_conv_id,
                            is_group_hint,
                            increment_unread,
                            notify_incoming,
                            persist_conversations,
                            probe_freshness,
                            poll_batch_done,
                            op_id,
                            sink: sink.clone(),
                            _guard: guard,
                        },
                        HostCall::MarkE2eeConversations { conv_ids } => {
                            HostJob::MarkE2eeConversations {
                                conv_ids,
                                _guard: guard,
                            }
                        }
                        HostCall::NotePollMessages { messages } => HostJob::NotePollMessages {
                            messages,
                            _guard: guard,
                        },
                        HostCall::NotifyIncomingMessages { messages } => {
                            HostJob::NotifyIncomingMessages {
                                messages,
                                _guard: guard,
                            }
                        }
                        HostCall::ShowBatchTyping { conv_id, sender_id } => {
                            HostJob::ShowBatchTyping {
                                conv_id,
                                sender_id,
                                _guard: guard,
                            }
                        }
                        HostCall::TransportBatchSettled => {
                            HostJob::TransportBatchSettled { _guard: guard }
                        }
                        HostCall::ShowCard { conv_id, text } => HostJob::ShowCard {
                            conv_id,
                            text,
                            _guard: guard,
                        },
                        // U11
                        HostCall::CloudResolveMedia {
                            op_id,
                            conv_id,
                            msg_id,
                            kind,
                        } => HostJob::CloudResolveMedia {
                            op_id,
                            conv_id,
                            msg_id,
                            kind,
                            sink: sink.clone(),
                            _guard: guard,
                        },
                        HostCall::CloudResolveFile {
                            op_id,
                            conv_id,
                            msg_id,
                            name,
                            url,
                        } => HostJob::CloudResolveFile {
                            op_id,
                            conv_id,
                            msg_id,
                            name,
                            url,
                            sink: sink.clone(),
                            _guard: guard,
                        },
                        HostCall::SendE2eeText { .. }
                        | HostCall::SendE2eeSticker { .. }
                        | HostCall::SendE2eeContactCard { .. }
                        | HostCall::ResolveMedia { .. }
                        | HostCall::ResolveFile { .. }
                        | HostCall::FetchMediaData { .. }
                        | HostCall::SendMedia { .. }
                        | HostCall::SendFiles { .. } => {
                            continue;
                        }
                    };
                    self.send_host(job);
                }
            }
        }
    }

    fn shutdown(&self) {
        *self
            .ws_active_gen
            .lock()
            .unwrap_or_else(PoisonError::into_inner) = None;
        *self
            .lp_active_gen
            .lock()
            .unwrap_or_else(PoisonError::into_inner) = None;
        self.cancel_active_tasks();
        self.cancel_bootstrap_tasks();
        self.cancel_typing_expiry(None);
        self.cancel_poll_debounces(None);
        self.cancel_long_poll();
        self.ws_driver.stop(false);
        self.host_worker_abort.abort();
        self.store_worker_abort.abort();
    }
}

fn unix_now_secs() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| i64::try_from(d.as_secs()).unwrap_or(i64::MAX))
}

fn unix_now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| i64::try_from(d.as_millis()).unwrap_or(i64::MAX))
}

async fn run_store_worker(
    mut rx: mpsc::UnboundedReceiver<StoreJob>,
    shared_store: SharedStoreSlot,
    runtime: Handle,
) {
    while let Some(job) = rx.recv().await {
        match job {
            StoreJob::Op { op, sink, _guard } => {
                let store_opt = shared_store
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner)
                    .clone();
                match op {
                    StoreOp::LoadMentionPreviewMessages {
                        op_id,
                        group_ids,
                        my_uid: _,
                    } => {
                        let messages = if let Some(store_arc) = store_opt {
                            runtime
                                .spawn_blocking(move || {
                                    let store =
                                        store_arc.lock().unwrap_or_else(PoisonError::into_inner);
                                    let mut map = BTreeMap::new();
                                    for gid in group_ids {
                                        if let Ok(rows) = store.messages(&gid, None, 1)
                                            && let Some(latest) = rows.last()
                                            && let Some(msg) =
                                                decode_stored_message(&to_wire_stored(latest))
                                        {
                                            map.insert(
                                                gid,
                                                MessagePreviewInput::from_chat_message(&msg),
                                            );
                                        }
                                    }
                                    map
                                })
                                .await
                                .unwrap_or_default()
                        } else {
                            BTreeMap::new()
                        };
                        sink.send(Input::MentionPreviewsLoaded { op_id, messages });
                    }
                    StoreOp::LoadOpenLocalMessages {
                        open_seq,
                        conv_id,
                        limit,
                        op_id,
                    } => {
                        let conv_clone = conv_id.clone();
                        let rows = if let Some(store_arc) = store_opt {
                            runtime
                                .spawn_blocking(move || {
                                    let store =
                                        store_arc.lock().unwrap_or_else(PoisonError::into_inner);
                                    store
                                        .messages(
                                            &conv_clone,
                                            None,
                                            i64::try_from(limit).unwrap_or(50),
                                        )
                                        .unwrap_or_default()
                                })
                                .await
                                .unwrap_or_default()
                        } else {
                            Vec::new()
                        };
                        sink.send(Input::OpenLocalMessagesLoaded {
                            open_seq,
                            conv_id,
                            rows,
                            op_id,
                        });
                    }
                    StoreOp::LoadOlderStoreMessages {
                        load_seq,
                        conv_id,
                        before_ts_ms,
                        limit,
                        op_id,
                    } => {
                        let conv_clone = conv_id.clone();
                        let rows = if let Some(store_arc) = store_opt {
                            runtime
                                .spawn_blocking(move || {
                                    let store =
                                        store_arc.lock().unwrap_or_else(PoisonError::into_inner);
                                    store
                                        .messages(
                                            &conv_clone,
                                            Some(before_ts_ms),
                                            i64::try_from(limit).unwrap_or(50),
                                        )
                                        .unwrap_or_default()
                                })
                                .await
                                .unwrap_or_default()
                        } else {
                            Vec::new()
                        };
                        sink.send(Input::LoadOlderStoreRead {
                            load_seq,
                            conv_id,
                            rows,
                            had_before_cursor: true,
                            op_id,
                        });
                    }
                    // U14
                    StoreOp::SearchMessagesPage {
                        op_id,
                        conv_id,
                        query,
                        before,
                        limit,
                    } => {
                        let page_limit = usize::try_from(limit).unwrap_or(50);
                        let rows = if let Some(store_arc) = store_opt {
                            runtime
                                .spawn_blocking(move || {
                                    let store =
                                        store_arc.lock().unwrap_or_else(PoisonError::into_inner);
                                    let cursor = before.as_ref().map(|(ts, id)| (*ts, id.as_str()));
                                    store
                                        .search_messages_page(&conv_id, &query, cursor, limit)
                                        .unwrap_or_default()
                                })
                                .await
                                .unwrap_or_default()
                        } else {
                            Vec::new()
                        };
                        sink.send(Input::SearchMessagesPageLoaded {
                            op_id,
                            rows,
                            page_limit,
                        });
                    }
                    StoreOp::LoadMessagesAround {
                        op_id,
                        conv_id,
                        target_ts_ms,
                        before_oldest_ts_ms,
                    } => {
                        let window = if let Some(store_arc) = store_opt {
                            runtime
                                .spawn_blocking(move || {
                                    let store =
                                        store_arc.lock().unwrap_or_else(PoisonError::into_inner);
                                    store
                                        .messages_around(
                                            &conv_id,
                                            target_ts_ms,
                                            before_oldest_ts_ms,
                                            25,
                                            3000,
                                        )
                                        .ok()
                                })
                                .await
                                .ok()
                                .flatten()
                        } else {
                            None
                        };
                        sink.send(Input::EnsureMessageWindowLoaded { op_id, window });
                    }
                    StoreOp::LookupMessage {
                        op_id,
                        conv_id,
                        key,
                    } => {
                        let row = if let Some(store_arc) = store_opt {
                            runtime
                                .spawn_blocking(move || {
                                    let store =
                                        store_arc.lock().unwrap_or_else(PoisonError::into_inner);
                                    store.message(&conv_id, &key).ok().flatten()
                                })
                                .await
                                .ok()
                                .flatten()
                        } else {
                            None
                        };
                        sink.send(Input::QuotedLookupDone { op_id, row });
                    }
                    StoreOp::FindLegacyQuoted {
                        op_id,
                        conv_id,
                        exclude_id,
                        max_ts_ms,
                        trimmed_text,
                        mine_only,
                        limit,
                    } => {
                        let rows = if let Some(store_arc) = store_opt {
                            runtime
                                .spawn_blocking(move || {
                                    let store =
                                        store_arc.lock().unwrap_or_else(PoisonError::into_inner);
                                    store
                                        .find_legacy_quoted_candidates(
                                            &conv_id,
                                            &exclude_id,
                                            max_ts_ms,
                                            &trimmed_text,
                                            mine_only,
                                            limit,
                                        )
                                        .unwrap_or_default()
                                })
                                .await
                                .unwrap_or_default()
                        } else {
                            Vec::new()
                        };
                        sink.send(Input::LegacyQuotedLookupDone { op_id, rows });
                    }
                    // U4-bootstrap
                    StoreOp::LoadPreferenceString { key, boot_gen } => {
                        let last_refresh_pref = if let Some(store_arc) = store_opt {
                            runtime
                                .spawn_blocking(move || {
                                    let store =
                                        store_arc.lock().unwrap_or_else(PoisonError::into_inner);
                                    store.get_preference_string(&key).ok().flatten()
                                })
                                .await
                                .ok()
                                .flatten()
                        } else {
                            None
                        };
                        sink.send(Input::BootstrapFreshnessLoaded {
                            boot_gen,
                            last_refresh_pref,
                        });
                    }
                    StoreOp::ProbeAndSaveMessages {
                        probe_targets,
                        rows,
                        preserve_existing_reactions,
                        reply_boot_gen,
                    } => {
                        let probes = if let Some(store_arc) = store_opt {
                            runtime
                                .spawn_blocking(move || {
                                    let mut store =
                                        store_arc.lock().unwrap_or_else(PoisonError::into_inner);
                                    let mut out = Vec::with_capacity(probe_targets.len());
                                    for (conv_id, msg_id) in probe_targets {
                                        let exists = store
                                            .existing_message_ids(
                                                &conv_id,
                                                std::slice::from_ref(&msg_id),
                                            )
                                            .map(|set| set.contains(&msg_id))
                                            .unwrap_or(false);
                                        out.push((conv_id, exists));
                                    }
                                    if !rows.is_empty() {
                                        let _ = store.save_messages_with(
                                            &rows,
                                            SaveOptions {
                                                skip_twin_checks: false,
                                                preserve_existing_reactions,
                                            },
                                        );
                                    }
                                    out
                                })
                                .await
                                .unwrap_or_default()
                        } else {
                            probe_targets
                                .into_keys()
                                .map(|conv_id| (conv_id, false))
                                .collect()
                        };
                        if !probes.is_empty() || reply_boot_gen.is_some() {
                            sink.send(Input::FreshnessProbed {
                                boot_gen: reply_boot_gen,
                                probes,
                            });
                        }
                    }
                    StoreOp::MarkRecalledAndCheckLatest {
                        conv_id,
                        target_id,
                        cli_msg_id,
                        found_in_memory,
                        recalled_last,
                        update_conversation_preview,
                        persist_conversations,
                        op_id,
                        recall_many_id,
                    } => {
                        let conv_c = conv_id.clone();
                        let target_c = target_id.clone();
                        let cli_c = cli_msg_id.clone();
                        let recalled_last_final = if let Some(store_arc) = store_opt {
                            runtime
                                .spawn_blocking(move || {
                                    let mut store =
                                        store_arc.lock().unwrap_or_else(PoisonError::into_inner);
                                    let _ = store.mark_recalled(&conv_c, &target_c, &cli_c);
                                    let mut rl = recalled_last;
                                    if !found_in_memory
                                        && let Ok(rows) = store.messages(&conv_c, None, 1)
                                        && let Some(latest) = rows.last()
                                        && latest.kind_tag == "recalled"
                                        && ((!target_c.is_empty()
                                            && (latest.id == target_c
                                                || latest.client_id == target_c))
                                            || (!cli_c.is_empty()
                                                && (latest.id == cli_c
                                                    || latest.client_id == cli_c)))
                                    {
                                        rl = Some((latest.ts_ms, latest.is_mine));
                                    }
                                    rl
                                })
                                .await
                                .unwrap_or(recalled_last)
                        } else {
                            recalled_last
                        };
                        sink.send(Input::RemoteRecallStoreDone {
                            conv_id,
                            recalled_last: recalled_last_final,
                            update_conversation_preview,
                            persist_conversations,
                            op_id,
                            recall_many_id,
                        });
                    }
                    StoreOp::DeleteMessageAndCheckLatest {
                        conv_id,
                        msg_id,
                        cli_msg_id,
                        deleted_ts_ms,
                        mem_latest,
                        update_conversation_preview,
                        persist_conversations,
                        cloud_delete_op_id,
                    } => {
                        let conv_c = conv_id.clone();
                        let msg_c = msg_id.clone();
                        let cli_c = cli_msg_id.clone();
                        let (resolved_deleted_ts_ms, store_latest) = if let Some(store_arc) =
                            store_opt
                        {
                            runtime
                                .spawn_blocking(move || {
                                    let mut store =
                                        store_arc.lock().unwrap_or_else(PoisonError::into_inner);
                                    let target_id = if !msg_c.is_empty() {
                                        msg_c.as_str()
                                    } else {
                                        cli_c.as_str()
                                    };
                                    let mut del_ts = deleted_ts_ms;
                                    if del_ts.is_none() {
                                        let mut existing = if !target_id.is_empty() {
                                            store.message(&conv_c, target_id).ok().flatten()
                                        } else {
                                            None
                                        };
                                        if existing.is_none() && !cli_c.is_empty() {
                                            existing =
                                                store.message(&conv_c, &cli_c).ok().flatten();
                                        }
                                        if let Some(row) = existing {
                                            del_ts = Some(row.ts_ms);
                                        }
                                    }
                                    for id in crate::actions::remote_delete_store_ids(
                                        crate::actions::REMOTE_DELETE_MATCH_POLICY,
                                        &msg_c,
                                        &cli_c,
                                    ) {
                                        let _ = store.delete_message(&conv_c, &id);
                                    }
                                    let latest_preview = store
                                        .messages(&conv_c, None, 1)
                                        .ok()
                                        .and_then(|rows| rows.into_iter().last())
                                        .map(|latest| {
                                            let text = if let Some(decoded) =
                                                crate::messages::decode_db_stored(&latest)
                                            {
                                                crate::conversations::message_preview_label(
                                                    &decoded,
                                                )
                                            } else if latest.kind_tag == "recalled" {
                                                "Tin nhắn đã được thu hồi".to_owned()
                                            } else {
                                                latest.text.clone()
                                            };
                                            crate::conversations::ConversationPreview {
                                                text,
                                                date_ms: Some(latest.ts_ms),
                                                from_me: latest.is_mine,
                                            }
                                        });
                                    (del_ts, latest_preview)
                                })
                                .await
                                .unwrap_or((deleted_ts_ms, None))
                        } else {
                            (deleted_ts_ms, None)
                        };
                        sink.send(Input::RemoteDeleteStoreDone {
                            conv_id,
                            deleted_ts_ms: resolved_deleted_ts_ms,
                            mem_latest,
                            store_latest,
                            update_conversation_preview,
                            persist_conversations,
                            cloud_delete_op_id,
                        });
                    }
                    other => {
                        if let Some(store_arc) = store_opt {
                            let _ = runtime
                                .spawn_blocking(move || {
                                    let mut store =
                                        store_arc.lock().unwrap_or_else(PoisonError::into_inner);
                                    match other {
                                        StoreOp::SaveConversations(mut rows) => {
                                            let now = unix_now_ms();
                                            for row in &mut rows {
                                                row.updated_at_ms = now;
                                            }
                                            let _ = store.save_conversations(&rows);
                                        }
                                        StoreOp::SetConversationPinned { id, pinned } => {
                                            let _ = store.set_conversation_pinned(&id, pinned);
                                        }
                                        StoreOp::SetConversationUnread { id, unread } => {
                                            let _ = store.set_conversation_unread(&id, unread);
                                        }
                                        StoreOp::SetConversationPreview {
                                            id,
                                            preview_text,
                                            preview_ts_ms,
                                            preview_from_me,
                                        } => {
                                            let _ = store.set_conversation_preview(
                                                &id,
                                                &preview_text,
                                                preview_ts_ms,
                                                preview_from_me,
                                                unix_now_ms(),
                                            );
                                        }
                                        StoreOp::DeleteConversation { id } => {
                                            let _ = store.delete_conversation(&id);
                                        }
                                        StoreOp::SetPreferenceString { key, value } => {
                                            let _ = store.set_preference_string(&key, &value);
                                        }
                                        StoreOp::SetPreferenceStrings { key, values } => {
                                            let _ = store.set_preference_strings(&key, &values);
                                        }
                                        StoreOp::SetPreferenceData { key, data } => {
                                            let _ = store.set_preference_data(&key, &data);
                                        }
                                        StoreOp::SetPreferenceBool { key, value } => {
                                            let _ = store.set_preference_bool(&key, value);
                                        }
                                        StoreOp::SaveRecentSticker { sticker } => {
                                            let existing_bytes = store
                                                .get_preference_data("recentStickers")
                                                .ok()
                                                .flatten();
                                            let existing = parse_recent_stickers_bytes(
                                                existing_bytes.as_deref(),
                                            );
                                            let updated =
                                                update_recent_stickers_json(&existing, &sticker);
                                            if let Ok(bytes) = serde_json::to_vec(&updated) {
                                                let _ = store
                                                    .set_preference_data("recentStickers", &bytes);
                                            }
                                        }
                                        StoreOp::DeletePreference { key } => {
                                            let _ = store.delete_preference(&key);
                                        }
                                        StoreOp::SaveMessages {
                                            rows,
                                            preserve_existing_reactions,
                                        } => {
                                            let _ = store.save_messages_with(
                                                &rows,
                                                SaveOptions {
                                                    skip_twin_checks: false,
                                                    preserve_existing_reactions,
                                                },
                                            );
                                        }
                                        // U6
                                        StoreOp::DeleteMessage { conv_id, id } => {
                                            let _ = store.delete_message(&conv_id, &id);
                                        }
                                        StoreOp::ApplyRemoteReactionInStore {
                                            conv_candidates,
                                            msg_id,
                                            cli_msg_id,
                                            actor_uid,
                                            my_uid,
                                            is_me,
                                            r_type,
                                            r_icon,
                                            allow_duplicate_same_user,
                                            snap,
                                        } => {
                                            let mut found = None;
                                            for candidate in &conv_candidates {
                                                if found.is_some() {
                                                    break;
                                                }
                                                if !msg_id.is_empty() {
                                                    found = store
                                                        .message(candidate, &msg_id)
                                                        .ok()
                                                        .flatten();
                                                }
                                                if found.is_none() && !cli_msg_id.is_empty() {
                                                    found = store
                                                        .message(candidate, &cli_msg_id)
                                                        .ok()
                                                        .flatten();
                                                }
                                            }
                                            if let Some(row) = found
                                                && let Some(mut msg) =
                                                    crate::messages::decode_db_stored(&row)
                                            {
                                                crate::actions::mutate_reactions(
                                                    &mut msg.reactions,
                                                    &crate::actions::ReactionMutation {
                                                        actor_uid: &actor_uid,
                                                        my_uid: &my_uid,
                                                        is_me,
                                                        r_type: &r_type,
                                                        r_icon: &r_icon,
                                                        allow_duplicate_same_user,
                                                    },
                                                    |uid| {
                                                        snap.lookup_person(uid)
                                                            .map(|p| p.name)
                                                            .unwrap_or_default()
                                                    },
                                                );
                                                if let Some(wire_stored) =
                                                    olaz_wire::encode_chat_message(
                                                        &msg,
                                                        &msg.client_id,
                                                    )
                                                {
                                                    let _ = store.save_messages_with(
                                                        &[crate::messages::to_db_stored(
                                                            &wire_stored,
                                                        )],
                                                        SaveOptions {
                                                            skip_twin_checks: false,
                                                            preserve_existing_reactions: false,
                                                        },
                                                    );
                                                }
                                            }
                                        }
                                        StoreOp::LoadMentionPreviewMessages { .. }
                                        | StoreOp::LoadPreferenceString { .. }
                                        | StoreOp::ProbeAndSaveMessages { .. }
                                        | StoreOp::LoadOpenLocalMessages { .. }
                                        | StoreOp::LoadOlderStoreMessages { .. }
                                        | StoreOp::SearchMessagesPage { .. }
                                        | StoreOp::LoadMessagesAround { .. }
                                        | StoreOp::LookupMessage { .. }
                                        | StoreOp::FindLegacyQuoted { .. }
                                        | StoreOp::MarkRecalledAndCheckLatest { .. }
                                        | StoreOp::DeleteMessageAndCheckLatest { .. } => {}
                                    }
                                })
                                .await;
                        }
                    }
                }
            }
            StoreJob::LoadRecentStickers { reply } => {
                let store_opt = shared_store
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner)
                    .clone();
                let rows = if let Some(store_arc) = store_opt {
                    runtime
                        .spawn_blocking(move || {
                            let store = store_arc.lock().unwrap_or_else(PoisonError::into_inner);
                            let raw = store.get_preference_data("recentStickers").ok().flatten();
                            parse_recent_stickers_bytes(raw.as_deref())
                        })
                        .await
                        .unwrap_or_default()
                } else {
                    Vec::new()
                };
                let _ = reply.send(rows);
            }
            StoreJob::LoadStickerSuggestPref { reply } => {
                let store_opt = shared_store
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner)
                    .clone();
                let enabled = if let Some(store_arc) = store_opt {
                    runtime
                        .spawn_blocking(move || {
                            let store = store_arc.lock().unwrap_or_else(PoisonError::into_inner);
                            store
                                .get_preference_bool("stickerSuggest", true)
                                .unwrap_or(true)
                        })
                        .await
                        .unwrap_or(true)
                } else {
                    true
                };
                let _ = reply.send(enabled);
            }
            StoreJob::ResolveMessageIdsLookup {
                conv_id,
                msg_id,
                cli_msg_id,
                reply,
            } => {
                let store_opt = shared_store
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner)
                    .clone();
                let msg_id_fb = msg_id.clone();
                let cli_msg_id_fb = cli_msg_id.clone();
                let res = if let Some(store_arc) = store_opt {
                    runtime
                        .spawn_blocking(move || {
                            let store = store_arc.lock().unwrap_or_else(PoisonError::into_inner);
                            let mut resolved_cli = cli_msg_id.trim().to_owned();
                            if resolved_cli.is_empty()
                                && let Ok(Some(stored)) = store.message(&conv_id, &msg_id)
                            {
                                let col_cli = stored.client_id.trim();
                                if !col_cli.is_empty() {
                                    resolved_cli = col_cli.to_owned();
                                } else if let Ok(Value::Object(map)) =
                                    serde_json::from_slice::<Value>(&stored.raw_json_data)
                                {
                                    let raw_cli = map
                                        .get("clientId")
                                        .or_else(|| map.get("cliMsgId"))
                                        .and_then(|v| match v {
                                            Value::String(s) => Some(s.trim().to_owned()),
                                            Value::Number(n) => Some(n.to_string()),
                                            _ => None,
                                        })
                                        .unwrap_or_default();
                                    if !raw_cli.is_empty() {
                                        resolved_cli = raw_cli;
                                    }
                                }
                            }
                            if resolved_cli.is_empty() {
                                resolved_cli = msg_id.clone();
                            }
                            let mut effective_msg_id = msg_id.trim().to_owned();
                            let mut need_history = false;
                            if effective_msg_id.is_empty() || effective_msg_id == resolved_cli {
                                if let Ok(Some(stored)) = store.message(&conv_id, &resolved_cli)
                                    && !stored.id.is_empty()
                                    && stored.id != resolved_cli
                                {
                                    effective_msg_id = stored.id;
                                } else {
                                    need_history = true;
                                }
                            }
                            (effective_msg_id, resolved_cli, need_history)
                        })
                        .await
                        .unwrap_or_else(|_| {
                            let cli = cli_msg_id_fb.trim();
                            let r = if cli.is_empty() {
                                msg_id_fb.clone()
                            } else {
                                cli.to_owned()
                            };
                            let eff = msg_id_fb.trim().to_owned();
                            let need = eff.is_empty() || eff == r;
                            (eff, r, need)
                        })
                } else {
                    let cli = cli_msg_id_fb.trim();
                    let r = if cli.is_empty() {
                        msg_id_fb.clone()
                    } else {
                        cli.to_owned()
                    };
                    let eff = msg_id_fb.trim().to_owned();
                    let need = eff.is_empty() || eff == r;
                    (eff, r, need)
                };
                let _ = reply.send(res);
            }
            StoreJob::UpgradeMessageId {
                conv_id,
                old_id,
                new_id,
                client_id,
                _guard,
            } => {
                let store_opt = shared_store
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner)
                    .clone();
                if let Some(store_arc) = store_opt {
                    let _ = runtime
                        .spawn_blocking(move || {
                            let mut store =
                                store_arc.lock().unwrap_or_else(PoisonError::into_inner);
                            let _ =
                                store.upgrade_message_id(&conv_id, &old_id, &new_id, &client_id);
                        })
                        .await;
                }
            }
            StoreJob::FlushOp {
                op_id,
                result,
                sink,
                _guard,
            } => {
                sink.send(Input::OpStoreFlushed { op_id, result });
            }
            // U11
            StoreJob::CloudRefreshQuery {
                op_id,
                server_snapshot,
                media_ids_by_conv,
                sink,
                _guard,
            } => {
                let store_opt = shared_store
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner)
                    .clone();
                let (sql_summaries, existing_ids_by_conv) = if let Some(store_arc) = store_opt {
                    tokio::task::spawn_blocking(move || {
                        let store = store_arc.lock().unwrap_or_else(PoisonError::into_inner);
                        let summaries = store.cloud_media_aggregation().unwrap_or_default();
                        let mut existing: BTreeMap<String, BTreeSet<String>> = BTreeMap::new();
                        for (cid, ids) in media_ids_by_conv {
                            if ids.is_empty() {
                                continue;
                            }
                            let found = store
                                .existing_message_ids(&cid, &ids)
                                .unwrap_or_default()
                                .into_iter()
                                .collect();
                            existing.insert(cid, found);
                        }
                        (summaries, existing)
                    })
                    .await
                    .unwrap_or_default()
                } else {
                    (Vec::new(), BTreeMap::new())
                };
                sink.send(Input::CloudRefreshLoaded {
                    op_id,
                    server_snapshot,
                    sql_summaries,
                    existing_ids_by_conv,
                });
            }
            StoreJob::CloudListQuery {
                op_id,
                conv_id,
                excluding_self,
                kind_tags,
                sort_by_size,
                ascending,
                offset,
                limit,
                memory_media,
                sink,
                _guard,
            } => {
                let store_opt = shared_store
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner)
                    .clone();
                if let Some(store_arc) = store_opt {
                    let (existing_ids_by_conv, sql_items, sql_has_more, sql_error) =
                        tokio::task::spawn_blocking(move || {
                            let store = store_arc.lock().unwrap_or_else(PoisonError::into_inner);
                            let mut existing: BTreeMap<String, BTreeSet<String>> = BTreeMap::new();
                            let mut has_unsynced = false;
                            for (cid, all_ids, matching_ids) in memory_media {
                                let found: BTreeSet<String> = store
                                    .existing_message_ids(&cid, &all_ids)
                                    .unwrap_or_default()
                                    .into_iter()
                                    .collect();
                                if matching_ids.iter().any(|id| !found.contains(id)) {
                                    has_unsynced = true;
                                }
                                existing.insert(cid, found);
                            }
                            if !has_unsynced {
                                let q = CloudMediaQuery {
                                    conv_id,
                                    excluding_conv_id: excluding_self,
                                    kind_tags,
                                    sort_by_size,
                                    ascending,
                                    offset,
                                    limit,
                                };
                                match store.cloud_media_items(&q) {
                                    Ok((items, has_more)) => (existing, items, has_more, false),
                                    Err(_) => (existing, Vec::new(), false, true),
                                }
                            } else {
                                let q = CloudMediaQuery {
                                    conv_id,
                                    excluding_conv_id: excluding_self,
                                    kind_tags,
                                    sort_by_size,
                                    ascending,
                                    offset: 0,
                                    limit: offset.saturating_add(limit),
                                };
                                let (items, has_more) =
                                    store.cloud_media_items(&q).unwrap_or_default();
                                (existing, items, has_more, false)
                            }
                        })
                        .await
                        .unwrap_or_else(|_| (BTreeMap::new(), Vec::new(), false, true));
                    sink.send(Input::CloudListStoreDone {
                        op_id,
                        store_present: true,
                        existing_ids_by_conv,
                        sql_items,
                        sql_has_more,
                        sql_error,
                    });
                } else {
                    sink.send(Input::CloudListStoreDone {
                        op_id,
                        store_present: false,
                        existing_ids_by_conv: BTreeMap::new(),
                        sql_items: Vec::new(),
                        sql_has_more: false,
                        sql_error: false,
                    });
                }
            }
            StoreJob::CloudLookupMessage {
                op_id,
                conv_id,
                msg_id,
                sink,
                _guard,
            } => {
                let store_opt = shared_store
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner)
                    .clone();
                let message = if let Some(store_arc) = store_opt {
                    tokio::task::spawn_blocking(move || {
                        let store = store_arc.lock().unwrap_or_else(PoisonError::into_inner);
                        store
                            .message(&conv_id, &msg_id)
                            .ok()
                            .flatten()
                            .and_then(|row| decode_db_stored(&row))
                    })
                    .await
                    .ok()
                    .flatten()
                } else {
                    None
                };
                sink.send(Input::CloudLookupMessageDone {
                    op_id,
                    message: message.map(Box::new),
                });
            }
            // U15
            StoreJob::MediaLookupMessage {
                flight_id,
                conv_id,
                msg_id,
                sink,
                _guard,
            } => {
                let store_opt = shared_store
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner)
                    .clone();
                let message = if let Some(store_arc) = store_opt {
                    tokio::task::spawn_blocking(move || {
                        let store = store_arc.lock().unwrap_or_else(PoisonError::into_inner);
                        store
                            .message(&conv_id, &msg_id)
                            .ok()
                            .flatten()
                            .and_then(|row| decode_db_stored(&row))
                    })
                    .await
                    .ok()
                    .flatten()
                } else {
                    None
                };
                sink.send(Input::MediaStoreMessageLoaded { flight_id, message });
            }
            StoreJob::MediaLookupFileMessage {
                op_id,
                conv_id,
                msg_id,
                sink,
                _guard,
            } => {
                let store_opt = shared_store
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner)
                    .clone();
                let message = if let Some(store_arc) = store_opt {
                    tokio::task::spawn_blocking(move || {
                        let store = store_arc.lock().unwrap_or_else(PoisonError::into_inner);
                        store
                            .message(&conv_id, &msg_id)
                            .ok()
                            .flatten()
                            .and_then(|row| decode_db_stored(&row))
                    })
                    .await
                    .ok()
                    .flatten()
                } else {
                    None
                };
                sink.send(Input::MediaFileMessageLoaded { op_id, message });
            }
            StoreJob::MediaQuerySharedMedia {
                op_id,
                conv_id,
                kind,
                after_cursor,
                limit,
                sink,
                _guard,
            } => {
                let store_opt = shared_store
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner)
                    .clone();
                let conv_id_out = conv_id.clone();
                let outcome = if let Some(store_arc) = store_opt {
                    let tags = kind.kind_tags();
                    let limit_i64 = i64::try_from(limit).unwrap_or(60);
                    let conv_for_decode = conv_id.clone();
                    match tokio::task::spawn_blocking(move || {
                        let store = store_arc.lock().unwrap_or_else(PoisonError::into_inner);
                        store.shared_media_raw(&conv_id, &tags, after_cursor.as_deref(), limit_i64)
                    })
                    .await
                    {
                        Ok(Ok(page)) => {
                            let items: Vec<ChatMessage> = page
                                .rows
                                .iter()
                                .filter_map(|raw| {
                                    let Value::Object(dict) =
                                        serde_json::from_slice::<Value>(raw).ok()?
                                    else {
                                        return None;
                                    };
                                    ChatMessage::from_json(&dict, &conv_for_decode)
                                })
                                .collect();
                            SharedMediaLoadOutcome::StoreOk(SharedMediaPage {
                                items,
                                cursor: page.cursor,
                                more: page.more,
                            })
                        }
                        _ => SharedMediaLoadOutcome::StoreError,
                    }
                } else {
                    SharedMediaLoadOutcome::NoStore
                };
                sink.send(Input::MediaSharedMediaLoaded {
                    op_id,
                    conv_id: conv_id_out,
                    kind,
                    limit,
                    outcome,
                });
            }
            StoreJob::Drain(tx) => {
                let _ = tx.send(());
            }
        }
    }
}

struct HostWorkerDeps<T: Transport + 'static> {
    rx: mpsc::UnboundedReceiver<HostJob>,
    client: Arc<SessionClient<T>>,
    host: Arc<dyn Host>,
    shared_store: SharedStoreSlot,
    store_tx: mpsc::UnboundedSender<StoreJob>,
    ws_driver: Arc<dyn WsDriver>,
    ws_active_gen: Arc<Mutex<Option<u64>>>,
    lp_active_gen: Arc<Mutex<Option<u64>>>,
    lp_timer_abort: Arc<Mutex<Option<AbortHandle>>>,
    suppress_long_poll: bool,
    active_tasks: Arc<Mutex<Vec<AbortHandle>>>,
    runtime: Handle,
}

async fn run_host_worker<T: Transport + 'static>(deps: HostWorkerDeps<T>) {
    let HostWorkerDeps {
        mut rx,
        client,
        host,
        shared_store,
        store_tx,
        ws_driver,
        ws_active_gen,
        lp_active_gen,
        lp_timer_abort,
        suppress_long_poll,
        active_tasks,
        runtime,
    } = deps;
    while let Some(job) = rx.recv().await {
        match job {
            HostJob::LoadSavedSession {
                boot_gen,
                sink,
                _guard,
            } => {
                let saved = host.load_saved_session().await;
                let (restored, account, ws_endpoints) = match saved
                    .as_deref()
                    .and_then(|json| serde_json::from_str::<NetSessionSnapshot>(json).ok())
                {
                    Some(snap) => {
                        let ok = client.restore(snap);
                        let account = if ok { client.account() } else { None };
                        let ws = client.domains().ws;
                        (ok, account, ws)
                    }
                    None => (false, None, Vec::new()),
                };
                sink.send(Input::SavedSessionLoaded {
                    boot_gen,
                    restored,
                    account,
                    ws_endpoints,
                });
            }
            HostJob::LoadLegacyCookie {
                boot_gen,
                sink,
                _guard,
            } => {
                let Some(cookie) = host.load_legacy_cookie().await else {
                    sink.send(Input::LegacyCookieResult {
                        boot_gen,
                        account: None,
                        ws_endpoints: Vec::new(),
                        profile_synced: false,
                    });
                    continue;
                };
                // Spawn the network `complete_login` so it stays cancellable without blocking
                // subsequent host calls.
                let client = Arc::clone(&client);
                let net_guard = sink.track();
                let handle = runtime
                    .spawn(async move {
                        client.with_session(|s| {
                            if let Some(imei) = cookie.imei
                                && imei.chars().count() == 69
                            {
                                s.imei = imei;
                            }
                            s.zpw_sek = Some(cookie.zpw_sek);
                        });
                        match client.complete_login_detailed().await {
                            Ok((account, profile_synced)) if client.is_authenticated() => {
                                let ws_endpoints = client.domains().ws;
                                sink.send(Input::LegacyCookieResult {
                                    boot_gen,
                                    account: Some(account),
                                    ws_endpoints,
                                    profile_synced,
                                });
                            }
                            _ => {
                                client.with_session(|s| {
                                    s.zpw_sek = None;
                                    s.account = None;
                                    s.secret_key = None;
                                });
                                sink.send(Input::LegacyCookieResult {
                                    boot_gen,
                                    account: None,
                                    ws_endpoints: Vec::new(),
                                    profile_synced: false,
                                });
                            }
                        }
                        drop(net_guard);
                    })
                    .abort_handle();
                let mut list = active_tasks.lock().unwrap_or_else(PoisonError::into_inner);
                list.retain(|h| !h.is_finished());
                list.push(handle);
            }
            HostJob::SetPref { key, value, _guard } => {
                host.set_pref(key, value).await;
            }
            HostJob::PrepareStore {
                token,
                user_id,
                account,
                identities,
                sink,
                _guard,
            } => {
                let my_uid = user_id.clone();
                let my_avatar = (!account.avatar.is_empty()).then(|| account.avatar.clone());
                let self_conv_id = if account.send2me_id.is_empty() {
                    Some(account.user_id.clone())
                } else {
                    Some(account.send2me_id.clone())
                };
                host.prepare_store(user_id, *account).await;
                let transport_state = host.load_transport_state().await;
                let store_opt = shared_store
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner)
                    .clone();
                let local_hydration = if let Some(store_arc) = store_opt {
                    runtime
                        .spawn_blocking(move || {
                            let mut store =
                                store_arc.lock().unwrap_or_else(PoisonError::into_inner);
                            load_local_account_from_store(
                                &mut store,
                                &my_uid,
                                my_avatar.as_deref(),
                                self_conv_id.as_deref(),
                                &identities,
                            )
                        })
                        .await
                        .ok()
                } else {
                    None
                };
                sink.send(Input::PrepareStoreDone {
                    token,
                    transport_state,
                    local_hydration: local_hydration.map(Box::new),
                });
            }
            HostJob::StartWs {
                params,
                sink,
                _guard,
            } => {
                let run_ws = host.on_ws_started(params.endpoints.clone()).await;
                if run_ws
                    && *ws_active_gen.lock().unwrap_or_else(PoisonError::into_inner)
                        == Some(params.ws_gen)
                {
                    ws_driver.start(params, sink, &runtime);
                }
            }
            HostJob::StartLpInitial {
                lp_gen,
                delay,
                sink,
                _guard,
            } => {
                let run_lp = host.on_long_poll_started().await;
                if !run_lp {
                    let mut active = lp_active_gen.lock().unwrap_or_else(PoisonError::into_inner);
                    if *active == Some(lp_gen) {
                        *active = None;
                    }
                } else if !suppress_long_poll
                    && *lp_active_gen.lock().unwrap_or_else(PoisonError::into_inner) == Some(lp_gen)
                {
                    let handle = runtime
                        .spawn(async move {
                            tokio::time::sleep(delay).await;
                            sink.send(Input::LpTick { lp_gen });
                        })
                        .abort_handle();
                    let prev = lp_timer_abort
                        .lock()
                        .unwrap_or_else(PoisonError::into_inner)
                        .replace(handle);
                    if let Some(old) = prev {
                        old.abort();
                    }
                }
            }
            HostJob::StartBootstrap { sink, _guard } => {
                if host.on_bootstrap_started().await {
                    sink.send(Input::Command(Command::Bootstrap {
                        now_ms: unix_now_ms(),
                    }));
                }
            }
            // U4-bootstrap
            HostJob::ApplyMutes { mutes, _guard } => {
                host.apply_mutes(mutes).await;
            }
            HostJob::RefreshCloud { _guard } => {
                host.refresh_cloud().await;
            }
            HostJob::OnOpenConversationSync {
                conv_id,
                changed,
                _guard,
            } => {
                host.on_open_conversation_sync(conv_id, changed).await;
            }
            HostJob::OnCloseConversation { _guard } => {
                host.on_close_conversation().await;
            }
            HostJob::RefreshBoardPins { conv_id, _guard } => {
                host.refresh_board_pins(conv_id).await;
            }
            // U12
            HostJob::RefreshBoardPinsThen {
                conv_id,
                continuation,
                sink,
                _guard,
            } => {
                host.refresh_board_pins(conv_id.clone()).await;
                sink.send(Input::PollBoardRefreshed {
                    conv_id,
                    continuation,
                });
            }
            HostJob::CancelAllPollDebounces { _guard } => {
                host.cancel_all_poll_debounces().await;
            }
            HostJob::MarkReadBoundary {
                conv_id,
                seen_target,
                _guard,
            } => {
                host.mark_read_boundary(conv_id, seen_target).await;
            }
            HostJob::ApplyRemoteReaction {
                conv_id,
                msg_id,
                cli_msg_id,
                sender_id,
                r_type,
                r_icon,
                event_id,
                react_client_id,
                sender_name,
                now_ms,
                sink,
                _guard,
            } => {
                let approved = host
                    .apply_remote_reaction(
                        conv_id.clone(),
                        msg_id.clone(),
                        cli_msg_id.clone(),
                        sender_id.clone(),
                        r_type.clone(),
                        r_icon.clone(),
                        event_id.clone(),
                        react_client_id.clone(),
                        sender_name.clone(),
                    )
                    .await;
                if approved {
                    let effective_now = if now_ms > 0 { now_ms } else { unix_now_ms() };
                    sink.send(Input::RemoteReactionApproved {
                        conv_id,
                        msg_id,
                        cli_msg_id,
                        sender_id,
                        r_type,
                        r_icon,
                        event_id,
                        react_client_id,
                        sender_name,
                        now_ms: effective_now,
                    });
                }
            }
            HostJob::ApplyRemoteRecall {
                conv_id,
                msg_id,
                cli_msg_id,
                update_conversation_preview,
                persist_conversations,
                op_id,
                recall_many_id,
                sink,
                _guard,
            } => {
                let approved = host
                    .apply_remote_recall(
                        conv_id.clone(),
                        msg_id.clone(),
                        cli_msg_id.clone(),
                        update_conversation_preview,
                        persist_conversations,
                    )
                    .await;
                if approved {
                    sink.send(Input::RemoteRecallApproved {
                        conv_id,
                        msg_id,
                        cli_msg_id,
                        update_conversation_preview,
                        persist_conversations,
                        op_id,
                        recall_many_id,
                    });
                } else if op_id.is_some() || recall_many_id.is_some() {
                    sink.send(Input::RemoteRecallSkipped {
                        op_id,
                        recall_many_id,
                    });
                }
            }
            HostJob::ApplyRemoteDelete {
                conv_id,
                msg_id,
                cli_msg_id,
                update_conversation_preview,
                persist_conversations,
                cloud_delete_op_id,
                sink,
                _guard,
            } => {
                let approved = host
                    .apply_remote_delete(
                        conv_id.clone(),
                        msg_id.clone(),
                        cli_msg_id.clone(),
                        update_conversation_preview,
                        persist_conversations,
                    )
                    .await;
                if approved {
                    sink.send(Input::RemoteDeleteApproved {
                        conv_id,
                        msg_id,
                        cli_msg_id,
                        update_conversation_preview,
                        persist_conversations,
                        cloud_delete_op_id,
                    });
                } else if let Some(op_id) = cloud_delete_op_id {
                    sink.send(Input::CloudRemoteDeleteDone { op_id });
                }
            }
            HostJob::DecryptEnvelope {
                payload,
                default_cmd,
                fallback_conv_id,
                is_group_hint,
                increment_unread,
                notify_incoming,
                persist_conversations,
                probe_freshness,
                poll_batch_done,
                op_id,
                sink,
                _guard,
            } => {
                let decrypted = host.decrypt_envelope(payload).await;
                sink.send(Input::DecryptedEnvelopeReady {
                    payload: decrypted,
                    default_cmd,
                    fallback_conv_id,
                    is_group_hint,
                    increment_unread,
                    notify_incoming,
                    persist_conversations,
                    probe_freshness,
                    poll_batch_done,
                    op_id,
                });
            }
            HostJob::MarkE2eeConversations { conv_ids, _guard } => {
                host.mark_e2ee_conversations(conv_ids).await;
            }
            HostJob::NotePollMessages { messages, _guard } => {
                host.note_poll_messages(messages).await;
            }
            HostJob::NotifyIncomingMessages { messages, _guard } => {
                host.notify_incoming_messages(messages).await;
            }
            HostJob::ShowBatchTyping {
                conv_id,
                sender_id,
                _guard,
            } => {
                host.show_batch_typing(conv_id, sender_id).await;
            }
            HostJob::TransportBatchSettled { _guard } => {
                host.transport_batch_settled().await;
            }
            HostJob::EngineLog { message, _guard } => {
                host.engine_log(message).await;
            }
            HostJob::OfferFirstLoginTransfer { force, _guard } => {
                host.offer_first_login_transfer(force).await;
            }
            HostJob::DetachStore { _guard } => {
                let (tx, rx) = oneshot::channel();
                if store_tx.send(StoreJob::Drain(tx)).is_ok() {
                    let _ = rx.await;
                }
                *shared_store.lock().unwrap_or_else(PoisonError::into_inner) = None;
            }
            HostJob::ResetDomains { _guard } => {
                host.reset_domains().await;
            }
            HostJob::PersistSession {
                snapshot_json,
                _guard,
            } => {
                host.persist_session(snapshot_json).await;
            }
            HostJob::ClearSession { _guard } => {
                host.clear_session().await;
            }
            HostJob::MarkExpired {
                snapshot_json,
                _guard,
            } => {
                // U4-bootstrap: Swift `markExpired` calls `hostResetDomains` and closes SQLite,
                // so drain pending store ops and detach the shared store handle first.
                let (tx, rx) = oneshot::channel();
                if store_tx.send(StoreJob::Drain(tx)).is_ok() {
                    let _ = rx.await;
                }
                *shared_store.lock().unwrap_or_else(PoisonError::into_inner) = None;
                host.mark_expired(snapshot_json).await;
            }
            HostJob::PersistPollState { state, _guard } => {
                host.persist_poll_state(state).await;
            }
            HostJob::PersistWsCursors { cursors, _guard } => {
                host.persist_ws_cursors(cursors).await;
            }
            HostJob::ApplyBatch {
                cmd,
                increment_unread,
                notify_incoming,
                payload,
                poll_batch_done,
                sink,
                _guard,
            } => {
                match host
                    .on_batch_received(cmd, increment_unread, notify_incoming, payload.clone())
                    .await
                {
                    BatchHookOutcome::IngestInCore(decrypted) => {
                        sink.send(Input::DecryptedEnvelopeReady {
                            payload: decrypted,
                            default_cmd: cmd.unwrap_or(0),
                            fallback_conv_id: None,
                            is_group_hint: None,
                            increment_unread,
                            notify_incoming,
                            persist_conversations: true,
                            probe_freshness: false,
                            poll_batch_done,
                            op_id: None,
                        });
                    }
                    BatchHookOutcome::Suppressed => {
                        host.transport_batch_settled().await;
                        if let Some((lp_gen, drain_id)) = poll_batch_done {
                            sink.send(Input::PollBatchApplied {
                                lp_gen,
                                drain_id,
                                delta: crate::conversations::BatchApplyDelta::default(),
                            });
                        }
                    }
                    BatchHookOutcome::DelegateToLegacy => {
                        let delta = host
                            .apply_batch(cmd, increment_unread, notify_incoming, payload)
                            .await;
                        if let Some((lp_gen, drain_id)) = poll_batch_done {
                            sink.send(Input::PollBatchApplied {
                                lp_gen,
                                drain_id,
                                delta,
                            });
                        } else if delta.applied_count > 0
                            || !delta.updates.is_empty()
                            || !delta.preview_overrides.is_empty()
                        {
                            sink.send(Input::BatchDeltaApplied { delta });
                        }
                    }
                }
            }
            HostJob::ApplyParsedEvents {
                cmd,
                increment_unread,
                notify_incoming,
                envelope,
                sink,
                _guard,
            } => {
                match host
                    .on_parsed_events_received(cmd, increment_unread, notify_incoming, &envelope)
                    .await
                {
                    ParsedEventsHookOutcome::IngestInCore => {
                        sink.send(Input::TypedEnvelopeReady {
                            cmd,
                            increment_unread,
                            notify_incoming,
                            envelope,
                        });
                    }
                    ParsedEventsHookOutcome::Suppressed => {
                        host.transport_batch_settled().await;
                    }
                    ParsedEventsHookOutcome::DelegateToLegacy => {
                        let delta = host
                            .apply_parsed_events(cmd, increment_unread, notify_incoming, envelope)
                            .await;
                        if delta.applied_count > 0
                            || !delta.updates.is_empty()
                            || !delta.preview_overrides.is_empty()
                        {
                            sink.send(Input::BatchDeltaApplied { delta });
                        }
                    }
                }
            }
            HostJob::MobileSync { events, _guard } => {
                host.mobile_sync(events).await;
            }
            HostJob::E2eeSignal {
                cmd,
                payload,
                _guard,
            } => {
                host.e2ee_signal(cmd, payload).await;
            }
            HostJob::E2eeDeliverReports {
                cmd,
                payload,
                _guard,
            } => {
                host.e2ee_deliver_reports(cmd, payload).await;
            }
            HostJob::E2eeConnected { uid, _guard } => {
                host.e2ee_connected(uid).await;
            }
            HostJob::E2eeDisconnected { _guard } => {
                host.e2ee_disconnected().await;
            }
            HostJob::VoipControl {
                act,
                raw_data,
                data,
                _guard,
            } => {
                host.voip_control(act, raw_data, data).await;
            }
            HostJob::ShowTyping {
                conv_id,
                uid,
                on_pc,
                _guard,
            } => {
                host.show_typing(conv_id, uid, on_pc).await;
            }
            HostJob::ShowCard {
                conv_id,
                text,
                _guard,
            } => {
                host.show_card(conv_id, text).await;
            }
            HostJob::PinTopic { conv_id, _guard } => {
                host.pin_topic(conv_id).await;
            }
            HostJob::GroupNotice {
                act,
                data,
                ts,
                _guard,
            } => {
                host.group_notice(act, data, ts).await;
            }
            HostJob::Mute {
                conv_id,
                set,
                start,
                start_explicit,
                duration,
                _guard,
            } => {
                host.mute(conv_id, set, start, start_explicit, duration)
                    .await;
            }
            // U11
            HostJob::CloudResolveMedia {
                op_id,
                conv_id,
                msg_id,
                kind,
                sink,
                _guard,
            } => {
                let outcome = host.resolve_media(conv_id, msg_id, kind).await;
                let file_size = match &outcome {
                    MediaResolutionOutcome::File(path) => std::fs::metadata(path)
                        .ok()
                        .and_then(|m| i64::try_from(m.len()).ok()),
                    _ => None,
                };
                sink.send(Input::CloudResolveMediaDone {
                    op_id,
                    outcome,
                    file_size,
                });
            }
            HostJob::CloudResolveFile {
                op_id,
                conv_id,
                msg_id,
                name,
                url,
                sink,
                _guard,
            } => {
                let outcome = host.resolve_file(conv_id, msg_id, name, url).await;
                let file_size = match &outcome {
                    FileResolutionOutcome::Ready(path) => std::fs::metadata(path)
                        .ok()
                        .and_then(|m| i64::try_from(m.len()).ok()),
                    _ => None,
                };
                sink.send(Input::CloudResolveFileDone {
                    op_id,
                    outcome,
                    file_size,
                });
            }
            // U13
            HostJob::SendE2eeSticker {
                send_id,
                conv_id,
                cate_id,
                sticker_id,
                client_id,
                sink,
                guard,
            } => {
                let host = Arc::clone(&host);
                tokio::spawn(async move {
                    let result = host
                        .send_e2ee_sticker(conv_id, cate_id, sticker_id, client_id)
                        .await;
                    sink.send(Input::SendStickerDone { send_id, result });
                    drop(guard);
                });
            }
            HostJob::SendE2eeContactCard {
                card_send_id,
                conv_id,
                client_id,
                contact_uid,
                title,
                phone,
                avatar,
                qr_code_url,
                sink,
                guard,
            } => {
                let host = Arc::clone(&host);
                tokio::spawn(async move {
                    let result = host
                        .send_e2ee_contact_card(
                            conv_id,
                            client_id,
                            contact_uid,
                            title,
                            phone,
                            avatar,
                            qr_code_url,
                        )
                        .await;
                    sink.send(Input::ContactCardSendDone {
                        card_send_id,
                        result,
                    });
                    drop(guard);
                });
            }
            HostJob::Drain(tx) => {
                let _ = tx.send(());
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::time::Duration;

    use olaz_net::mock::MockTransport;

    use super::*;
    use crate::actor::CoreHandle;
    use crate::input::Command;

    struct SlowOrderedHost {
        log: Mutex<Vec<&'static str>>,
        active: AtomicUsize,
        max_concurrent: AtomicUsize,
    }

    impl SlowOrderedHost {
        fn new() -> Self {
            Self {
                log: Mutex::new(Vec::new()),
                active: AtomicUsize::new(0),
                max_concurrent: AtomicUsize::new(0),
            }
        }

        async fn record(&self, name: &'static str, delay_ms: u64) {
            let now = self.active.fetch_add(1, Ordering::SeqCst) + 1;
            self.max_concurrent.fetch_max(now, Ordering::SeqCst);
            tokio::time::sleep(Duration::from_millis(delay_ms)).await;
            self.log
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .push(name);
            self.active.fetch_sub(1, Ordering::SeqCst);
        }
    }

    #[async_trait]
    impl Host for SlowOrderedHost {
        async fn load_saved_session(&self) -> Option<String> {
            None
        }
        async fn load_legacy_cookie(&self) -> Option<LegacyCookie> {
            None
        }
        async fn set_pref(&self, _key: String, _value: String) {}
        async fn prepare_store(&self, _user_id: String, _account: LoginAccount) {}
        async fn start_bootstrap(&self) {}
        async fn offer_first_login_transfer(&self, _force: bool) {}
        async fn reset_domains(&self) {
            self.record("reset_domains", 5).await;
        }
        async fn persist_session(&self, _snapshot_json: String) {}
        async fn clear_session(&self) {
            // Slower than reset_domains: serial execution must still finish clear_session first.
            self.record("clear_session", 30).await;
        }
        async fn mark_expired(&self, _snapshot_json: String) {}
        async fn persist_poll_state(&self, _state: PollState) {}
        async fn persist_ws_cursors(&self, _cursors: CursorMap) {}
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
        async fn mobile_sync(&self, _events: Vec<MobileSyncEvent>) {}
        async fn e2ee_signal(&self, _cmd: u16, _payload: Map<String, Value>) {}
        async fn e2ee_deliver_reports(&self, _cmd: u16, _payload: Map<String, Value>) {}
        async fn e2ee_connected(&self, _uid: String) {}
        async fn e2ee_disconnected(&self) {}
        async fn voip_control(&self, _act: String, _raw_data: Value, _data: Map<String, Value>) {}
        async fn show_typing(&self, _conv_id: String, _uid: String, _on_pc: bool) {}
        async fn pin_topic(&self, _conv_id: String) {}
        async fn group_notice(&self, _act: String, _data: Map<String, Value>, _ts: i64) {}
        async fn mute(
            &self,
            _conv_id: String,
            _set: bool,
            _start: i64,
            _start_explicit: bool,
            _duration: i64,
        ) {
        }
    }

    #[tokio::test]
    async fn host_calls_run_serially_in_emitted_order() {
        let host = Arc::new(SlowOrderedHost::new());
        let client = Arc::new(SessionClient::new(
            MockTransport::scripted(vec![]),
            "imei-1".to_owned(),
            "Mac".to_owned(),
        ));
        let runner = Arc::new(SessionEffectRunner::new(
            client,
            Arc::clone(&host) as Arc<dyn Host>,
            Handle::current(),
        ));
        let core = CoreHandle::start(runner, Handle::current());
        core.send(Command::LogOut);
        core.wait_idle().await;

        assert_eq!(host.max_concurrent.load(Ordering::SeqCst), 1);
        assert_eq!(
            *host.log.lock().unwrap_or_else(PoisonError::into_inner),
            vec!["clear_session", "reset_domains"]
        );
        core.stop();
    }

    #[tokio::test]
    async fn flush_host_waits_for_returned_batch_delta_to_reach_actor() {
        struct DelayedDeltaHost {
            entered: Arc<tokio::sync::Notify>,
            release: Arc<tokio::sync::Notify>,
        }

        #[async_trait]
        impl Host for DelayedDeltaHost {
            async fn load_saved_session(&self) -> Option<String> {
                None
            }
            async fn load_legacy_cookie(&self) -> Option<LegacyCookie> {
                None
            }
            async fn set_pref(&self, _key: String, _value: String) {}
            async fn prepare_store(&self, _user_id: String, _account: LoginAccount) {}
            async fn start_bootstrap(&self) {}
            async fn offer_first_login_transfer(&self, _force: bool) {}
            async fn reset_domains(&self) {}
            async fn persist_session(&self, _snapshot_json: String) {}
            async fn clear_session(&self) {}
            async fn mark_expired(&self, _snapshot_json: String) {}
            async fn persist_poll_state(&self, _state: PollState) {}
            async fn persist_ws_cursors(&self, _cursors: CursorMap) {}
            async fn on_batch_received(
                &self,
                _cmd: Option<u16>,
                _increment_unread: bool,
                _notify_incoming: bool,
                _payload: Map<String, Value>,
            ) -> BatchHookOutcome {
                BatchHookOutcome::DelegateToLegacy
            }
            async fn apply_batch(
                &self,
                _cmd: Option<u16>,
                _increment_unread: bool,
                _notify_incoming: bool,
                _payload: Map<String, Value>,
            ) -> BatchApplyDelta {
                self.entered.notify_waiters();
                self.release.notified().await;
                BatchApplyDelta {
                    applied_count: 1,
                    updates: vec![crate::conversations::ConvMessageDelta {
                        conv_id: "u42".to_owned(),
                        preview_text: "hello".to_owned(),
                        preview_date_ms: 1_700_000_000_000,
                        preview_from_me: false,
                        is_mine: false,
                        sender_name: "Peer 42".to_owned(),
                        sender_avatar: None,
                        unread_delta: 1,
                    }],
                    preview_overrides: Vec::new(),
                    persist_conversations: false,
                }
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
            async fn mobile_sync(&self, _events: Vec<MobileSyncEvent>) {}
            async fn e2ee_signal(&self, _cmd: u16, _payload: Map<String, Value>) {}
            async fn e2ee_deliver_reports(&self, _cmd: u16, _payload: Map<String, Value>) {}
            async fn e2ee_connected(&self, _uid: String) {}
            async fn e2ee_disconnected(&self) {}
            async fn voip_control(
                &self,
                _act: String,
                _raw_data: Value,
                _data: Map<String, Value>,
            ) {
            }
            async fn show_typing(&self, _conv_id: String, _uid: String, _on_pc: bool) {}
            async fn pin_topic(&self, _conv_id: String) {}
            async fn group_notice(&self, _act: String, _data: Map<String, Value>, _ts: i64) {}
            async fn mute(
                &self,
                _conv_id: String,
                _set: bool,
                _start: i64,
                _start_explicit: bool,
                _duration: i64,
            ) {
            }
        }

        struct SinkCaptureRunner<T: Transport + 'static> {
            inner: Arc<SessionEffectRunner<T>>,
            sink: Mutex<Option<ActorSink>>,
        }

        impl<T: Transport + 'static> EffectRunner for SinkCaptureRunner<T> {
            fn dispatch(&self, effects: Vec<Effect>, sink: ActorSink) {
                *self.sink.lock().unwrap_or_else(PoisonError::into_inner) = Some(sink.clone());
                self.inner.dispatch(effects, sink);
            }

            fn shutdown(&self) {
                self.inner.shutdown();
            }
        }

        let entered = Arc::new(tokio::sync::Notify::new());
        let release = Arc::new(tokio::sync::Notify::new());
        let host = Arc::new(DelayedDeltaHost {
            entered: Arc::clone(&entered),
            release: Arc::clone(&release),
        });
        let client = Arc::new(SessionClient::new(
            MockTransport::scripted(vec![]),
            "imei-2".to_owned(),
            "Mac".to_owned(),
        ));
        let runner = Arc::new(SessionEffectRunner::new(client, host, Handle::current()));
        let wrapper = Arc::new(SinkCaptureRunner {
            inner: Arc::clone(&runner),
            sink: Mutex::new(None),
        });
        let core = CoreHandle::start(
            Arc::clone(&wrapper) as Arc<dyn EffectRunner>,
            Handle::current(),
        );
        // Trigger a StoreOp effect to capture the actor's real sink.
        core.send(Command::UpdateConversationOnMessage {
            msg: MessagePreviewInput {
                conv_id: "u_seed".to_owned(),
                text: "seed".to_owned(),
                mentions: Vec::new(),
                preview_label: "seed".to_owned(),
                date_ms: 1_700_000_000_000,
                is_mine: false,
                sender_name: "Seed".to_owned(),
                sender_avatar: None,
            },
            increment_unread: false,
        });
        let _ = core.settle().await;
        let Some(sink) = wrapper
            .sink
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone()
        else {
            panic!("actor sink captured");
        };

        // Dispatch a host ApplyBatch whose delta is delayed until `release` fires.
        let entered_fut = entered.notified();
        tokio::pin!(entered_fut);
        entered_fut.as_mut().enable();
        runner.dispatch(
            vec![Effect::Host(HostCall::ApplyBatch {
                cmd: Some(501),
                increment_unread: true,
                notify_incoming: false,
                payload: Map::new(),
                poll_batch_done: None,
            })],
            sink,
        );
        entered_fut.await;

        let settle_task = tokio::spawn({
            let runner = Arc::clone(&runner);
            async move {
                runner.flush_host().await;
            }
        });
        // Give flush_host a chance to enqueue behind the blocked ApplyBatch.
        tokio::task::yield_now().await;
        assert!(!settle_task.is_finished());

        release.notify_waiters();
        assert!(settle_task.await.is_ok(), "flush_host task succeeded");

        // After flush_host + actor settle, the returned delta MUST already be reduced.
        let Some(version) = core.settle().await else {
            panic!("actor running");
        };
        assert!(version >= 2);
        let Some(snap) = core.full_snapshot().await else {
            panic!("snapshot available");
        };
        assert!(
            snap.conversations
                .conversations
                .iter()
                .any(|c| c.id == "u42" && c.unread == 1),
            "expected u42 from returned ApplyBatch delta, got {:?}",
            snap.conversations
        );
        core.stop();
    }

    #[derive(Default)]
    struct RecordingTypingHost {
        calls: Mutex<Vec<(String, String, bool)>>,
    }

    #[async_trait]
    impl Host for RecordingTypingHost {
        async fn load_saved_session(&self) -> Option<String> {
            None
        }
        async fn load_legacy_cookie(&self) -> Option<LegacyCookie> {
            None
        }
        async fn set_pref(&self, _key: String, _value: String) {}
        async fn prepare_store(&self, _user_id: String, _account: LoginAccount) {}
        async fn start_bootstrap(&self) {}
        async fn offer_first_login_transfer(&self, _force: bool) {}
        async fn reset_domains(&self) {}
        async fn persist_session(&self, _snapshot_json: String) {}
        async fn clear_session(&self) {}
        async fn mark_expired(&self, _snapshot_json: String) {}
        async fn persist_poll_state(&self, _state: PollState) {}
        async fn persist_ws_cursors(&self, _cursors: CursorMap) {}
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
        async fn mobile_sync(&self, _events: Vec<MobileSyncEvent>) {}
        async fn e2ee_signal(&self, _cmd: u16, _payload: Map<String, Value>) {}
        async fn e2ee_deliver_reports(&self, _cmd: u16, _payload: Map<String, Value>) {}
        async fn e2ee_connected(&self, _uid: String) {}
        async fn e2ee_disconnected(&self) {}
        async fn voip_control(&self, _act: String, _raw_data: Value, _data: Map<String, Value>) {}
        async fn show_typing(&self, conv_id: String, uid: String, on_pc: bool) {
            self.calls
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .push((conv_id, uid, on_pc));
        }
        async fn pin_topic(&self, _conv_id: String) {}
        async fn group_notice(&self, _act: String, _data: Map<String, Value>, _ts: i64) {}
        async fn mute(
            &self,
            _conv_id: String,
            _set: bool,
            _start: i64,
            _start_explicit: bool,
            _duration: i64,
        ) {
        }
    }

    #[tokio::test(start_paused = true)]
    async fn typing_expiry_runs_on_paused_time_restarts_on_reping_and_cancels_on_open() {
        use olaz_net::mock::MockTransport;

        use crate::actor::CoreHandle;
        use crate::input::Command;
        use crate::state::{CoreState, Phase};
        use crate::typing::{TYPING_DISPLAY_DURATION, TypingStatus};

        let client = Arc::new(SessionClient::new(
            MockTransport::scripted(vec![]),
            "imei-t".to_owned(),
            "Mac".to_owned(),
        ));
        let runner = Arc::new(SessionEffectRunner::new(
            client,
            Arc::new(RecordingTypingHost::default()),
            tokio::runtime::Handle::current(),
        ));
        let mut initial = CoreState::default();
        initial.session.phase = Phase::Ready;
        let core = CoreHandle::start_with_state(initial, runner, tokio::runtime::Handle::current());

        let ping = |conv: &str, name: &str, on_pc: bool| match serde_json::json!({"typing": {"convId": conv, "name": name, "isPC": on_pc}})
        {
            Value::Object(map) => map,
            other => panic!("expected object, got {other:?}"),
        };

        core.send_and_ack(Command::HandleTyping {
            state: ping("3000515", "Alice", true),
        })
        .await;
        // wait_idle returns immediately even while the 10 s expiry timer is pending.
        core.wait_idle().await;
        let Some(batch1) = core.next_changes().await else {
            panic!("expected initial typing batch");
        };
        assert_eq!(
            batch1.typing.as_ref().and_then(|m| m.get("3000515")),
            Some(&TypingStatus {
                name: "Alice".to_owned(),
                on_pc: true,
            })
        );

        // Advance 5 s: still active. Re-ping restarts the 10 s window.
        tokio::time::advance(Duration::from_secs(5)).await;
        tokio::task::yield_now().await;
        assert!(
            core.full_snapshot()
                .await
                .is_some_and(|s| s.typing.contains_key("3000515"))
        );

        core.send_and_ack(Command::HandleTyping {
            state: ping("3000515", "Alice", true),
        })
        .await;

        // 6 s after re-ping (11 s since first ping): still active because gen1 was cancelled/superseded.
        tokio::time::advance(Duration::from_secs(6)).await;
        tokio::task::yield_now().await;
        assert!(
            core.full_snapshot()
                .await
                .is_some_and(|s| s.typing.contains_key("3000515"))
        );

        // 4 more seconds (10 s since re-ping): expires cleanly.
        tokio::time::advance(Duration::from_secs(4)).await;
        let Some(batch_exp) = core.next_changes().await else {
            panic!("expected expiry typing batch");
        };
        assert!(batch_exp.typing.as_ref().is_some_and(BTreeMap::is_empty));
        assert!(
            core.full_snapshot()
                .await
                .is_some_and(|s| s.typing.is_empty())
        );

        // Opening a conversation clears its typing indicator and cancels the expiry timer.
        core.send_and_ack(Command::HandleTyping {
            state: ping("g500515", "Dana", false),
        })
        .await;
        let _ = core.next_changes().await;
        core.send_and_ack(Command::SetOpenConversation {
            id: Some("g500515".to_owned()),
        })
        .await;
        let Some(batch_cleared) = core.next_changes().await else {
            panic!("expected cleared typing batch");
        };
        assert!(
            batch_cleared
                .typing
                .as_ref()
                .is_some_and(BTreeMap::is_empty)
        );

        tokio::time::advance(TYPING_DISPLAY_DURATION + Duration::from_secs(5)).await;
        tokio::task::yield_now().await;
        assert!(
            core.full_snapshot()
                .await
                .is_some_and(|s| s.typing.is_empty())
        );

        core.stop();
    }

    #[tokio::test(start_paused = true)]
    async fn ws_601_typing_updates_core_state_emits_host_call_and_expires() {
        use olaz_net::mock::MockTransport;

        use crate::actor::CoreHandle;
        use crate::conversations::FriendIdentity;
        use crate::input::Command;
        use crate::state::{CoreState, Phase, Profile, WsPhase};
        use crate::typing::{TYPING_DISPLAY_DURATION, TypingStatus};

        struct SinkCaptureRunner<T: Transport + 'static> {
            inner: Arc<SessionEffectRunner<T>>,
            sink: Mutex<Option<ActorSink>>,
        }

        impl<T: Transport + 'static> EffectRunner for SinkCaptureRunner<T> {
            fn dispatch(&self, effects: Vec<Effect>, sink: ActorSink) {
                *self.sink.lock().unwrap_or_else(PoisonError::into_inner) = Some(sink.clone());
                self.inner.dispatch(effects, sink);
            }

            fn shutdown(&self) {
                self.inner.shutdown();
            }
        }

        let host = Arc::new(RecordingTypingHost {
            calls: Mutex::new(Vec::new()),
        });
        let client = Arc::new(SessionClient::new(
            MockTransport::scripted(vec![]),
            "imei-t2".to_owned(),
            "Mac".to_owned(),
        ));
        let inner = Arc::new(SessionEffectRunner::new(
            client,
            Arc::clone(&host) as Arc<dyn Host>,
            tokio::runtime::Handle::current(),
        ));
        let capture = Arc::new(SinkCaptureRunner {
            inner: Arc::clone(&inner),
            sink: Mutex::new(None),
        });

        let mut initial = CoreState::default();
        initial.session.phase = Phase::Ready;
        initial.session.profile = Some(Profile {
            user_id: "2000515".to_owned(),
            display_name: "Me".to_owned(),
            avatar: None,
            phone: None,
        });
        initial.conversations.identities.friends = vec![
            FriendIdentity {
                id: "3000515".to_owned(),
                name: "Alice".to_owned(),
                avatar: None,
            },
            FriendIdentity {
                id: "3000516".to_owned(),
                name: "Bob".to_owned(),
                avatar: None,
            },
        ];
        initial.transport.ws_phase = WsPhase::Running;
        initial.transport.ws_gen = 1;

        let core = CoreHandle::start_with_state(
            initial,
            Arc::clone(&capture) as Arc<dyn EffectRunner>,
            tokio::runtime::Handle::current(),
        );
        // Prime sink capture via a command that dispatches an effect through EffectRunner.
        core.send_and_ack(Command::PersistConversations).await;
        let Some(sink) = capture
            .sink
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone()
        else {
            panic!("sink captured");
        };

        let Value::Object(payload) = serde_json::json!({
            "error_code": 0,
            "data": {
                "controls": [
                    {"act": "typing", "act_type": "typing", "data": {"isPC": 1, "uid": "3000515"}},
                    {"act": "gtyping", "act_type": "typing", "data": {"gid": "500515", "uid": "3000516"}}
                ]
            }
        }) else {
            panic!("expected payload object");
        };

        sink.send(Input::WsEvent {
            ws_gen: 1,
            cmd: 601,
            payload,
            now_unix_secs: 1_700_000_000,
        });
        core.settle().await;
        inner.flush_host().await;

        let recorded = host
            .calls
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone();
        assert_eq!(
            recorded,
            vec![
                ("3000515".to_owned(), "3000515".to_owned(), true),
                ("g500515".to_owned(), "3000516".to_owned(), false),
            ]
        );
        let Some(snap) = core.full_snapshot().await else {
            panic!("expected core snapshot");
        };
        assert_eq!(
            snap.typing.get("3000515"),
            Some(&TypingStatus {
                name: "Alice".to_owned(),
                on_pc: true,
            })
        );
        assert_eq!(
            snap.typing.get("g500515"),
            Some(&TypingStatus {
                name: "Bob".to_owned(),
                on_pc: false,
            })
        );

        // Advance paused time by 10 s: both expire without wall-clock sleeps.
        tokio::time::advance(TYPING_DISPLAY_DURATION).await;
        tokio::task::yield_now().await;
        core.settle().await;
        assert!(
            core.full_snapshot()
                .await
                .is_some_and(|s| s.typing.is_empty())
        );

        core.stop();
    }

    #[tokio::test]
    async fn send_typing_api_checks_auth_and_routes_1_1_and_group() {
        use olaz_net::http::RawResponse;
        use olaz_net::mock::MockTransport;

        use crate::actor::CoreHandle;
        use crate::input::Command;
        use crate::state::{CoreState, Phase};

        let transport = MockTransport::from_fn(|_| {
            Ok(RawResponse::new(
                200,
                br#"{"error_code":0,"data":{}}"#.to_vec(),
            ))
        });
        let client = Arc::new(SessionClient::new(
            transport,
            "imei-t3".to_owned(),
            "Mac".to_owned(),
        ));
        client.update_credentials(
            LoginAccount {
                user_id: "2000517".to_owned(),
                ..LoginAccount::default()
            },
            b"0123456789abcdef".to_vec(),
            "sek.1".to_owned(),
            Some(ZaloDomains::default()),
        );
        let runner = Arc::new(SessionEffectRunner::new(
            Arc::clone(&client),
            Arc::new(RecordingTypingHost::default()),
            tokio::runtime::Handle::current(),
        ));
        let mut initial = CoreState::default();
        initial.session.phase = Phase::Ready;
        let core = CoreHandle::start_with_state(initial, runner, tokio::runtime::Handle::current());

        core.send(Command::NotifyTyping {
            conv_id: "  3000517  ".to_owned(),
            now_ms: 1_700_000_000_000,
        });
        core.send(Command::NotifyTyping {
            conv_id: "3000517".to_owned(),
            now_ms: 1_700_000_005_000,
        });
        core.send(Command::NotifyTyping {
            conv_id: "g500517".to_owned(),
            now_ms: 1_700_000_005_000,
        });
        core.wait_idle().await;

        let mut paths: Vec<String> = client
            .transport()
            .requests()
            .into_iter()
            .map(|r| r.path())
            .collect();
        paths.sort();
        assert_eq!(paths, vec!["/api/group/typing", "/api/message/typing"]);

        // Clearing client auth suppresses SendTypingApi even while phase stays Ready.
        client.clear_session();
        core.send(Command::NotifyTyping {
            conv_id: "3000519".to_owned(),
            now_ms: 1_700_000_020_000,
        });
        core.wait_idle().await;
        assert_eq!(client.transport().requests().len(), 2);

        core.stop();
    }

    #[tokio::test(start_paused = true)]
    async fn poll_debounce_timer_coalesces_and_cancels_on_reset() {
        use olaz_net::http::RawResponse;
        use olaz_net::mock::MockTransport;

        use crate::actor::CoreHandle;
        use crate::input::Command;
        use crate::polls::{POLL_DEBOUNCE_DELAY_MS, PollDetail, PollMessageNotice};
        use crate::state::{CoreState, Phase, Profile};

        let transport = MockTransport::from_fn(|_| {
            Ok(RawResponse::new(
                200,
                br#"{"error_code":0,"data":{"group_id":"5001","question":"Q","creator":"2001","status":1,"expired_time":0,"options":[]}}"#.to_vec(),
            ))
        });
        let client = Arc::new(SessionClient::new(
            transport,
            "imei-poll-timer".to_owned(),
            "Mac".to_owned(),
        ));
        client.update_credentials(
            LoginAccount {
                user_id: "2001".to_owned(),
                ..LoginAccount::default()
            },
            b"0123456789abcdef".to_vec(),
            "sek.1".to_owned(),
            Some(ZaloDomains::default()),
        );
        // RecordingTypingHost uses the default Host::arm_poll_debounce -> false,
        // exercising SessionEffectRunner's native tokio::time::sleep_until timer.
        let runner = Arc::new(SessionEffectRunner::new(
            Arc::clone(&client),
            Arc::new(RecordingTypingHost::default()),
            tokio::runtime::Handle::current(),
        ));
        let mut initial = CoreState::default();
        initial.session.phase = Phase::Ready;
        initial.session.profile = Some(Profile {
            user_id: "2001".to_owned(),
            display_name: "Tester".to_owned(),
            avatar: None,
            phone: None,
        });
        initial.contacts.group_details_json.insert(
            "5001".to_owned(),
            r#"{"groupId":"5001","creatorId":"2001"}"#.to_owned(),
        );
        let seeded_detail = serde_json::json!({
            "id": "p1",
            "groupId": "g5001",
            "question": "Old",
        });
        if let Some(d) = seeded_detail.as_object().and_then(PollDetail::from_json) {
            initial.polls.details.insert("p1".to_owned(), d);
        }
        let core = CoreHandle::start_with_state(initial, runner, tokio::runtime::Handle::current());

        let now_ms = 1_700_000_000_000_i64;
        core.send(Command::NotePollMessages {
            notices: vec![PollMessageNotice {
                msg_id: "m1".to_owned(),
                poll_id: "p1".to_owned(),
                conv_id: "g5001".to_owned(),
                date_ms: now_ms,
            }],
            now_ms,
            host_already_armed: false,
        });
        core.wait_idle().await;
        tokio::task::yield_now().await;

        // Second message 500 ms later re-arms p1; original 1.5 s deadline must not fire early.
        tokio::time::advance(Duration::from_millis(500)).await;
        core.send(Command::NotePollMessages {
            notices: vec![PollMessageNotice {
                msg_id: "m2".to_owned(),
                poll_id: "p1".to_owned(),
                conv_id: "g5001".to_owned(),
                date_ms: now_ms + 500,
            }],
            now_ms: now_ms + 500,
            host_already_armed: false,
        });
        core.wait_idle().await;
        tokio::task::yield_now().await;

        tokio::time::advance(Duration::from_millis(1_100)).await;
        tokio::task::yield_now().await;
        core.wait_idle().await;
        assert_eq!(client.transport().requests().len(), 0);

        // Reaching 1.5 s after m2 fires exactly one refresh.
        tokio::time::advance(Duration::from_millis(POLL_DEBOUNCE_DELAY_MS - 1_100)).await;
        tokio::task::yield_now().await;
        core.wait_idle().await;
        assert_eq!(client.transport().requests().len(), 1);
        assert_eq!(
            core.full_snapshot()
                .await
                .and_then(|s| s.polls.details.get("p1").map(|d| d.question.clone()))
                .as_deref(),
            Some("Q")
        );

        // ResetPolls cancels an armed native timer before it can fire.
        core.send(Command::NotePollMessages {
            notices: vec![PollMessageNotice {
                msg_id: "m3".to_owned(),
                poll_id: "p1".to_owned(),
                conv_id: "g5001".to_owned(),
                date_ms: now_ms + 2_000,
            }],
            now_ms: now_ms + 2_000,
            host_already_armed: false,
        });
        core.wait_idle().await;
        tokio::task::yield_now().await;
        core.send(Command::ResetPolls { sync_epoch: 0 });
        core.wait_idle().await;

        tokio::time::advance(Duration::from_secs(2)).await;
        tokio::task::yield_now().await;
        core.wait_idle().await;
        assert_eq!(client.transport().requests().len(), 1);

        core.stop();
    }

    #[derive(Default)]
    struct RecordingCardHost {
        cards: Mutex<Vec<(String, String)>>,
    }

    #[async_trait]
    impl Host for RecordingCardHost {
        async fn load_saved_session(&self) -> Option<String> {
            None
        }
        async fn load_legacy_cookie(&self) -> Option<LegacyCookie> {
            None
        }
        async fn set_pref(&self, _key: String, _value: String) {}
        async fn prepare_store(&self, _user_id: String, _account: LoginAccount) {}
        async fn start_bootstrap(&self) {}
        async fn offer_first_login_transfer(&self, _force: bool) {}
        async fn reset_domains(&self) {}
        async fn persist_session(&self, _snapshot_json: String) {}
        async fn clear_session(&self) {}
        async fn mark_expired(&self, _snapshot_json: String) {}
        async fn persist_poll_state(&self, _state: PollState) {}
        async fn persist_ws_cursors(&self, _cursors: CursorMap) {}
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
        async fn mobile_sync(&self, _events: Vec<MobileSyncEvent>) {}
        async fn e2ee_signal(&self, _cmd: u16, _payload: Map<String, Value>) {}
        async fn e2ee_deliver_reports(&self, _cmd: u16, _payload: Map<String, Value>) {}
        async fn e2ee_connected(&self, _uid: String) {}
        async fn e2ee_disconnected(&self) {}
        async fn voip_control(&self, _act: String, _raw_data: Value, _data: Map<String, Value>) {}
        async fn show_typing(&self, _conv_id: String, _uid: String, _on_pc: bool) {}
        async fn pin_topic(&self, _conv_id: String) {}
        async fn group_notice(&self, _act: String, _data: Map<String, Value>, _ts: i64) {}
        async fn mute(
            &self,
            _conv_id: String,
            _set: bool,
            _start: i64,
            _start_explicit: bool,
            _duration: i64,
        ) {
        }
        async fn show_card(&self, conv_id: Option<String>, text: String) {
            let conv_id = conv_id.unwrap_or_default();
            self.cards
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .push((conv_id, text));
        }
    }

    #[tokio::test(start_paused = true)]
    async fn delete_undo_timer_commits_after_5s_and_undo_cancels_with_show_card() {
        use crate::actions::{DELETE_UNDO_DURATION, DeleteUndoItem, RESTORE_SUCCESS_CARD_TEXT};
        use crate::reduce::ReduceOutput;
        use crate::state::CoreState;
        use olaz_net::http::RawResponse;
        use olaz_store::{Store, StoredMessage};

        let transport = MockTransport::from_fn(|_req| {
            Ok(RawResponse::new(
                200,
                serde_json::json!({"error_code": 0, "data": {}})
                    .to_string()
                    .into_bytes(),
            ))
        });
        let client = Arc::new(SessionClient::new(
            transport,
            "imei-u6".to_owned(),
            "Mac".to_owned(),
        ));
        client.update_credentials(
            LoginAccount {
                user_id: "2000620".to_owned(),
                ..LoginAccount::default()
            },
            b"0123456789abcdef".to_vec(),
            "sek.1".to_owned(),
            Some(ZaloDomains::default()),
        );
        let host = Arc::new(RecordingCardHost::default());
        let runner = Arc::new(SessionEffectRunner::new(
            Arc::clone(&client),
            Arc::clone(&host) as Arc<dyn Host>,
            Handle::current(),
        ));

        // Seed an in-memory SQLite store with one message to confirm CommitDeleteBatch deletes it.
        let Ok(mut store) = Store::open_in_memory() else {
            panic!("failed to open in-memory store");
        };
        let seeded = StoredMessage {
            id: "9020001".to_owned(),
            conv_id: "3000620".to_owned(),
            client_id: "c9020001".to_owned(),
            sender_id: "2000620".to_owned(),
            sender_name: "Me".to_owned(),
            sender_avatar: String::new(),
            is_mine: true,
            text: "to delete".to_owned(),
            kind_tag: "text".to_owned(),
            ts_ms: 1_700_000_000_000,
            status: "sent".to_owned(),
            raw_json_data: Vec::new(),
        };
        let Ok(_) = store.save_messages(&[seeded]) else {
            panic!("failed to save seeded message");
        };
        let store_arc = Arc::new(Mutex::new(store));
        runner.attach_store(Arc::clone(&store_arc));

        // 1) Undo before 5 s cancels timer, emits show_card, and never calls delete API.
        let mut initial = CoreState::default();
        let mut out = ReduceOutput::default();
        initial.actions.delete_undo.start_batch(
            "3000620".to_owned(),
            vec![DeleteUndoItem {
                conv_id: "3000620".to_owned(),
                msg_id: "9020001".to_owned(),
                cli_msg_id: "c9020001".to_owned(),
                sender_id: "2000620".to_owned(),
                message: None,
            }],
            1_700_000_011_000,
            &mut out,
        );
        let core = CoreHandle::start_with_state(
            initial,
            Arc::clone(&runner) as Arc<dyn EffectRunner>,
            Handle::current(),
        );
        core.request_unit(Command::UndoDelete).await;
        core.wait_idle().await;
        assert_eq!(
            *host.cards.lock().unwrap_or_else(PoisonError::into_inner),
            vec![("3000620".to_owned(), RESTORE_SUCCESS_CARD_TEXT.to_owned())]
        );
        assert!(client.transport().requests().is_empty());
        core.stop();

        // 2) DismissDeleteUndo commits batch via delete_message_for_me API + SQLite delete.
        let mut initial2 = CoreState::default();
        let mut out2 = ReduceOutput::default();
        initial2.actions.delete_undo.start_batch(
            "3000620".to_owned(),
            vec![DeleteUndoItem {
                conv_id: "3000620".to_owned(),
                msg_id: "9020001".to_owned(),
                cli_msg_id: "c9020001".to_owned(),
                sender_id: "2000620".to_owned(),
                message: None,
            }],
            1_700_000_011_000,
            &mut out2,
        );
        let runner2 = Arc::new(SessionEffectRunner::new(
            Arc::clone(&client),
            Arc::clone(&host) as Arc<dyn Host>,
            Handle::current(),
        ));
        runner2.attach_store(Arc::clone(&store_arc));
        let core2 = CoreHandle::start_with_state(
            initial2,
            Arc::clone(&runner2) as Arc<dyn EffectRunner>,
            Handle::current(),
        );
        core2.request_unit(Command::DismissDeleteUndo).await;
        core2.wait_idle().await;
        runner2.flush_store().await;

        assert_eq!(client.transport().requests().len(), 1);
        assert_eq!(
            client.transport().requests()[0].path(),
            "/api/message/delete"
        );
        let remaining = store_arc
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .read_messages_now("3000620", None, 10)
            .unwrap_or_default();
        assert!(remaining.is_empty());
        core2.stop();

        // 3) StartDeleteUndoExpiry fires after 5 s on paused time, clears the bar, and commits.
        let mut initial3 = CoreState::default();
        let mut out3 = ReduceOutput::default();
        initial3.actions.delete_undo.start_batch(
            "3000620".to_owned(),
            vec![DeleteUndoItem {
                conv_id: "3000620".to_owned(),
                msg_id: "9020002".to_owned(),
                cli_msg_id: "c9020002".to_owned(),
                sender_id: "2000620".to_owned(),
                message: None,
            }],
            1_700_000_020_000,
            &mut out3,
        );
        let runner3 = Arc::new(SessionEffectRunner::new(
            Arc::clone(&client),
            Arc::clone(&host) as Arc<dyn Host>,
            Handle::current(),
        ));
        let core3 = CoreHandle::start_with_state(
            initial3,
            Arc::clone(&runner3) as Arc<dyn EffectRunner>,
            Handle::current(),
        );
        runner3.dispatch(out3.effects, core3.test_sink());
        // wait_idle returns immediately while the 5 s timer is armed.
        core3.wait_idle().await;

        // Before 5 s: undo bar is still active, no new delete API request yet.
        tokio::time::advance(Duration::from_millis(4_900)).await;
        tokio::task::yield_now().await;
        assert!(
            core3
                .full_snapshot()
                .await
                .and_then(|s| s.delete_undo)
                .is_some()
        );
        assert_eq!(client.transport().requests().len(), 1);

        // At 5 s: timer fires DeleteUndoExpired -> clears bar + commits delete via API.
        tokio::time::advance(DELETE_UNDO_DURATION).await;
        let Some(change) = core3.next_changes().await else {
            panic!("expected delete_undo clear change");
        };
        assert_eq!(change.delete_undo, Some(None));
        core3.wait_idle().await;
        assert_eq!(client.transport().requests().len(), 2);
        assert_eq!(
            client.transport().requests()[1].path(),
            "/api/message/delete"
        );
        core3.stop();
    }

    #[tokio::test(start_paused = true)]
    async fn auto_delete_load_and_set_runner_flow_updates_state_and_emits_show_card_on_error() {
        use crate::actions::AUTO_DELETE_FAILED_CARD_TEXT;
        use olaz_net::http::RawResponse;
        use std::sync::atomic::AtomicUsize;

        let load_calls = Arc::new(AtomicUsize::new(0));
        let update_calls = Arc::new(AtomicUsize::new(0));
        let lc = Arc::clone(&load_calls);
        let uc = Arc::clone(&update_calls);
        let transport = MockTransport::from_fn(move |req| match req.path().as_str() {
            "/api/conv/autodelete/getConvers" => {
                let n = lc.fetch_add(1, Ordering::SeqCst);
                if n == 0 {
                    // First call fails -> initializes empty map when None.
                    Ok(RawResponse::new(
                        200,
                        serde_json::json!({"error_code": 500, "error_message": "fail"})
                            .to_string()
                            .into_bytes(),
                    ))
                } else {
                    Ok(RawResponse::new(
                        200,
                        serde_json::json!({
                            "error_code": 0,
                            "data": {
                                "convers": [
                                    {"destId": "627", "isGroup": 1, "ttl": 86_400_000}
                                ]
                            }
                        })
                        .to_string()
                        .into_bytes(),
                    ))
                }
            }
            "/api/conv/autodelete/updateConvers" => {
                let n = uc.fetch_add(1, Ordering::SeqCst);
                if n == 0 {
                    Ok(RawResponse::new(
                        200,
                        serde_json::json!({"error_code": 112, "error_message": "bad"})
                            .to_string()
                            .into_bytes(),
                    ))
                } else {
                    Ok(RawResponse::new(
                        200,
                        serde_json::json!({"error_code": 0, "data": {}})
                            .to_string()
                            .into_bytes(),
                    ))
                }
            }
            _ => Ok(RawResponse::new(404, b"{}".to_vec())),
        });
        let client = Arc::new(SessionClient::new(
            transport,
            "imei-ad".to_owned(),
            "Mac".to_owned(),
        ));
        client.update_credentials(
            LoginAccount {
                user_id: "2000627".to_owned(),
                ..LoginAccount::default()
            },
            b"0123456789abcdef".to_vec(),
            "sek.1".to_owned(),
            Some(ZaloDomains::default()),
        );
        let host = Arc::new(RecordingCardHost::default());
        let runner = Arc::new(SessionEffectRunner::new(
            Arc::clone(&client),
            Arc::clone(&host) as Arc<dyn Host>,
            Handle::current(),
        ));
        let core = CoreHandle::start(runner, Handle::current());

        // 1) Load failure when None sets Some({}).
        core.request_unit(Command::LoadAutoDelete).await;
        let snap1 = core.full_snapshot().await;
        assert_eq!(snap1.and_then(|s| s.auto_delete), Some(BTreeMap::new()));

        // 2) Load success populates map.
        core.request_unit(Command::LoadAutoDelete).await;
        let snap2 = core.full_snapshot().await;
        assert_eq!(
            snap2.and_then(|s| s.auto_delete),
            Some(BTreeMap::from([("g627".to_owned(), 86_400_000)]))
        );

        // 3) SetAutoDelete failure leaves map intact and emits show_card.
        core.request_unit(Command::SetAutoDelete {
            conv_id: "3000628".to_owned(),
            ttl: 3_600_000,
            now_ms: 1_700_000_000_000,
        })
        .await;
        core.wait_idle().await;
        assert_eq!(
            *host.cards.lock().unwrap_or_else(PoisonError::into_inner),
            vec![(
                "3000628".to_owned(),
                AUTO_DELETE_FAILED_CARD_TEXT.to_owned()
            )]
        );

        // 4) SetAutoDelete success updates map and publishes CoreChanges.auto_delete.
        core.request_unit(Command::SetAutoDelete {
            conv_id: "3000628".to_owned(),
            ttl: 3_600_000,
            now_ms: 1_700_000_005_000,
        })
        .await;
        let snap4 = core.full_snapshot().await;
        assert_eq!(
            snap4.and_then(|s| s.auto_delete),
            Some(BTreeMap::from([
                ("3000628".to_owned(), 3_600_000),
                ("g627".to_owned(), 86_400_000),
            ]))
        );

        core.stop();
    }
}
