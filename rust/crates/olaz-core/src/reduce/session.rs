//! Pure reducer for the session domain: boot, QR login, log out, session expiry, and profile.

use olaz_net::{LoginAccount, QrTicket, ServerSettingsSource, SessionStatus};

use crate::changes::DirtyKey;
use crate::effect::{Effect, HostCall};
use crate::input::{Command, Input, SessionFailure, StoreToken};
use crate::reduce::{ReduceOutput, bootstrap, transport};
use crate::state::{
    AttestFlags, CoreState, LoginState, LoginStep, PendingStore, Phase, Profile, SessionState,
};

/// Default Vietnamese display name when the server returns an empty string (Swift `applyAccountProfile`).
pub const DEFAULT_DISPLAY_NAME: &str = "Người dùng Zalo";

/// Expiry notice shown when boot detects an expired saved session (Swift `bootSession`).
pub const BOOT_EXPIRED_NOTICE: &str =
    "Phiên đăng nhập đã hết hạn. Vui lòng quét mã QR để đăng nhập lại.";

const DEFAULT_QR_LANGUAGE: &str = "vi";
const PREF_DID_OFFER_INITIAL_SYNC: &str = "didOfferInitialSync";

pub fn reduce_session(state: &mut CoreState, input: Input, out: &mut ReduceOutput) {
    match input {
        Input::Command(cmd) => reduce_command(state, cmd, out),

        Input::SavedSessionLoaded {
            boot_gen,
            restored,
            account,
            ws_endpoints,
        } => {
            if boot_gen != state.session.boot_gen {
                return;
            }
            if !restored {
                out.effects.push(Effect::LoadLegacyCookie { boot_gen });
                return;
            }
            match account {
                Some(acc) if !acc.user_id.is_empty() => {
                    begin_store_prepare_for_boot(state, boot_gen, acc, ws_endpoints, out);
                }
                _ => {
                    tracing::debug!("session: saved session has empty user id, starting qr login");
                    start_qr_login(&mut state.session, out);
                }
            }
        }

        Input::LegacyCookieResult {
            boot_gen,
            account,
            ws_endpoints,
            profile_synced,
        } => {
            if boot_gen != state.session.boot_gen {
                return;
            }
            match account {
                Some(acc) if !acc.user_id.is_empty() => {
                    // `tryRestoreLegacyCookieSession` ran `completeLogin`: `syncProfileMe` saves
                    // if profile was returned, then `completeLogin` saves once the account is set.
                    if profile_synced {
                        out.effects.push(Effect::Host(HostCall::PersistSession));
                    }
                    out.effects.push(Effect::Host(HostCall::PersistSession));
                    begin_store_prepare_for_boot(state, boot_gen, acc, ws_endpoints, out);
                }
                _ => {
                    tracing::debug!(
                        "session: no saved session or legacy cookie, starting qr login"
                    );
                    start_qr_login(&mut state.session, out);
                }
            }
        }

        Input::PrepareStoreDone {
            token,
            transport_state,
            local_hydration,
        } => {
            let matches = match (&state.session.pending_store, token) {
                (Some(PendingStore::Boot { boot_gen, .. }), StoreToken::Boot(t)) => {
                    *boot_gen == t && *boot_gen == state.session.boot_gen
                }
                (Some(PendingStore::QrComplete { qr_gen, .. }), StoreToken::Qr(t)) => {
                    *qr_gen == t && *qr_gen == state.session.qr_gen
                }
                _ => false,
            };
            if !matches {
                return;
            }
            let Some(pending) = state.session.pending_store.take() else {
                return;
            };
            state.transport.poll_state = transport_state.poll_state;
            state.transport.ws_cursors = transport_state.ws_cursors;
            if let Some(hydration) = local_hydration {
                let my_uid = state
                    .session
                    .profile
                    .as_ref()
                    .map(|p| p.user_id.clone())
                    .unwrap_or_default();
                let my_avatar = state
                    .session
                    .profile
                    .as_ref()
                    .and_then(|p| p.avatar.clone());
                let self_conv_id = state.session.self_conversation_id.clone();
                let starred_ids = hydration.starred_ids.clone();
                let seen_reaction_event_ids = hydration.seen_reaction_event_ids.clone();
                let notif_enabled = hydration.notif_enabled;
                let notif_sound = hydration.notif_sound;
                let muted_threads = hydration.muted_threads.clone();
                state.conversations.hydrate_from_local(
                    &mut state.contacts,
                    *hydration,
                    &my_uid,
                    my_avatar.as_deref(),
                    self_conv_id.as_deref(),
                );
                state
                    .actions
                    .seen_reactions
                    .hydrate_from_saved(&seen_reaction_event_ids);
                state.actions.starred_ids = starred_ids.into_iter().collect();
                out.dirty.insert(DirtyKey::Conversations);
                out.dirty.insert(DirtyKey::ConversationFlags);
                out.dirty.insert(DirtyKey::ConversationExtras);
                if !state.actions.starred_ids.is_empty() {
                    out.dirty.insert(DirtyKey::StarredIds);
                }
                // U16: hydrate notification preferences from SQLite.
                let init_auth = (state.notify.settings.authorization
                    == crate::notify::NotifAuthorization::Unknown)
                    .then_some(crate::notify::NotifAuthorization::Unavailable);
                crate::reduce::notify::hydrate_notification_prefs(
                    state,
                    notif_enabled,
                    notif_sound,
                    muted_threads,
                    init_auth,
                    out,
                );
            }
            match pending {
                PendingStore::Boot {
                    boot_gen,
                    ws_endpoints,
                } => {
                    state.session.boot_ws_endpoints = ws_endpoints;
                    state.session.phase = Phase::Ready;
                    out.dirty.insert(DirtyKey::Session);
                    out.effects.push(Effect::CheckSessionStatus { boot_gen });
                }
                PendingStore::QrComplete {
                    ws_endpoints,
                    need_sync_msg,
                    ..
                } => {
                    state
                        .session
                        .prefs
                        .insert(PREF_DID_OFFER_INITIAL_SYNC.to_owned(), "0".to_owned());
                    state.session.phase = Phase::Ready;
                    out.dirty.insert(DirtyKey::Session);
                    out.effects.push(Effect::SetPref {
                        key: PREF_DID_OFFER_INITIAL_SYNC.to_owned(),
                        value: "0".to_owned(),
                    });
                    transport::start_transport(state, ws_endpoints, out);
                    out.effects.push(Effect::Host(HostCall::StartBootstrap));
                    out.effects
                        .push(Effect::Host(HostCall::OfferFirstLoginTransfer {
                            force: need_sync_msg,
                        }));
                }
            }
        }

        Input::SessionStatusResult {
            boot_gen,
            status,
            updated_from_login_info,
            ws_endpoints,
        } => {
            if boot_gen != state.session.boot_gen {
                return;
            }
            match status {
                SessionStatus::Valid => {
                    tracing::debug!("session: status valid, syncing profile");
                    state.session.boot_ws_endpoints = ws_endpoints;
                    if updated_from_login_info {
                        out.effects.push(Effect::Host(HostCall::PersistSession));
                    }
                    out.effects.push(Effect::SyncProfileMe { boot_gen });
                }
                SessionStatus::Expired => {
                    tracing::debug!("session: status expired");
                    enter_session_expired(state, BOOT_EXPIRED_NOTICE.to_owned(), out);
                }
                SessionStatus::Unreachable => {
                    tracing::debug!("session: status unreachable, starting from cache");
                    let endpoints = state.session.boot_ws_endpoints.clone();
                    transport::start_transport(state, endpoints, out);
                    out.effects.push(Effect::Host(HostCall::StartBootstrap));
                }
            }
        }

        Input::SyncProfileMeDone {
            boot_gen,
            profile_synced,
            account,
            ws_endpoints,
        } => {
            if boot_gen != state.session.boot_gen {
                return;
            }
            if profile_synced {
                out.effects.push(Effect::Host(HostCall::PersistSession));
            }
            if let Some(acc) = account {
                apply_account_profile(&mut state.session, &acc);
                out.dirty.insert(DirtyKey::Session);
            }
            transport::start_transport(state, ws_endpoints, out);
            out.effects.push(Effect::Host(HostCall::StartBootstrap));
        }

        Input::QrRequested { qr_gen, result } => {
            if qr_gen != state.session.qr_gen {
                return;
            }
            match result {
                Ok(ticket) => {
                    state.session.phase = Phase::Login(waiting_scan_state(&ticket));
                    out.dirty.insert(DirtyKey::Session);
                    out.effects.push(Effect::WaitQrScan { qr_gen, ticket });
                }
                Err(failure) => apply_qr_failure(&mut state.session, failure, out),
            }
        }

        Input::QrRotated { qr_gen, ticket } => {
            if qr_gen != state.session.qr_gen {
                return;
            }
            state.session.phase = Phase::Login(waiting_scan_state(&ticket));
            out.dirty.insert(DirtyKey::Session);
        }

        Input::QrScanned { qr_gen, result } => {
            if qr_gen != state.session.qr_gen {
                return;
            }
            match result {
                Ok(scan) => {
                    state.session.phase = Phase::Login(LoginState {
                        step: LoginStep::WaitingConfirm {
                            name: scan.display_name,
                            avatar: scan.avatar,
                        },
                        qr_payload: non_empty_string(&scan.active_ticket.qr_payload),
                        qr_png: scan.active_ticket.png_data.clone(),
                    });
                    out.dirty.insert(DirtyKey::Session);
                    out.effects.push(Effect::WaitQrConfirm {
                        qr_gen,
                        ticket: scan.active_ticket,
                    });
                }
                Err(failure) => apply_qr_failure(&mut state.session, failure, out),
            }
        }

        Input::QrConfirmed { qr_gen, result } => {
            if qr_gen != state.session.qr_gen {
                return;
            }
            match result {
                Ok(()) => {
                    state.session.phase = Phase::SigningIn;
                    out.dirty.insert(DirtyKey::Session);
                    out.effects.push(Effect::CompleteLogin { qr_gen });
                }
                Err(failure) => apply_qr_failure(&mut state.session, failure, out),
            }
        }

        Input::LoginCompleted { qr_gen, result } => {
            if qr_gen != state.session.qr_gen {
                return;
            }
            match result {
                Ok(done) => {
                    state.session.sign_out_notice = None;
                    apply_account_profile(&mut state.session, &done.account);
                    out.dirty.insert(DirtyKey::Session);
                    state.session.pending_store = Some(PendingStore::QrComplete {
                        qr_gen,
                        ws_endpoints: done.ws_endpoints,
                        need_sync_msg: done.account.need_sync_msg == Some(true),
                    });
                    if done.profile_synced {
                        out.effects.push(Effect::Host(HostCall::PersistSession));
                    }
                    out.effects.push(Effect::Host(HostCall::PersistSession));
                    out.effects.push(Effect::Host(HostCall::PrepareStore {
                        token: StoreToken::Qr(qr_gen),
                        user_id: done.account.user_id.clone(),
                        account: Box::new(done.account),
                        identities: Box::new(state.contacts.to_identity_table()),
                    }));
                }
                Err(failure) => apply_qr_failure(&mut state.session, failure, out),
            }
        }

        Input::ServerSettingsReceived { source, payload } => {
            apply_server_settings(&mut state.session, source, &payload, out);
        }

        _ => {}
    }
}

