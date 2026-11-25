//! Session state, the serde-serializable snapshot Swift persists, IMEI generation and the
//! login-config merge.

use olaz_crypto::{bool_value, int64, md5_hex, parse_secret_key, random_hex, string};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

use crate::cookie::is_valid_zpw_sek;
use crate::domains::{USER_AGENT, ZPW_TYPE, ZPW_WEB_TYPE, ZaloDomains};
use crate::request::is_valid_secret_key;

/// Result of [`crate::SessionClient::session_status`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SessionStatus {
    Valid,
    Expired,
    Unreachable,
}

/// Logged-in account (Swift `ZaloLoginAccount`; same JSON keys).
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct LoginAccount {
    pub user_id: String,
    pub display_name: String,
    pub avatar: String,
    pub phone: String,
    #[serde(rename = "send2MeId")]
    pub send2me_id: String,
    pub dkey: String,
    pub zpw_enk: String,
    pub zpw_sek: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub need_sync_msg: Option<bool>,
}

/// Everything Swift needs to persist (Keychain/vault sealing stays in Swift). Same JSON keys as
/// `StoredNativeSession`, with the account in the clear under `plainAccount`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionSnapshot {
    pub zpw_type: Option<String>,
    pub imei: String,
    pub computer_name: String,
    pub domains: ZaloDomains,
    pub plain_account: Option<LoginAccount>,
    pub expired_at: Option<f64>,
}

/// `<uuid v4 lowercase>-<md5(userAgent)>`, 69 characters (Swift `generateIMEI`).
pub fn generate_imei() -> String {
    let h = random_hex(32);
    let variant = match h.as_bytes()[16] % 4 {
        0 => '8',
        1 => '9',
        2 => 'a',
        _ => 'b',
    };
    let uuid = format!(
        "{}-{}-4{}-{variant}{}-{}",
        &h[0..8],
        &h[8..12],
        &h[13..16],
        &h[17..20],
        &h[20..32]
    );
    format!("{uuid}-{}", md5_hex(USER_AGENT))
}

/// True for an IMEI Swift would keep: 69 characters ending in `md5(userAgent)`.
pub fn is_current_imei(imei: &str) -> bool {
    imei.chars().count() == 69 && imei.ends_with(&md5_hex(USER_AGENT))
}

/// Mutable session fields (Swift actor properties that belong to the transport layer).
#[derive(Debug, Clone)]
pub struct SessionState {
    pub domains: ZaloDomains,
    pub imei: String,
    pub computer_name: String,
    /// Raw `zpw_enk` bytes (16 or 32).
    pub secret_key: Option<Vec<u8>>,
    pub zpw_sek: Option<String>,
    pub account: Option<LoginAccount>,
    pub expired_at: Option<f64>,
    pub server_self_g: i64,
    pub server_qr_form: i64,
    pub needs_pc_type_upgrade: bool,
    pub last_client_id_ms: i64,
    pub seeded_next_client_id: Option<i64>,
    pub cloud_viewer_key: Option<String>,
    pub cloud_enk: Option<String>,
}

impl SessionState {
    pub fn new(imei: String, computer_name: String) -> Self {
        Self {
            domains: ZaloDomains::default(),
            imei,
            computer_name,
            secret_key: None,
            zpw_sek: None,
            account: None,
            expired_at: None,
            server_self_g: 0,
            server_qr_form: 0,
            needs_pc_type_upgrade: false,
            last_client_id_ms: 0,
            seeded_next_client_id: None,
            cloud_viewer_key: None,
            cloud_enk: None,
        }
    }

    /// Swift `isAuthenticated`.
    pub fn is_authenticated(&self) -> bool {
        let has_account = self.account.as_ref().is_some_and(|a| !a.user_id.is_empty());
        let has_sek = self.zpw_sek.as_ref().is_some_and(|s| !s.is_empty());
        let has_key = self
            .secret_key
            .as_ref()
            .is_some_and(|k| is_valid_secret_key(k));
        has_account && has_sek && has_key
    }

    /// Seeds the deterministic client id sequence (test recorder).
    pub fn seed_next_client_id(&mut self, next: i64) {
        self.seeded_next_client_id = Some(next);
        self.last_client_id_ms = next - 1;
    }

    /// Swift `nextClientId`: epoch ms, strictly increasing.
    pub fn next_client_id(&mut self, now_ms: i64) -> i64 {
        if let Some(seeded) = self.seeded_next_client_id {
            self.seeded_next_client_id = Some(seeded + 1);
            self.last_client_id_ms = seeded;
            return seeded;
        }
        let next = if now_ms > self.last_client_id_ms {
            now_ms
        } else {
            self.last_client_id_ms + 1
        };
        self.last_client_id_ms = next;
        next
    }

    /// Swift `updateCredentials`.
    pub fn update_credentials(
        &mut self,
        account: LoginAccount,
        secret_key: Vec<u8>,
        zpw_sek: String,
        domains: Option<ZaloDomains>,
    ) {
        self.account = Some(account);
        self.secret_key = Some(secret_key);
        self.zpw_sek = Some(zpw_sek);
        if let Some(domains) = domains {
            self.domains = domains;
        }
        self.expired_at = None;
        self.cloud_viewer_key = None;
        self.cloud_enk = None;
    }

