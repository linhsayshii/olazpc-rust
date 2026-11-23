//! `SessionClient`: authenticated requests with multi-host failover over a [`Transport`].

use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde_json::{Map, Value};

use crate::cookie::{extract_zpw_sek_cookie, is_valid_zpw_sek};
use crate::decode::{check_response_error, decode_response, parse_and_decrypt_response};
use crate::error::NetError;
use crate::http::{Method, RawResponse, RequestOptions, Transport, build_request, url_path};
use crate::request::{
    ApiRequest, MultipartPart, get_suffix, multipart_body, multipart_suffix,
    new_multipart_boundary, post_suffix_and_body,
};
use crate::session::{SessionSnapshot, SessionState};

type Clock = Arc<dyn Fn() -> i64 + Send + Sync>;

/// A response plus the `zpw_sek` cookie found in its `Set-Cookie` headers (Swift `rawRequest`
/// returns `(status, data, cookieSek)`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RawOutcome {
    pub response: RawResponse,
    pub zpw_sek_cookie: Option<String>,
}

fn system_now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| i64::try_from(d.as_millis()).unwrap_or(i64::MAX))
        .unwrap_or(0)
}

/// Session client. Methods take `&self`: state sits behind a short-lived mutex that is never held
/// across an `.await`, so one client can serve concurrent requests.
pub struct SessionClient<T: Transport> {
    pub(crate) transport: T,
    state: Mutex<SessionState>,
    pub(crate) clock: Clock,
    pub(crate) fixed_zcid_ext: Option<String>,
}

impl<T: Transport> SessionClient<T> {
    pub fn new(transport: T, imei: String, computer_name: String) -> Self {
        Self::with_state(transport, SessionState::new(imei, computer_name))
    }

    pub fn with_state(transport: T, state: SessionState) -> Self {
        Self {
            transport,
            state: Mutex::new(state),
            clock: Arc::new(system_now_ms),
            fixed_zcid_ext: None,
        }
    }

    /// Replaces the millisecond clock (tests).
    #[must_use]
    pub fn with_clock(mut self, clock: impl Fn() -> i64 + Send + Sync + 'static) -> Self {
        self.clock = Arc::new(clock);
        self
    }

    /// Pins the ParamCipher `zcid_ext` (tests; makes login request URLs deterministic).
    #[must_use]
    pub fn with_fixed_zcid_ext(mut self, zcid_ext: impl Into<String>) -> Self {
        self.fixed_zcid_ext = Some(zcid_ext.into());
        self
    }

    pub fn transport(&self) -> &T {
        &self.transport
    }

    pub(crate) fn lock(&self) -> MutexGuard<'_, SessionState> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Current time in epoch milliseconds from the client's clock.
    pub fn now_ms(&self) -> i64 {
        (self.clock)()
    }

    // MARK: state accessors

    pub fn is_authenticated(&self) -> bool {
        self.lock().is_authenticated()
    }

    pub fn imei(&self) -> String {
        self.lock().imei.clone()
    }

    pub fn zpw_sek(&self) -> Option<String> {
        self.lock().zpw_sek.clone()
    }

    pub fn set_zpw_sek(&self, sek: Option<String>) {
        self.lock().zpw_sek = sek;
    }

    pub fn secret_key(&self) -> Option<Vec<u8>> {
        self.lock().secret_key.clone()
    }

    pub fn domains(&self) -> crate::ZaloDomains {
        self.lock().domains.clone()
    }

    pub fn set_domains(&self, domains: crate::ZaloDomains) {
        self.lock().domains = domains;
    }

    pub fn account(&self) -> Option<crate::LoginAccount> {
        self.lock().account.clone()
    }

    /// Runs `f` on the state under the lock (keep it short, never await inside).
    pub fn with_session<R>(&self, f: impl FnOnce(&mut SessionState) -> R) -> R {
        f(&mut self.lock())
    }

    pub fn next_client_id(&self) -> i64 {
        let now = self.now_ms();
        self.lock().next_client_id(now)
    }