fn reduce_command(state: &mut CoreState, cmd: Command, out: &mut ReduceOutput) {
    match cmd {
        Command::Start => {
            if state.session.started {
                return;
            }
            state.session.started = true;
            state.session.boot_gen = state.session.boot_gen.saturating_add(1);
            out.effects.push(Effect::LoadSavedSession {
                boot_gen: state.session.boot_gen,
            });
        }
        Command::RefreshQr => {
            state.session.sign_out_notice = None;
            start_qr_login(&mut state.session, out);
        }
        Command::LogOut => {
            tracing::debug!("session: log out");
            reset_session_fields(&mut state.session);
            state.conversations.reset();
            // U4-bootstrap
            bootstrap::cancel_bootstrap_state(state, out);
            state.messages.reset();
            state.contacts.reset();
            // U5
            if state.typing.reset_session() {
                out.dirty.insert(DirtyKey::Typing);
            }
            state.send.reset(out);
            if state.forward.reset(out) {
                out.dirty.insert(DirtyKey::ForwardRequest);
            }
            // U11
            if state.cloud.reset_session() {
                out.dirty.insert(DirtyKey::Cloud);
            }
            // U13
            if state.stickers.suggest_setting.is_some() {
                out.dirty.insert(DirtyKey::StickerSuggest);
            }
            state.stickers.reset();
            crate::reduce::composer::reset_composer(state, false, out);
            state.search.reset(out);
            // U6
            let (undo_changed, confirm_changed, auto_del_changed, starred_changed) =
                state.actions.reset_session();
            if undo_changed {
                out.dirty.insert(DirtyKey::DeleteUndo);
            }
            if confirm_changed {
                out.dirty.insert(DirtyKey::MessageConfirm);
            }
            if auto_del_changed {
                out.dirty.insert(DirtyKey::AutoDelete);
            }
            if starred_changed {
                out.dirty.insert(DirtyKey::StarredIds);
            }
            // U16
            state.notify.reset_on_logout();
            out.dirty.insert(DirtyKey::NotificationSettings);
            out.dirty.insert(DirtyKey::Aliases);
            // U7
            if state.pins.reset_session() {
                out.dirty.insert(DirtyKey::Pins);
            }
            // U12
            state.polls.reset();
            state.session.sign_out_notice = None;
            state.session.qr_gen = state.session.qr_gen.saturating_add(1);
            state.session.phase = Phase::Login(LoginState::generating());
            out.dirty.insert(DirtyKey::Session);
            out.dirty.insert(DirtyKey::Conversations);
            out.dirty.insert(DirtyKey::ConversationFlags);
            out.dirty.insert(DirtyKey::ConversationExtras);
            out.dirty.insert(DirtyKey::ConversationUi);
            out.dirty.insert(DirtyKey::ConversationPrompt);
            out.dirty.insert(DirtyKey::MessagesResetAll);
            out.dirty.insert(DirtyKey::Contacts);
            // U12
            out.dirty.insert(DirtyKey::Polls);

            // Order matches Swift `logOut`: cancel tasks, stop transport, clear session,
            // detach SQLite store, reset domains, start QR.
            out.effects.push(Effect::CancelSessionTasks);
            transport::stop_transport(state, true, out);
            out.effects.push(Effect::ClearCoreSession);
            out.effects.push(Effect::Host(HostCall::ClearSession));
            out.effects.push(Effect::DetachStore);
            out.effects.push(Effect::Host(HostCall::ResetDomains));
            out.effects.push(Effect::RequestQr {
                qr_gen: state.session.qr_gen,
                language: DEFAULT_QR_LANGUAGE.to_owned(),
            });
        }
        Command::SessionExpired { reason } => {
            enter_session_expired(state, reason, out);
        }
        Command::ApplyAccountProfile(account) => {
            apply_account_profile(&mut state.session, &account);
            out.dirty.insert(DirtyKey::Session);
        }
        _ => {}
    }
}

