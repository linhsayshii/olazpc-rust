//! Rust port of Olaz `ZaloDomains.swift` and `ZaloSessionClient.swift`: the service map, signed
//! and encrypted request building, response decoding, multi-host failover and QR login.
//!
//! Design: everything that decides what goes on the wire or how an answer is read is a pure
//! function ([`http::build_request`], [`request::get_suffix`], [`decode::decode_response`], ...).
//! [`SessionClient`] glues them to a [`Transport`], which is [`ReqwestTransport`] in production
//! and [`mock::MockTransport`] in tests. Keychain / vault persistence stays in Swift; this crate
//! exposes a serde [`SessionSnapshot`] instead.
//!
//! Failover rule (Swift `shouldFailover`): HTTP 404, HTTP >= 500 and network errors move to the
//! next host; a server `error_code` ([`ZaloSessionError`]) never does.

pub mod cookie;
pub mod decode;
pub mod domains;
mod error;
pub mod generic;
pub mod http;
pub mod mock;
pub mod request;
pub mod session;

mod client;
mod login;

pub use client::{RawOutcome, SessionClient, download_data, download_sync_batch_with, send_raw};
pub use cookie::{extract_zpw_sek, extract_zpw_sek_cookie, is_valid_zpw_sek};
pub use decode::{
    check_response_error, decode_response, parse_and_decrypt_response, unwrap_decrypted_response,
};
pub use domains::{
    USER_AGENT, WS_ORIGIN, ZPW_PC_TYPE, ZPW_TYPE, ZPW_VER, ZPW_WEB_TYPE, ZaloDomains,
    canonical_service, default_service_hosts, fallback_service_hosts, normalize_host,
};
pub use error::{NetError, NetworkErrorKind, ZaloSessionError};
pub use generic::GenericCall;
pub use http::{
    DEFAULT_REQUEST_TIMEOUT, Method, RawResponse, RequestOptions, RequestSpec, ReqwestTransport,
    Transport, build_request, common_params, sorted_query_string, url_encode,
};
pub use login::{
    QrScanResult, QrTicket, build_server_info_url, login_info_payload, parse_qr_ticket, qr_payload,
};
pub use request::{ApiRequest, MultipartPart, canonical_json};
pub use session::{
    LoginAccount, ServerSettingsSource, SessionSnapshot, SessionState, SessionStatus,
    generate_imei, is_valid_pc_imei,
};