    pub fn update_credentials(
        &self,
        account: crate::LoginAccount,
        secret_key: Vec<u8>,
        zpw_sek: String,
        domains: Option<crate::ZaloDomains>,
    ) {
        self.lock()
            .update_credentials(account, secret_key, zpw_sek, domains);
    }

    pub fn snapshot(&self) -> SessionSnapshot {
        self.lock().snapshot()
    }

    /// Loads a persisted snapshot (Swift `loadSavedSession` after unsealing).
    pub fn restore(&self, stored: SessionSnapshot) -> bool {
        self.lock().restore(stored)
    }

    /// Swift `markExpired`: records the expiry time; the caller persists [`Self::snapshot`].
    pub fn mark_expired(&self) {
        let now = self.now_ms() as f64 / 1000.0;
        self.lock().expired_at = Some(now);
    }

    pub fn clear_session(&self) {
        self.lock().clear();
    }

    // MARK: low level

    /// Swift `rawRequest`: builds headers from the current session and sends.
    pub async fn raw_request(&self, options: RequestOptions) -> Result<RawOutcome, NetError> {
        let sek = self.zpw_sek();
        let spec = build_request(&options, sek.as_deref())?;
        let response = self.transport.send(spec).await?;
        let now_unix = self.now_ms() / 1000;
        let zpw_sek_cookie = extract_zpw_sek_cookie(&response.headers, now_unix);
        Ok(RawOutcome {
            response,
            zpw_sek_cookie,
        })
    }

    /// Swift `rawGetJSON`: one GET, 2xx required, decoded and `error_code` checked.
    pub async fn raw_get_json(
        &self,
        url: &str,
        timeout: Duration,
        decrypt: bool,
    ) -> Result<Map<String, Value>, NetError> {
        let outcome = self
            .raw_request(RequestOptions::get(url).timeout(timeout))
            .await?;
        let status = outcome.response.status;
        if !(200..300).contains(&status) {
            return Err(NetError::Http {
                status,
                body: String::new(),
            });
        }
        let key = self.secret_key();
        let result = parse_and_decrypt_response(&outcome.response.body, decrypt, key.as_deref())?;
        check_response_error(&result, &url_path(url))?;
        Ok(result)
    }

    /// Swift `rawDownloadData`: GET with only the `User-Agent` header (no session cookie).
    pub async fn raw_download_data(
        &self,
        url: &str,
        timeout: Duration,
    ) -> Result<Vec<u8>, NetError> {
        let spec = bare_request(url, timeout, None)?;
        let response = self.transport.send(spec).await?;
        if (200..300).contains(&response.status) {
            Ok(response.body)
        } else {
            Err(NetError::Http {
                status: response.status,
                body: String::new(),
            })
        }
    }

    /// Swift `downloadSyncBatch`: GET; on 401/403 retries once with
    /// `Cookie: zpw_sek=<sek>; zpw_uin=<uid>` when the session has both.
    pub async fn download_sync_batch(
        &self,
        url: &str,
        timeout: Duration,
    ) -> Result<Vec<u8>, NetError> {
        let spec = bare_request(url, timeout, None)?;
        let response = self.transport.send(spec).await?;
        if (200..300).contains(&response.status) {
            return Ok(response.body);
        }
        if response.status == 401 || response.status == 403 {
            let (sek, uid) = {
                let s = self.lock();
                (
                    s.zpw_sek.clone(),
                    s.account.as_ref().map(|a| a.user_id.clone()),
                )
            };
            if let (Some(sek), Some(uid)) = (sek, uid)
                && is_valid_zpw_sek(Some(&sek))
                && !uid.is_empty()
            {
                let cookie = format!("zpw_sek={sek}; zpw_uin={uid}");
                let retry = bare_request(url, timeout, Some(&cookie))?;
                let retried = self.transport.send(retry).await?;
                if (200..300).contains(&retried.status) {
                    return Ok(retried.body);
                }
            }
        }
        tracing::debug!(http = response.status, "sync batch download failed");
        Err(NetError::Http {
            status: response.status,
            body: String::new(),
        })
    }