fn begin_store_prepare_for_boot(
    state: &mut CoreState,
    boot_gen: u64,
    account: LoginAccount,
    ws_endpoints: Vec<String>,
    out: &mut ReduceOutput,
) {
    apply_account_profile(&mut state.session, &account);
    out.dirty.insert(DirtyKey::Session);
    state.session.pending_store = Some(PendingStore::Boot {
        boot_gen,
        ws_endpoints,
    });
    out.effects.push(Effect::Host(HostCall::PrepareStore {
        token: StoreToken::Boot(boot_gen),
        user_id: account.user_id.clone(),
        account: Box::new(account),
        identities: Box::new(state.contacts.to_identity_table()),
    }));
}

fn start_qr_login(state: &mut SessionState, out: &mut ReduceOutput) {
    state.qr_gen = state.qr_gen.saturating_add(1);
    state.phase = Phase::Login(LoginState::generating());
    out.dirty.insert(DirtyKey::Session);
    out.effects.push(Effect::CancelSessionTasks);
    out.effects.push(Effect::RequestQr {
        qr_gen: state.qr_gen,
        language: DEFAULT_QR_LANGUAGE.to_owned(),
    });
}

pub(crate) fn enter_session_expired(state: &mut CoreState, reason: String, out: &mut ReduceOutput) {
    tracing::debug!("session: expired");
    reset_session_fields(&mut state.session);
    // U4-bootstrap: mirror Swift `markExpired -> hostResetDomains` domain teardown.
    state.conversations.reset();
    bootstrap::cancel_bootstrap_state(state, out);
    state.messages.reset();
    state.contacts.reset();
    // U5
    if state.typing.reset_session() {
        out.dirty.insert(DirtyKey::Typing);
    }
    state.send.reset(out);
    if state.forward.reset(out) {
        out.dirty.insert(DirtyKey::ForwardRequest);
    }
    // U13
    if state.stickers.suggest_setting.is_some() {
        out.dirty.insert(DirtyKey::StickerSuggest);
    }
    state.stickers.reset();
    crate::reduce::composer::reset_composer(state, false, out);
    state.search.reset(out);
    // U6
    let (undo_changed, confirm_changed, auto_del_changed, starred_changed) =
        state.actions.reset_session();
    if undo_changed {
        out.dirty.insert(DirtyKey::DeleteUndo);
    }
    if confirm_changed {
        out.dirty.insert(DirtyKey::MessageConfirm);
    }
    if auto_del_changed {
        out.dirty.insert(DirtyKey::AutoDelete);
    }
    if starred_changed {
        out.dirty.insert(DirtyKey::StarredIds);
    }
    // U16
    state.notify.reset_on_logout();
    out.dirty.insert(DirtyKey::NotificationSettings);
    out.dirty.insert(DirtyKey::Aliases);
    // U7
    if state.pins.reset_session() {
        out.dirty.insert(DirtyKey::Pins);
    }
    // U12
    state.polls.reset();
    state.session.sign_out_notice = Some(reason);
    state.session.qr_gen = state.session.qr_gen.saturating_add(1);
    state.session.phase = Phase::Login(LoginState::generating());
    out.dirty.insert(DirtyKey::Session);
    out.dirty.insert(DirtyKey::Conversations);
    out.dirty.insert(DirtyKey::ConversationFlags);
    out.dirty.insert(DirtyKey::ConversationExtras);
    out.dirty.insert(DirtyKey::ConversationUi);
    out.dirty.insert(DirtyKey::ConversationPrompt);
    out.dirty.insert(DirtyKey::MessagesResetAll);
    out.dirty.insert(DirtyKey::Contacts);
    // U12
    out.dirty.insert(DirtyKey::Polls);

    // Order matches Swift `handleSessionExpiredNotice`: cancel, stop transport, mark_expired, QR.
    // Unlike `logOut`, session expiry does not reset `ZaloDomains`.
    out.effects.push(Effect::CancelSessionTasks);
    transport::stop_transport(state, true, out);
    out.effects.push(Effect::MarkCoreSessionExpired);
    out.effects.push(Effect::Host(HostCall::MarkExpired));
    out.effects.push(Effect::RequestQr {
        qr_gen: state.session.qr_gen,
        language: DEFAULT_QR_LANGUAGE.to_owned(),
    });
}

