//! Pre-login discovery and QR login (`zpw_type=23`): `getServerInfo`, `reqqr`, scan / confirm
//! long-polls, `getLoginInfo`, profile sync and session status.

use std::collections::BTreeMap;
use std::time::Duration;

use olaz_crypto::{
    ParamCipher, decode_foundation_base64_ignoring_unknown, int64, parse_object, sign_key, string,
};
use serde_json::{Map, Value, json};
use tokio::time::{Instant, sleep};

use crate::client::SessionClient;
use crate::cookie::{extract_zpw_sek, is_valid_zpw_sek};
use crate::decode::{http_error, unwrap_decrypted_response};
use crate::domains::{ZPW_TYPE, ZPW_VER};
use crate::error::{NetError, ZaloSessionError};
use crate::http::{RequestOptions, Transport, sorted_query_string, url_path};
use crate::request::{ApiRequest, canonical_json};
use crate::session::{LoginAccount, SessionStatus};

/// QR login ticket (Swift `ZaloQRTicket`). `png_data` is `None` when the server sent only the
/// payload; Swift renders it with CoreImage.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct QrTicket {
    pub token_id: String,
    pub qr_payload: String,
    pub base64_png: Option<String>,
    pub png_data: Option<Vec<u8>>,
    pub chk_wait_scan: String,
    pub chk_wait_cfirm: String,
    pub qr_timeout_seconds: i64,
    pub qr_retry: i64,
}

/// Outcome of [`SessionClient::wait_for_qr_scan`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct QrScanResult {
    pub display_name: String,
    pub avatar: Option<String>,
    pub active_ticket: QrTicket,
}

/// Swift `parseQRTicket`.
pub fn parse_qr_ticket(d: &Map<String, Value>, fallback_cfirm: &str) -> Result<QrTicket, NetError> {
    let token_id = string(d.get("token_id").or_else(|| d.get("ntk")));
    let qr_payload = string(d.get("qr_cnt"));
    let raw_base64 = match d.get("base64_qr") {
        Some(Value::String(s)) if !s.is_empty() => Some(s.as_str()),
        _ => None,
    };
    let base64_png: Option<String> = raw_base64.map(|b64| match b64.split_once(',') {
        Some((_, rest)) if b64.starts_with("data:image") => rest.to_owned(),
        _ => b64.to_owned(),
    });
    let chk_scan = string(d.get("chk_wait_scan"));
    let chk_cfirm_raw = string(d.get("chk_wait_cfirm"));
    let chk_cfirm = if chk_cfirm_raw.is_empty() {
        fallback_cfirm.to_owned()
    } else {
        chk_cfirm_raw
    };
    let timeout = int64(d.get("qr_timeout")).unwrap_or(180);
    let retry = int64(d.get("qr_retry")).unwrap_or(3);

    if chk_scan.is_empty() {
        return Err(NetError::QrFailed("Thiếu endpoint chờ quét QR.".to_owned()));
    }
    let png = base64_png
        .as_deref()
        .and_then(|b| decode_foundation_base64_ignoring_unknown(b).ok());
    if png.is_none() && qr_payload.is_empty() {
        return Err(NetError::QrFailed("Không tạo được ảnh mã QR.".to_owned()));
    }
    Ok(QrTicket {
        token_id,
        qr_payload,
        base64_png,
        png_data: png,
        chk_wait_scan: chk_scan,
        chk_wait_cfirm: chk_cfirm,
        qr_timeout_seconds: timeout,
        qr_retry: retry,
    })
}

/// `…/api/login/getServerInfo?<sorted signed query>`.
pub fn build_server_info_url(auth: &str, imei: &str, computer_name: &str) -> String {
    let mut params: BTreeMap<String, String> = BTreeMap::from([
        ("imei".to_owned(), imei.to_owned()),
        ("type".to_owned(), ZPW_TYPE.to_owned()),
        ("client_version".to_owned(), ZPW_VER.to_owned()),
        ("computer_name".to_owned(), computer_name.to_owned()),
        ("sp_mtn".to_owned(), "-1".to_owned()),
        ("bkt".to_owned(), "-1".to_owned()),
    ]);
    let signkey = sign_key("getserverinfo", &params);
    params.insert("signkey".to_owned(), signkey);
    format!(
        "{auth}/api/login/getServerInfo?{}",
        sorted_query_string(&params)
    )
}

/// `reqqr` payload (key order as Swift's literal; order is irrelevant after encryption).
pub fn qr_payload(
    language: &str,
    client_time_sec: i64,
    imei: &str,
    computer_name: &str,
    self_g: i64,
    qr_form: i64,
) -> Value {
    json!({
        "language": language,
        "client_time": client_time_sec,
        "imei": imei,
        "computer_name": computer_name,
        "logged_uids": "",
        "self_g": self_g,
        "qr_form": qr_form,
    })
}

