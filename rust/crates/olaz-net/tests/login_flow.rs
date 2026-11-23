#![allow(clippy::expect_used, clippy::unwrap_used)]
//! QR login, `getLoginInfo`, profile sync and session status against a scripted transport.
//! Timers run on tokio's paused clock, so long-polls finish instantly.

mod common;

use std::sync::{Arc, Mutex};

use common::*;
use olaz_crypto::{ParamCipher, encode_aes, parse_object_str};
use olaz_net::mock::MockTransport;
use olaz_net::{
    LoginAccount, NetError, NetworkErrorKind, QrTicket, RawResponse, SessionClient, SessionStatus,
    ZaloSessionError, parse_qr_ticket,
};
use serde_json::{Value, json};

fn cipher() -> ParamCipher {
    ParamCipher::with_zcid_ext("23", IMEI, NOW_MS, "abcdef0123".to_owned()).unwrap()
}

fn encrypt_with_cipher(plain: &str) -> String {
    encode_aes(cipher().key_data(), plain).unwrap()
}

fn ticket(scan: &str, cfirm: &str) -> QrTicket {
    QrTicket {
        token_id: "t".into(),
        qr_payload: "zalo://q".into(),
        chk_wait_scan: scan.into(),
        chk_wait_cfirm: cfirm.into(),
        qr_timeout_seconds: 10,
        qr_retry: 2,
        ..QrTicket::default()
    }
}

fn logged_out(t: MockTransport) -> SessionClient<MockTransport> {
    SessionClient::new(t, IMEI.to_owned(), "Linh MacBook Pro".to_owned())
        .with_clock(|| NOW_MS)
        .with_fixed_zcid_ext("abcdef0123")
}

fn obj(s: &str) -> serde_json::Map<String, Value> {
    parse_object_str(s).unwrap()
}

