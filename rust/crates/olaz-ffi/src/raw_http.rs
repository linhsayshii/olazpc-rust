//! `CoreRawHttp`: the session-free "raw" HTTP seam (Swift `ZaloSessionClient.rawRequest`,
//! `rawDownloadData`, `downloadSyncBatch`). Unlike [`crate::CoreHttp`] it needs no logged-in
//! `CoreSession`: the QR login runs through it before any account exists, so Swift passes its own
//! `zpw_sek` on every call (Swift stays the owner of the session) and gets the status, body and the
//! `zpw_sek` cookie of the response back untouched. There is no cookie jar (the Swift transport had
//! `httpCookieAcceptPolicy = .never` too): the cookie is only read out of `Set-Cookie`.

use std::collections::HashMap;
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use olaz_net::{
    Method, NetError, RequestOptions, ReqwestTransport, Transport, download_data,
    download_sync_batch_with, send_raw,
};

use crate::error::CoreError;
use crate::http::HttpMethod;
use crate::runtime::run;

/// One raw request (Swift `rawRequest` arguments plus the session cookie to send).
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct RawRequestRecord {
    pub method: HttpMethod,
    /// Absolute URL including the query string, exactly as it must be sent.
    pub url: String,
    pub body: Option<Vec<u8>>,
    pub content_type: Option<String>,
    /// Inactivity timeout in seconds; `None` = the 35 s default.
    pub timeout_secs: Option<f64>,
    pub headers: HashMap<String, String>,
    /// Sent as `Cookie: zpw_sek=..; _zlang=vi` + `zpw_sek:` header on Zalo hosts only.
    pub zpw_sek: Option<String>,
}

/// Any HTTP answer (no status mapping), like Swift's `(status, data, cookieSek)`.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct RawResponseRecord {
    pub status: u16,
    pub body: Vec<u8>,
    /// Valid `zpw_sek` found in `Set-Cookie`, when any.
    pub zpw_sek_cookie: Option<String>,
}

fn timeout_of(secs: Option<f64>) -> Option<Duration> {
    // Negative, NaN and infinite values would panic in `from_secs_f64`: fall back to the default.
    secs.and_then(|s| Duration::try_from_secs_f64(s).ok())
}

fn now_unix() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| i64::try_from(d.as_secs()).unwrap_or(i64::MAX))
        .unwrap_or(0)
}

/// Runs a raw request on `transport` (generic so tests use the mock).
pub(crate) async fn perform_raw<T: Transport>(
    transport: &T,
    request: RawRequestRecord,
    now_unix: i64,
) -> Result<RawResponseRecord, CoreError> {
    let options = RequestOptions {
        method: match request.method {
            HttpMethod::Get => Method::Get,
            HttpMethod::Post => Method::Post,
        },
        url: request.url,
        body: request.body,
        content_type: request.content_type,
        timeout: timeout_of(request.timeout_secs),
        extra_headers: request.headers.into_iter().collect(),
    };
    let outcome = send_raw(transport, &options, request.zpw_sek.as_deref(), now_unix).await?;
    Ok(RawResponseRecord {
        status: outcome.response.status,
        body: outcome.response.body,
        zpw_sek_cookie: outcome.zpw_sek_cookie,
    })
}

fn download_timeout(secs: f64) -> Result<Duration, CoreError> {
    timeout_of(Some(secs)).ok_or_else(|| CoreError::from(NetError::InvalidUrl(String::new())))
}

/// Raw HTTP over the shared rustls transport. Cheap to create; every method is async, runs on the
/// shared runtime and throws `CoreError` (transport failures and non-2xx downloads only: a raw
/// request returns any status).
#[derive(uniffi::Object)]
pub struct CoreRawHttp {
    transport: ReqwestTransport,
}

#[uniffi::export]
impl CoreRawHttp {
    #[uniffi::constructor]
    pub fn new() -> Result<Arc<Self>, CoreError> {
        Ok(Arc::new(Self {
            transport: ReqwestTransport::new()?,
        }))
    }

    /// Swift `rawRequest`.
    pub async fn request(&self, request: RawRequestRecord) -> Result<RawResponseRecord, CoreError> {
        let transport = self.transport.clone();
        run(async move { perform_raw(&transport, request, now_unix()).await }).await?
    }

    /// Swift `rawDownloadData`: GET with only the `User-Agent` header; non-2xx is `CoreError.http`.
    pub async fn download(&self, url: String, timeout_secs: f64) -> Result<Vec<u8>, CoreError> {
        let transport = self.transport.clone();
        let timeout = download_timeout(timeout_secs)?;
        run(async move { Ok(download_data(&transport, &url, timeout).await?) }).await?
    }