fn apply_server_settings(
    state: &mut SessionState,
    source: ServerSettingsSource,
    payload: &serde_json::Map<String, serde_json::Value>,
    out: &mut ReduceOutput,
) {
    let attest_obj = AttestFlags::find_in_payload(payload);
    // A post-login payload without `features.attest` must not clear flags already learned from
    // `getServerInfo`.
    if source == ServerSettingsSource::LoginInfo
        && attest_obj.is_none()
        && state.last_attest_flags.is_some()
    {
        return;
    }
    let flags = AttestFlags::from_attest_map(attest_obj);
    if state.last_attest_flags != Some(flags) {
        state.last_attest_flags = Some(flags);
        out.effects.push(Effect::EngineLog(flags.engine_log_line()));
        if state.attest_enforced != flags.enforce {
            state.attest_enforced = flags.enforce;
            out.dirty.insert(DirtyKey::Session);
        }
    }
}

fn reset_session_fields(state: &mut SessionState) {
    state.boot_gen = state.boot_gen.saturating_add(1);
    state.pending_store = None;
    state.boot_ws_endpoints.clear();
    state.profile = None;
    state.self_conversation_id = None;
    state.prefs.clear();
    state.attest_enforced = false;
    state.last_attest_flags = None;
}

fn apply_qr_failure(state: &mut SessionState, failure: SessionFailure, out: &mut ReduceOutput) {
    match failure {
        SessionFailure::Cancelled => {}
        SessionFailure::QrTimeout => {
            state.phase = Phase::Login(LoginState::expired());
            out.dirty.insert(DirtyKey::Session);
        }
        SessionFailure::Failed(reason) => {
            state.phase = Phase::Login(LoginState::failed(reason));
            out.dirty.insert(DirtyKey::Session);
        }
    }
}

