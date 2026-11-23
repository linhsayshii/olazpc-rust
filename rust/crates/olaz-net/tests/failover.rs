#![allow(clippy::expect_used, clippy::unwrap_used)]
//! Failover rules of `requestWithFailover` (scripted 404 / 5xx / network / error_code).

mod common;

use common::*;
use olaz_net::mock::MockTransport;
use olaz_net::{
    ApiRequest, MultipartPart, NetError, NetworkErrorKind, RawResponse, ZaloSessionError,
};
use serde_json::json;

const OK_BODY: &str = r#"{"error_code":0,"data":{"a":1}}"#;

fn net_err(kind: NetworkErrorKind) -> Result<RawResponse, NetError> {
    Err(NetError::network(kind, "boom"))
}

fn hosts(client: &olaz_net::SessionClient<MockTransport>) -> Vec<String> {
    client.transport().requests().iter().map(host_of).collect()
}

#[tokio::test]
async fn http_404_fails_over_to_next_host() {
    let t = MockTransport::scripted(vec![json_response(404, "nope"), ok(OK_BODY)]);
    let c = client_with_hosts(t, &[H1, H2]);
    let res = c.get(&profile_req()).await.expect("second host answers");
    assert_eq!(res["data"]["a"], json!(1));
    assert_eq!(hosts(&c), [H1, H2]);
}

#[tokio::test]
async fn http_503_fails_over_to_next_host() {
    let t = MockTransport::scripted(vec![json_response(503, "busy"), ok(OK_BODY)]);
    let c = client_with_hosts(t, &[H1, H2]);
    assert!(c.get(&profile_req()).await.is_ok());
    assert_eq!(hosts(&c), [H1, H2]);
}

#[tokio::test]
async fn http_500_and_599_fail_over_but_499_does_not() {
    for status in [500u16, 502, 599] {
        let t = MockTransport::scripted(vec![json_response(status, ""), ok(OK_BODY)]);
        let c = client_with_hosts(t, &[H1, H2]);
        assert!(c.get(&profile_req()).await.is_ok(), "status {status}");
    }
    for status in [400u16, 401, 403, 408, 429, 499] {
        let t = MockTransport::scripted(vec![json_response(status, "denied"), ok(OK_BODY)]);
        let c = client_with_hosts(t, &[H1, H2]);
        let err = c.get(&profile_req()).await.expect_err("no failover");
        assert_eq!(
            err,
            NetError::Http {
                status,
                body: "denied".to_owned()
            }
        );
        assert_eq!(c.transport().requests().len(), 1, "status {status}");
    }
}

#[tokio::test]
async fn network_errors_fail_over_to_next_host() {
    for kind in [
        NetworkErrorKind::Timeout,
        NetworkErrorKind::ConnectionLost,
        NetworkErrorKind::Other,
    ] {
        let t = MockTransport::scripted(vec![net_err(kind), ok(OK_BODY)]);
        let c = client_with_hosts(t, &[H1, H2]);
        assert!(c.get(&profile_req()).await.is_ok(), "{kind:?}");
        assert_eq!(hosts(&c), [H1, H2]);
    }
}

#[tokio::test]
async fn error_code_never_fails_over() {
    let body = r#"{"error_code":114,"error_message":"Group members fallback"}"#;
    let t = MockTransport::scripted(vec![ok(body), ok(OK_BODY)]);
    let c = client_with_hosts(t, &[H1, H2]);
    let err = c.get(&profile_req()).await.expect_err("server error");
    assert_eq!(
        err,
        NetError::Session(ZaloSessionError {
            code: 114,
            message: "Group members fallback".to_owned(),
            url: "/api/social/profile/me-v2".to_owned(),
        })
    );
    assert_eq!(c.transport().requests().len(), 1);
    // A failing answer is not a winner.
    assert!(!c.domains().preferred_hosts.contains_key("svc"));
}

