#![allow(clippy::expect_used, clippy::unwrap_used)]
//! Golden vectors produced by compiling the real Swift code (`ZaloCrypto.swift`, `ZaloDomains.swift`
//! and the pure parts of `ZaloSessionClient.swift`) with `swiftc`; see
//! `tests/fixtures/swift_probe_main.swift.txt` (probe) and `swift_golden.tsv` (its output).
//! The probe pins `zcid_ext = "abcdef0123"` and serializes payloads with sorted keys.

mod common;

use std::collections::BTreeMap;

use common::*;
use olaz_net::mock::MockTransport;
use olaz_net::request::{get_suffix, multipart_body, post_suffix_and_body};
use olaz_net::{
    ApiRequest, MultipartPart, NetError, ZaloDomains, build_server_info_url, extract_zpw_sek,
    extract_zpw_sek_cookie, is_valid_zpw_sek, unwrap_decrypted_response, url_encode,
};
use serde_json::{Value, json};

fn golden_map() -> BTreeMap<String, String> {
    include_str!("fixtures/swift_golden.tsv")
        .lines()
        .filter_map(|l| l.split_once('\t'))
        .map(|(k, v)| (k.to_owned(), v.to_owned()))
        .collect()
}

fn golden(key: &str) -> String {
    golden_map()
        .get(key)
        .cloned()
        .unwrap_or_else(|| panic!("missing golden {key}"))
}

#[test]
fn golden_imei_matches_probe_construction() {
    // `uuid-md5(userAgent)`
    assert_eq!(IMEI, golden("imei"));
    assert!(olaz_net::is_current_imei(IMEI));
}

#[test]
fn golden_get_server_info_url() {
    for name in ["Linh MacBook Pro", "Linh's Mac", "Máy của Linh’s Mac"] {
        assert_eq!(
            build_server_info_url("https://wpa.zaloapp.com", IMEI, name),
            golden(&format!("serverinfo[{name}]")),
            "{name}"
        );
    }
}

#[test]
fn golden_url_encode() {
    assert_eq!(
        url_encode("AZaz09-._~ !\"#$%&'()*+,/:;<=>?@[\\]^`{|}é€"),
        golden("urlEncode")
    );
}

async fn capture_login_url(
    path_part: &str,
    run: impl AsyncFnOnce(&olaz_net::SessionClient<MockTransport>),
) -> String {
    let t = MockTransport::from_fn(|req| {
        if req.url.contains("getServerInfo") {
            return ok("{}");
        }
        Err(NetError::Cancelled)
    });
    let c = client_with_hosts(t, &[H1]);
    run(&c).await;
    c.transport()
        .requests()
        .into_iter()
        .find(|r| r.url.contains(path_part))
        .expect("request recorded")
        .url
}

#[tokio::test]
async fn golden_reqqr_url() {
    let url = capture_login_url("/api/login/reqqr", async |c| {
        let _ = c.request_qr("vi").await;
    })
    .await;
    assert_eq!(url, golden("reqqr"));
}

#[tokio::test]
async fn golden_get_login_info_url() {
    let url = capture_login_url("/api/login/getLoginInfo", async |c| {
        let _ = c.get_login_info("23").await;
    })
    .await;
    assert_eq!(url, golden("logininfo"));
}

#[test]
fn golden_get_post_and_multipart_shapes() {
    let get = get_suffix(&profile_req(), Some(KEY)).expect("get");
    assert_eq!(get, golden("get"));

    let req = ApiRequest::new("svc", "/api/y")
        .query("b", "x y")
        .query("a", "1/2+3=4&5")
        .query("c", "ü")
        .payload(json!({"k": 1, "s": "hé/llo"}));
    let (suffix, body) = post_suffix_and_body(&req, Some(KEY)).expect("post");
    assert_eq!(
        format!("{suffix} BODY {}", String::from_utf8(body).expect("utf8")),
        golden("post")
    );

    let part = MultipartPart {
        field_name: "chunkContent".to_owned(),
        file_name: "a.bin".to_owned(),
        mime_type: "application/octet-stream".to_owned(),
        data: vec![0x01, 0x02, 0x41],
    };
    let hex: String = multipart_body("----OlazBoundaryABCDEF", &part)
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect();
    assert_eq!(hex, golden("multipart"));
}