/// Applies `ZaloEngine.applyAccountProfile` rules to `SessionState`.
pub fn apply_account_profile(state: &mut SessionState, account: &LoginAccount) {
    let display_name = if account.display_name.is_empty() {
        DEFAULT_DISPLAY_NAME.to_owned()
    } else {
        account.display_name.clone()
    };
    let avatar = non_empty_string(&account.avatar);
    let phone = non_empty_string(&account.phone);
    let self_conv = if account.send2me_id.is_empty() {
        account.user_id.clone()
    } else {
        account.send2me_id.clone()
    };
    state.profile = Some(Profile {
        user_id: account.user_id.clone(),
        display_name,
        avatar,
        phone,
    });
    state.self_conversation_id = Some(self_conv);
}

fn waiting_scan_state(ticket: &QrTicket) -> LoginState {
    LoginState {
        step: LoginStep::WaitingScan,
        qr_payload: non_empty_string(&ticket.qr_payload),
        qr_png: ticket.png_data.clone(),
    }
}

fn non_empty_string(s: &str) -> Option<String> {
    (!s.is_empty()).then(|| s.to_owned())
}

#[cfg(test)]
mod tests {
    use olaz_net::{NetworkErrorKind, QrScanResult};

    use super::*;
    use crate::input::CompletedLogin;
    use crate::reduce::reduce;
    use crate::state::{CoreFailKind, CoreState, FailReason, PersistedTransportState};

