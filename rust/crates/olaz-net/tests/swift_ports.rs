#![allow(clippy::expect_used, clippy::unwrap_used)]
//! Ports of the Swift tests that touch `ZaloDomains`, `ZaloSessionClient` statics, IMEI and
//! signed params (`Tests/OlazTests/NativeProtocolTests.swift`), with identical expectations.

mod common;

use std::collections::BTreeMap;

use common::*;
use olaz_crypto::{ParamCipher, decode_aes, encode_aes, md5_hex, sign_key};
use olaz_net::mock::MockTransport;
use olaz_net::{
    ApiRequest, USER_AGENT, WS_ORIGIN, ZPW_TYPE, ZPW_VER, ZaloDomains, extract_zpw_sek,
    extract_zpw_sek_cookie, generate_imei, is_valid_zpw_sek, unwrap_decrypted_response,
};
use serde_json::{Value, json};

/// `NativeDomainsAndWSTests.serviceCandidateFailoverAndWinnerPromotion`
#[test]
fn service_candidate_failover_and_winner_promotion() {
    assert_eq!(ZPW_TYPE, "23");
    assert_eq!(USER_AGENT, "ZaloPC-darwin-23v694");
    assert_eq!(WS_ORIGIN, "file://");

    let mut domains = ZaloDomains::default();
    let initial = domains.candidates("chat");
    assert_eq!(
        initial.first().unwrap(),
        "https://tt-chat3-wpa.api.zaloapp.com"
    );
    assert_eq!(
        domains.candidates("group_board").first().unwrap(),
        "https://groupboard-wpa.api.zaloapp.com"
    );
    assert!(initial.len() >= 2);

    domains.remember_winner("chat", "https://tt-chat1-wpa.api.zaloapp.com");
    assert_eq!(
        domains.candidates("chat").first().unwrap(),
        "https://tt-chat1-wpa.api.zaloapp.com"
    );

    let mut custom = ZaloDomains::default();
    custom.apply_server_info(
        &olaz_crypto::parse_object_str(
            r#"{"zpw_service_map_v3":{"chat":["https://custom-chat.api.zaloapp.com"]},
                "zpw_ws":["wss://ws1-msg.zaloapp.com"]}"#,
        )
        .unwrap(),
    );
    assert_eq!(
        custom.candidates("chat").first().unwrap(),
        "https://custom-chat.api.zaloapp.com"
    );
    assert_eq!(custom.ws.first().unwrap(), "wss://ws1-msg.zaloapp.com");
}

/// `NativeDomainsAndWSTests.domainHealAndNestedStringDataDecryption`
#[test]
fn domain_heal_and_nested_string_data_decryption() {
    let mut domains = ZaloDomains::default();
    domains.remember_winner("chat", "https://tt-chat3-wpa.chat.zalo.me");
    domains.remember_winner("group_board", "https://groupboard-wpa.api.zaloapp.com");
    domains.heal_from_verified();
    assert!(!domains.preferred_hosts.contains_key("chat"));
    assert_eq!(
        domains.preferred_hosts["group_board"],
        "https://groupboard-wpa.api.zaloapp.com"
    );

    let inner = r#"{"error_code":0,"data":"{\"groupMsgs\":[{\"msgId\":\"10\"}]}"}"#;
    let enc = encode_aes(KEY, inner).unwrap();
    let mut response = serde_json::Map::new();
    response.insert("error_code".to_owned(), json!(0));
    response.insert("data".to_owned(), json!(enc));
    let unwrapped = unwrap_decrypted_response(&response, Some(KEY));
    let group_msgs = unwrapped["data"]["groupMsgs"].as_array().unwrap();
    assert_eq!(group_msgs.len(), 1);
}

/// `PhoneSyncAndAuthFixTests.extractZpwSekRejectsWpskVapidKeyAndAcceptsRealSek`
#[test]
fn extract_zpw_sek_rejects_wpsk_vapid_key_and_accepts_real_sek() {
    let vapid_like = "B".repeat(87);
    let bad = json!({"error_code": 0, "data": {
        "zpw_wpsk": vapid_like, "zpw_enk": "abcd1234abcd1234",
        "zpw_kt": "some_kt_token", "token": "unrelated_token"}});
    let Value::Object(bad) = bad else { panic!() };
    assert_eq!(extract_zpw_sek(&bad), None);
    assert!(!is_valid_zpw_sek(Some(&vapid_like)));
    assert!(!is_valid_zpw_sek(Some("EXPIRED")));
    assert!(!is_valid_zpw_sek(Some("")));

    let good = json!({"error_code": 0, "data": {
        "zpw_wpsk": vapid_like, "zpw_sek": "abcd.123456.a0.xyz789"}});
    let Value::Object(good) = good else { panic!() };
    assert_eq!(extract_zpw_sek(&good).unwrap(), "abcd.123456.a0.xyz789");
}

