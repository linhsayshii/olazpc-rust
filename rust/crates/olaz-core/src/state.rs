//! Core domain state owned by the actor (ADR-016).
//!
//! `Debug` implementations on types that carry credentials, display names, phone numbers, or QR
//! payloads emit shape-only summaries (ADR-008).

use std::collections::{BTreeMap, BTreeSet, VecDeque};
use std::fmt;

use olaz_api::PollState;
use olaz_net::NetworkErrorKind;
use olaz_ws::CursorMap;
use serde_json::{Map, Value, json};

use crate::actions::{ActionsState, DeleteUndoSnapshot, MessageConfirmState};
use crate::conversations::{CachedProfile, ConversationsState};
use crate::messages::{ContactsState, IdentitySnapshot, MessagesState};
use crate::typing::{TypingState, TypingStatus};

/// Top-level state owned by the single `olaz-core` actor.
#[derive(Clone, Default)]
pub struct CoreState {
    pub session: SessionState,
    pub transport: TransportState,
    pub conversations: ConversationsState,
    pub messages: MessagesState,
    pub contacts: ContactsState,
    // U4-bootstrap
    pub(crate) bootstrap: crate::reduce::bootstrap::BootstrapRuntimeState,
    // U5
    pub typing: TypingState,
    // U5-send
    pub send: crate::reduce::send::SendState,
    // U14
    pub search: crate::search::SearchState,
    // U6
    pub actions: ActionsState,
}

impl CoreState {
    /// Projects the observable state across all core-owned domains (tests / diagnostics).
    #[must_use]
    pub fn full_snapshot(&self) -> CoreSnapshot {
        CoreSnapshot {
            session: self.session.snapshot(),
            conversations: self.conversations.clone(),
            messages: self.messages.clone(),
            contacts: self.contacts.clone(),
            // U5
            typing: self.typing.active.clone(),
            // U6
            delete_undo: self.actions.delete_undo.snapshot(),
            message_confirm: self.actions.message_confirm.clone(),
            auto_delete: self.actions.auto_delete.clone(),
            starred_ids: self.actions.starred_ids.clone(),
            cached_profiles: self.conversations.identities.cached_profiles.clone(),
            last_prune_next_expiry_ms: self.actions.last_prune_next_expiry_ms,
        }
    }

    /// Builds an [`IdentitySnapshot`] from the current session profile and conversation identities.
    #[must_use]
    pub fn identity_snapshot(&self) -> IdentitySnapshot {
        let my_uid = self
            .session
            .profile
            .as_ref()
            .map_or("", |p| p.user_id.as_str());
        let my_avatar = self
            .session
            .profile
            .as_ref()
            .and_then(|p| p.avatar.as_deref());
        IdentitySnapshot::from_core(my_uid, my_avatar, &self.conversations)
    }
}

impl fmt::Debug for CoreState {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("CoreState")
            .field("session", &self.session)
            .field("transport", &self.transport)
            .field("conversations", &self.conversations)
            .field("messages", &self.messages)
            .field("contacts", &self.contacts)
            .field("bootstrap", &self.bootstrap)
            // U5
            .field("typing", &self.typing)
            // U5-send
            .field("send", &self.send)
            // U6
            .field("actions", &self.actions)
            .finish()
    }
}

/// Full observable snapshot across session + conversations + messages + contacts + typing domains.
#[derive(Clone, Default)]
pub struct CoreSnapshot {
    pub session: SessionSnapshot,
    pub conversations: ConversationsState,
    pub messages: MessagesState,
    pub contacts: ContactsState,
    // U5
    pub typing: BTreeMap<String, TypingStatus>,
    // U6
    pub delete_undo: Option<DeleteUndoSnapshot>,
    pub message_confirm: Option<MessageConfirmState>,
    pub auto_delete: Option<BTreeMap<String, i64>>,
    pub starred_ids: BTreeSet<String>,
    pub cached_profiles: BTreeMap<String, CachedProfile>,
    pub last_prune_next_expiry_ms: Option<i64>,
}