    fn sample_account(uid: &str) -> LoginAccount {
        LoginAccount {
            user_id: uid.to_owned(),
            display_name: "An".to_owned(),
            avatar: "https://cdn.example/avt.jpg".to_owned(),
            phone: "+84901234567".to_owned(),
            send2me_id: "self-1".to_owned(),
            dkey: "dk".to_owned(),
            zpw_enk: "MDEyMzQ1Njc4OWFiY2RlZg==".to_owned(),
            zpw_sek: "sek.1.2".to_owned(),
            need_sync_msg: Some(false),
        }
    }

    fn sample_ticket(payload: &str) -> QrTicket {
        QrTicket {
            token_id: "tok".to_owned(),
            qr_payload: payload.to_owned(),
            base64_png: None,
            png_data: None,
            chk_wait_scan: "http://fake/scan".to_owned(),
            chk_wait_cfirm: "http://fake/confirm".to_owned(),
            qr_timeout_seconds: 180,
            qr_retry: 3,
        }
    }

    #[test]
    fn start_twice_is_noop() {
        let mut state = CoreState::default();
        let out1 = reduce(&mut state, Input::Command(Command::Start));
        assert_eq!(out1.effects.len(), 1);
        assert!(matches!(
            out1.effects[0],
            Effect::LoadSavedSession { boot_gen: 1 }
        ));

        let out2 = reduce(&mut state, Input::Command(Command::Start));
        assert!(out2.effects.is_empty());
        assert!(out2.dirty.is_empty());
    }

    #[test]
    fn profile_defaults_when_fields_empty() {
        let mut state = CoreState::default();
        let acc = LoginAccount {
            user_id: "42".to_owned(),
            ..LoginAccount::default()
        };
        let out = reduce(
            &mut state,
            Input::Command(Command::ApplyAccountProfile(acc)),
        );
        assert!(out.dirty.contains(&DirtyKey::Session));
        assert_eq!(
            state.session.profile,
            Some(Profile {
                user_id: "42".to_owned(),
                display_name: DEFAULT_DISPLAY_NAME.to_owned(),
                avatar: None,
                phone: None,
            })
        );
        assert_eq!(state.session.self_conversation_id.as_deref(), Some("42"));
    }

    #[test]
    fn boot_saved_session_becomes_ready_before_status_returns() {
        let mut state = CoreState::default();
        reduce(&mut state, Input::Command(Command::Start));

        let out = reduce(
            &mut state,
            Input::SavedSessionLoaded {
                boot_gen: 1,
                restored: true,
                account: Some(sample_account("100")),
                ws_endpoints: vec!["wss://ws1".to_owned()],
            },
        );
        assert_eq!(state.session.phase, Phase::Starting);
        assert!(matches!(
            out.effects.as_slice(),
            [Effect::Host(HostCall::PrepareStore {
                token: StoreToken::Boot(1),
                ..
            })]
        ));

        let out = reduce(
            &mut state,
            Input::PrepareStoreDone {
                token: StoreToken::Boot(1),
                transport_state: PersistedTransportState::default(),
                local_hydration: None,
            },
        );
        assert_eq!(state.session.phase, Phase::Ready);
        assert!(matches!(
            out.effects.as_slice(),
            [Effect::CheckSessionStatus { boot_gen: 1 }]
        ));
    }

    #[test]
    fn boot_saved_session_empty_user_falls_back_to_qr() {
        let mut state = CoreState::default();
        reduce(&mut state, Input::Command(Command::Start));
        let out = reduce(
            &mut state,
            Input::SavedSessionLoaded {
                boot_gen: 1,
                restored: true,
                account: Some(LoginAccount::default()),
                ws_endpoints: vec![],
            },
        );
        assert_eq!(state.session.phase, Phase::Login(LoginState::generating()));
        assert!(matches!(
            out.effects.as_slice(),
            [
                Effect::CancelSessionTasks,
                Effect::RequestQr { qr_gen: 1, .. }
            ]
        ));
    }

