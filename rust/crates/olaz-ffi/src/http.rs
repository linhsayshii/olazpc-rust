//! `CoreHttp`: the generic authenticated HTTP seam (Swift `ZaloSessionClient.get / post /
//! postMultipart`) as one object, so every feature endpoint can ride the Rust client (ParamCipher
//! `params=`, session cookie, multi-host failover, response decryption) without a typed method each.
//!
//! Requests carry the payload as JSON text (what Swift's `JSONSerialization` already produced); the
//! answer is the whole decoded response object (`error_code`, `data` already decrypted) as lossless
//! JSON text, the same shape `ZaloSessionClient.get` returned, so Swift parsing stays unchanged.

use std::collections::HashMap;
use std::io::{Read, Seek, SeekFrom};
use std::sync::Arc;

use olaz_json::to_swift_json_string;
use olaz_net::{
    GenericCall, Method, MultipartPart, NetError, ReqwestTransport, SessionClient, Transport,
};
use serde_json::Value;

use crate::error::CoreError;
use crate::runtime::{blocking, run};
use crate::session::CoreSession;

/// HTTP method of a [`HttpRequestRecord`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum HttpMethod {
    Get,
    Post,
}

/// One authenticated call (Swift `get` / `post` / `postMultipart` arguments).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct HttpRequestRecord {
    pub method: HttpMethod,
    /// `SERVICE_MAP_V3` key, e.g. `"profile"`, `"file"`.
    pub service: String,
    /// Path with leading slash.
    pub path: String,
    /// Plain query parameters (sorted by key on the wire).
    pub query: HashMap<String, String>,
    /// Extra headers (ignored by the multipart calls, like Swift).
    pub headers: HashMap<String, String>,
    /// JSON object text encrypted into `params=` (required for POST and multipart).
    pub payload_json: Option<String>,
    /// GET only, used when `payload_json` is `None`: plaintext to encrypt into `params=`.
    pub raw_encrypted: Option<String>,
    /// Decrypt the answer's `data` (multipart always does).
    pub decrypt_response: bool,
}

impl From<HttpRequestRecord> for GenericCall {
    fn from(r: HttpRequestRecord) -> Self {
        Self {
            method: match r.method {
                HttpMethod::Get => Method::Get,
                HttpMethod::Post => Method::Post,
            },
            service: r.service,
            path: r.path,
            query: r.query.into_iter().collect(),
            headers: r.headers.into_iter().collect(),
            payload_json: r.payload_json,
            raw_encrypted: r.raw_encrypted,
            decrypt_response: r.decrypt_response,
        }
    }
}

/// Form field of the single file part of a multipart upload.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct UploadPartRecord {
    pub field_name: String,
    pub file_name: String,
    pub mime_type: String,
}

impl UploadPartRecord {
    fn with_data(self, data: Vec<u8>) -> MultipartPart {
        MultipartPart {
            field_name: self.field_name,
            file_name: self.file_name,
            mime_type: self.mime_type,
            data,
        }
    }
}

fn answer(result: Result<serde_json::Map<String, Value>, NetError>) -> Result<String, CoreError> {
    let map = result?;
    Ok(to_swift_json_string(&Value::Object(map)))
}

/// Runs `call` on `client` (generic over the transport so tests can use the mock).
pub(crate) async fn perform<T: Transport + 'static>(
    client: &SessionClient<T>,
    request: HttpRequestRecord,
) -> Result<String, CoreError> {
    answer(client.call(&request.into()).await)
}

/// Multipart variant of [`perform`].
pub(crate) async fn perform_multipart<T: Transport + 'static>(
    client: &SessionClient<T>,
    request: HttpRequestRecord,
    part: MultipartPart,
) -> Result<String, CoreError> {
    answer(client.call_multipart(&request.into(), &part).await)
}