impl fmt::Debug for CoreSnapshot {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("CoreSnapshot")
            .field("session", &self.session)
            .field("conversations", &self.conversations)
            .field("messages", &self.messages)
            .field("contacts", &self.contacts)
            // U5
            .field("typing_count", &self.typing.len())
            // U6
            .field("delete_undo", &self.delete_undo)
            .field("message_confirm", &self.message_confirm)
            .field(
                "auto_delete_count",
                &self.auto_delete.as_ref().map(BTreeMap::len),
            )
            .field("starred_ids_count", &self.starred_ids.len())
            .field("cached_profiles_count", &self.cached_profiles.len())
            .field("last_prune_next_expiry_ms", &self.last_prune_next_expiry_ms)
            .finish()
    }
}

/// Persisted transport cursors loaded from the store after `prepare_store` (U2).
#[derive(Clone, Default, PartialEq, Eq)]
pub struct PersistedTransportState {
    pub poll_state: PollState,
    pub ws_cursors: CursorMap,
}

impl fmt::Debug for PersistedTransportState {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("PersistedTransportState")
            .field("ws_cursors_count", &self.ws_cursors.len())
            .finish()
    }
}

/// Lifecycle phase of the core-owned WebSocket connection (U2).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum WsPhase {
    #[default]
    Stopped,
    Running,
}

/// Active long-poll drain currently executing batch-by-batch.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ActiveDrain {
    pub drain_id: u64,
    pub lp_gen: u64,
    pub remaining_batches: u32,
    pub notify_incoming: bool,
    pub is_periodic: bool,
    pub total_events: u32,
    pub more_after_current: bool,
}

/// Queued long-poll drain waiting for the active drain to finish (ADR-018).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PendingDrain {
    pub drain_id: u64,
    pub max_batches: u32,
    pub notify_incoming: bool,
    pub is_periodic: bool,
}

/// Full transport-domain state inside [`CoreState`] (U2).
#[derive(Clone, Default)]
pub struct TransportState {
    pub ws_phase: WsPhase,
    pub ws_authed: bool,
    pub ws_gen: u64,
    pub lp_running: bool,
    pub lp_gen: u64,
    pub ws_cursors: CursorMap,
    pub poll_state: PollState,
    pub(crate) seen_typing_shapes: BTreeSet<String>,
    pub(crate) active_drain: Option<ActiveDrain>,
    pub(crate) pending_drains: VecDeque<PendingDrain>,
    pub(crate) next_drain_id: u64,
}

impl TransportState {
    pub(crate) fn alloc_drain_id(&mut self) -> u64 {
        self.next_drain_id = self.next_drain_id.saturating_add(1);
        self.next_drain_id
    }
}

impl fmt::Debug for TransportState {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("TransportState")
            .field("ws_phase", &self.ws_phase)
            .field("ws_authed", &self.ws_authed)
            .field("ws_gen", &self.ws_gen)
            .field("lp_running", &self.lp_running)
            .field("lp_gen", &self.lp_gen)
            .field("ws_cursors_count", &self.ws_cursors.len())
            .field("has_active_drain", &self.active_drain.is_some())
            .field("pending_drains", &self.pending_drains.len())
            .finish()
    }
}

/// Core/transport error kinds kept typed until Swift renders them through `RustCore.mapError`,
/// so `NSError` and `ZaloSessionError`/`ZaloTransportError` descriptions stay identical to Swift.
#[derive(Clone, PartialEq, Eq)]
pub enum CoreFailKind {
    Network(NetworkErrorKind),
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
    Crypto(String),
}

impl fmt::Debug for CoreFailKind {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Network(kind) => f.debug_tuple("Network").field(kind).finish(),
            Self::Session { code, .. } => f.debug_struct("Session").field("code", code).finish(),
            Self::Http { status } => f.debug_struct("Http").field("status", status).finish(),
            Self::InvalidJson => f.write_str("InvalidJson"),
            Self::NotAuthenticated => f.write_str("NotAuthenticated"),
            Self::Crypto(_) => f.write_str("Crypto(<redacted>)"),
        }
    }
}