    // MARK: authenticated API

    /// Swift `get`.
    pub async fn get(&self, req: &ApiRequest) -> Result<Map<String, Value>, NetError> {
        let suffix = get_suffix(req, self.secret_key().as_deref())?;
        self.request_with_failover(
            &req.service,
            &suffix,
            Method::Get,
            None,
            None,
            &req.headers,
            req.decrypt_response,
        )
        .await
    }

    /// Swift `post`: payload goes into a `params=` form body.
    pub async fn post(&self, req: &ApiRequest) -> Result<Map<String, Value>, NetError> {
        let (suffix, body) = post_suffix_and_body(req, self.secret_key().as_deref())?;
        self.request_with_failover(
            &req.service,
            &suffix,
            Method::Post,
            Some(body),
            Some("application/x-www-form-urlencoded"),
            &req.headers,
            req.decrypt_response,
        )
        .await
    }

    /// Swift `postMultipart` (always decrypts the response, sends no extra headers).
    pub async fn post_multipart(
        &self,
        req: &ApiRequest,
        part: &MultipartPart,
    ) -> Result<Map<String, Value>, NetError> {
        let suffix = multipart_suffix(req, self.secret_key().as_deref())?;
        let boundary = new_multipart_boundary();
        let body = multipart_body(&boundary, part);
        let content_type = format!("multipart/form-data; boundary={boundary}");
        self.request_with_failover(
            &req.service,
            &suffix,
            Method::Post,
            Some(body),
            Some(&content_type),
            &[],
            true,
        )
        .await
    }

    /// Swift `requestWithFailover`.
    ///
    /// Tries `domains.candidates(service)` in order. Moves to the next host only on HTTP 404,
    /// HTTP >= 500 or a network error. A 2xx answer carrying a non-zero `error_code`, any other
    /// 4xx, bad JSON and crypto errors abort at once. The first host that answers is remembered
    /// as the preferred one. When every host failed the last failover error is returned
    /// (`InvalidUrl(service)` if there were no usable hosts).
    #[allow(clippy::too_many_arguments)]
    pub async fn request_with_failover(
        &self,
        service: &str,
        suffix: &str,
        method: Method,
        body: Option<Vec<u8>>,
        content_type: Option<&str>,
        extra_headers: &[(String, String)],
        decrypt: bool,
    ) -> Result<Map<String, Value>, NetError> {
        let hosts = self.lock().domains.candidates(service);
        let mut last_error = NetError::InvalidUrl(service.to_owned());
        for host in hosts {
            let url = format!("{host}{suffix}");
            let options = RequestOptions {
                method,
                url: url.clone(),
                body: body.clone(),
                content_type: content_type.map(str::to_owned),
                timeout: None,
                extra_headers: extra_headers.to_vec(),
            };
            let outcome = match self.raw_request(options).await {
                Ok(o) => o,
                Err(NetError::InvalidUrl(_)) => continue,
                Err(e) if e.should_failover() => {
                    last_error = e;
                    continue;
                }
                Err(e) => return Err(e),
            };
            let key = self.secret_key();
            match decode_response(&outcome.response, &url_path(&url), key.as_deref(), decrypt) {
                Ok(result) => {
                    self.lock().domains.remember_winner(service, &host);
                    return Ok(result);
                }
                Err(e) if e.should_failover() => {
                    last_error = e;
                }
                Err(e) => return Err(e),
            }
        }
        Err(last_error)
    }
}

fn bare_request(
    url: &str,
    timeout: Duration,
    cookie: Option<&str>,
) -> Result<crate::http::RequestSpec, NetError> {
    let mut options = RequestOptions::get(url).timeout(timeout);
    if let Some(cookie) = cookie {
        options
            .extra_headers
            .push(("Cookie".to_owned(), cookie.to_owned()));
    }
    // A bare request never carries the session cookie: pass no sek.
    build_request(&options, None)
}