    #[test]
    fn qr_full_login_emits_expected_host_order_and_pref() {
        let mut state = CoreState::default();
        reduce(&mut state, Input::Command(Command::Start));
        reduce(
            &mut state,
            Input::SavedSessionLoaded {
                boot_gen: 1,
                restored: false,
                account: None,
                ws_endpoints: vec![],
            },
        );
        reduce(
            &mut state,
            Input::LegacyCookieResult {
                boot_gen: 1,
                account: None,
                ws_endpoints: vec![],
                profile_synced: false,
            },
        );
        let t1 = sample_ticket("qr-1");
        reduce(
            &mut state,
            Input::QrRequested {
                qr_gen: 1,
                result: Ok(t1),
            },
        );
        let t2 = sample_ticket("qr-2");
        reduce(
            &mut state,
            Input::QrRotated {
                qr_gen: 1,
                ticket: t2.clone(),
            },
        );
        assert_eq!(
            state.session.phase,
            Phase::Login(LoginState {
                step: LoginStep::WaitingScan,
                qr_payload: Some("qr-2".to_owned()),
                qr_png: None,
            })
        );
        reduce(
            &mut state,
            Input::QrScanned {
                qr_gen: 1,
                result: Ok(QrScanResult {
                    display_name: "An".to_owned(),
                    avatar: None,
                    active_ticket: t2,
                }),
            },
        );
        reduce(
            &mut state,
            Input::QrConfirmed {
                qr_gen: 1,
                result: Ok(()),
            },
        );
        assert_eq!(state.session.phase, Phase::SigningIn);

        let mut acc = sample_account("100");
        acc.need_sync_msg = Some(true);
        let out = reduce(
            &mut state,
            Input::LoginCompleted {
                qr_gen: 1,
                result: Ok(CompletedLogin {
                    account: acc,
                    ws_endpoints: vec!["wss://ws1".to_owned()],
                    profile_synced: true,
                }),
            },
        );
        assert!(matches!(
            out.effects.as_slice(),
            [
                Effect::Host(HostCall::PersistSession),
                Effect::Host(HostCall::PersistSession),
                Effect::Host(HostCall::PrepareStore {
                    token: StoreToken::Qr(1),
                    ..
                })
            ]
        ));

        let out = reduce(
            &mut state,
            Input::PrepareStoreDone {
                token: StoreToken::Qr(1),
                transport_state: PersistedTransportState::default(),
                local_hydration: None,
            },
        );
        assert_eq!(state.session.phase, Phase::Ready);
        assert_eq!(
            state
                .session
                .prefs
                .get("didOfferInitialSync")
                .map(String::as_str),
            Some("0")
        );
        assert!(matches!(
            out.effects.as_slice(),
            [
                Effect::SetPref { .. },
                Effect::StartWs { ws_gen: 1, .. },
                Effect::StartLpTimer {
                    lp_gen: 1,
                    initial: true,
                    ..
                },
                Effect::Host(HostCall::StartBootstrap),
                Effect::Host(HostCall::OfferFirstLoginTransfer { force: true }),
            ]
        ));
    }

    #[test]
    fn logout_and_session_expired_preserve_host_order_and_ignore_stale_gen() {
        let mut state = CoreState::default();
        reduce(&mut state, Input::Command(Command::Start));
        let out = reduce(&mut state, Input::Command(Command::LogOut));
        assert!(matches!(
            out.effects.as_slice(),
            [
                Effect::CancelSessionTasks,
                Effect::StopWs {
                    reset_cursors: true
                },
                Effect::StopLongPoll,
                Effect::ClearCoreSession,
                Effect::Host(HostCall::ClearSession),
                Effect::DetachStore,
                Effect::Host(HostCall::ResetDomains),
                Effect::RequestQr { qr_gen: 1, .. }
            ]
        ));

        let out = reduce(
            &mut state,
            Input::Command(Command::SessionExpired {
                reason: "Hết hạn".to_owned(),
            }),
        );
        assert_eq!(state.session.sign_out_notice.as_deref(), Some("Hết hạn"));
        assert!(matches!(
            out.effects.as_slice(),
            [
                Effect::CancelSessionTasks,
                Effect::StopWs {
                    reset_cursors: true
                },
                Effect::StopLongPoll,
                Effect::MarkCoreSessionExpired,
                Effect::Host(HostCall::MarkExpired),
                Effect::RequestQr { qr_gen: 2, .. }
            ]
        ));

        // Stale QR result from qr_gen 1 must be ignored.
        let stale = reduce(
            &mut state,
            Input::QrRequested {
                qr_gen: 1,
                result: Err(SessionFailure::Failed(FailReason::Core(
                    CoreFailKind::Network(NetworkErrorKind::Other),
                ))),
            },
        );
        assert!(stale.dirty.is_empty());
        assert_eq!(state.session.phase, Phase::Login(LoginState::generating()));

        // RefreshQr clears sign_out_notice.
        let out = reduce(&mut state, Input::Command(Command::RefreshQr));
        assert_eq!(state.session.sign_out_notice, None);
        assert!(matches!(
            out.effects.as_slice(),
            [
                Effect::CancelSessionTasks,
                Effect::RequestQr { qr_gen: 3, .. }
            ]
        ));
    }