/// Reason why QR login entered `LoginStep::Failed`.
#[derive(Clone, PartialEq, Eq)]
pub enum FailReason {
    /// Deterministic text owned by the session flow or returned by the server.
    Text(String),
    /// Transport/core failure rendered via Swift's `RustCore.mapError(...).localizedDescription`.
    Core(CoreFailKind),
}

impl fmt::Debug for FailReason {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Text(s) => f.debug_tuple("Text").field(&s.len()).finish(),
            Self::Core(kind) => f.debug_tuple("Core").field(kind).finish(),
        }
    }
}

/// Sub-state of `Phase::Login`.
#[derive(Clone, PartialEq, Eq)]
pub enum LoginStep {
    Generating,
    WaitingScan,
    WaitingConfirm {
        name: String,
        avatar: Option<String>,
    },
    Expired,
    Failed(FailReason),
}

impl LoginStep {
    /// Shape-only label for logs (ADR-008).
    #[must_use]
    pub fn kind_name(&self) -> &'static str {
        match self {
            Self::Generating => "generating",
            Self::WaitingScan => "waiting_scan",
            Self::WaitingConfirm { .. } => "waiting_confirm",
            Self::Expired => "expired",
            Self::Failed(_) => "failed",
        }
    }
}

impl fmt::Debug for LoginStep {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Generating => f.write_str("Generating"),
            Self::WaitingScan => f.write_str("WaitingScan"),
            Self::WaitingConfirm { avatar, .. } => f
                .debug_struct("WaitingConfirm")
                .field("has_avatar", &avatar.is_some())
                .finish(),
            Self::Expired => f.write_str("Expired"),
            Self::Failed(reason) => f.debug_tuple("Failed").field(reason).finish(),
        }
    }
}

/// QR login state (`ZaloEngine.LoginState`).
///
/// `qr_payload` is the raw QR string (Swift renders it with CoreImage); `qr_png` is set only when
/// the server sent ready-made PNG bytes.
#[derive(Clone, PartialEq, Eq)]
pub struct LoginState {
    pub step: LoginStep,
    pub qr_payload: Option<String>,
    pub qr_png: Option<Vec<u8>>,
}

impl LoginState {
    #[must_use]
    pub fn generating() -> Self {
        Self {
            step: LoginStep::Generating,
            qr_payload: None,
            qr_png: None,
        }
    }

    #[must_use]
    pub fn expired() -> Self {
        Self {
            step: LoginStep::Expired,
            qr_payload: None,
            qr_png: None,
        }
    }

    #[must_use]
    pub fn failed(reason: FailReason) -> Self {
        Self {
            step: LoginStep::Failed(reason),
            qr_payload: None,
            qr_png: None,
        }
    }
}

impl fmt::Debug for LoginState {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("LoginState")
            .field("step", &self.step)
            .field("has_qr_payload", &self.qr_payload.is_some())
            .field("qr_png_bytes", &self.qr_png.as_ref().map_or(0, Vec::len))
            .finish()
    }
}

/// Top-level engine phase (`ZaloEngine.Phase`, minus the unused `preparing` case).
#[derive(Clone, PartialEq, Eq, Default)]
pub enum Phase {
    #[default]
    Starting,
    Login(LoginState),
    SigningIn,
    Ready,
}

impl Phase {
    /// Shape-only label for logs (ADR-008).
    #[must_use]
    pub fn kind_name(&self) -> &'static str {
        match self {
            Self::Starting => "starting",
            Self::Login(_) => "login",
            Self::SigningIn => "signing_in",
            Self::Ready => "ready",
        }
    }
}