    /// Swift `downloadSyncBatch`: like `download`, plus one retry with
    /// `Cookie: zpw_sek=..; zpw_uin=..` on 401/403 when both values are given.
    pub async fn download_sync_batch(
        &self,
        url: String,
        timeout_secs: f64,
        zpw_sek: Option<String>,
        user_id: Option<String>,
    ) -> Result<Vec<u8>, CoreError> {
        let transport = self.transport.clone();
        let timeout = download_timeout(timeout_secs)?;
        run(async move {
            Ok(download_sync_batch_with(
                &transport,
                &url,
                timeout,
                zpw_sek.as_deref(),
                user_id.as_deref(),
            )
            .await?)
        })
        .await?
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used)]

    use olaz_net::NetworkErrorKind;
    use olaz_net::http::RawResponse;
    use olaz_net::mock::MockTransport;

    use super::*;

    fn record(url: &str) -> RawRequestRecord {
        RawRequestRecord {
            method: HttpMethod::Get,
            url: url.to_owned(),
            body: None,
            content_type: None,
            timeout_secs: None,
            headers: HashMap::new(),
            zpw_sek: None,
        }
    }

    #[tokio::test]
    async fn passes_status_body_and_headers_through() {
        let t = MockTransport::from_fn(|_| {
            Ok(RawResponse::new(403, b"nope".to_vec()).with_header("X-A", "1"))
        });
        let mut r = record("https://auth.zaloapp.com/x?a=1");
        r.method = HttpMethod::Post;
        r.body = Some(b"k=v".to_vec());
        r.content_type = Some("application/x-www-form-urlencoded".into());
        r.headers.insert("cloud-viewer-key".into(), "vk".into());
        r.timeout_secs = Some(7.5);
        r.zpw_sek = Some("sek.1.2".into());
        let out = perform_raw(&t, r, 1_700_000_000).await.unwrap();
        // A raw request never maps the status to an error.
        assert_eq!(out.status, 403);
        assert_eq!(out.body, b"nope");
        assert_eq!(out.zpw_sek_cookie, None);
        let req = &t.requests()[0];
        assert_eq!(req.method, Method::Post);
        assert_eq!(req.body.as_deref(), Some(&b"k=v"[..]));
        assert_eq!(req.timeout, Some(Duration::from_millis(7500)));
        assert_eq!(req.header("cloud-viewer-key"), Some("vk"));
        assert_eq!(
            req.header("Content-Type"),
            Some("application/x-www-form-urlencoded")
        );
        assert_eq!(req.header("Cookie"), Some("zpw_sek=sek.1.2; _zlang=vi"));
        assert_eq!(req.header("zpw_sek"), Some("sek.1.2"));
    }

    #[tokio::test]
    async fn session_cookie_only_goes_to_zalo_hosts() {
        let t = MockTransport::from_fn(|_| Ok(RawResponse::new(200, Vec::new())));
        let mut r = record("https://example.com/x");
        r.zpw_sek = Some("sek.1.2".into());
        perform_raw(&t, r, 0).await.unwrap();
        assert_eq!(t.requests()[0].header("Cookie"), None);
        assert!(t.requests()[0].header("User-Agent").is_some());
    }

    #[tokio::test]
    async fn returns_the_zpw_sek_cookie_of_the_response() {
        let t = MockTransport::from_fn(|_| {
            Ok(RawResponse::new(200, b"{}".to_vec())
                .with_header("Set-Cookie", "zpw_sek=new.9.9; Path=/; HttpOnly")
                .with_header("Set-Cookie", "other=1"))
        });
        let out = perform_raw(&t, record("https://auth.zaloapp.com/x"), 0)
            .await
            .unwrap();
        assert_eq!(out.zpw_sek_cookie.as_deref(), Some("new.9.9"));

        let t = MockTransport::from_fn(|_| {
            Ok(RawResponse::new(200, Vec::new()).with_header(
                "Set-Cookie",
                "zpw_sek=old.1.2; Expires=Thu, 01-Jan-1970 00:00:01 GMT",
            ))
        });
        let out = perform_raw(&t, record("https://auth.zaloapp.com/x"), 1_700_000_000)
            .await
            .unwrap();
        assert_eq!(out.zpw_sek_cookie, None);
    }

    #[tokio::test]
    async fn transport_errors_map_to_core_errors() {
        let t = MockTransport::from_fn(|_| Err(NetError::network(NetworkErrorKind::Timeout, "t")));
        let e = perform_raw(&t, record("https://auth.zaloapp.com/x"), 0)
            .await
            .unwrap_err();
        assert!(matches!(
            e,
            CoreError::Network {
                kind: crate::NetworkKind::Timeout,
                ..
            }
        ));
        let t = MockTransport::from_fn(|_| Ok(RawResponse::new(200, Vec::new())));
        let e = perform_raw(&t, record("not a url"), 0).await.unwrap_err();
        assert!(matches!(e, CoreError::Parse { .. }), "{e:?}");
    }

    #[test]
    fn bad_timeouts_fall_back_to_the_default() {
        assert_eq!(timeout_of(None), None);
        assert_eq!(timeout_of(Some(-1.0)), None);
        assert_eq!(timeout_of(Some(f64::NAN)), None);
        assert_eq!(timeout_of(Some(20.0)), Some(Duration::from_secs(20)));
        assert!(download_timeout(f64::INFINITY).is_err());
    }

    #[tokio::test]
    async fn downloads_send_only_the_user_agent_and_map_status() {
        let t = MockTransport::from_fn(|_| Ok(RawResponse::new(200, b"bytes".to_vec())));
        let body = download_data(&t, "https://f.zadn.vn/a", Duration::from_secs(20))
            .await
            .unwrap();
        assert_eq!(body, b"bytes");
        let req = &t.requests()[0];
        assert_eq!(req.timeout, Some(Duration::from_secs(20)));
        assert_eq!(req.header("Cookie"), None);

        let t = MockTransport::from_fn(|_| Ok(RawResponse::new(404, Vec::new())));
        let e = download_data(&t, "https://f.zadn.vn/a", Duration::from_secs(20))
            .await
            .unwrap_err();
        assert!(matches!(
            CoreError::from(e),
            CoreError::Http { status: 404 }
        ));
    }

    #[tokio::test]
    async fn sync_batch_retries_once_with_cookie_on_401() {
        let t = MockTransport::from_fn(|spec| {
            if spec.header("Cookie").is_some() {
                Ok(RawResponse::new(200, b"batch".to_vec()))
            } else {
                Ok(RawResponse::new(401, Vec::new()))
            }
        });
        let body = download_sync_batch_with(
            &t,
            "https://sync.zaloapp.com/b",
            Duration::from_secs(45),
            Some("sek.1.2"),
            Some("100"),
        )
        .await
        .unwrap();
        assert_eq!(body, b"batch");
        let reqs = t.requests();
        assert_eq!(reqs.len(), 2);
        assert_eq!(
            reqs[1].header("Cookie"),
            Some("zpw_sek=sek.1.2; zpw_uin=100")
        );

        // No credentials: no retry, the status comes back.
        let t = MockTransport::from_fn(|_| Ok(RawResponse::new(403, Vec::new())));
        let e = download_sync_batch_with(
            &t,
            "https://s.zaloapp.com/b",
            Duration::from_secs(45),
            None,
            None,
        )
        .await
        .unwrap_err();
        assert!(matches!(
            CoreError::from(e),
            CoreError::Http { status: 403 }
        ));
        assert_eq!(t.requests().len(), 1);
    }

    #[tokio::test]
    async fn core_raw_http_hits_a_local_server() {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move {
            while let Ok((mut s, _)) = listener.accept().await {
                let mut buf = [0u8; 4096];
                let n = s.read(&mut buf).await.unwrap_or(0);
                let req = String::from_utf8_lossy(&buf[..n]).to_lowercase();
                let reply = if req.contains("x-probe: 1") {
                    "HTTP/1.1 202 Accepted\r\nSet-Cookie: zpw_sek=live.1.2; Path=/\r\nContent-Length: 2\r\nConnection: close\r\n\r\nhi"
                } else {
                    "HTTP/1.1 500 Err\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                };
                let _ = s.write_all(reply.as_bytes()).await;
            }
        });
        let raw = CoreRawHttp::new().unwrap();
        let mut r = record(&format!("http://{addr}/p"));
        r.headers.insert("X-Probe".into(), "1".into());
        let out = raw.request(r).await.unwrap();
        assert_eq!((out.status, out.body.as_slice()), (202, &b"hi"[..]));
        assert_eq!(out.zpw_sek_cookie.as_deref(), Some("live.1.2"));
        let e = raw
            .download(format!("http://{addr}/p"), 5.0)
            .await
            .unwrap_err();
        assert!(matches!(e, CoreError::Http { status: 500 }), "{e:?}");
    }
}