#[test]
fn golden_cookie_extraction() {
    let now = 1_795_000_000;
    for name in [
        "expired",
        "mixed",
        "future",
        "futureDash",
        "nodot",
        "EXPIREDval",
        "other",
        "two",
        "pastDate",
        "maxage0",
    ] {
        let header = swift_cookie_header(name);
        let got = extract_zpw_sek_cookie(&[("Set-Cookie".to_owned(), header)], now);
        let want = golden(&format!("cookie[{name}]"));
        assert_eq!(got.unwrap_or_else(|| "nil".to_owned()), want, "{name}");
    }
}

/// The probe's cookie inputs (kept in the probe source, repeated here verbatim).
fn swift_cookie_header(name: &str) -> String {
    match name {
        "expired" => "zpw_sek=; Domain=.zalo.me; Path=/; Expires=Thu, 01-Jan-1970 00:00:01 GMT; Max-Age=0, zpw_sek=; Domain=.chat.zalo.me; Path=/; Expires=Thu, 01-Jan-1970 00:00:01 GMT; Max-Age=0",
        "mixed" => "zpw_sek=; Domain=.zalo.me; Path=/; Expires=Thu, 01-Jan-1970 00:00:01 GMT; Max-Age=0, zpw_sek=hdr.999999.a0.validToken; Domain=.zalo.me; Path=/; HttpOnly",
        "future" => "zpw_sek=fut.1.2.3; Domain=.zalo.me; Path=/; Expires=Wed, 21 Oct 2037 07:28:00 GMT; HttpOnly",
        "futureDash" => "zpw_sek=fut.dash.2; Domain=.zalo.me; Path=/; Expires=Wed, 21-Oct-2037 07:28:00 GMT",
        "nodot" => "zpw_sek=nodot; Domain=.zalo.me; Path=/",
        "EXPIREDval" => "zpw_sek=EXPIRED; Domain=.zalo.me; Path=/",
        "other" => "foo=bar.baz; Path=/",
        "two" => "zpw_sek=first.1.2; Path=/, zpw_sek=second.3.4; Path=/",
        "pastDate" => "zpw_sek=past.1.2; Expires=Wed, 21 Oct 2015 07:28:00 GMT; Path=/",
        "maxage0" => "zpw_sek=age.1.2; Max-Age=0; Path=/",
        other => panic!("unknown case {other}"),
    }
    .to_owned()
}

#[test]
fn golden_is_valid_zpw_sek() {
    for v in [
        "abc.def", "EXPIRED", "deleted", "null", "", " a.b ", "nodot",
    ] {
        assert_eq!(
            is_valid_zpw_sek(Some(v)).to_string(),
            golden(&format!("valid[{v}]")),
            "{v:?}"
        );
    }
    assert!(!is_valid_zpw_sek(None));
}

