//! Pure request building plus the thin [`Transport`] seam (reqwest in production, a mock in tests).

use std::future::Future;
use std::time::Duration;

use crate::domains::{USER_AGENT, ZPW_TYPE, ZPW_VER};
use crate::error::{NetError, NetworkErrorKind};

/// Default per-request INACTIVITY timeout (Swift `timeoutIntervalForRequest = 35`): it applies to
/// each wait for headers or body bytes, not to the whole request.
pub const DEFAULT_REQUEST_TIMEOUT: Duration = Duration::from_secs(35);
/// Whole-request cap used by the reqwest client (Swift `timeoutIntervalForResource = 180`).
pub const RESOURCE_TIMEOUT: Duration = Duration::from_secs(180);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Method {
    Get,
    Post,
}

impl Method {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Get => "GET",
            Self::Post => "POST",
        }
    }
}

/// A fully built HTTP request, ready for any [`Transport`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RequestSpec {
    pub method: Method,
    /// Absolute URL including the query string, exactly as sent.
    pub url: String,
    /// Decoded query pairs, in URL order.
    pub query: Vec<(String, String)>,
    /// Header names and values in send order (never log these: they carry the session cookie).
    pub headers: Vec<(String, String)>,
    pub body: Option<Vec<u8>>,
    /// `None` means [`DEFAULT_REQUEST_TIMEOUT`].
    pub timeout: Option<Duration>,
}

impl RequestSpec {
    /// Path component of the URL (what Swift passes as `url.path` into errors).
    pub fn path(&self) -> String {
        url_path(&self.url)
    }

    /// Header value by case-insensitive name.
    pub fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|(k, _)| k.eq_ignore_ascii_case(name))
            .map(|(_, v)| v.as_str())
    }

    /// First query value for `name`.
    pub fn query_value(&self, name: &str) -> Option<&str> {
        self.query
            .iter()
            .find(|(k, _)| k == name)
            .map(|(_, v)| v.as_str())
    }
}

/// Response as seen on the wire. `headers` keeps duplicates (several `Set-Cookie`).
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct RawResponse {
    pub status: u16,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
}

impl RawResponse {
    pub fn new(status: u16, body: impl Into<Vec<u8>>) -> Self {
        Self {
            status,
            headers: Vec::new(),
            body: body.into(),
        }
    }

    pub fn with_header(mut self, name: &str, value: &str) -> Self {
        self.headers.push((name.to_owned(), value.to_owned()));
        self
    }
}

/// The only place that touches the network.
pub trait Transport: Send + Sync {
    fn send(
        &self,
        request: RequestSpec,
    ) -> impl Future<Output = Result<RawResponse, NetError>> + Send;
}

/// Path of an absolute URL, `""` when it does not parse.
pub fn url_path(url: &str) -> String {
    url::Url::parse(url)
        .map(|u| u.path().to_owned())
        .unwrap_or_default()
}

