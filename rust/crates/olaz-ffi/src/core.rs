//! `CoreEngine` & `CoreHost`: UniFFI export for the `olaz-core` actor and change stream (ADR-016).
//!
//! Credentials and user-facing personal data never reach `Debug` output or error messages (ADR-008).

use std::fmt;
use std::sync::Arc;

use olaz_core::{
    Command, CoreChanges, CoreFailKind, CoreHandle, FailReason, Host, LegacyCookie, LoginState,
    LoginStep, Phase, Profile, SessionEffectRunner, SessionSnapshot,
};
use olaz_net::{LoginAccount, NetworkErrorKind};

use crate::error::{CoreError, NetworkKind};
use crate::runtime::{run, runtime};
use crate::session::CoreSession;

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
    async fn set_pref(&self, key: String, value: String);
    async fn prepare_store(&self, user_id: String, account: LoginAccountRecord);
    async fn start_ws(&self, endpoints: Vec<String>, zpw_sek: String);
    async fn start_long_poll(&self);
    async fn start_bootstrap(&self);
    async fn offer_first_login_transfer(&self, force: bool);
    async fn reset_domains(&self);
    async fn persist_session(&self, snapshot_json: String);
    async fn clear_session(&self);
    async fn mark_expired(&self, snapshot_json: String);
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

    async fn set_pref(&self, key: String, value: String) {
        self.0.set_pref(key, value).await;
    }

    async fn prepare_store(&self, user_id: String, account: LoginAccount) {
        self.0.prepare_store(user_id, account.into()).await;
    }

    async fn start_ws(&self, endpoints: Vec<String>, zpw_sek: String) {
        self.0.start_ws(endpoints, zpw_sek).await;
    }

    async fn start_long_poll(&self) {
        self.0.start_long_poll().await;
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
}

/// The `olaz-core` actor handle exported to Swift.
///
/// Owns session state and drives boot, QR login, expiry, and logout over the shared [`CoreSession`].
/// Swift pushes commands via sync/async methods and pulls coalesced updates via [`Self::next_changes`].
#[derive(uniffi::Object)]
pub struct CoreEngine {
    handle: Arc<CoreHandle>,
}

#[uniffi::export]
impl CoreEngine {
    /// Starts the `olaz-core` actor on the shared tokio runtime.
    #[uniffi::constructor]
    pub fn new(session: Arc<CoreSession>, host: Arc<dyn CoreHost>) -> Result<Arc<Self>, CoreError> {
        let rt_handle = runtime()?.handle().clone();
        let runner = SessionEffectRunner::with_default_domains(
            Arc::clone(&session.client),
            Arc::new(FfiHostBridge(host)),
            rt_handle.clone(),
            session.default_domains.clone(),
        );
        let handle = CoreHandle::start(Arc::new(runner), rt_handle);
        Ok(Arc::new(Self {
            handle: Arc::new(handle),
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

    /// Stops the actor, aborts in-flight session tasks, and closes `next_changes()`.
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
        async fn set_pref(&self, _key: String, _value: String) {}
        async fn prepare_store(&self, _user_id: String, _account: LoginAccountRecord) {}
        async fn start_ws(&self, _endpoints: Vec<String>, _zpw_sek: String) {}
        async fn start_long_poll(&self) {}
        async fn start_bootstrap(&self) {}
        async fn offer_first_login_transfer(&self, _force: bool) {}
        async fn reset_domains(&self) {}
        async fn persist_session(&self, _snapshot_json: String) {}
        async fn clear_session(&self) {}
        async fn mark_expired(&self, _snapshot_json: String) {}
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