#[test]
fn golden_extract_zpw_sek_from_json() {
    let root = olaz_crypto::parse_object_str(r#"{"zpw_sek":" r.1 "}"#).unwrap();
    assert_eq!(extract_zpw_sek(&root).unwrap(), golden("extractSek[root]"));
    let acct =
        olaz_crypto::parse_object_str(r#"{"data":{"account":{"zpw_sek":"a.b.c"}}}"#).unwrap();
    assert_eq!(extract_zpw_sek(&acct).unwrap(), golden("extractSek[acct]"));
}

fn csv(v: Vec<String>) -> String {
    v.join(",")
}

#[test]
fn golden_domain_candidates_and_server_info() {
    let mut d = ZaloDomains::default();
    for (probe, svc) in [
        ("cand.chat", "chat"),
        ("cand.zcloud", "zcloud"),
        ("cand.friend", "friend"),
        ("cand.convers_api", "convers_api"),
        ("cand.auth", "auth"),
        ("cand.nope", "nope"),
        ("cand.group_poll", "group_poll"),
    ] {
        assert_eq!(csv(d.candidates(svc)), golden(probe), "{svc}");
    }

    let info = olaz_crypto::parse_object_str(
        r#"{
        "zpw_chts_new": ["https://p9-msg.example.com/"],
        "zpw_ctrs_new": "ctl.example.com",
        "zpw_ws": ["ws1.example.com", "wss://ws2.example.com/", "ftp://nope", 5],
        "zpw_service_map_v3": {
            "chat": ["chat.custom.com", "https://chat.custom.com/", " https://tt-chat1-wpa.api.zaloapp.com "],
            "convers_api": "conv.custom.com",
            "cloud_msg": ["cm.custom.com"],
            "friend": [],
            "label": "",
            "sticker": ["https://tt-sticker-wpa.zaloapp.com"]
        }}"#,
    )
    .unwrap();
    d.apply_server_info(&info);
    assert_eq!(
        format!("{} {}", d.lp_chat, d.lp_control),
        golden("after.lp")
    );
    assert_eq!(csv(d.ws.clone()), golden("after.ws"));
    for svc in [
        "chat",
        "conversation",
        "convers_api",
        "group_cloud_message",
        "friend",
        "label",
        "sticker",
    ] {
        assert_eq!(
            csv(d.candidates(svc)),
            golden(&format!("after.cand.{svc}")),
            "{svc}"
        );
    }

    d.remember_winner("chat", "https://tt-chat4-wpa.api.zaloapp.com/");
    d.remember_winner("cloud_msg", "cm.custom.com");
    d.preferred_hosts.insert(
        "profile".to_owned(),
        "https://tt-profile-wpa.chat.zalo.me".to_owned(),
    );
    d.ws.push("wss://ws9-msg.zaloapp.com".to_owned());
    assert_eq!(csv(d.candidates("chat")), golden("after.chat"));
    d.heal_from_verified();
    let got = serde_json::to_value(&d).unwrap();
    let want: Value = serde_json::from_str(&golden("domainsJSON")).unwrap();
    assert_eq!(got, want);
    // And Swift's JSON reads back into the Rust struct.
    let back: ZaloDomains = serde_json::from_value(want).unwrap();
    assert_eq!(back, d);

    let mut d2 = ZaloDomains::default();
    d2.apply_server_info(
        &olaz_crypto::parse_object_str(r#"{"zpw_service_map_new":{"group":["g.custom.com"]}}"#)
            .unwrap(),
    );
    assert_eq!(csv(d2.candidates("group")), golden("v2map"));
}

#[test]
fn golden_unwrap_decrypted_response() {
    let g = |name: &str, data: Value, extra: &[(&str, Value)]| {
        let mut m = serde_json::Map::new();
        m.insert("error_code".to_owned(), json!(0));
        m.insert("data".to_owned(), data);
        for (k, v) in extra {
            m.insert((*k).to_owned(), v.clone());
        }
        let out = unwrap_decrypted_response(&m, Some(KEY));
        let want: Value = serde_json::from_str(&golden(&format!("unwrap[{name}]"))).unwrap();
        assert_eq!(Value::Object(out), want, "{name}");
    };
    let enc = |s: &str| json!(olaz_crypto::encode_aes(KEY, s).unwrap());
    // Ciphertext the Swift probe produced (zero-IV AES-CBC is deterministic).
    assert_eq!(enc("[1,2,3]"), json!(golden("enc.arr")));
    let inner = r#"{"error_code":0,"data":"{\"groupMsgs\":[{\"msgId\":\"10\"}]}"}"#;
    assert_eq!(enc(inner), json!(golden("enc.inner")));

    g("nested", json!(golden("enc.inner")), &[]);
    g("nestedEnc", json!(golden("enc.innerEnc")), &[]);
    g("obj", json!(golden("enc.obj")), &[]);
    g("arr", json!(golden("enc.arr")), &[]);
    g("jsonStr", json!(r#"  {"a":1}  "#), &[]);
    g("badStr", json!("not base64 !!"), &[]);
    g(
        "withErr",
        enc(r#"{"error_code":114,"error_message":"x"}"#),
        &[],
    );
    g("numData", json!(5), &[]);

    let no_data = olaz_crypto::parse_object_str(r#"{"error_code":3,"error_message":"m"}"#).unwrap();
    assert_eq!(
        Value::Object(unwrap_decrypted_response(&no_data, Some(KEY))),
        serde_json::from_str::<Value>(&golden("unwrap[noData]")).unwrap()
    );
    let m = olaz_crypto::parse_object_str(&format!(
        r#"{{"error_code":0,"data":"{}"}}"#,
        olaz_crypto::encode_aes(KEY, "[1]").unwrap()
    ))
    .unwrap();
    assert_eq!(
        Value::Object(unwrap_decrypted_response(&m, None)),
        serde_json::from_str::<Value>(&golden("unwrap[nokey]")).unwrap()
    );
}