    /// Swift `clearSession` minus file/cookie-storage side effects.
    pub fn clear(&mut self) {
        self.account = None;
        self.zpw_sek = None;
        self.secret_key = None;
        self.expired_at = None;
        self.cloud_viewer_key = None;
        self.cloud_enk = None;
        self.domains = ZaloDomains::default();
    }

    pub fn snapshot(&self) -> SessionSnapshot {
        SessionSnapshot {
            zpw_type: Some(ZPW_TYPE.to_owned()),
            imei: self.imei.clone(),
            computer_name: self.computer_name.clone(),
            domains: self.domains.clone(),
            plain_account: self.account.clone(),
            expired_at: self.expired_at,
        }
    }

    /// Swift `loadSavedSession` after the vault was opened: returns `false` when the stored
    /// account lacks a usable `zpw_sek` / `zpw_enk`.
    pub fn restore(&mut self, stored: SessionSnapshot) -> bool {
        let saved_type = stored.zpw_type.as_deref().unwrap_or(ZPW_WEB_TYPE);
        self.needs_pc_type_upgrade = saved_type != ZPW_TYPE;
        if self.needs_pc_type_upgrade {
            if stored.imei.chars().count() == 69 {
                self.imei = stored.imei.clone();
            }
        } else if is_current_imei(&stored.imei) {
            self.imei = stored.imei.clone();
        }
        if !stored.computer_name.is_empty() {
            self.computer_name = stored.computer_name;
        }
        self.domains = stored.domains;
        self.domains.heal_from_verified();
        self.expired_at = stored.expired_at;

        let Some(account) = stored.plain_account else {
            return false;
        };
        if account.zpw_sek.is_empty() || account.zpw_enk.is_empty() {
            return false;
        }
        let key = parse_secret_key(&account.zpw_enk);
        if !is_valid_secret_key(&key) {
            return false;
        }
        self.zpw_sek = Some(account.zpw_sek.clone());
        self.secret_key = Some(key);
        self.account = Some(account);
        true
    }

    /// Swift `applyLoginConfig`: merges `getLoginInfo` / `confirm` data into key, cookie, account
    /// and service map.
    pub fn apply_login_config(&mut self, cfg: &Map<String, Value>) {
        let acct = cfg.get("account").and_then(Value::as_object);
        let acct_get = |k: &str| acct.and_then(|a| a.get(k));
        let first_non_empty = |values: [Option<&Value>; 5]| {
            values
                .into_iter()
                .map(|v| string(v))
                .find(|s| !s.is_empty())
                .unwrap_or_default()
        };
        let uid = first_non_empty([
            cfg.get("uid"),
            cfg.get("userId"),
            acct_get("userId"),
            acct_get("uid"),
            cfg.get("dkey"),
        ]);
        let dkey = string(cfg.get("dkey"));
        let enk = string(cfg.get("zpw_enk"));
        let send2me = string(cfg.get("send2me_id"));
        let sek = [cfg.get("zpw_sek"), acct_get("zpw_sek")]
            .into_iter()
            .map(|v| string(v))
            .find(|s| is_valid_zpw_sek(Some(s)))
            .unwrap_or_default();
        let profile_name = cfg
            .get("settings")
            .and_then(Value::as_object)
            .and_then(|s| s.get("profile"))
            .and_then(Value::as_object)
            .and_then(|p| p.get("name"));
        let name = [
            acct_get("display_name"),
            cfg.get("display_name"),
            profile_name,
        ]
        .into_iter()
        .map(|v| string(v))
        .find(|s| !s.is_empty())
        .unwrap_or_default();
        let has_pc_client = int64(cfg.get("has_pc_client"));
        let need_sync_flag =
            bool_value(cfg.get("need_sync_msg").or_else(|| cfg.get("needSyncMsg")));

        if !enk.is_empty() {
            let parsed = parse_secret_key(&enk);
            if is_valid_secret_key(&parsed) {
                self.secret_key = Some(parsed);
            }
        }
        if is_valid_zpw_sek(Some(&sek)) {
            self.zpw_sek = Some(sek.clone());
        }

        let mut current = self.account.take().unwrap_or_default();
        if !uid.is_empty() {
            current.user_id = uid;
        }
        if !dkey.is_empty() {
            current.dkey = dkey;
        }
        if !enk.is_empty() {
            current.zpw_enk = enk;
        }
        if is_valid_zpw_sek(Some(&sek)) {
            current.zpw_sek = sek;
        } else if !is_valid_zpw_sek(Some(&current.zpw_sek))
            && let Some(existing) = self
                .zpw_sek
                .as_deref()
                .filter(|s| is_valid_zpw_sek(Some(s)))
        {
            current.zpw_sek = existing.to_owned();
        }
        if !name.is_empty() {
            current.display_name = name;
        }
        if !send2me.is_empty() {
            current.send2me_id = send2me;
        }
        if let Some(flag) = need_sync_flag {
            current.need_sync_msg = Some(flag);
        } else if let Some(has) = has_pc_client {
            current.need_sync_msg = Some(has == 0);
        }
        self.account = Some(current);
        self.domains.apply_server_info(cfg);
        self.expired_at = None;
    }
}