/// Swift `urlEncode`: percent-encode everything except ASCII letters, digits and `-._~`
/// (uppercase hex). Non-ASCII letters, which Swift left raw before `URL(string:)` re-encoded
/// them as UTF-8, come out as the same UTF-8 percent bytes.
pub fn url_encode(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for b in s.bytes() {
        if b.is_ascii_alphanumeric() || matches!(b, b'-' | b'.' | b'_' | b'~') {
            out.push(char::from(b));
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

/// Swift `sortedQueryString`: keys ascending, values [`url_encode`]d, joined with `&`.
pub fn sorted_query_string<'a, I>(params: I) -> String
where
    I: IntoIterator<Item = (&'a String, &'a String)>,
{
    let mut pairs: Vec<(&String, &String)> = params.into_iter().collect();
    pairs.sort_by(|a, b| a.0.cmp(b.0));
    pairs
        .iter()
        .map(|(k, v)| format!("{k}={}", url_encode(v)))
        .collect::<Vec<_>>()
        .join("&")
}

/// `zpw_ver=694&zpw_type=23`, the query prefix of every authenticated call.
pub fn common_params() -> String {
    format!("zpw_ver={ZPW_VER}&zpw_type={ZPW_TYPE}")
}

/// Inputs of [`build_request`] (Swift `rawRequest` parameters).
#[derive(Debug, Clone)]
pub struct RequestOptions {
    pub method: Method,
    pub url: String,
    pub body: Option<Vec<u8>>,
    pub content_type: Option<String>,
    pub timeout: Option<Duration>,
    pub extra_headers: Vec<(String, String)>,
}

impl RequestOptions {
    pub fn get(url: impl Into<String>) -> Self {
        Self {
            method: Method::Get,
            url: url.into(),
            body: None,
            content_type: None,
            timeout: None,
            extra_headers: Vec::new(),
        }
    }

    pub fn timeout(mut self, timeout: Duration) -> Self {
        self.timeout = Some(timeout);
        self
    }

    pub fn header(mut self, name: impl Into<String>, value: impl Into<String>) -> Self {
        self.extra_headers.push((name.into(), value.into()));
        self
    }
}

/// True for hosts that receive the `zpw_sek` cookie (`zalo.me`, `zaloapp.com`, `zadn.vn`).
pub fn is_zalo_host(host: &str) -> bool {
    let host = host.to_lowercase();
    host.contains("zalo.me") || host.contains("zaloapp.com") || host.contains("zadn.vn")
}

/// Sets a header, replacing any existing one with the same name (Swift `setValue`).
pub fn set_header(headers: &mut Vec<(String, String)>, name: &str, value: &str) {
    if let Some(existing) = headers
        .iter_mut()
        .find(|(k, _)| k.eq_ignore_ascii_case(name))
    {
        existing.1 = value.to_owned();
    } else {
        headers.push((name.to_owned(), value.to_owned()));
    }
}

/// Swift `rawRequest` header logic as a pure function.
///
/// Header order: `User-Agent`, then (when a session cookie exists and the host is a Zalo host)
/// `Cookie: zpw_sek=<sek>; _zlang=vi` and `zpw_sek: <sek>`, then `Content-Type`, then extras.
pub fn build_request(
    options: &RequestOptions,
    zpw_sek: Option<&str>,
) -> Result<RequestSpec, NetError> {
    let parsed =
        url::Url::parse(&options.url).map_err(|_| NetError::InvalidUrl(options.url.clone()))?;
    let mut headers: Vec<(String, String)> = Vec::new();
    set_header(&mut headers, "User-Agent", USER_AGENT);
    if let Some(sek) = zpw_sek.filter(|s| !s.is_empty())
        && is_zalo_host(parsed.host_str().unwrap_or(""))
    {
        set_header(&mut headers, "Cookie", &format!("zpw_sek={sek}; _zlang=vi"));
        set_header(&mut headers, "zpw_sek", sek);
    }
    if let Some(ct) = &options.content_type {
        set_header(&mut headers, "Content-Type", ct);
    }
    for (k, v) in &options.extra_headers {
        set_header(&mut headers, k, v);
    }
    Ok(RequestSpec {
        method: options.method,
        url: options.url.clone(),
        query: parsed
            .query_pairs()
            .map(|(k, v)| (k.into_owned(), v.into_owned()))
            .collect(),
        headers,
        body: options.body.clone(),
        timeout: options.timeout,
    })
}

/// Production transport: reqwest + rustls. No cookie store (the session cookie is a header),
/// no automatic proxies beyond reqwest defaults.
#[derive(Debug, Clone)]
pub struct ReqwestTransport {
    client: reqwest::Client,
}

impl ReqwestTransport {
    pub fn new() -> Result<Self, NetError> {
        let client = reqwest::Client::builder()
            .timeout(RESOURCE_TIMEOUT)
            .build()
            .map_err(map_reqwest_error)?;
        Ok(Self { client })
    }
}

fn idle_timeout() -> NetError {
    NetError::network(NetworkErrorKind::Timeout, "request timed out")
}

fn map_reqwest_error(e: reqwest::Error) -> NetError {
    // Strip the URL: it carries encrypted params and signing material (ADR-008).
    let e = e.without_url();
    let kind = if e.is_timeout() {
        NetworkErrorKind::Timeout
    } else if e.is_body() || e.is_decode() {
        NetworkErrorKind::ConnectionLost
    } else {
        NetworkErrorKind::Other
    };
    NetError::network(kind, e.to_string())
}

impl Transport for ReqwestTransport {
    fn send(
        &self,
        request: RequestSpec,
    ) -> impl Future<Output = Result<RawResponse, NetError>> + Send {
        let client = self.client.clone();
        async move {
            let method = match request.method {
                Method::Get => reqwest::Method::GET,
                Method::Post => reqwest::Method::POST,
            };
            let mut builder = client.request(method, &request.url);
            for (k, v) in &request.headers {
                builder = builder.header(k.as_str(), v.as_str());
            }
            if let Some(body) = request.body {
                builder = builder.body(body);
            }
            // Swift `URLRequest.timeoutInterval` is an inactivity timer: it restarts whenever bytes
            // move. reqwest's per-request `timeout` is a total deadline, so apply the limit to each
            // wait instead (headers, then every body chunk). The client-wide `RESOURCE_TIMEOUT`
            // stays the total cap, like `timeoutIntervalForResource`.
            let idle = request.timeout.unwrap_or(DEFAULT_REQUEST_TIMEOUT);
            let mut response = tokio::time::timeout(idle, builder.send())
                .await
                .map_err(|_| idle_timeout())?
                .map_err(map_reqwest_error)?;
            let status = response.status().as_u16();
            let headers = response
                .headers()
                .iter()
                .map(|(k, v)| {
                    (
                        k.as_str().to_owned(),
                        String::from_utf8_lossy(v.as_bytes()).into_owned(),
                    )
                })
                .collect();
            let mut body = Vec::new();
            while let Some(chunk) = tokio::time::timeout(idle, response.chunk())
                .await
                .map_err(|_| idle_timeout())?
                .map_err(map_reqwest_error)?
            {
                body.extend_from_slice(&chunk);
            }
            Ok(RawResponse {
                status,
                headers,
                body,
            })
        }
    }
}
