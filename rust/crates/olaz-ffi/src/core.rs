//! `CoreEngine` & `CoreHost`: UniFFI export for the `olaz-core` actor and change stream (ADR-016).
//!
//! Credentials and user-facing personal data never reach `Debug` output or error messages (ADR-008).

use std::fmt;
use std::sync::Arc;
use std::time::Duration;

use olaz_api::PollState;
use olaz_core::reduce::classify::{MobileSyncEvent, Route, classify};
use olaz_core::runner::WsDriver;
use olaz_core::state::PersistedTransportState;
use olaz_core::typed_chat::{TypedChatEnvelope, WirePayloadHandle};
use olaz_core::{
    Command, CoreChanges, CoreFailKind, CoreHandle, FailReason, Host, LegacyCookie, LoginState,
    LoginStep, Phase, Profile, SessionEffectRunner, SessionSnapshot,
};
use olaz_json::to_swift_json_string;
use olaz_net::{LoginAccount, NetworkErrorKind};
use olaz_wire::NameLookup;
use olaz_ws::CursorMap;
use serde_json::{Map, Value};

use crate::api::PollStateRecord;
use crate::error::{CoreError, NetworkKind};
use crate::runtime::{run, runtime};
use crate::session::CoreSession;
use crate::wire::{NameEntry, WireEvent, convert as convert_wire_event};
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

/// Coalesced dirty-key change batch returned by [`CoreEngine::next_changes`].
#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct CoreChangesRecord {
    pub version: u64,
    pub session: Option<SessionStateRecord>,
}

impl fmt::Debug for CoreChangesRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("CoreChangesRecord")
            .field("version", &self.version)
            .field("session", &self.session)
            .finish()
    }
}

impl From<CoreChanges> for CoreChangesRecord {
    fn from(c: CoreChanges) -> Self {
        Self {
            version: c.version,
            session: c.session.map(Into::into),
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
    async fn start_bootstrap(&self);
    async fn offer_first_login_transfer(&self, force: bool);
    async fn reset_domains(&self);
    async fn persist_session(&self, snapshot_json: String);
    async fn clear_session(&self);
    async fn mark_expired(&self, snapshot_json: String);

    // --- Transport domain callbacks (U2) ---
    async fn persist_poll_state(&self, state: PollStateRecord);
    async fn persist_ws_cursors(&self, cursors: Vec<CursorEntry>);
    async fn apply_batch(
        &self,
        cmd: Option<u16>,
        increment_unread: bool,
        notify_incoming: bool,
        payload_json: String,
    ) -> u32;
    async fn apply_parsed_events(
        &self,
        cmd: u16,
        increment_unread: bool,
        notify_incoming: bool,
        events: Vec<WireEvent>,
        uids: Vec<String>,
        payload: Arc<CoreWirePayload>,
    );
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
        self.0.start_bootstrap().await;
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
        cmd: Option<u16>,
        increment_unread: bool,
        notify_incoming: bool,
        payload: Map<String, Value>,
    ) -> u32 {
        let payload_json = to_swift_json_string(&Value::Object(payload));
        self.0
            .apply_batch(cmd, increment_unread, notify_incoming, payload_json)
            .await
    }

    async fn apply_parsed_events(
        &self,
        cmd: u16,
        increment_unread: bool,
        notify_incoming: bool,
        envelope: TypedChatEnvelope,
    ) {
        let events = envelope
            .events
            .into_iter()
            .map(convert_wire_event)
            .collect();
        let payload = Arc::new(CoreWirePayload {
            inner: envelope.payload,
        });
        self.0
            .apply_parsed_events(
                cmd,
                increment_unread,
                notify_incoming,
                events,
                envelope.uids,
                payload,
            )
            .await;
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
/// Owns session & transport state (boot, QR login, expiry, logout, WebSocket lifecycle,
/// long-poll loop, and event routing) over the shared [`CoreSession`].
/// Swift pushes commands via sync/async methods and pulls coalesced updates via [`Self::next_changes`].
#[derive(uniffi::Object)]
pub struct CoreEngine {
    handle: Arc<CoreHandle>,
    ws_driver: Arc<dyn WsDriver>,
}

#[uniffi::export]
impl CoreEngine {
    /// Starts the `olaz-core` actor on the shared tokio runtime.
    #[uniffi::constructor]
    pub fn new(session: Arc<CoreSession>, host: Arc<dyn CoreHost>) -> Result<Arc<Self>, CoreError> {
        let rt_handle = runtime()?.handle().clone();
        let runner = Arc::new(SessionEffectRunner::with_default_domains(
            Arc::clone(&session.client),
            Arc::new(FfiHostBridge(host)),
            rt_handle.clone(),
            session.default_domains.clone(),
        ));
        let ws_driver = Arc::clone(runner.ws_driver());
        let handle = CoreHandle::start(runner, rt_handle);
        Ok(Arc::new(Self {
            handle: Arc::new(handle),
            ws_driver,
        }))
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

    /// Enqueues a barrier on the actor mailbox and returns the change revision once every input
    /// enqueued before this call has been reduced and published (`0` if already stopped).
    pub async fn settle(&self) -> Result<u64, CoreError> {
        let handle = Arc::clone(&self.handle);
        let version = run(async move { handle.settle().await.unwrap_or(0) }).await?;
        Ok(version)
    }

    /// Stops the actor, aborts in-flight session & transport tasks, and closes `next_changes()`.
    pub fn stop(&self) {
        self.handle.stop();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

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
        async fn start_bootstrap(&self) {}
        async fn offer_first_login_transfer(&self, _force: bool) {}
        async fn reset_domains(&self) {}
        async fn persist_session(&self, _snapshot_json: String) {}
        async fn clear_session(&self) {}
        async fn mark_expired(&self, _snapshot_json: String) {}
        async fn persist_poll_state(&self, _state: PollStateRecord) {}
        async fn persist_ws_cursors(&self, _cursors: Vec<CursorEntry>) {}
        async fn apply_batch(
            &self,
            _cmd: Option<u16>,
            _increment_unread: bool,
            _notify_incoming: bool,
            _payload_json: String,
        ) -> u32 {
            0
        }
        async fn apply_parsed_events(
            &self,
            _cmd: u16,
            _increment_unread: bool,
            _notify_incoming: bool,
            _events: Vec<WireEvent>,
            _uids: Vec<String>,
            _payload: Arc<CoreWirePayload>,
        ) {
        }
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