/// Reads `length` bytes (to EOF when `None`) of `path` starting at `offset`.
pub(crate) fn read_file_slice(
    path: &str,
    offset: u64,
    length: Option<u64>,
) -> Result<Vec<u8>, CoreError> {
    let io_err = |what: &str, e: std::io::Error| CoreError::Internal {
        // Kind only: the path is user data.
        message: format!("{what}: {:?}", e.kind()),
    };
    let mut file = std::fs::File::open(path).map_err(|e| io_err("open upload file", e))?;
    file.seek(SeekFrom::Start(offset))
        .map_err(|e| io_err("seek upload file", e))?;
    let mut data = Vec::new();
    match length {
        Some(len) => {
            file.take(len)
                .read_to_end(&mut data)
                .map_err(|e| io_err("read upload file", e))?;
        }
        None => {
            file.read_to_end(&mut data)
                .map_err(|e| io_err("read upload file", e))?;
        }
    }
    Ok(data)
}

/// Generic authenticated requests over a shared [`CoreSession`]. Every method is async, runs on the
/// shared runtime and throws `CoreError` (`.session(isAuth: true)` means re-login).
#[derive(uniffi::Object)]
pub struct CoreHttp {
    client: Arc<SessionClient<ReqwestTransport>>,
}

#[uniffi::export]
impl CoreHttp {
    #[uniffi::constructor]
    pub fn new(session: Arc<CoreSession>) -> Arc<Self> {
        Arc::new(Self {
            client: Arc::clone(&session.client),
        })
    }

    /// `get` / `post`: the full decoded answer as lossless JSON text.
    pub async fn request(&self, request: HttpRequestRecord) -> Result<String, CoreError> {
        let client = Arc::clone(&self.client);
        run(async move { perform(&client, request).await }).await?
    }

    /// `postMultipart` with the file part given as bytes.
    pub async fn post_multipart(
        &self,
        request: HttpRequestRecord,
        part: UploadPartRecord,
        data: Vec<u8>,
    ) -> Result<String, CoreError> {
        let client = Arc::clone(&self.client);
        let part = part.with_data(data);
        run(async move { perform_multipart(&client, request, part).await }).await?
    }

