#![allow(clippy::expect_used, clippy::unwrap_used)]
//! Request headers, response decoding, state handling and persistence snapshot.

mod common;

use std::time::Duration;

use common::*;
use olaz_net::decode::{decode_response, parse_and_decrypt_response};
use olaz_net::http::{RequestOptions, build_request};
use olaz_net::mock::MockTransport;
use olaz_net::{
    ApiRequest, LoginAccount, Method, NetError, RawResponse, SessionSnapshot, SessionState,
    ZaloDomains, ZaloSessionError,
};
use serde_json::{Value, json};

#[test]
fn headers_have_user_agent_cookie_and_sek_in_swift_order() {
    let mut options = RequestOptions::get("https://tt-chat3-wpa.api.zaloapp.com/api/x?a=1");
    options.method = Method::Post;
    options.content_type = Some("application/x-www-form-urlencoded".to_owned());
    options.extra_headers = vec![("X-Extra".to_owned(), "1".to_owned())];
    let spec = build_request(&options, Some("sek.1.2")).unwrap();
    let names: Vec<&str> = spec.headers.iter().map(|(k, _)| k.as_str()).collect();
    assert_eq!(
        names,
        ["User-Agent", "Cookie", "zpw_sek", "Content-Type", "X-Extra"]
    );
    assert_eq!(spec.header("user-agent"), Some("ZaloPC-darwin-23v694"));
    assert_eq!(spec.header("Cookie"), Some("zpw_sek=sek.1.2; _zlang=vi"));
    assert_eq!(spec.header("zpw_sek"), Some("sek.1.2"));
    assert_eq!(spec.query, [("a".to_owned(), "1".to_owned())]);
}

#[test]
fn cookie_is_only_sent_to_zalo_hosts_and_when_a_session_exists() {
    for host in [
        "https://tt-friend-wpa.zaloapp.com/x",
        "https://zcld.chat.zalo.me/x",
        "https://photo-stal-1.zadn.vn/x",
        "https://WPA.ZALOAPP.COM/x",
    ] {
        let spec = build_request(&RequestOptions::get(host), Some("a.b")).unwrap();
        assert!(spec.header("Cookie").is_some(), "{host}");
    }
    for (host, sek) in [
        ("https://example.com/x", Some("a.b")),
        ("https://wpa.zaloapp.com/x", None),
        ("https://wpa.zaloapp.com/x", Some("")),
    ] {
        let spec = build_request(&RequestOptions::get(host), sek).unwrap();
        assert!(spec.header("Cookie").is_none(), "{host} {sek:?}");
        assert!(spec.header("zpw_sek").is_none());
        assert_eq!(spec.headers.len(), 1, "only the User-Agent");
    }
}

#[test]
fn extra_headers_replace_defaults_like_set_value() {
    let mut options = RequestOptions::get("https://wpa.zaloapp.com/x");
    options.content_type = Some("a/b".to_owned());
    options.extra_headers = vec![
        ("content-type".to_owned(), "c/d".to_owned()),
        ("User-Agent".to_owned(), "custom".to_owned()),
    ];
    let spec = build_request(&options, None).unwrap();
    assert_eq!(spec.header("Content-Type"), Some("c/d"));
    assert_eq!(spec.header("User-Agent"), Some("custom"));
    assert_eq!(spec.headers.len(), 2);
}

#[test]
fn invalid_urls_are_rejected_without_a_request() {
    let err = build_request(&RequestOptions::get("not a url"), None).unwrap_err();
    assert_eq!(err, NetError::InvalidUrl("not a url".to_owned()));
}