    #[test]
    fn attest_flags_absent_all_false_and_enforced_log_only_on_change() {
        let mut state = CoreState::default();
        let obj = |v: serde_json::Value| v.as_object().cloned().unwrap_or_default();

        // 1. Flags absent in getServerInfo -> all false, logged once, attest_enforced = false.
        let out = reduce(
            &mut state,
            Input::ServerSettingsReceived {
                source: ServerSettingsSource::ServerInfo,
                payload: obj(serde_json::json!({"setttings": {"trusted_device": {"self_g": 0}}})),
            },
        );
        assert!(!state.session.attest_enforced);
        assert!(out.dirty.is_empty());
        assert!(matches!(
            out.effects.as_slice(),
            [Effect::EngineLog(msg)]
                if msg == "attest: enable=false enable_on_login=false enforce=false enable_qos=false deactivated=false"
        ));

        // 2. Repeated all-false payload (explicit 0/false) -> no duplicate log.
        let out = reduce(
            &mut state,
            Input::ServerSettingsReceived {
                source: ServerSettingsSource::LoginInfo,
                payload: obj(serde_json::json!({
                    "data": {
                        "settings": {
                            "features": {
                                "attest": {
                                    "enable": false,
                                    "enable_on_login": 0,
                                    "enforce": false,
                                    "enable_qos": 0,
                                    "deactivated": false
                                }
                            }
                        }
                    }
                })),
            },
        );
        assert!(!state.session.attest_enforced);
        assert!(out.effects.is_empty());
        assert!(out.dirty.is_empty());

        // 3. Post-login settings enables enforce -> logs 5 booleans and sets attest_enforced = true.
        let out = reduce(
            &mut state,
            Input::ServerSettingsReceived {
                source: ServerSettingsSource::LoginInfo,
                payload: obj(serde_json::json!({
                    "data": {
                        "setttings": {
                            "features": {
                                "attest": {
                                    "enable": 1,
                                    "enable_on_login": true,
                                    "enforce": 1
                                }
                            }
                        }
                    }
                })),
            },
        );
        assert!(state.session.attest_enforced);
        assert!(out.dirty.contains(&DirtyKey::Session));
        assert!(matches!(
            out.effects.as_slice(),
            [Effect::EngineLog(msg)]
                if msg == "attest: enable=true enable_on_login=true enforce=true enable_qos=false deactivated=false"
        ));

        // 4. Subsequent post-login payload without features.attest preserves enforce=true without logging.
        let out = reduce(
            &mut state,
            Input::ServerSettingsReceived {
                source: ServerSettingsSource::LoginInfo,
                payload: obj(serde_json::json!({"data": {"uid": "100"}})),
            },
        );
        assert!(state.session.attest_enforced);
        assert!(out.effects.is_empty());
        assert!(out.dirty.is_empty());

        // 5. Same enforced flags repeated -> no duplicate log.
        let out = reduce(
            &mut state,
            Input::ServerSettingsReceived {
                source: ServerSettingsSource::ServerInfo,
                payload: obj(serde_json::json!({
                    "setttings": {
                        "features": {
                            "attest": {
                                "enable": true,
                                "enable_on_login": true,
                                "enforce": true,
                                "enable_qos": false,
                                "deactivated": false
                            }
                        }
                    }
                })),
            },
        );
        assert!(state.session.attest_enforced);
        assert!(out.effects.is_empty());
    }
}