impl fmt::Debug for Phase {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Starting => f.write_str("Starting"),
            Self::Login(login) => f.debug_tuple("Login").field(login).finish(),
            Self::SigningIn => f.write_str("SigningIn"),
            Self::Ready => f.write_str("Ready"),
        }
    }
}

/// Signed-in account profile (`ZaloEngine.Profile`).
#[derive(Clone, PartialEq, Eq)]
pub struct Profile {
    pub user_id: String,
    pub display_name: String,
    pub avatar: Option<String>,
    pub phone: Option<String>,
}

impl fmt::Debug for Profile {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Profile")
            .field("has_user_id", &!self.user_id.is_empty())
            .field("has_display_name", &!self.display_name.is_empty())
            .field("has_avatar", &self.avatar.is_some())
            .field("has_phone", &self.phone.is_some())
            .finish()
    }
}

/// Tracks which flow is awaiting `HostCall::PrepareStore` completion.
#[derive(Clone, PartialEq, Eq)]
pub(crate) enum PendingStore {
    Boot {
        boot_gen: u64,
        ws_endpoints: Vec<String>,
    },
    QrComplete {
        qr_gen: u64,
        ws_endpoints: Vec<String>,
        need_sync_msg: bool,
    },
}

/// Full session-domain state inside [`CoreState`].
#[derive(Clone, Default)]
pub struct SessionState {
    pub phase: Phase,
    pub profile: Option<Profile>,
    pub sign_out_notice: Option<String>,
    pub self_conversation_id: Option<String>,
    pub prefs: BTreeMap<String, String>,

    // Internal reducer bookkeeping (never serialized in case snapshots).
    pub(crate) started: bool,
    pub(crate) qr_gen: u64,
    pub(crate) boot_gen: u64,
    pub(crate) pending_store: Option<PendingStore>,
    pub(crate) boot_ws_endpoints: Vec<String>,
}

impl SessionState {
    /// Projects the observable state delivered to Swift and compared in case tests.
    #[must_use]
    pub fn snapshot(&self) -> SessionSnapshot {
        SessionSnapshot {
            phase: self.phase.clone(),
            profile: self.profile.clone(),
            sign_out_notice: self.sign_out_notice.clone(),
            self_conversation_id: self.self_conversation_id.clone(),
            prefs: self.prefs.clone(),
        }
    }
}

impl fmt::Debug for SessionState {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("SessionState")
            .field("phase", &self.phase)
            .field("has_profile", &self.profile.is_some())
            .field("has_sign_out_notice", &self.sign_out_notice.is_some())
            .field("has_self_conv", &self.self_conversation_id.is_some())
            .field("prefs_count", &self.prefs.len())
            .field("started", &self.started)
            .field("qr_gen", &self.qr_gen)
            .field("boot_gen", &self.boot_gen)
            .finish()
    }
}

/// Observable snapshot of the session domain (D2/D3 + Case format v1).
#[derive(Clone, PartialEq, Eq, Default)]
pub struct SessionSnapshot {
    pub phase: Phase,
    pub profile: Option<Profile>,
    pub sign_out_notice: Option<String>,
    pub self_conversation_id: Option<String>,
    pub prefs: BTreeMap<String, String>,
}