#[tokio::test]
async fn get_and_post_shapes_through_the_client() {
    let t = MockTransport::from_fn(|_| ok(r#"{"error_code":0,"data":null}"#));
    let c = client_with_hosts(t, &[H1]);
    let req = ApiRequest::new("svc", "/api/p")
        .query("z", "1")
        .query("a", "b c")
        .header("X-Trace", "t1")
        .payload(json!({"k": "v"}));
    c.get(&req).await.unwrap();
    c.post(&req).await.unwrap();
    let reqs = c.transport().requests();

    let get = &reqs[0];
    assert_eq!(get.method, Method::Get);
    assert!(get.body.is_none());
    assert!(get.header("Content-Type").is_none());
    let names: Vec<&str> = get.query.iter().map(|(k, _)| k.as_str()).collect();
    assert_eq!(
        names,
        ["zpw_ver", "zpw_type", "params", "a", "z"],
        "extras sorted after params"
    );
    assert_eq!(get.header("X-Trace"), Some("t1"));

    let post = &reqs[1];
    assert_eq!(post.method, Method::Post);
    let names: Vec<&str> = post.query.iter().map(|(k, _)| k.as_str()).collect();
    assert_eq!(
        names,
        ["zpw_ver", "zpw_type", "a", "z"],
        "payload goes in the body"
    );
    assert_eq!(
        post.header("Content-Type"),
        Some("application/x-www-form-urlencoded")
    );
    let body = String::from_utf8(post.body.clone().unwrap()).unwrap();
    let enc = body.strip_prefix("params=").unwrap();
    let plain = olaz_crypto::decode_aes(KEY, &urlencoded_decode(enc)).unwrap();
    assert_eq!(plain, r#"{"k":"v"}"#);
}

fn urlencoded_decode(s: &str) -> String {
    olaz_crypto::percent_decode(s)
}

#[tokio::test]
async fn raw_encrypted_string_goes_into_params() {
    let t = MockTransport::from_fn(|_| ok(r#"{"error_code":0}"#));
    let c = client_with_hosts(t, &[H1]);
    c.get(&ApiRequest::new("svc", "/api/raw").raw_encrypted("a=1&b=2"))
        .await
        .unwrap();
    let req = c.transport().requests().pop().unwrap();
    let plain = olaz_crypto::decode_aes(KEY, req.query_value("params").unwrap()).unwrap();
    assert_eq!(plain, "a=1&b=2");
}

#[tokio::test]
async fn multipart_boundary_in_header_matches_body() {
    let t = MockTransport::from_fn(|_| ok(r#"{"error_code":0}"#));
    let c = client_with_hosts(t, &[H1]);
    let part = olaz_net::MultipartPart {
        field_name: "f".to_owned(),
        file_name: "x.bin".to_owned(),
        mime_type: "image/png".to_owned(),
        data: vec![9, 8, 7],
    };
    c.post_multipart(&profile_req(), &part).await.unwrap();
    let req = c.transport().requests().pop().unwrap();
    let ct = req.header("Content-Type").unwrap();
    let boundary = ct.strip_prefix("multipart/form-data; boundary=").unwrap();
    let suffix = boundary.strip_prefix("----WebKitFormBoundary").unwrap();
    assert_eq!(suffix.len(), 16);
    assert!(suffix.bytes().all(|b| b.is_ascii_alphanumeric()));
    let body = req.body.clone().unwrap();
    assert!(body.starts_with(format!("--{boundary}\r\n").as_bytes()));
    assert!(body.ends_with(format!("\r\n--{boundary}--\r\n").as_bytes()));
    // params precede the sorted extras in the query
    let names: Vec<&str> = req.query.iter().map(|(k, _)| k.as_str()).collect();
    assert_eq!(names, ["zpw_ver", "zpw_type", "params", "os"]);
}

#[test]
fn response_decoding_rules() {
    let key = Some(KEY);
    let empty = parse_and_decrypt_response(b" \n ", true, key).unwrap();
    assert_eq!(Value::Object(empty), json!({"error_code": 0, "data": null}));

    // Whole body is Base64 AES of the JSON object.
    let enc = olaz_crypto::encode_aes(KEY, r#"{"error_code":0,"data":{"ok":true}}"#).unwrap();
    let r = parse_and_decrypt_response(format!("{enc}\n").as_bytes(), true, key).unwrap();
    assert_eq!(r["data"]["ok"], json!(true));
    // ...but not when decrypt is off, or without a usable key.
    assert_eq!(
        parse_and_decrypt_response(enc.as_bytes(), false, key).unwrap_err(),
        NetError::InvalidJson
    );
    assert_eq!(
        parse_and_decrypt_response(enc.as_bytes(), true, Some(&[1, 2, 3])).unwrap_err(),
        NetError::InvalidJson
    );
    assert_eq!(
        parse_and_decrypt_response(b"[1,2]", true, key).unwrap_err(),
        NetError::InvalidJson,
        "top-level arrays are not objects"
    );

    // decrypt=false leaves an encrypted data string alone.
    let body = format!(r#"{{"error_code":0,"data":"{enc}"}}"#);
    let plain = parse_and_decrypt_response(body.as_bytes(), false, key).unwrap();
    assert_eq!(plain["data"], json!(enc));
    let dec = parse_and_decrypt_response(body.as_bytes(), true, key).unwrap();
    assert_eq!(dec["data"]["ok"], json!(true));
}

#[test]
fn big_ids_stay_lossless() {
    let body = br#"{"error_code":0,"data":{"msgId":9876543210987654321,"id":"12"}}"#;
    let r = parse_and_decrypt_response(body, true, Some(KEY)).unwrap();
    assert_eq!(
        olaz_crypto::string(r["data"].get("msgId")),
        "9876543210987654321"
    );
}

#[test]
fn decode_response_maps_status_and_error_code() {
    let ok = RawResponse::new(200, r#"{"error_code":0,"data":{"a":1}}"#);
    assert!(decode_response(&ok, "/p", Some(KEY), true).is_ok());

    let err = decode_response(
        &RawResponse::new(200, r#"{"error_code":-1,"error_message":"bad"}"#),
        "/api/x",
        Some(KEY),
        true,
    )
    .unwrap_err();
    assert_eq!(
        err,
        NetError::Session(ZaloSessionError {
            code: -1,
            message: "bad".to_owned(),
            url: "/api/x".to_owned()
        })
    );
    assert_eq!(err.to_string(), "Zalo error -1: bad (/api/x)");
    assert_eq!(
        ZaloSessionError {
            code: 1,
            message: "m".into(),
            url: String::new()
        }
        .to_string(),
        "Zalo error 1: m"
    );

    // error_code may be a string; null is "absent".
    assert!(
        decode_response(
            &RawResponse::new(200, r#"{"error_code":"5"}"#),
            "/p",
            None,
            true
        )
        .is_err()
    );
    assert!(
        decode_response(
            &RawResponse::new(200, r#"{"error_code":null}"#),
            "/p",
            None,
            true
        )
        .is_ok()
    );
    assert!(decode_response(&RawResponse::new(200, r#"{"data":1}"#), "/p", None, true).is_ok());
    // 2xx other than 200 is fine; 3xx is an HTTP error.
    assert!(decode_response(&RawResponse::new(204, ""), "/p", None, true).is_ok());
    assert!(matches!(
        decode_response(&RawResponse::new(302, "x"), "/p", None, true),
        Err(NetError::Http { status: 302, .. })
    ));
    // Board notices are still errors (only the log line is skipped).
    assert!(
        decode_response(
            &RawResponse::new(200, r#"{"error_code":112}"#),
            "/api/board/x",
            None,
            true
        )
        .is_err()
    );
}

#[tokio::test]
async fn raw_get_json_download_and_sync_batch() {
    let t = MockTransport::from_fn(|req| match req.url.as_str() {
        u if u.ends_with("/json") => ok(r#"{"error_code":0,"data":{"k":1}}"#),
        u if u.ends_with("/err") => ok(r#"{"error_code":7,"error_message":"e"}"#),
        u if u.ends_with("/bad") => json_response(500, ""),
        u if u.ends_with("/blob") => Ok(RawResponse::new(200, vec![1, 2, 3])),
        u if u.ends_with("/batch") => {
            if req.header("Cookie").is_some() {
                Ok(RawResponse::new(200, vec![4, 5]))
            } else {
                Ok(RawResponse::new(403, ""))
            }
        }
        _ => json_response(404, ""),
    });
    let c = client_with_hosts(t, &[H1]);
    let d = Duration::from_secs(5);
    let r = c
        .raw_get_json("https://wpa.zaloapp.com/json", d, true)
        .await
        .unwrap();
    assert_eq!(r["data"]["k"], json!(1));
    assert!(matches!(
        c.raw_get_json("https://wpa.zaloapp.com/err", d, true).await,
        Err(NetError::Session(ZaloSessionError { code: 7, .. }))
    ));
    assert!(matches!(
        c.raw_get_json("https://wpa.zaloapp.com/bad", d, true).await,
        Err(NetError::Http { status: 500, .. })
    ));
    assert_eq!(
        c.raw_download_data("https://cdn.zadn.vn/blob", d)
            .await
            .unwrap(),
        [1, 2, 3]
    );
    // The download path never attaches the session cookie; sync batch retries once with one.
    assert_eq!(
        c.download_sync_batch("https://sync.zaloapp.com/batch", d)
            .await
            .unwrap(),
        [4, 5]
    );
    let reqs = c.transport().requests();
    let dl = reqs.iter().find(|r| r.url.ends_with("/blob")).unwrap();
    assert_eq!(dl.headers.len(), 1);
    let batch: Vec<_> = reqs.iter().filter(|r| r.url.ends_with("/batch")).collect();
    assert_eq!(batch.len(), 2);
    assert_eq!(
        batch[1].header("Cookie"),
        Some("zpw_sek=sek.1.2; zpw_uin=100")
    );
    assert_eq!(batch[0].timeout, Some(d));
}

#[test]
fn client_ids_are_strictly_increasing() {
    let mut s = SessionState::new(IMEI.to_owned(), "Mac".to_owned());
    assert_eq!(s.next_client_id(1000), 1000);
    assert_eq!(s.next_client_id(1000), 1001);
    assert_eq!(s.next_client_id(500), 1002);
    assert_eq!(s.next_client_id(2000), 2000);
}

#[test]
fn seeded_client_ids_ignore_wall_clock_and_increment() {
    let mut s = SessionState::new(IMEI.to_owned(), "Mac".to_owned());
    s.seed_next_client_id(6_000_000_000_001);
    assert_eq!(s.last_client_id_ms, 6_000_000_000_000);
    assert_eq!(s.next_client_id(1000), 6_000_000_000_001);
    assert_eq!(s.next_client_id(9_999_999_999_999), 6_000_000_000_002);
    assert_eq!(s.last_client_id_ms, 6_000_000_000_002);

    let client = olaz_net::SessionClient::new(
        MockTransport::scripted(Vec::new()),
        IMEI.to_owned(),
        "Mac".to_owned(),
    )
    .with_clock(|| 1_700_000_000_000);
    assert_eq!(client.next_client_id(), 1_700_000_000_000);
    assert_eq!(client.next_client_id(), 1_700_000_000_001);
    client.seed_next_client_id(6_000_000_000_050);
    assert_eq!(client.next_client_id(), 6_000_000_000_050);
    assert_eq!(client.next_client_id(), 6_000_000_000_051);
}

#[test]
fn is_authenticated_needs_uid_sek_and_a_valid_key_length() {
    let mut s = SessionState::new(IMEI.to_owned(), "Mac".to_owned());
    assert!(!s.is_authenticated());
    let acct = LoginAccount {
        user_id: "1".into(),
        ..Default::default()
    };
    s.update_credentials(acct.clone(), vec![0; 16], "s.1".into(), None);
    assert!(s.is_authenticated());
    s.secret_key = Some(vec![0; 24]);
    assert!(!s.is_authenticated());
    s.secret_key = Some(vec![0; 32]);
    assert!(s.is_authenticated());
    s.account = Some(LoginAccount::default());
    assert!(!s.is_authenticated());
    s.clear();
    assert!(s.account.is_none() && s.zpw_sek.is_none() && s.secret_key.is_none());
    assert_eq!(s.domains, ZaloDomains::default());
}

#[test]
fn snapshot_uses_swift_json_keys_and_restores() {
    let mut s = SessionState::new(IMEI.to_owned(), "Linh Mac".to_owned());
    let enk = olaz_crypto::parse_secret_key("0123456789abcdef");
    assert_eq!(enk, KEY);
    s.update_credentials(
        LoginAccount {
            user_id: "100".into(),
            display_name: "Linh".into(),
            send2me_id: "s2m".into(),
            zpw_enk: "0123456789abcdef".into(),
            zpw_sek: "sek.1.2".into(),
            need_sync_msg: Some(true),
            ..Default::default()
        },
        enk,
        "sek.1.2".into(),
        None,
    );
    s.expired_at = Some(12.5);
    let json = serde_json::to_value(s.snapshot()).unwrap();
    assert_eq!(json["zpwType"], "23");
    assert_eq!(json["computerName"], "Linh Mac");
    assert_eq!(json["plainAccount"]["send2MeId"], "s2m");
    assert_eq!(json["plainAccount"]["zpwEnk"], "0123456789abcdef");
    assert_eq!(json["plainAccount"]["needSyncMsg"], true);
    assert_eq!(json["domains"]["wpaChat"], "https://wpa.chat.zalo.me");
    assert_eq!(json["expiredAt"], 12.5);

    // Round trip into a fresh state.
    let back: SessionSnapshot = serde_json::from_value(json).unwrap();
    let mut fresh = SessionState::new("other".to_owned(), "x".to_owned());
    assert!(fresh.restore(back));
    assert_eq!(fresh.imei, IMEI);
    assert_eq!(fresh.computer_name, "Linh Mac");
    assert_eq!(fresh.zpw_sek.as_deref(), Some("sek.1.2"));
    assert_eq!(fresh.secret_key.as_deref(), Some(KEY));
    assert_eq!(fresh.expired_at, Some(12.5));
    assert!(fresh.is_authenticated());
}

#[test]
fn restore_rules_for_legacy_type_and_bad_accounts() {
    let account = LoginAccount {
        user_id: "1".into(),
        zpw_enk: "0123456789abcdef".into(),
        zpw_sek: "a.b".into(),
        ..Default::default()
    };
    let legacy_imei = format!("{}-{}", "x".repeat(36), "y".repeat(32));
    assert_eq!(legacy_imei.len(), 69);
    let mut snap = SessionSnapshot {
        zpw_type: None,
        imei: legacy_imei.clone(),
        computer_name: String::new(),
        domains: ZaloDomains::default(),
        plain_account: Some(account.clone()),
        expired_at: None,
    };
    snap.domains
        .preferred_hosts
        .insert("chat".into(), "https://tt-chat3-wpa.chat.zalo.me".into());

    // Legacy zpw_type=30: any 69-char IMEI is kept, upgrade flagged, stale hosts healed.
    let mut s = SessionState::new(IMEI.to_owned(), "keep".to_owned());
    assert!(s.restore(snap.clone()));
    assert!(s.needs_pc_type_upgrade);
    assert_eq!(s.imei, legacy_imei);
    assert_eq!(
        s.computer_name, "keep",
        "empty stored name keeps the current one"
    );
    assert!(!s.domains.preferred_hosts.contains_key("chat"));

    // Current type: an IMEI that does not end in md5(userAgent) is not adopted.
    snap.zpw_type = Some("23".to_owned());
    let mut s = SessionState::new(IMEI.to_owned(), "n".to_owned());
    assert!(s.restore(snap.clone()));
    assert!(!s.needs_pc_type_upgrade);
    assert_eq!(s.imei, IMEI);

    // Accounts without usable key / sek do not restore.
    for (enk, sek) in [("", "a.b"), ("0123456789abcdef", ""), ("short", "a.b")] {
        let mut bad = snap.clone();
        let acct = bad.plain_account.as_mut().unwrap();
        acct.zpw_enk = enk.to_owned();
        acct.zpw_sek = sek.to_owned();
        assert!(
            !SessionState::new(IMEI.to_owned(), "n".to_owned()).restore(bad),
            "{enk:?} {sek:?}"
        );
    }
    snap.plain_account = None;
    assert!(!SessionState::new(IMEI.to_owned(), "n".to_owned()).restore(snap));
}

#[test]
fn apply_login_config_merges_account_key_cookie_and_domains() {
    let mut s = SessionState::new(IMEI.to_owned(), "Mac".to_owned());
    let cfg = olaz_crypto::parse_object_str(
        r#"{"uid":9007199254740993,"dkey":"dk","zpw_enk":"0123456789abcdef","send2me_id":"s2m",
            "zpw_sek":"EXPIRED","account":{"zpw_sek":"ok.1.2","display_name":"Acct Name"},
            "settings":{"profile":{"name":"Prof"}},"has_pc_client":0,
            "zpw_ws":["wss://ws7-msg.chat.zalo.me"]}"#,
    )
    .unwrap();
    s.apply_login_config(&cfg);
    let a = s.account.clone().unwrap();
    assert_eq!(a.user_id, "9007199254740993");
    assert_eq!(a.dkey, "dk");
    assert_eq!(a.zpw_enk, "0123456789abcdef");
    assert_eq!(a.zpw_sek, "ok.1.2");
    assert_eq!(a.display_name, "Acct Name");
    assert_eq!(a.send2me_id, "s2m");
    assert_eq!(
        a.need_sync_msg,
        Some(true),
        "has_pc_client == 0 means sync needed"
    );
    assert_eq!(s.zpw_sek.as_deref(), Some("ok.1.2"));
    assert_eq!(s.secret_key.as_deref(), Some(KEY));
    assert_eq!(s.domains.ws, ["wss://ws7-msg.chat.zalo.me"]);

    // uid falls back to dkey; explicit need_sync_msg beats has_pc_client; bad key ignored.
    let cfg2 = olaz_crypto::parse_object_str(
        r#"{"dkey":"only-dkey","zpw_enk":"bad","needSyncMsg":"false","has_pc_client":0}"#,
    )
    .unwrap();
    let mut s2 = SessionState::new(IMEI.to_owned(), "Mac".to_owned());
    s2.apply_login_config(&cfg2);
    let a2 = s2.account.unwrap();
    assert_eq!(a2.user_id, "only-dkey");
    assert_eq!(a2.need_sync_msg, Some(false));
    assert!(s2.secret_key.is_none());
    assert_eq!(
        a2.zpw_enk, "bad",
        "Swift stores the raw enk even when it parses to a bad key"
    );
}

#[test]
fn account_json_matches_swift_codable() {
    let a = LoginAccount {
        user_id: "1".into(),
        ..Default::default()
    };
    let v = serde_json::to_value(&a).unwrap();
    assert!(v.get("needSyncMsg").is_none(), "nil optional is omitted");
    for k in [
        "userId",
        "displayName",
        "avatar",
        "phone",
        "send2MeId",
        "dkey",
        "zpwEnk",
        "zpwSek",
    ] {
        assert!(v.get(k).is_some(), "{k}");
    }
    let parsed: LoginAccount = serde_json::from_str(r#"{"userId":"5"}"#).unwrap();
    assert_eq!(parsed.user_id, "5");
}