#[tokio::test]
async fn auth_error_codes_are_flagged_and_stop() {
    for code in [600, -102] {
        let t = MockTransport::scripted(vec![
            ok(&format!(r#"{{"error_code":{code}}}"#)),
            ok(OK_BODY),
        ]);
        let c = client_with_hosts(t, &[H1, H2]);
        match c.get(&profile_req()).await {
            Err(NetError::Session(e)) => assert!(e.is_auth_error()),
            other => panic!("unexpected {other:?}"),
        }
        assert_eq!(c.transport().requests().len(), 1);
    }
}

#[tokio::test]
async fn all_hosts_failing_returns_the_last_error() {
    let t = MockTransport::scripted(vec![
        json_response(404, ""),
        json_response(503, "down"),
        net_err(NetworkErrorKind::Timeout),
    ]);
    let c = client_with_hosts(t, &[H1, H2, H3]);
    let err = c.get(&profile_req()).await.expect_err("all fail");
    assert_eq!(err, NetError::network(NetworkErrorKind::Timeout, "boom"));
    assert_eq!(hosts(&c), [H1, H2, H3]);

    // last is a 404: body is empty like Swift `httpError(404, "")`.
    let t = MockTransport::scripted(vec![json_response(503, "down"), json_response(404, "x")]);
    let c = client_with_hosts(t, &[H1, H2]);
    let err = c.get(&profile_req()).await.expect_err("all fail");
    assert_eq!(
        err,
        NetError::Http {
            status: 404,
            body: String::new()
        }
    );

    // last is a 5xx: body prefix is kept (first 200 bytes).
    let long = "x".repeat(300);
    let t = MockTransport::scripted(vec![json_response(404, ""), json_response(502, &long)]);
    let c = client_with_hosts(t, &[H1, H2]);
    match c.get(&profile_req()).await {
        Err(NetError::Http { status: 502, body }) => assert_eq!(body.len(), 200),
        other => panic!("unexpected {other:?}"),
    }
}

#[tokio::test]
async fn unknown_service_has_no_hosts_and_reports_invalid_url() {
    let c = client_with_hosts(MockTransport::scripted(vec![]), &[H1]);
    let err = c
        .get(&ApiRequest::new("nope", "/x").payload(json!({})))
        .await
        .expect_err("no hosts");
    assert_eq!(err, NetError::InvalidUrl("nope".to_owned()));
    assert!(c.transport().requests().is_empty());
}

#[tokio::test]
async fn invalid_json_and_crypto_errors_do_not_fail_over() {
    let t = MockTransport::scripted(vec![ok("<html>oops</html>"), ok(OK_BODY)]);
    let c = client_with_hosts(t, &[H1, H2]);
    assert_eq!(
        c.get(&profile_req()).await.expect_err("bad json"),
        NetError::InvalidJson
    );
    assert_eq!(c.transport().requests().len(), 1);
}

#[tokio::test]
async fn winner_is_promoted_and_tried_first_next_time() {
    let t = MockTransport::scripted(vec![json_response(503, ""), ok(OK_BODY), ok(OK_BODY)]);
    let c = client_with_hosts(t, &[H1, H2]);
    c.get(&profile_req()).await.expect("first call");
    assert_eq!(c.domains().preferred_hosts["svc"], H2);
    c.get(&profile_req()).await.expect("second call");
    assert_eq!(hosts(&c), [H1, H2, H2]);
}

#[tokio::test]
async fn unauthenticated_calls_fail_before_the_network() {
    let c = olaz_net::SessionClient::new(
        MockTransport::scripted(vec![]),
        IMEI.to_owned(),
        "Mac".to_owned(),
    );
    assert_eq!(
        c.get(&profile_req()).await.expect_err("no key"),
        NetError::NotAuthenticated
    );
    assert_eq!(
        c.post(&profile_req()).await.expect_err("no key"),
        NetError::NotAuthenticated
    );
    assert!(c.transport().requests().is_empty());
}

#[tokio::test]
async fn post_and_multipart_use_the_same_failover() {
    let t = MockTransport::scripted(vec![json_response(404, ""), ok(OK_BODY)]);
    let c = client_with_hosts(t, &[H1, H2]);
    c.post(&profile_req()).await.expect("post");
    assert_eq!(hosts(&c), [H1, H2]);

    let t = MockTransport::scripted(vec![net_err(NetworkErrorKind::Other), ok(OK_BODY)]);
    let c = client_with_hosts(t, &[H1, H2]);
    let part = MultipartPart {
        field_name: "chunkContent".to_owned(),
        file_name: "a.bin".to_owned(),
        mime_type: "application/octet-stream".to_owned(),
        data: vec![1, 2, 3],
    };
    c.post_multipart(&profile_req(), &part)
        .await
        .expect("multipart");
    assert_eq!(hosts(&c), [H1, H2]);
}

#[test]
fn should_failover_table() {
    let http = |status| NetError::Http {
        status,
        body: String::new(),
    };
    assert!(http(404).should_failover());
    assert!(http(500).should_failover());
    assert!(http(503).should_failover());
    assert!(!http(400).should_failover());
    assert!(!http(403).should_failover());
    assert!(!http(200).should_failover());
    assert!(NetError::network(NetworkErrorKind::Timeout, "").should_failover());
    assert!(NetError::network(NetworkErrorKind::Other, "").should_failover());
    for e in [
        NetError::NotAuthenticated,
        NetError::InvalidJson,
        NetError::InvalidUrl("x".into()),
        NetError::QrTimeout,
        NetError::Cancelled,
        NetError::QrFailed("x".into()),
        NetError::Session(ZaloSessionError {
            code: 5,
            message: String::new(),
            url: String::new(),
        }),
    ] {
        assert!(!e.should_failover(), "{e:?}");
    }
}