/// `getLoginInfo` payload.
pub fn login_info_payload(imei: &str, computer_name: &str, now_ms: i64) -> Value {
    json!({
        "imei": imei,
        "computer_name": computer_name,
        "language": "vi",
        "ts": now_ms,
    })
}

fn secs(v: i64) -> Duration {
    Duration::from_secs(u64::try_from(v.max(0)).unwrap_or(0))
}

fn status_body_error(status: u16, body: &[u8]) -> NetError {
    http_error(&crate::http::RawResponse::new(status, body.to_vec()))
}

impl<T: Transport> SessionClient<T> {
    fn new_cipher(&self, api_type: &str, imei: &str, now_ms: i64) -> Result<ParamCipher, NetError> {
        Ok(match &self.fixed_zcid_ext {
            Some(ext) => ParamCipher::with_zcid_ext(api_type, imei, now_ms, ext.clone())?,
            None => ParamCipher::new(api_type, imei, now_ms)?,
        })
    }

    /// Swift `fetchServerInfo`: GET `getServerInfo`, merge the service map, remember the
    /// `self_g` / `qr_format_trust_device` settings. Needs HTTP 200 and a JSON object.
    pub async fn fetch_server_info(&self) -> Result<Map<String, Value>, NetError> {
        let (auth, imei, name) = {
            let s = self.lock();
            (
                s.domains.auth.clone(),
                s.imei.clone(),
                s.computer_name.clone(),
            )
        };
        let url = build_server_info_url(&auth, &imei, &name);
        let outcome = match self.raw_request(RequestOptions::get(url)).await {
            Err(NetError::InvalidUrl(_)) => {
                return Err(NetError::InvalidUrl("getServerInfo".to_owned()));
            }
            other => other?,
        };
        let response = outcome.response;
        let json = match (response.status, parse_object(&response.body)) {
            (200, Some(json)) => json,
            (status, _) => {
                return Err(NetError::Http {
                    status,
                    body: String::new(),
                });
            }
        };
        let mut s = self.lock();
        s.domains.apply_server_info(&json);
        let settings = json
            .get("setttings")
            .and_then(Value::as_object)
            .or_else(|| json.get("settings").and_then(Value::as_object));
        if let Some(trusted) = settings
            .and_then(|s| s.get("trusted_device"))
            .and_then(Value::as_object)
        {
            s.server_qr_form = int64(trusted.get("qr_format_trust_device")).unwrap_or(0);
            s.server_self_g = int64(trusted.get("self_g")).unwrap_or(0);
        }
        drop(s);
        Ok(json)
    }

    /// Swift `requestQR`: refreshes server info (errors ignored), then `reqqr`.
    pub async fn request_qr(&self, language: &str) -> Result<QrTicket, NetError> {
        let _ = self.fetch_server_info().await;
        let now_ms = self.now_ms();
        let (auth, imei, name, self_g, qr_form) = {
            let s = self.lock();
            (
                s.domains.auth.clone(),
                s.imei.clone(),
                s.computer_name.clone(),
                s.server_self_g,
                s.server_qr_form,
            )
        };
        let cipher = self.new_cipher(ZPW_TYPE, &imei, now_ms)?;
        let payload = qr_payload(language, now_ms / 1000, &imei, &name, self_g, qr_form);
        let signed =
            cipher.build_signed_params(ZPW_TYPE, ZPW_VER, &canonical_json(&payload), "reqqr")?;
        let url = format!("{auth}/api/login/reqqr?{}", sorted_query_string(&signed));
        let outcome = match self.raw_request(RequestOptions::get(url.clone())).await {
            Err(NetError::InvalidUrl(_)) => return Err(NetError::InvalidUrl("reqqr".to_owned())),
            other => other?,
        };
        let response = outcome.response;
        if response.status != 200 {
            return Err(status_body_error(response.status, &response.body));
        }
        let raw = parse_object(&response.body).ok_or(NetError::InvalidJson)?;
        let json = unwrap_decrypted_response(&raw, Some(cipher.key_data()));
        let code = int64(json.get("error_code")).unwrap_or(0);
        if code != 0 {
            let msg = string(json.get("error_message"));
            return Err(ZaloSessionError {
                code,
                message: if msg.is_empty() {
                    "Không tạo được mã QR".to_owned()
                } else {
                    msg
                },
                url: url_path(&url),
            }
            .into());
        }
        let Some(Value::Object(d)) = json.get("data") else {
            return Err(NetError::QrFailed(
                "Máy chủ không trả về dữ liệu QR.".to_owned(),
            ));
        };
        parse_qr_ticket(d, "")
    }