    /// `postMultipart` with the file part read from `file_path` (`length` bytes from `offset`, to
    /// EOF when `None`) on the blocking pool: the bytes never cross the FFI boundary. Pass one
    /// upload chunk at a time, the slice is held in memory while the request (and its failover
    /// retries) runs.
    pub async fn post_multipart_file(
        &self,
        request: HttpRequestRecord,
        part: UploadPartRecord,
        file_path: String,
        offset: u64,
        length: Option<u64>,
    ) -> Result<String, CoreError> {
        let client = Arc::clone(&self.client);
        run(async move {
            let data = blocking(move || read_file_slice(&file_path, offset, length)).await??;
            perform_multipart(&client, request, part.with_data(data)).await
        })
        .await?
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used)]

    use olaz_net::http::RawResponse;
    use olaz_net::mock::MockTransport;
    use olaz_net::{LoginAccount, NetworkErrorKind, ZaloDomains};

    use super::*;

    fn client(
        reply: impl FnMut(&olaz_net::http::RequestSpec) -> Result<RawResponse, NetError>
        + Send
        + 'static,
    ) -> SessionClient<MockTransport> {
        let client = SessionClient::new(
            MockTransport::from_fn(reply),
            "imei-1".to_owned(),
            "Mac".to_owned(),
        )
        .with_clock(|| 1_700_000_000_123);
        client.update_credentials(
            LoginAccount {
                user_id: "100".to_owned(),
                ..LoginAccount::default()
            },
            b"0123456789abcdef".to_vec(),
            "sek.1.2".to_owned(),
            Some(ZaloDomains::default()),
        );
        client
    }

    fn record(method: HttpMethod) -> HttpRequestRecord {
        HttpRequestRecord {
            method,
            service: "profile".into(),
            path: "/api/social/friend/getfriends".into(),
            query: HashMap::from([("os".to_owned(), "8".to_owned())]),
            headers: HashMap::new(),
            payload_json: Some(r#"{"page":1,"count":20000,"incInvalid":1}"#.into()),
            raw_encrypted: None,
            decrypt_response: true,
        }
    }

    fn ok(body: &str) -> Result<RawResponse, NetError> {
        Ok(RawResponse::new(200, body.as_bytes().to_vec()))
    }

    #[tokio::test]
    async fn get_returns_the_whole_answer_as_lossless_json() {
        let c = client(|_| ok(r#"{"error_code":0,"data":{"id":7412345678901234567}}"#));
        let text = perform(&c, record(HttpMethod::Get)).await.unwrap();
        let v: Value = serde_json::from_str(&text).unwrap();
        assert_eq!(v["error_code"], 0);
        assert_eq!(v["data"]["id"], "7412345678901234567");
        let req = &c.transport().requests()[0];
        assert!(req.url.contains("/api/social/friend/getfriends?zpw_ver="));
        assert!(req.url.contains("&params="));
        assert!(req.url.ends_with("&os=8"));
    }

    #[tokio::test]
    async fn post_sends_form_body() {
        let c = client(|_| ok(r#"{"error_code":0,"data":{}}"#));
        perform(&c, record(HttpMethod::Post)).await.unwrap();
        let req = &c.transport().requests()[0];
        assert_eq!(req.method, Method::Post);
        assert!(
            String::from_utf8(req.body.clone().unwrap())
                .unwrap()
                .starts_with("params=")
        );
    }

    #[tokio::test]
    async fn errors_map_to_core_errors() {
        let c = client(|_| ok(r#"{"error_code":600,"error_message":"x"}"#));
        let e = perform(&c, record(HttpMethod::Get)).await.unwrap_err();
        assert!(e.is_auth_error(), "{e:?}");

        let c = client(|_| Err(NetError::network(NetworkErrorKind::Timeout, "t")));
        let e = perform(&c, record(HttpMethod::Get)).await.unwrap_err();
        assert!(matches!(
            e,
            CoreError::Network {
                kind: crate::NetworkKind::Timeout,
                ..
            }
        ));

        let c = client(|_| Ok(RawResponse::new(403, b"no".to_vec())));
        let e = perform(&c, record(HttpMethod::Get)).await.unwrap_err();
        assert!(matches!(e, CoreError::Http { status: 403 }));

        let mut bad = record(HttpMethod::Post);
        bad.payload_json = Some("[1]".into());
        let c = client(|_| ok("{}"));
        assert!(matches!(
            perform(&c, bad).await.unwrap_err(),
            CoreError::Parse { .. }
        ));
    }

    #[tokio::test]
    async fn multipart_from_file_slice_reads_the_requested_range() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("f.bin");
        std::fs::write(&path, b"0123456789").unwrap();
        let slice = read_file_slice(path.to_str().unwrap(), 2, Some(5)).unwrap();
        assert_eq!(slice, b"23456");
        assert_eq!(
            read_file_slice(path.to_str().unwrap(), 8, None).unwrap(),
            b"89"
        );
        assert_eq!(
            read_file_slice(path.to_str().unwrap(), 20, Some(5)).unwrap(),
            b""
        );
        assert!(matches!(
            read_file_slice(dir.path().join("missing").to_str().unwrap(), 0, None),
            Err(CoreError::Internal { .. })
        ));

        let part = MultipartPart {
            field_name: "chunkContent".into(),
            file_name: "f.bin".into(),
            mime_type: "application/octet-stream".into(),
            data: slice,
        };
        let c = client(|_| ok(r#"{"error_code":0,"data":{"ok":1}}"#));
        let text = perform_multipart(&c, record(HttpMethod::Post), part)
            .await
            .unwrap();
        assert!(text.contains("\"ok\""));
        let req = &c.transport().requests()[0];
        let ct = req.header("Content-Type").unwrap();
        assert!(ct.starts_with("multipart/form-data; boundary=----WebKitFormBoundary"));
        let body = req.body.clone().unwrap();
        assert!(body.windows(5).any(|w| w == b"23456"));
        assert!(req.url.contains("&params="));
    }

    #[tokio::test]
    async fn core_http_without_login_is_not_authenticated() {
        let session = CoreSession::new("Mac".into()).unwrap();
        let http = CoreHttp::new(session);
        let e = http.request(record(HttpMethod::Get)).await.unwrap_err();
        assert!(matches!(e, CoreError::NotAuthenticated), "{e:?}");
    }
}
