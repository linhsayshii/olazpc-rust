#![allow(clippy::expect_used, clippy::unwrap_used)]
#![allow(dead_code)]

use olaz_net::mock::MockTransport;
use olaz_net::{
    ApiRequest, LoginAccount, NetError, RawResponse, RequestSpec, SessionClient, ZaloDomains,
};
use serde_json::{Map, Value};

pub const KEY: &[u8] = b"0123456789abcdef";
pub const IMEI: &str = "123e4567-e89b-42d3-a456-426614174000-f39f277f3586bbc6c6ab67a11a27cc0a";
pub const NOW_MS: i64 = 1_700_000_000_123;
pub const H1: &str = "https://h1.zaloapp.com";
pub const H2: &str = "https://h2.zaloapp.com";
pub const H3: &str = "https://h3.zaloapp.com";

pub fn json_response(status: u16, body: &str) -> Result<RawResponse, NetError> {
    Ok(RawResponse::new(status, body.as_bytes().to_vec()))
}

pub fn ok(body: &str) -> Result<RawResponse, NetError> {
    json_response(200, body)
}

/// Logged-in client whose `profile` service resolves to `hosts` only (plus Swift defaults).
pub fn client_with_hosts(transport: MockTransport, hosts: &[&str]) -> SessionClient<MockTransport> {
    let client = SessionClient::new(transport, IMEI.to_owned(), "Linh MacBook Pro".to_owned())
        .with_clock(|| NOW_MS)
        .with_fixed_zcid_ext("abcdef0123");
    let mut domains = ZaloDomains::default();
    // "svc" has no built-in defaults, so the host list is exactly `hosts`.
    for service in ["svc", "profile"] {
        domains.service_candidates.insert(
            service.to_owned(),
            hosts.iter().map(|h| (*h).to_owned()).collect(),
        );
    }
    let account = LoginAccount {
        user_id: "100".to_owned(),
        ..LoginAccount::default()
    };
    client.update_credentials(account, KEY.to_vec(), "sek.1.2".to_owned(), Some(domains));
    client
}

pub fn profile_req() -> ApiRequest {
    ApiRequest::new("svc", "/api/social/profile/me-v2")
        .query("os", "8")
        .payload(serde_json::json!({"avatar_size": 160, "imei": IMEI}))
}

/// Host part (`scheme://host`) of a recorded request.
pub fn host_of(req: &RequestSpec) -> String {
    let u = url::Url::parse(&req.url).expect("valid url");
    format!("{}://{}", u.scheme(), u.host_str().expect("host"))
}

/// Decrypts the `params` query value of a recorded request.
pub fn decrypted_params(req: &RequestSpec) -> Map<String, Value> {
    let enc = req.query_value("params").expect("params");
    let plain = olaz_crypto::decode_aes(KEY, enc).expect("decrypt");
    olaz_crypto::parse_object_str(&plain).expect("json object")
}
