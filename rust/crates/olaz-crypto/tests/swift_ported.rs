//! Ports of the Swift tests in `Tests/OlazTests` that exercise ZaloCrypto / JSONLossless.
#![allow(clippy::unwrap_used, clippy::expect_used)]
use base64::{Engine as _, engine::general_purpose::STANDARD};
use flate2::{Compression, write::ZlibEncoder};
use olaz_crypto::*;
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::io::Write;

fn map(pairs: &[(&str, &str)]) -> BTreeMap<String, String> {
    pairs
        .iter()
        .map(|(k, v)| ((*k).to_owned(), (*v).to_owned()))
        .collect()
}

/// NativeProtocolTests.signKeyDeterminismAndSorting
#[test]
fn sign_key_determinism_and_sorting() {
    let p1 = map(&[("b", "2"), ("a", "1"), ("imei", "abc")]);
    let p2 = map(&[("imei", "abc"), ("a", "1"), ("b", "2")]);
    let k1 = sign_key("reqqr", &p1);
    assert_eq!(k1, sign_key("reqqr", &p2));
    assert_eq!(k1.len(), 32);
    assert_eq!(k1, md5_hex("zsecurereqqr12abc"));
}

/// NativeProtocolTests.paramCipherAndAESCBCRoundTrip (IMEI generator lives in olaz-net/olaz-api).
#[test]
fn param_cipher_and_aes_cbc_round_trip() {
    let imei = "x".repeat(69);
    let cipher = ParamCipher::new("30", &imei, 1_700_000_000_000).unwrap();
    assert_eq!(cipher.zcid_ext().len(), 10);
    assert_eq!(cipher.encrypt_key().len(), 32);
    let payload = json!({"imei": imei, "computer_name": "Mac", "language": "vi"});
    let signed = cipher
        .build_signed_params("30", "694", &payload, "getlogininfo")
        .unwrap();
    for k in [
        "zcid",
        "zcid_ext",
        "enc_ver",
        "params",
        "signkey",
        "type",
        "client_version",
    ] {
        assert!(signed.contains_key(k), "{k}");
    }
    assert_eq!(signed["enc_ver"], "v2");
    let mut unsigned = signed.clone();
    unsigned.remove("signkey");
    assert_eq!(signed["signkey"], sign_key("getlogininfo", &unsigned));
    // The encrypted `params` decrypts back to the payload.
    let plain = decode_aes(cipher.key_data(), &signed["params"]).unwrap();
    assert_eq!(serde_json::from_str::<Value>(&plain).unwrap(), payload);

    let raw_key = [0x42u8; 16];
    let encrypted = encode_aes(&raw_key, r#"{"ok":true,"id":123}"#).unwrap();
    assert_eq!(
        decode_aes(&raw_key, &encrypted).unwrap(),
        r#"{"ok":true,"id":123}"#
    );
}

/// NativeProtocolTests.parseSecretKeyAndLiveVectorShape
#[test]
fn parse_secret_key_and_live_vector_shape() {
    assert_eq!(parse_secret_key("0123456789abcdef"), b"0123456789abcdef");
    let raw32: Vec<u8> = (0..32).collect();
    assert_eq!(parse_secret_key(&STANDARD.encode(&raw32)), raw32);
}

fn zlib(data: &[u8]) -> Vec<u8> {
    let mut e = ZlibEncoder::new(Vec::new(), Compression::default());
    e.write_all(data).unwrap();
    e.finish().unwrap()
}

/// NativeProtocolTests.wsFrameAESGCMAndGzipDecryption
#[test]
fn ws_frame_aes_gcm_and_gzip_decryption() {
    let key: Vec<u8> = (0..32u32).map(|i| ((i * 7) & 0xFF) as u8).collect();
    let iv: Vec<u8> = (0..16u8).map(|i| i + 1).collect();
    let aad: Vec<u8> = (0..16u8).map(|i| i + 17).collect();
    let plain = br#"{"error_code":0,"data":{"msgId":9876543210987654321}}"#;

    // encrypt=3, percent-encoded Base64 (Swift `.alphanumerics` encodes every non-alnum char).
    let frame3 = gcm_encrypt16(&key, plain, &iv, &aad).unwrap();
    let b64: String = STANDARD
        .encode(&frame3)
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() {
                c.to_string()
            } else {
                format!("%{:02X}", c as u32)
            }
        })
        .collect();
    assert_eq!(decrypt_ws_frame(Some(&key), 3, &b64).unwrap(), plain);

    let compressed = zlib(plain);
    let out1 = decrypt_ws_frame(None, 1, &STANDARD.encode(&compressed)).unwrap();
    assert_eq!(out1, plain);

    let frame2 = gcm_encrypt16(&key, &compressed, &iv, &aad).unwrap();
    let out2 = decrypt_ws_frame(Some(&key), 2, &STANDARD.encode(&frame2)).unwrap();
    assert_eq!(out2, plain);
}