    /// Swift `waitForQRScan`: long-polls `chkWaitScan` until the phone scans.
    ///
    /// Overall deadline `max(60, timeout * max(1, retry))` s; each poll times out after
    /// `max(70, timeout + 12)` s. A poll timeout or lost connection is retried after 500 ms.
    /// HTTP 408 retries; other non-200 fails. Server codes: `-20` rotates to a second QR (and
    /// extends the deadline, calling `on_rotated`), `8`/`13`/`-13` keep polling, any other
    /// non-zero code fails after more than `max(1, retry)` occurrences.
    pub async fn wait_for_qr_scan(
        &self,
        ticket: &QrTicket,
        mut on_rotated: Option<&mut (dyn FnMut(&QrTicket) + Send)>,
    ) -> Result<QrScanResult, NetError> {
        let mut current = ticket.clone();
        let mut deadline = Instant::now()
            + secs(
                60.max(
                    current
                        .qr_timeout_seconds
                        .saturating_mul(1.max(current.qr_retry)),
                ),
            );
        let mut error_attempts: i64 = 0;

        while Instant::now() < deadline {
            let sep = if current.chk_wait_scan.contains('?') {
                '&'
            } else {
                '?'
            };
            let url = format!("{}{sep}lang=vi", current.chk_wait_scan);
            if url::Url::parse(&url).is_err() {
                return Err(NetError::InvalidUrl(current.chk_wait_scan.clone()));
            }
            let req_timeout = secs(70.max(current.qr_timeout_seconds + 12));
            let outcome = match self
                .raw_request(RequestOptions::get(url).timeout(req_timeout))
                .await
            {
                Ok(o) => o,
                Err(e) if e.is_timeout_or_connection_lost() => {
                    if Instant::now() < deadline {
                        sleep(Duration::from_millis(500)).await;
                        continue;
                    }
                    return Err(NetError::QrTimeout);
                }
                Err(e) => return Err(e),
            };
            let response = outcome.response;
            if response.status == 408 {
                sleep(Duration::from_millis(500)).await;
                continue;
            }
            if response.status != 200 {
                return Err(status_body_error(response.status, &response.body));
            }
            if let Some(json) = parse_object(&response.body) {
                let code = int64(json.get("error_code")).unwrap_or(0);
                let data = json.get("data").and_then(Value::as_object);
                if code == 0 && data.is_some() {
                    let d = data.cloned().unwrap_or_default();
                    let name = string(d.get("display_name").or_else(|| d.get("displayName")));
                    let avatar = string(d.get("avatar"));
                    let avatar =
                        (!avatar.is_empty() && url::Url::parse(&avatar).is_ok()).then_some(avatar);
                    return Ok(QrScanResult {
                        display_name: name,
                        avatar,
                        active_ticket: current,
                    });
                }
                let rotated = if code == -20 {
                    data.and_then(|d| parse_qr_ticket(d, &current.chk_wait_cfirm).ok())
                } else {
                    None
                };
                if let Some(rotated) = rotated {
                    // Multi-layer QR verification on an untrusted device: second QR.
                    deadline = Instant::now()
                        + secs(
                            90.max(
                                rotated
                                    .qr_timeout_seconds
                                    .saturating_mul(1.max(rotated.qr_retry)),
                            ),
                        );
                    error_attempts = 0;
                    tracing::debug!("login: rotated to multi-layer second QR");
                    if let Some(cb) = on_rotated.as_deref_mut() {
                        cb(&rotated);
                    }
                    current = rotated;
                    continue;
                } else if code == 8 || code == 13 || code == -13 {
                    sleep(Duration::from_millis(500)).await;
                    continue;
                } else if code != 0 {
                    error_attempts += 1;
                    if error_attempts > 1.max(current.qr_retry) {
                        let msg = string(json.get("error_message"));
                        return Err(NetError::QrFailed(if msg.is_empty() {
                            format!("Mã QR đã hết hạn (mã {code}).")
                        } else {
                            msg
                        }));
                    }
                }
            }
            sleep(Duration::from_millis(600)).await;
        }
        Err(NetError::QrTimeout)
    }