/// `PhoneSyncAndAuthFixTests.extractZpwSekCookieHandlesExpiresCommaAndSkipsMaxAgeZero`
#[test]
fn extract_zpw_sek_cookie_handles_expires_comma_and_skips_max_age_zero() {
    let now = 1_795_000_000;
    let only_expired = "zpw_sek=; Domain=.zalo.me; Path=/; Expires=Thu, 01-Jan-1970 00:00:01 GMT; Max-Age=0, zpw_sek=; Domain=.chat.zalo.me; Path=/; Expires=Thu, 01-Jan-1970 00:00:01 GMT; Max-Age=0";
    assert_eq!(
        extract_zpw_sek_cookie(&[("Set-Cookie".to_owned(), only_expired.to_owned())], now),
        None
    );
    let mixed = "zpw_sek=; Domain=.zalo.me; Path=/; Expires=Thu, 01-Jan-1970 00:00:01 GMT; Max-Age=0, zpw_sek=hdr.999999.a0.validToken; Domain=.zalo.me; Path=/; HttpOnly";
    assert_eq!(
        extract_zpw_sek_cookie(&[("Set-Cookie".to_owned(), mixed.to_owned())], now).unwrap(),
        "hdr.999999.a0.validToken"
    );
    // Multiple separate Set-Cookie headers (reqwest keeps them apart) behave the same.
    let separate = [
        (
            "set-cookie".to_owned(),
            "zpw_sek=; Domain=.zalo.me; Path=/; Expires=Thu, 01-Jan-1970 00:00:01 GMT; Max-Age=0"
                .to_owned(),
        ),
        (
            "Set-Cookie".to_owned(),
            "zpw_sek=hdr.999999.a0.validToken; Domain=.zalo.me; Path=/; HttpOnly".to_owned(),
        ),
    ];
    assert_eq!(
        extract_zpw_sek_cookie(&separate, now).unwrap(),
        "hdr.999999.a0.validToken"
    );
}

/// `NativeProtocolTests.paramCipherAndAESCBCRoundTrip` (+ IMEI shape)
#[test]
fn param_cipher_and_aes_cbc_round_trip() {
    let imei = generate_imei();
    assert_eq!(imei.chars().count(), 69);
    let cipher = ParamCipher::new("30", &imei, 1_700_000_000_000).unwrap();
    let payload = json!({"imei": imei, "computer_name": "Mac", "language": "vi"});
    let signed = cipher
        .build_signed_params("30", ZPW_VER, &payload, "getlogininfo")
        .unwrap();
    assert!(signed.contains_key("zcid"));
    assert!(signed.contains_key("zcid_ext"));
    assert_eq!(signed["enc_ver"], "v2");
    assert!(signed.contains_key("params"));
    let without_sign: BTreeMap<String, String> = signed
        .iter()
        .filter(|(k, _)| *k != "signkey")
        .map(|(k, v)| (k.clone(), v.clone()))
        .collect();
    assert_eq!(signed["signkey"], sign_key("getlogininfo", &without_sign));

    let raw_key = [0x42u8; 16];
    let encrypted = encode_aes(&raw_key, r#"{"ok":true,"id":123}"#).unwrap();
    assert_eq!(
        decode_aes(&raw_key, &encrypted).unwrap(),
        r#"{"ok":true,"id":123}"#
    );
}

#[test]
fn generated_imei_is_uuid_v4_plus_user_agent_md5() {
    for _ in 0..50 {
        let imei = generate_imei();
        assert_eq!(imei.len(), 69);
        let (uuid, suffix) = imei.split_at(36);
        assert_eq!(suffix, format!("-{}", md5_hex(USER_AGENT)));
        let parts: Vec<&str> = uuid.split('-').collect();
        assert_eq!(
            parts.iter().map(|p| p.len()).collect::<Vec<_>>(),
            [8, 4, 4, 4, 12]
        );
        assert!(parts[2].starts_with('4'), "{uuid}");
        assert!("89ab".contains(parts[3].chars().next().unwrap()), "{uuid}");
        assert!(
            uuid.chars()
                .all(|c| c == '-' || c.is_ascii_hexdigit() && !c.is_ascii_uppercase())
        );
        assert!(olaz_net::is_current_imei(&imei));
    }
    assert_ne!(generate_imei(), generate_imei());
    assert!(!olaz_net::is_current_imei("short"));
    assert!(!olaz_net::is_current_imei(&format!(
        "{}-{}",
        "a".repeat(36),
        "0".repeat(32)
    )));
}

/// Pattern of `MockProfileURLProtocol` tests (e.g. `sendE2EEMessageAPI`): credentials + mocked
/// service host, request captured, payload decrypted from the `params` query value.
#[tokio::test]
async fn mocked_service_captures_path_and_decrypts_request_payload() {
    let t = MockTransport::from_fn(|_| ok(r#"{"error_code":0,"data":{"msgId":"8800112233"}}"#));
    let c = client_with_hosts(t, &["https://e2e.mock.zaloapp.com"]);
    let req = ApiRequest::new("svc", "/api/e2ee/pc/message/sms").payload(json!({
        "destType": 3, "threadId": "222", "clientId": 1_795_000_000_123_i64,
        "listParams": "[{\"e2eeExt\":\"x\"}]"
    }));
    let res = c.get(&req).await.unwrap();
    assert_eq!(olaz_crypto::string(res["data"].get("msgId")), "8800112233");

    let recorded = c.transport().requests().pop().unwrap();
    assert_eq!(recorded.path(), "/api/e2ee/pc/message/sms");
    assert_eq!(recorded.query_value("zpw_ver"), Some("694"));
    assert_eq!(recorded.query_value("zpw_type"), Some("23"));
    let payload = decrypted_params(&recorded);
    assert_eq!(olaz_crypto::int64(payload.get("destType")), Some(3));
    assert_eq!(olaz_crypto::string(payload.get("threadId")), "222");
    assert_eq!(
        olaz_crypto::int64(payload.get("clientId")),
        Some(1_795_000_000_123)
    );
    let sent_list =
        olaz_crypto::parse_any(payload["listParams"].as_str().unwrap().as_bytes()).unwrap();
    assert_eq!(sent_list[0]["e2eeExt"], "x");
}
