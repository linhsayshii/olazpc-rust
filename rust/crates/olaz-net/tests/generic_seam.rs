#![allow(clippy::expect_used, clippy::unwrap_used)]
//! The generic request seam (`GenericCall`) must produce the same wire requests and the same
//! failover behaviour as the typed `get` / `post` / `post_multipart` (which carry the Swift golden
//! vectors), starting from Swift-style JSON payload text.

mod common;

use std::collections::BTreeMap;

use common::*;
use olaz_net::mock::MockTransport;
use olaz_net::request::{get_suffix, multipart_suffix, post_suffix_and_body};
use olaz_net::{
    ApiRequest, GenericCall, Method, MultipartPart, NetError, NetworkErrorKind, ZaloSessionError,
};
use serde_json::json;

fn golden(key: &str) -> String {
    include_str!("fixtures/swift_golden.tsv")
        .lines()
        .filter_map(|l| l.split_once('\t'))
        .map(|(k, v)| (k.to_owned(), v.to_owned()))
        .collect::<BTreeMap<_, _>>()
        .get(key)
        .cloned()
        .unwrap_or_else(|| panic!("missing golden {key}"))
}

const OK_BODY: &str = r#"{"error_code":0,"data":{"a":1}}"#;

fn get_call() -> GenericCall {
    let mut c = GenericCall::new(Method::Get, "svc", "/api/social/profile/me-v2");
    c.query.push(("os".into(), "8".into()));
    // Swift `JSONSerialization` writes keys in arbitrary order.
    c.payload_json = Some(format!(r#"{{"imei":"{IMEI}","avatar_size":160}}"#));
    c
}

fn post_call() -> GenericCall {
    let mut c = GenericCall::new(Method::Post, "svc", "/api/y");
    c.query.push(("b".into(), "x y".into()));
    c.query.push(("a".into(), "1/2+3=4&5".into()));
    c.query.push(("c".into(), "ü".into()));
    c.payload_json = Some(r#"{"s":"hé/llo","k":1}"#.to_owned());
    c
}

#[tokio::test]
async fn generic_get_matches_swift_golden_url() {
    let c = client_with_hosts(MockTransport::scripted(vec![ok(OK_BODY)]), &[H1]);
    let res = c.call(&get_call()).await.unwrap();
    assert_eq!(res["data"]["a"], json!(1));
    let reqs = c.transport().requests();
    assert_eq!(reqs.len(), 1);
    assert_eq!(reqs[0].method, Method::Get);
    assert_eq!(reqs[0].url, format!("{H1}{}", golden("get")));
    assert_eq!(
        reqs[0].url,
        format!("{H1}{}", get_suffix(&profile_req(), Some(KEY)).unwrap())
    );
    assert!(reqs[0].body.is_none());
    assert_eq!(reqs[0].header("Content-Type"), None);
}

#[tokio::test]
async fn generic_post_matches_swift_golden_url_and_body() {
    let c = client_with_hosts(MockTransport::scripted(vec![ok(OK_BODY)]), &[H1]);
    c.call(&post_call()).await.unwrap();
    let reqs = c.transport().requests();
    let body = String::from_utf8(reqs[0].body.clone().unwrap()).unwrap();
    let path = reqs[0].url.strip_prefix(H1).unwrap();
    assert_eq!(format!("{path} BODY {body}"), golden("post"));
    assert_eq!(
        reqs[0].header("Content-Type"),
        Some("application/x-www-form-urlencoded")
    );
    // Same as the typed builder.
    let req = ApiRequest::new("svc", "/api/y")
        .query("b", "x y")
        .query("a", "1/2+3=4&5")
        .query("c", "ü")
        .payload(json!({"k": 1, "s": "hé/llo"}));
    let (suffix, typed_body) = post_suffix_and_body(&req, Some(KEY)).unwrap();
    assert_eq!(path, suffix);
    assert_eq!(body.as_bytes(), typed_body.as_slice());
}

#[tokio::test]
async fn generic_multipart_matches_typed_and_swift_body_shape() {
    let c = client_with_hosts(MockTransport::scripted(vec![ok(OK_BODY)]), &[H1]);
    let mut call = post_call();
    call.headers.push(("X-Ignored".into(), "1".into()));
    let part = MultipartPart {
        field_name: "chunkContent".into(),
        file_name: "a.bin".into(),
        mime_type: "application/octet-stream".into(),
        data: vec![1, 2, 0x41],
    };
    c.call_multipart(&call, &part).await.unwrap();
    let r = &c.transport().requests()[0];
    let req = call.to_api_request().unwrap();
    assert_eq!(
        r.url,
        format!("{H1}{}", multipart_suffix(&req, Some(KEY)).unwrap())
    );
    // Swift sends no extra headers on multipart.
    assert_eq!(r.header("X-Ignored"), None);
    let ct = r.header("Content-Type").unwrap();
    let boundary = ct.strip_prefix("multipart/form-data; boundary=").unwrap();
    assert!(boundary.starts_with("----OlazBoundary") && boundary.len() == 16 + 32);
    let expected = olaz_net::request::multipart_body(boundary, &part);
    assert_eq!(r.body.as_deref(), Some(expected.as_slice()));
}

#[tokio::test]
async fn payload_keeps_64_bit_integers_as_numbers() {
    let c = client_with_hosts(MockTransport::scripted(vec![ok(OK_BODY)]), &[H1]);
    let mut call = GenericCall::new(Method::Post, "svc", "/api/poll/detail");
    call.payload_json =
        Some(r#"{"poll_id":7412345678901234567,"f":1.5,"ok":true,"n":null}"#.into());
    c.call(&call).await.unwrap();
    let r = &c.transport().requests()[0];
    let body = String::from_utf8(r.body.clone().unwrap()).unwrap();
    let enc = body.strip_prefix("params=").unwrap();
    let decoded = url::form_urlencoded::parse(format!("p={enc}").as_bytes())
        .next()
        .unwrap()
        .1
        .into_owned();
    let plain = olaz_crypto::decode_aes(KEY, &decoded).unwrap();
    assert_eq!(
        plain,
        r#"{"f":1.5,"n":null,"ok":true,"poll_id":7412345678901234567}"#
    );
}

#[tokio::test]
async fn answers_are_lossless_for_big_ids() {
    let body = r#"{"error_code":0,"data":{"msgId":7412345678901234567}}"#;
    let c = client_with_hosts(MockTransport::scripted(vec![ok(body)]), &[H1]);
    let res = c.call(&get_call()).await.unwrap();
    assert_eq!(res["data"]["msgId"], json!("7412345678901234567"));
}

#[tokio::test]
async fn failover_rules_are_the_swift_ones() {
    // 404 / 5xx / network move on, winner is remembered.
    let t = MockTransport::scripted(vec![
        json_response(404, ""),
        Err(NetError::network(NetworkErrorKind::Timeout, "t")),
        json_response(502, ""),
        ok(OK_BODY),
    ]);
    let c = client_with_hosts(t, &[H1, H2, H3, "https://h4.zaloapp.com"]);
    c.call(&get_call()).await.unwrap();
    assert_eq!(c.transport().requests().len(), 4);
    assert_eq!(c.domains().candidates("svc")[0], "https://h4.zaloapp.com");

    // error_code never fails over.
    let t = MockTransport::scripted(vec![
        ok(r#"{"error_code":-5,"error_message":"no"}"#),
        ok(OK_BODY),
    ]);
    let c = client_with_hosts(t, &[H1, H2]);
    let err = c.call(&post_call()).await.unwrap_err();
    assert_eq!(
        err,
        NetError::Session(ZaloSessionError {
            code: -5,
            message: "no".into(),
            url: "/api/y".into()
        })
    );
    assert_eq!(c.transport().requests().len(), 1);

    // 4xx other than 404 aborts at once.
    let t = MockTransport::scripted(vec![json_response(403, "x"), ok(OK_BODY)]);
    let c = client_with_hosts(t, &[H1, H2]);
    assert!(matches!(
        c.call(&get_call()).await.unwrap_err(),
        NetError::Http { status: 403, .. }
    ));
    assert_eq!(c.transport().requests().len(), 1);
}

#[tokio::test]
async fn bad_payload_and_missing_session_are_typed_errors() {
    let c = client_with_hosts(MockTransport::scripted(vec![]), &[H1]);
    let mut call = post_call();
    call.payload_json = Some("[1,2]".into());
    assert_eq!(c.call(&call).await.unwrap_err(), NetError::InvalidJson);
    call.payload_json = Some("not json".into());
    assert_eq!(c.call(&call).await.unwrap_err(), NetError::InvalidJson);
    call.payload_json = None;
    assert_eq!(c.call(&call).await.unwrap_err(), NetError::InvalidJson);
    assert!(c.transport().requests().is_empty());

    c.clear_session();
    assert_eq!(
        c.call(&get_call()).await.unwrap_err(),
        NetError::NotAuthenticated
    );
}

#[tokio::test]
async fn get_with_raw_encrypted_string_and_decrypt_off() {
    let c = client_with_hosts(
        MockTransport::scripted(vec![ok(r#"{"error_code":0,"data":"abc"}"#)]),
        &[H1],
    );
    let mut call = GenericCall::new(Method::Get, "svc", "/api/raw");
    call.raw_encrypted = Some("plain=1".into());
    call.decrypt_response = false;
    let res = c.call(&call).await.unwrap();
    assert_eq!(res["data"], json!("abc"));
    let r = &c.transport().requests()[0];
    assert!(r.url.contains("&params="));
}
