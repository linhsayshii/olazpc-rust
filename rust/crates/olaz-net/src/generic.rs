//! Generic signed request seam: the whole of Swift `ZaloSessionClient.get / post / postMultipart`
//! driven by plain data (service key, path, query, headers, payload JSON text), so a caller does not
//! need one typed method per endpoint.
//!
//! The payload arrives as JSON text, exactly what Swift's `JSONSerialization` produced, and is parsed
//! with `serde_json` (arbitrary precision: a 64-bit id written as a number stays a number, byte for
//! byte). Encryption (`params=` with the session `zpw_enk`), the session cookie, multi-host failover
//! and response decryption are the same code the typed endpoints use ([`SessionClient::get`] etc.).
//!
//! Signed (`signkey`) and unencrypted calls are not part of `get`/`post`/`postMultipart` in Swift;
//! they only exist in the login flow (`getServerInfo`, QR, `getLoginInfo`), which is already
//! ported in [`crate::SessionClient::fetch_server_info`] and friends.

use serde_json::{Map, Value};

use crate::client::SessionClient;
use crate::error::NetError;
use crate::http::{Method, Transport};
use crate::request::{ApiRequest, MultipartPart};

/// One call to an authenticated endpoint.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GenericCall {
    pub method: Method,
    /// `SERVICE_MAP_V3` key (`"profile"`, `"file"`, ...).
    pub service: String,
    /// Path with leading slash, no host and no query.
    pub path: String,
    /// Plain query parameters (appended sorted by key; a repeated key keeps the last value).
    pub query: Vec<(String, String)>,
    /// Extra request headers (ignored by multipart, like Swift).
    pub headers: Vec<(String, String)>,
    /// JSON object text encrypted into `params=`. Required for POST and multipart.
    pub payload_json: Option<String>,
    /// GET only, used when `payload_json` is `None`: plaintext encrypted into `params=`.
    pub raw_encrypted: Option<String>,
    /// Decrypt the `data` field of the answer (multipart always does).
    pub decrypt_response: bool,
}

impl GenericCall {
    pub fn new(method: Method, service: impl Into<String>, path: impl Into<String>) -> Self {
        Self {
            method,
            service: service.into(),
            path: path.into(),
            query: Vec::new(),
            headers: Vec::new(),
            payload_json: None,
            raw_encrypted: None,
            decrypt_response: true,
        }
    }

    /// Builds the [`ApiRequest`] the typed client methods take.
    pub fn to_api_request(&self) -> Result<ApiRequest, NetError> {
        let mut req = ApiRequest::new(self.service.clone(), self.path.clone());
        for (k, v) in &self.query {
            req = req.query(k, v);
        }
        for (k, v) in &self.headers {
            req = req.header(k, v);
        }
        if let Some(text) = &self.payload_json {
            // `arbitrary_precision`: large integer literals survive untouched.
            let value: Value = serde_json::from_str(text).map_err(|_| NetError::InvalidJson)?;
            if !value.is_object() {
                return Err(NetError::InvalidJson);
            }
            req = req.payload(value);
        }
        if let Some(raw) = &self.raw_encrypted {
            req = req.raw_encrypted(raw.clone());
        }
        Ok(req.decrypt_response(self.decrypt_response))
    }
}

impl<T: Transport> SessionClient<T> {
    /// Swift `get` / `post` for a [`GenericCall`] (the method picks which). Returns the whole decoded
    /// answer object (`error_code`, `data` already decrypted, ...).
    pub async fn call(&self, call: &GenericCall) -> Result<Map<String, Value>, NetError> {
        let req = call.to_api_request()?;
        match call.method {
            Method::Get => self.get(&req).await,
            Method::Post => self.post(&req).await,
        }
    }

    /// Swift `postMultipart` for a [`GenericCall`] (method is always POST).
    pub async fn call_multipart(
        &self,
        call: &GenericCall,
        part: &MultipartPart,
    ) -> Result<Map<String, Value>, NetError> {
        let req = call.to_api_request()?;
        self.post_multipart(&req, part).await
    }
}