/// NativeProtocolTests.jsonLosslessPreserves64BitIntegers
#[test]
fn json_lossless_preserves_64bit_integers() {
    let raw = r#"{"msgId":1731849600123456789,"cliMsgId":1731849600987654,"count":42}"#;
    let parsed = parse_object_str(raw);
    let p = parsed.as_ref();
    assert_eq!(
        string(p.and_then(|m| m.get("msgId"))),
        "1731849600123456789"
    );
    assert_eq!(
        string(p.and_then(|m| m.get("cliMsgId"))),
        "1731849600987654"
    );
    assert_eq!(int64(p.and_then(|m| m.get("count"))), Some(42));
}

/// FeatureFixesTests.cloudAESRoundTripsWithRandomIVAndRejectsInvalidInputs
#[test]
fn cloud_aes_round_trips_with_random_iv_and_rejects_invalid_inputs() {
    let key16 = STANDARD.encode([0x2Au8; 16]);
    let key32 = STANDARD.encode([0x5Cu8; 32]);
    let plain = r#"{"plan":-1,"quota":1073741824,"usage":5242880}"#;

    let c1 = encode_cloud_aes(&key16, plain).unwrap();
    let c2 = encode_cloud_aes(&key16, plain).unwrap();
    assert_ne!(c1, c2); // random 16-byte IV produces distinct ciphertexts
    assert_eq!(decode_cloud_aes(&key16, &c1).unwrap(), plain);
    assert_eq!(decode_cloud_aes(&key16, &c2).unwrap(), plain);

    let c32 = encode_cloud_aes(&key32, plain).unwrap();
    assert_eq!(decode_cloud_aes(&key32, &c32).unwrap(), plain);

    let bad_key = STANDARD.encode([1u8, 2, 3]);
    assert!(encode_cloud_aes(&bad_key, "hi").is_err());
    assert!(decode_cloud_aes(&key16, &STANDARD.encode([1u8; 16])).is_err());
}

/// GroupMgmtAndSearchTests / MediaSendAndTypingTests / Stage4FeaturesTests accessor usage.
#[test]
fn json_accessors_as_used_by_feature_tests() {
    let o = parse_object_str(
        r#"{"grid":555,"avatarSize":320,"gname":"Nhóm Mới","silent":1,"duration":4200,
            "fileSize":987654,"checksum":"abc","visibility":0,"topicId":"poll_42"}"#,
    )
    .unwrap();
    assert_eq!(string(o.get("grid")), "555");
    assert_eq!(int64(o.get("avatarSize")), Some(320));
    assert_eq!(string(o.get("gname")), "Nhóm Mới");
    assert_eq!(int64(o.get("silent")), Some(1));
    assert_eq!(int64(o.get("fileSize")), Some(987_654));
    assert_eq!(int64(o.get("visibility")), Some(0));
    assert_eq!(string(o.get("topicId")), "poll_42");
    assert_eq!(int64(o.get("missing")), None);
}

#[test]
fn random_helpers_have_expected_shape() {
    assert_eq!(random_hex(0), "");
    for n in [1usize, 2, 9, 10, 33] {
        let h = random_hex(n);
        assert_eq!(h.len(), n);
        assert!(h.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f')));
    }
    assert_ne!(random_hex(32), random_hex(32));
    assert_eq!(random_salt(0), "");
    for n in [1usize, 8, 64] {
        let s = random_salt(n);
        assert_eq!(s.len(), n);
        assert!(
            s.bytes()
                .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit())
        );
    }
}

#[test]
fn random_alphanumeric_has_expected_shape() {
    assert_eq!(random_alphanumeric(0), "");
    for n in [1usize, 16, 64] {
        let s = random_alphanumeric(n);
        assert_eq!(s.len(), n);
        assert!(s.bytes().all(|b| b.is_ascii_alphanumeric()));
    }
    assert_ne!(random_alphanumeric(16), random_alphanumeric(16));
}

#[test]
fn param_cipher_random_ext_is_10_hex_and_key_matches_swift_derivation() {
    let c = ParamCipher::new("30", "imei", 1).unwrap();
    assert_eq!(c.zcid_ext().len(), 10);
    assert!(
        c.zcid_ext()
            .bytes()
            .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())
    );
    let key = c.encrypt_key();
    let md5_upper = md5_hex(c.zcid_ext()).to_uppercase();
    let even: String = md5_upper.chars().step_by(2).take(8).collect();
    assert!(key.starts_with(&even));
}