#[tokio::test]
async fn request_qr_decrypts_response_and_sends_server_settings() {
    let data = r#"{"token_id":"tk","qr_cnt":"zalo://x","base64_qr":"data:image/png;base64,AQID","chk_wait_scan":"https://wpa.zaloapp.com/scan","chk_wait_cfirm":"https://wpa.zaloapp.com/cfirm","qr_timeout":120,"qr_retry":2}"#;
    let enc = encrypt_with_cipher(data);
    let t = MockTransport::from_fn(move |req| {
        if req.url.contains("getServerInfo") {
            ok(
                r#"{"setttings":{"trusted_device":{"qr_format_trust_device":1,"self_g":2}},"zpw_chts_new":"lp.example.com"}"#,
            )
        } else {
            ok(&format!(r#"{{"error_code":0,"data":"{enc}"}}"#))
        }
    });
    let c = logged_out(t);
    let t = c.request_qr("vi").await.unwrap();
    assert_eq!(t.token_id, "tk");
    assert_eq!(t.qr_payload, "zalo://x");
    assert_eq!(
        t.base64_png.as_deref(),
        Some("AQID"),
        "data: prefix stripped"
    );
    assert_eq!(t.png_data.as_deref(), Some(&[1u8, 2, 3][..]));
    assert_eq!((t.qr_timeout_seconds, t.qr_retry), (120, 2));
    assert_eq!(c.domains().lp_chat, "https://lp.example.com");

    let reqs = c.transport().requests();
    assert_eq!(reqs.len(), 2);
    assert!(
        reqs[0]
            .url
            .starts_with("https://wpa.zaloapp.com/api/login/getServerInfo?")
    );
    let qr = &reqs[1];
    assert_eq!(qr.path(), "/api/login/reqqr");
    let plain =
        olaz_crypto::decode_aes(cipher().key_data(), qr.query_value("params").unwrap()).unwrap();
    let payload = obj(&plain);
    assert_eq!(payload["self_g"], json!(2));
    assert_eq!(payload["qr_form"], json!(1));
    assert_eq!(payload["client_time"], json!(1_700_000_000));
    assert_eq!(payload["language"], json!("vi"));
    assert_eq!(payload["logged_uids"], json!(""));
    assert_eq!(qr.query_value("zcid_ext"), Some("abcdef0123"));
    assert_eq!(qr.query_value("enc_ver"), Some("v2"));
}

#[tokio::test]
async fn request_qr_error_paths() {
    // fetchServerInfo failure is ignored; non-zero code maps to ZaloSessionError with default text.
    let t = MockTransport::from_fn(|req| {
        if req.url.contains("getServerInfo") {
            Err(NetError::network(NetworkErrorKind::Other, "offline"))
        } else {
            ok(r#"{"error_code":5}"#)
        }
    });
    let err = logged_out(t).request_qr("vi").await.unwrap_err();
    assert_eq!(
        err,
        NetError::Session(ZaloSessionError {
            code: 5,
            message: "Không tạo được mã QR".to_owned(),
            url: "/api/login/reqqr".to_owned(),
        })
    );

    let cases: Vec<(Result<RawResponse, NetError>, NetError)> = vec![
        (
            json_response(500, "oops"),
            NetError::Http {
                status: 500,
                body: "oops".into(),
            },
        ),
        (ok("nope"), NetError::InvalidJson),
        (
            ok(r#"{"error_code":0,"data":null}"#),
            NetError::QrFailed("Máy chủ không trả về dữ liệu QR.".into()),
        ),
    ];
    for (resp, want) in cases {
        let resp = Arc::new(Mutex::new(Some(resp)));
        let t = MockTransport::from_fn(move |req| {
            if req.url.contains("getServerInfo") {
                ok("{}")
            } else {
                resp.lock().unwrap().take().unwrap()
            }
        });
        assert_eq!(logged_out(t).request_qr("vi").await.unwrap_err(), want);
    }
}

#[test]
fn parse_qr_ticket_rules() {
    let t = parse_qr_ticket(
        &obj(r#"{"ntk":"n1","qr_cnt":"zalo://x","chk_wait_scan":"s"}"#),
        "fallback-cfirm",
    )
    .unwrap();
    assert_eq!(t.token_id, "n1");
    assert_eq!(t.chk_wait_cfirm, "fallback-cfirm");
    assert_eq!((t.qr_timeout_seconds, t.qr_retry), (180, 3), "defaults");
    assert!(
        t.png_data.is_none() && t.base64_png.is_none(),
        "payload-only: Swift renders it"
    );

    assert_eq!(
        parse_qr_ticket(&obj(r#"{"qr_cnt":"x"}"#), "").unwrap_err(),
        NetError::QrFailed("Thiếu endpoint chờ quét QR.".into())
    );
    assert_eq!(
        parse_qr_ticket(&obj(r#"{"chk_wait_scan":"s"}"#), "").unwrap_err(),
        NetError::QrFailed("Không tạo được ảnh mã QR.".into())
    );
    // Bad base64 but a payload present: still fine, image is rendered locally.
    let t = parse_qr_ticket(
        &obj(r#"{"chk_wait_scan":"s","qr_cnt":"p","base64_qr":"!!!"}"#),
        "",
    )
    .unwrap();
    assert!(t.png_data.is_none());
    assert_eq!(t.base64_png.as_deref(), Some("!!!"));
    // Empty base64_qr counts as absent.
    let t = parse_qr_ticket(
        &obj(r#"{"chk_wait_scan":"s","qr_cnt":"p","base64_qr":""}"#),
        "",
    )
    .unwrap();
    assert!(t.base64_png.is_none());
}

#[tokio::test(start_paused = true)]
async fn wait_for_qr_scan_polls_through_408_timeouts_and_server_waits() {
    let script = vec![
        Err(NetError::network(NetworkErrorKind::Timeout, "t")),
        Err(NetError::network(NetworkErrorKind::ConnectionLost, "c")),
        json_response(408, ""),
        ok(r#"{"error_code":8}"#),
        ok(r#"{"error_code":-13}"#),
        ok("not json"),
        ok(r#"{"error_code":0,"data":{"displayName":"Linh","avatar":"https://a.example/x.jpg"}}"#),
    ];
    let c = logged_out(MockTransport::scripted(script));
    let res = c
        .wait_for_qr_scan(
            &ticket("https://wpa.zaloapp.com/scan?x=1", "https://c"),
            None,
        )
        .await
        .unwrap();
    assert_eq!(res.display_name, "Linh");
    assert_eq!(res.avatar.as_deref(), Some("https://a.example/x.jpg"));
    let reqs = c.transport().requests();
    assert_eq!(reqs.len(), 7);
    assert!(
        reqs.iter()
            .all(|r| r.url == "https://wpa.zaloapp.com/scan?x=1&lang=vi")
    );
    assert_eq!(reqs[0].timeout, Some(std::time::Duration::from_secs(70)));
}

#[tokio::test(start_paused = true)]
async fn wait_for_qr_scan_url_separator_and_fatal_errors() {
    let c = logged_out(MockTransport::scripted(vec![ok(
        r#"{"error_code":0,"data":{"display_name":"A"}}"#,
    )]));
    c.wait_for_qr_scan(&ticket("https://wpa.zaloapp.com/scan", "c"), None)
        .await
        .unwrap();
    assert_eq!(
        c.transport().requests()[0].url,
        "https://wpa.zaloapp.com/scan?lang=vi"
    );

    // Non-network failures and non-200 statuses end the wait.
    let c = logged_out(MockTransport::scripted(vec![json_response(500, "srv")]));
    assert_eq!(
        c.wait_for_qr_scan(&ticket("https://s/x", "c"), None)
            .await
            .unwrap_err(),
        NetError::Http {
            status: 500,
            body: "srv".into()
        }
    );
    let c = logged_out(MockTransport::scripted(vec![Err(NetError::network(
        NetworkErrorKind::Other,
        "dns",
    ))]));
    assert!(matches!(
        c.wait_for_qr_scan(&ticket("https://s/x", "c"), None).await,
        Err(NetError::Network {
            kind: NetworkErrorKind::Other,
            ..
        })
    ));
    let c = logged_out(MockTransport::scripted(vec![]));
    assert_eq!(
        c.wait_for_qr_scan(&ticket("not a url", "c"), None)
            .await
            .unwrap_err(),
        NetError::InvalidUrl("not a url".into())
    );

    // Unknown codes fail after more than max(1, retry) of them, using the server message.
    let script = (0..3)
        .map(|_| ok(r#"{"error_code":77,"error_message":"expired qr"}"#))
        .collect();
    let c = logged_out(MockTransport::scripted(script));
    assert_eq!(
        c.wait_for_qr_scan(&ticket("https://s/x", "c"), None)
            .await
            .unwrap_err(),
        NetError::QrFailed("expired qr".into())
    );
    assert_eq!(
        c.transport().requests().len(),
        3,
        "retry=2 -> third failure aborts"
    );
    let script = (0..3).map(|_| ok(r#"{"error_code":77}"#)).collect();
    let c = logged_out(MockTransport::scripted(script));
    assert_eq!(
        c.wait_for_qr_scan(&ticket("https://s/x", "c"), None)
            .await
            .unwrap_err(),
        NetError::QrFailed("Mã QR đã hết hạn (mã 77).".into())
    );
}

#[tokio::test(start_paused = true)]
async fn wait_for_qr_scan_deadline_ends_in_qr_timeout() {
    let t = MockTransport::from_fn(|_| ok(r#"{"error_code":8}"#));
    let c = logged_out(t);
    assert_eq!(
        c.wait_for_qr_scan(&ticket("https://s/x", "c"), None)
            .await
            .unwrap_err(),
        NetError::QrTimeout
    );
    // deadline is max(60, 10*2) = 60 s of 500 ms sleeps
    assert!(c.transport().requests().len() >= 100);

    let t = MockTransport::from_fn(|_| Err(NetError::network(NetworkErrorKind::Timeout, "t")));
    let c = logged_out(t);
    assert_eq!(
        c.wait_for_qr_scan(&ticket("https://s/x", "c"), None)
            .await
            .unwrap_err(),
        NetError::QrTimeout
    );
}

#[tokio::test(start_paused = true)]
async fn wait_for_qr_scan_rotates_to_second_qr_on_minus_20() {
    let rotated = r#"{"error_code":-20,"data":{"token_id":"tk2","qr_cnt":"zalo://2","chk_wait_scan":"https://s/second","qr_timeout":30,"qr_retry":1}}"#;
    let t = MockTransport::from_fn(move |req| {
        if req.url.starts_with("https://s/first") {
            ok(rotated)
        } else {
            ok(r#"{"error_code":0,"data":{"display_name":"B"}}"#)
        }
    });
    let c = logged_out(t);
    let seen: Arc<Mutex<Vec<String>>> = Arc::default();
    let sink = seen.clone();
    let mut cb = move |t: &QrTicket| sink.lock().unwrap().push(t.token_id.clone());
    let res = c
        .wait_for_qr_scan(&ticket("https://s/first", "https://c/orig"), Some(&mut cb))
        .await
        .unwrap();
    assert_eq!(*seen.lock().unwrap(), ["tk2"]);
    assert_eq!(res.active_ticket.token_id, "tk2");
    assert_eq!(
        res.active_ticket.chk_wait_cfirm, "https://c/orig",
        "cfirm carried over"
    );
    let urls: Vec<String> = c
        .transport()
        .requests()
        .iter()
        .map(|r| r.url.clone())
        .collect();
    assert_eq!(
        urls,
        ["https://s/first?lang=vi", "https://s/second?lang=vi"]
    );

    // -20 without a usable ticket falls through to the error counter.
    let c = logged_out(MockTransport::scripted(vec![
        ok(r#"{"error_code":-20,"data":{}}"#),
        ok(r#"{"error_code":0,"data":{"display_name":"C"}}"#),
    ]));
    assert!(
        c.wait_for_qr_scan(&ticket("https://s/x", "c"), None)
            .await
            .is_ok()
    );
}

#[tokio::test(start_paused = true)]
async fn wait_for_qr_confirm_stores_cookie_sek_and_login_config() {
    let confirmed = RawResponse::new(
        200,
        r#"{"error_code":0,"data":{"uid":"100","zpw_enk":"0123456789abcdef","display_name":"Linh","zpw_sek":"json.1.2"}}"#,
    )
    .with_header("Set-Cookie", "zpw_sek=cookie.1.2; Path=/; HttpOnly");
    let c = logged_out(MockTransport::scripted(vec![
        ok(r#"{"error_code":18012}"#),
        json_response(408, ""),
        Err(NetError::network(NetworkErrorKind::Timeout, "t")),
        Ok(confirmed),
    ]));
    let sek = c
        .wait_for_qr_confirm(&ticket("s", "https://wpa.zaloapp.com/cfirm"))
        .await
        .unwrap();
    assert_eq!(sek, "cookie.1.2", "cookie wins over JSON, like Swift");
    let acct = c.account().unwrap();
    assert_eq!(acct.user_id, "100");
    assert_eq!(acct.display_name, "Linh");
    assert_eq!(c.secret_key().unwrap(), KEY);
    // apply_login_config then overwrote the cookie sek with the (valid) JSON one.
    assert_eq!(c.zpw_sek().as_deref(), Some("json.1.2"));
    assert_eq!(c.transport().requests().len(), 4);
}

#[tokio::test(start_paused = true)]
async fn wait_for_qr_confirm_errors() {
    let c = logged_out(MockTransport::scripted(vec![]));
    for bad in ["", "not a url"] {
        assert_eq!(
            c.wait_for_qr_confirm(&ticket("s", bad)).await.unwrap_err(),
            NetError::QrFailed("Thiếu endpoint xác nhận QR.".into())
        );
    }
    let c = logged_out(MockTransport::scripted(vec![ok(
        r#"{"error_code":0,"data":{}}"#,
    )]));
    assert_eq!(
        c.wait_for_qr_confirm(&ticket("s", "https://c/x"))
            .await
            .unwrap_err(),
        NetError::QrFailed("Xác nhận QR thành công nhưng thiếu phiên zpw_sek.".into())
    );
    let c = logged_out(MockTransport::scripted(vec![ok(r#"{"error_code":99}"#)]));
    assert_eq!(
        c.wait_for_qr_confirm(&ticket("s", "https://c/x"))
            .await
            .unwrap_err(),
        NetError::QrFailed("Đăng nhập bị từ chối (mã 99).".into())
    );
    let c = logged_out(MockTransport::scripted(vec![ok(
        r#"{"error_code":99,"error_message":"no"}"#,
    )]));
    assert_eq!(
        c.wait_for_qr_confirm(&ticket("s", "https://c/x"))
            .await
            .unwrap_err(),
        NetError::QrFailed("no".into())
    );
    let c = logged_out(MockTransport::scripted(vec![ok("html")]));
    assert_eq!(
        c.wait_for_qr_confirm(&ticket("s", "https://c/x"))
            .await
            .unwrap_err(),
        NetError::InvalidJson
    );
    let c = logged_out(MockTransport::scripted(vec![json_response(502, "x")]));
    assert!(matches!(
        c.wait_for_qr_confirm(&ticket("s", "https://c/x")).await,
        Err(NetError::Http { status: 502, .. })
    ));
    let c = logged_out(MockTransport::from_fn(|_| ok(r#"{"error_code":13}"#)));
    assert_eq!(
        c.wait_for_qr_confirm(&ticket("s", "https://c/x"))
            .await
            .unwrap_err(),
        NetError::QrTimeout
    );
}

fn login_ok_body() -> String {
    let data = r#"{"uid":"100","zpw_enk":"0123456789abcdef","zpw_sek":"info.1.2","display_name":"Linh","zpw_service_map_v3":{"profile":["https://me.example.com"]}}"#;
    format!(r#"{{"error_code":0,"data":{}}}"#, data)
}

#[tokio::test]
async fn get_login_info_tries_both_hosts_and_returns_last_error() {
    // Swift quirk: an auth error (600) is swallowed by its own catch, the 2nd host still runs.
    let c = logged_out(MockTransport::scripted(vec![
        ok(r#"{"error_code":600,"error_message":"auth"}"#),
        ok(&login_ok_body()),
    ]));
    let info = c.get_login_info("23").await.unwrap();
    assert_eq!(info["data"]["uid"], json!("100"));
    let reqs = c.transport().requests();
    assert_eq!(reqs[0].url.split('/').nth(2), Some("wpa.zaloapp.com"));
    assert_eq!(reqs[1].url.split('/').nth(2), Some("wpa.chat.zalo.me"));
    assert!(reqs[0].url.ends_with("&nretry=0"));
    assert_eq!(reqs[0].query_value("type"), Some("23"));

    let c = logged_out(MockTransport::scripted(vec![
        ok(r#"{"error_code":600,"error_message":"auth"}"#),
        json_response(503, ""),
    ]));
    assert_eq!(
        c.get_login_info("23").await.unwrap_err(),
        NetError::Http {
            status: 503,
            body: String::new()
        }
    );
    let c = logged_out(MockTransport::scripted(vec![
        json_response(500, ""),
        ok(r#"{"error_code":-102,"error_message":"gone"}"#),
    ]));
    match c.get_login_info("23").await.unwrap_err() {
        NetError::Session(e) => {
            assert!(e.is_auth_error());
            assert_eq!(e.url, "/api/login/getLoginInfo");
        }
        other => panic!("{other:?}"),
    }
    let c = logged_out(MockTransport::scripted(vec![
        ok("nope"),
        Err(NetError::network(NetworkErrorKind::Timeout, "t")),
    ]));
    assert!(matches!(
        c.get_login_info("23").await,
        Err(NetError::Network { .. })
    ));
}

#[tokio::test]
async fn get_login_info_decrypts_data_with_the_param_cipher_key() {
    let enc = encrypt_with_cipher(r#"{"uid":"7","zpw_sek":"x.1.2"}"#);
    let c = logged_out(MockTransport::scripted(vec![ok(&format!(
        r#"{{"error_code":0,"data":"{enc}"}}"#
    ))]));
    let info = c.get_login_info("23").await.unwrap();
    assert_eq!(info["data"]["uid"], json!("7"));
}

#[tokio::test]
async fn get_login_info_adopts_cookie_only_when_session_sek_is_invalid() {
    let with_cookie =
        |sek: &str| Ok(RawResponse::new(200, login_ok_body()).with_header("Set-Cookie", sek));
    let c = logged_out(MockTransport::scripted(vec![with_cookie(
        "zpw_sek=ck.1.2; Path=/",
    )]));
    c.get_login_info("23").await.unwrap();
    assert_eq!(c.zpw_sek().as_deref(), Some("ck.1.2"));

    let c = logged_out(MockTransport::scripted(vec![with_cookie(
        "zpw_sek=ck.1.2; Path=/",
    )]));
    c.set_zpw_sek(Some("keep.1.2".into()));
    c.get_login_info("23").await.unwrap();
    assert_eq!(c.zpw_sek().as_deref(), Some("keep.1.2"));
}

fn me_body() -> &'static str {
    r#"{"error_code":0,"data":{"profile":{"userId":"100","displayName":"Linh Real","avatar":"https://a/x","phoneNumber":"84900"}}}"#
}

#[tokio::test]
async fn complete_login_merges_login_info_and_profile() {
    let t = MockTransport::from_fn(|req| {
        if req.path() == "/api/login/getLoginInfo" {
            ok(&login_ok_body())
        } else if req.path() == "/api/social/profile/me-v2" {
            ok(me_body())
        } else {
            json_response(404, "")
        }
    });
    let c = logged_out(t);
    let acct = c.complete_login().await.unwrap();
    assert_eq!(acct.user_id, "100");
    assert_eq!(acct.display_name, "Linh Real");
    assert_eq!(acct.phone, "84900");
    assert_eq!(acct.avatar, "https://a/x");
    assert_eq!(acct.zpw_sek, "info.1.2");
    assert!(c.is_authenticated());
    // The profile call used the service map delivered by getLoginInfo.
    let reqs = c.transport().requests();
    let me = reqs
        .iter()
        .find(|r| r.path() == "/api/social/profile/me-v2")
        .unwrap();
    assert_eq!(host_of(me), "https://me.example.com");
    assert_eq!(me.header("Cookie"), None, "example.com is not a Zalo host");
    assert_eq!(me.query_value("os"), Some("8"));
}

#[tokio::test]
async fn complete_login_fails_without_uid_or_sek() {
    let t = MockTransport::from_fn(|req| {
        if req.path() == "/api/login/getLoginInfo" {
            ok(r#"{"error_code":0,"data":{"zpw_enk":"0123456789abcdef"}}"#)
        } else {
            json_response(500, "")
        }
    });
    let c = logged_out(t);
    assert_eq!(
        c.complete_login().await.unwrap_err(),
        NetError::NotAuthenticated
    );
}

fn authed(t: MockTransport) -> SessionClient<MockTransport> {
    let c = logged_out(t);
    c.update_credentials(
        LoginAccount {
            user_id: "100".into(),
            ..Default::default()
        },
        KEY.to_vec(),
        "sek.1.2".into(),
        None,
    );
    c
}

#[tokio::test]
async fn session_status_paths() {
    // Never logged in.
    assert_eq!(
        logged_out(MockTransport::scripted(vec![]))
            .session_status()
            .await,
        SessionStatus::Expired
    );

    // getLoginInfo OK -> valid and config applied.
    let c = authed(MockTransport::scripted(vec![ok(&login_ok_body())]));
    assert_eq!(c.session_status().await, SessionStatus::Valid);
    assert_eq!(c.account().unwrap().display_name, "Linh");

    // Auth error on getLoginInfo (both hosts) -> expired, no me-v2 probe.
    let c = authed(MockTransport::scripted(vec![
        ok(r#"{"error_code":600}"#),
        ok(r#"{"error_code":600}"#),
    ]));
    assert_eq!(c.session_status().await, SessionStatus::Expired);
    assert_eq!(c.transport().requests().len(), 2);

    // getLoginInfo unreachable -> me-v2 probe decides.
    let probe = |body: &'static str| {
        MockTransport::from_fn(move |req| {
            if req.path() == "/api/login/getLoginInfo" {
                Err(NetError::network(NetworkErrorKind::Other, "down"))
            } else {
                ok(body)
            }
        })
    };
    assert_eq!(
        authed(probe(r#"{"error_code":0,"data":{}}"#))
            .session_status()
            .await,
        SessionStatus::Valid
    );
    assert_eq!(
        authed(probe(r#"{"error_code":600}"#))
            .session_status()
            .await,
        SessionStatus::Expired
    );
    assert_eq!(
        authed(probe(r#"{"error_code":-102}"#))
            .session_status()
            .await,
        SessionStatus::Expired
    );
    assert_eq!(
        authed(probe(r#"{"error_code":3}"#)).session_status().await,
        SessionStatus::Unreachable
    );
    assert_eq!(
        authed(probe(r#"{"data":{}}"#)).session_status().await,
        SessionStatus::Unreachable
    );
    assert_eq!(
        authed(probe("garbage")).session_status().await,
        SessionStatus::Unreachable
    );

    // A legacy zpw_type=30 session that cannot reach the server stays "unreachable".
    let c = authed(MockTransport::from_fn(|_| {
        Err(NetError::network(NetworkErrorKind::Other, "down"))
    }));
    c.with_session(|s| s.needs_pc_type_upgrade = true);
    assert_eq!(c.session_status().await, SessionStatus::Unreachable);
    assert_eq!(
        c.transport().requests().len(),
        2,
        "no me-v2 probe for legacy sessions"
    );
    // ...and one rejected with any session error is expired.
    let c = authed(MockTransport::from_fn(|_| ok(r#"{"error_code":5}"#)));
    c.with_session(|s| s.needs_pc_type_upgrade = true);
    assert_eq!(c.session_status().await, SessionStatus::Expired);
}