    /// Swift `waitForQRConfirm`: long-polls `chkWaitCfirm` until the user taps confirm on the
    /// phone; stores and returns the new `zpw_sek`.
    pub async fn wait_for_qr_confirm(&self, ticket: &QrTicket) -> Result<String, NetError> {
        if ticket.chk_wait_cfirm.is_empty() || url::Url::parse(&ticket.chk_wait_cfirm).is_err() {
            return Err(NetError::QrFailed("Thiếu endpoint xác nhận QR.".to_owned()));
        }
        let deadline = Instant::now() + secs(120.max(ticket.qr_timeout_seconds));
        let req_timeout = secs(70.max(ticket.qr_timeout_seconds + 12));

        while Instant::now() < deadline {
            let outcome = match self
                .raw_request(
                    RequestOptions::get(ticket.chk_wait_cfirm.clone()).timeout(req_timeout),
                )
                .await
            {
                Ok(o) => o,
                Err(e) if e.is_timeout_or_connection_lost() => {
                    if Instant::now() < deadline {
                        sleep(Duration::from_millis(500)).await;
                        continue;
                    }
                    return Err(NetError::QrTimeout);
                }
                Err(e) => return Err(e),
            };
            let response = outcome.response;
            if response.status == 408 {
                sleep(Duration::from_millis(500)).await;
                continue;
            }
            if response.status != 200 {
                return Err(status_body_error(response.status, &response.body));
            }
            let json = parse_object(&response.body).ok_or(NetError::InvalidJson)?;
            let code = int64(json.get("error_code")).unwrap_or(0);
            if code == 0 {
                let sek = outcome
                    .zpw_sek_cookie
                    .or_else(|| extract_zpw_sek(&json))
                    .filter(|s| is_valid_zpw_sek(Some(s)))
                    .ok_or_else(|| {
                        NetError::QrFailed(
                            "Xác nhận QR thành công nhưng thiếu phiên zpw_sek.".to_owned(),
                        )
                    })?;
                let mut s = self.lock();
                s.zpw_sek = Some(sek.clone());
                if let Some(d) = json.get("data").and_then(Value::as_object) {
                    s.apply_login_config(d);
                }
                drop(s);
                return Ok(sek);
            } else if matches!(code, 18012 | -13 | 13 | 8) {
                // Scanned; waiting for the user to tap Confirm on the phone.
                sleep(Duration::from_millis(700)).await;
                continue;
            }
            let msg = string(json.get("error_message"));
            return Err(NetError::QrFailed(if msg.is_empty() {
                format!("Đăng nhập bị từ chối (mã {code}).")
            } else {
                msg
            }));
        }
        Err(NetError::QrTimeout)
    }

    /// Swift `getLoginInfo`: tries `auth` then `wpaChat`.
    ///
    /// Faithful quirk: Swift's `throw lastError` for an auth code (600/-102) sits inside the
    /// `do` block whose own `catch` swallows it, so the second host is still tried and the
    /// auth error is returned only if nothing else replaces it.
    pub async fn get_login_info(&self, zpw_type: &str) -> Result<Map<String, Value>, NetError> {
        let now_ms = self.now_ms();
        let (auth, wpa_chat, imei, name) = {
            let s = self.lock();
            (
                s.domains.auth.clone(),
                s.domains.wpa_chat.clone(),
                s.imei.clone(),
                s.computer_name.clone(),
            )
        };
        let cipher = self.new_cipher(zpw_type, &imei, now_ms)?;
        let payload = login_info_payload(&imei, &name, now_ms);
        let signed = cipher.build_signed_params(
            zpw_type,
            ZPW_VER,
            &canonical_json(&payload),
            "getlogininfo",
        )?;
        let query = sorted_query_string(&signed);
        let mut last_error = NetError::NotAuthenticated;

        for host in [auth, wpa_chat] {
            let url = format!("{host}/api/login/getLoginInfo?{query}&nretry=0");
            let outcome = match self.raw_request(RequestOptions::get(url.clone())).await {
                Ok(o) => o,
                Err(NetError::InvalidUrl(_)) => continue,
                Err(e) => {
                    last_error = e;
                    continue;
                }
            };
            if outcome.response.status != 200 {
                last_error = NetError::Http {
                    status: outcome.response.status,
                    body: String::new(),
                };
                continue;
            }
            let Some(raw) = parse_object(&outcome.response.body) else {
                last_error = NetError::InvalidJson;
                continue;
            };
            let decrypted = unwrap_decrypted_response(&raw, Some(cipher.key_data()));
            let code = int64(decrypted.get("error_code")).unwrap_or(0);
            if code == 0 {
                if let Some(cookie) = outcome.zpw_sek_cookie.filter(|c| is_valid_zpw_sek(Some(c))) {
                    let mut s = self.lock();
                    if !is_valid_zpw_sek(s.zpw_sek.as_deref()) {
                        s.zpw_sek = Some(cookie);
                    }
                }
                return Ok(decrypted);
            }
            last_error = ZaloSessionError {
                code,
                message: string(decrypted.get("error_message")),
                url: url_path(&url),
            }
            .into();
        }
        Err(last_error)
    }