impl SessionSnapshot {
    /// Converts to the Case format v1 JSON representation of the session domain state.
    pub fn to_case_json(&self, render_core_fail: &dyn Fn(&CoreFailKind) -> String) -> Value {
        let phase_val = match &self.phase {
            Phase::Starting => json!({ "kind": "starting" }),
            Phase::SigningIn => json!({ "kind": "signing_in" }),
            Phase::Ready => json!({ "kind": "ready" }),
            Phase::Login(login) => {
                let mut m = Map::new();
                m.insert("kind".to_owned(), Value::String("login".to_owned()));
                m.insert(
                    "step".to_owned(),
                    Value::String(login.step.kind_name().to_owned()),
                );
                m.insert(
                    "qr".to_owned(),
                    login
                        .qr_payload
                        .as_ref()
                        .map_or(Value::Null, |q| Value::String(q.clone())),
                );
                match &login.step {
                    LoginStep::WaitingConfirm { name, avatar } => {
                        m.insert("name".to_owned(), Value::String(name.clone()));
                        m.insert(
                            "avatar".to_owned(),
                            avatar
                                .as_ref()
                                .map_or(Value::Null, |a| Value::String(a.clone())),
                        );
                    }
                    LoginStep::Failed(reason) => {
                        let msg = match reason {
                            FailReason::Text(s) => s.clone(),
                            FailReason::Core(kind) => render_core_fail(kind),
                        };
                        m.insert("message".to_owned(), Value::String(msg));
                    }
                    LoginStep::Generating | LoginStep::WaitingScan | LoginStep::Expired => {}
                }
                Value::Object(m)
            }
        };

        let profile_val = match &self.profile {
            None => Value::Null,
            Some(p) => json!({
                "user_id": p.user_id,
                "display_name": p.display_name,
                "avatar": p.avatar,
                "phone": p.phone,
            }),
        };

        let mut prefs_map = Map::new();
        for (k, v) in &self.prefs {
            prefs_map.insert(k.clone(), Value::String(v.clone()));
        }

        json!({
            "phase": phase_val,
            "profile": profile_val,
            "sign_out_notice": self.sign_out_notice,
            "self_conversation_id": self.self_conversation_id,
            "prefs": Value::Object(prefs_map),
        })
    }
}

impl fmt::Debug for SessionSnapshot {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("SessionSnapshot")
            .field("phase", &self.phase)
            .field("has_profile", &self.profile.is_some())
            .field("has_sign_out_notice", &self.sign_out_notice.is_some())
            .field("has_self_conv", &self.self_conversation_id.is_some())
            .field("prefs_count", &self.prefs.len())
            .finish()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn debug_output_never_leaks_sensitive_values() {
        let st = SessionState {
            phase: Phase::Login(LoginState {
                step: LoginStep::WaitingConfirm {
                    name: "SECRET_NAME".to_owned(),
                    avatar: Some("https://secret.example/avt.jpg".to_owned()),
                },
                qr_payload: Some("SECRET_QR_PAYLOAD".to_owned()),
                qr_png: Some(vec![1, 2, 3, 4]),
            }),
            profile: Some(Profile {
                user_id: "999888".to_owned(),
                display_name: "SECRET_PROFILE".to_owned(),
                avatar: Some("https://secret.example/p.jpg".to_owned()),
                phone: Some("+84900000000".to_owned()),
            }),
            ..SessionState::default()
        };
        let dbg = format!("{st:?}");
        assert!(!dbg.contains("SECRET_NAME"));
        assert!(!dbg.contains("SECRET_QR_PAYLOAD"));
        assert!(!dbg.contains("SECRET_PROFILE"));
        assert!(!dbg.contains("84900000000"));
        assert!(!dbg.contains("secret.example"));
    }

    #[test]
    fn case_json_matches_schema_shapes() {
        let snap = SessionSnapshot {
            phase: Phase::Login(LoginState {
                step: LoginStep::WaitingConfirm {
                    name: "An".to_owned(),
                    avatar: None,
                },
                qr_payload: Some("qr-1".to_owned()),
                qr_png: Some(vec![9, 9]),
            }),
            profile: None,
            sign_out_notice: None,
            self_conversation_id: None,
            prefs: BTreeMap::new(),
        };
        let v = snap.to_case_json(&|_| String::new());
        assert_eq!(v["phase"]["kind"], "login");
        assert_eq!(v["phase"]["step"], "waiting_confirm");
        assert_eq!(v["phase"]["qr"], "qr-1");
        assert_eq!(v["phase"]["name"], "An");
        assert_eq!(v["phase"]["avatar"], Value::Null);
        assert!(v["phase"].get("message").is_none());
        assert!(v["phase"].get("qr_png").is_none());
    }
}