    /// Swift `completeLogin` minus `saveSession` (caller persists [`Self::snapshot`]).
    pub async fn complete_login(&self) -> Result<LoginAccount, NetError> {
        let info = self.get_login_info(ZPW_TYPE).await?;
        if let Some(cfg) = info.get("data").and_then(Value::as_object) {
            self.lock().apply_login_config(cfg);
        }
        {
            let s = self.lock();
            let sek_dots = s
                .zpw_sek
                .as_deref()
                .map_or(0, |v| v.chars().filter(|c| *c == '.').count());
            tracing::debug!(
                zpw_type = ZPW_TYPE,
                key_len = s.secret_key.as_ref().map_or(0, Vec::len),
                sek_dots,
                ws = s.domains.ws.len(),
                "login: complete"
            );
        }
        let _ = self.sync_profile_me().await;
        let mut s = self.lock();
        let account = s.account.clone();
        match account {
            Some(a) if !a.user_id.is_empty() && is_valid_zpw_sek(s.zpw_sek.as_deref()) => {
                s.expired_at = None;
                Ok(a)
            }
            _ => Err(NetError::NotAuthenticated),
        }
    }

    fn me_request(&self) -> ApiRequest {
        let imei = self.imei();
        ApiRequest::new("profile", "/api/social/profile/me-v2")
            .query("os", "8")
            .payload(json!({"avatar_size": 160, "imei": imei}))
    }

    /// Swift `syncProfileMe`: refreshes uid/name/avatar/phone from `me-v2`.
    pub async fn sync_profile_me(&self) -> Option<LoginAccount> {
        let resp = self.get(&self.me_request()).await.ok()?;
        let data_node = resp.get("data").and_then(Value::as_object);
        let profile = data_node
            .and_then(|d| d.get("profile"))
            .and_then(Value::as_object)
            .or_else(|| resp.get("profile").and_then(Value::as_object))?;
        let pick = |a: &str, b: &str| string(profile.get(a).or_else(|| profile.get(b)));
        let uid = pick("userId", "uid");
        let name = pick("displayName", "zaloName");
        let avatar = pick("avatar", "avt");
        let phone = pick("phoneNumber", "phone");

        let mut s = self.lock();
        let mut updated = s.account.clone().unwrap_or_default();
        if !uid.is_empty() {
            updated.user_id = uid;
        }
        if !name.is_empty() {
            updated.display_name = name;
        }
        if !avatar.is_empty() {
            updated.avatar = avatar;
        }
        if !phone.is_empty() {
            updated.phone = phone;
        }
        if let Some(sek) = s.zpw_sek.clone().filter(|v| !v.is_empty()) {
            updated.zpw_sek = sek;
        }
        s.account = Some(updated.clone());
        Some(updated)
    }

    /// Swift `sessionStatus`: `getLoginInfo` first, then a `me-v2` probe.
    pub async fn session_status(&self) -> SessionStatus {
        {
            let s = self.lock();
            if s.account.is_none() || s.zpw_sek.is_none() || s.secret_key.is_none() {
                return SessionStatus::Expired;
            }
        }
        match self.get_login_info(ZPW_TYPE).await {
            Ok(info) => {
                if let Some(cfg) = info.get("data").and_then(Value::as_object) {
                    let mut s = self.lock();
                    s.apply_login_config(cfg);
                    s.needs_pc_type_upgrade = false;
                    return SessionStatus::Valid;
                }
            }
            Err(NetError::Session(err)) => {
                if self.lock().needs_pc_type_upgrade || err.is_auth_error() {
                    tracing::debug!(
                        code = err.code,
                        "session: getLoginInfo rejected, need QR login"
                    );
                    return SessionStatus::Expired;
                }
            }
            Err(_) => {
                if self.lock().needs_pc_type_upgrade {
                    return SessionStatus::Unreachable;
                }
            }
        }
        match self.get(&self.me_request()).await {
            Ok(resp) => match int64(resp.get("error_code")) {
                None => SessionStatus::Unreachable,
                Some(0) => SessionStatus::Valid,
                Some(code) if ZaloSessionError::AUTH_ERROR_CODES.contains(&code) => {
                    SessionStatus::Expired
                }
                Some(_) => SessionStatus::Unreachable,
            },
            Err(NetError::Session(err)) if err.is_auth_error() => SessionStatus::Expired,
            Err(_) => SessionStatus::Unreachable,
        }
    }
}
