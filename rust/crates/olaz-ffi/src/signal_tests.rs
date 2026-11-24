#![allow(clippy::unwrap_used, clippy::expect_used)]

use serde_json::Value;

use super::*;

fn scenario() -> Value {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../olaz-signal/tests/fixtures/js_scenario.json");
    serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap()
}

/// Every JS ciphertext of the 6b fixtures decrypts through the FFI object (and the shadow entry
/// point) from the JS snapshot taken just before it.
#[tokio::test]
async fn fixtures_decrypt_through_ffi_and_shadow() {
    let sc = scenario();
    let mut count = 0;
    for (j, step) in sc["steps"].as_array().unwrap().iter().enumerate() {
        if step["op"] != "decrypt" {
            continue;
        }
        let who = if step["at"] == "alice-test" {
            "alice"
        } else {
            "bob"
        };
        let snapshot = sc["snapshots"][j][who].as_str().unwrap().to_owned();
        let sender = step["from"].as_str().unwrap().to_owned();
        let device = u32::try_from(step["device"].as_u64().unwrap()).unwrap();
        let cipher = step["cipher"].as_str().unwrap().to_owned();
        let expected = step["plaintext"].as_str().unwrap().as_bytes().to_vec();

        let shadow =
            signal_shadow_decrypt(snapshot.clone(), sender.clone(), device, cipher.clone())
                .await
                .unwrap();
        assert_eq!(shadow, expected, "shadow step {j}");

        let obj = signal_init_or_restore(snapshot).await.unwrap();
        assert!(obj.restored());
        let plain = obj.decrypt_cipher(sender, device, cipher).await.unwrap();
        assert_eq!(plain, expected, "step {j}");
        // The advanced store exports JSON the Rust side reads back.
        let json = obj.export_store_json().await.unwrap();
        assert!(signal_init_or_restore(json).await.unwrap().restored());
        count += 1;
    }
    assert!(count >= 13);
}

#[tokio::test]
async fn generate_exchange_export_reload() {
    let alice = signal_init_or_restore(String::new()).await.unwrap();
    let bob = signal_init_or_restore(String::new()).await.unwrap();
    assert!(!alice.restored());
    assert!(alice.registration_id() > 0);

    let bundle = bob.bundle_payload_json().await.unwrap();
    let v: Value = serde_json::from_str(&bundle).unwrap();
    assert_eq!(v["key"]["deviceId"], 2);
    assert_eq!(v["key"]["opKeys"].as_array().unwrap().len(), 25);

    assert!(!alice.has_session("bob".into(), 2).await.unwrap());
    alice
        .process_prekey_bundle("bob".into(), 2, bundle)
        .await
        .unwrap();
    assert!(alice.has_session("bob".into(), 2).await.unwrap());
    let sessions = alice.list_sessions("bob".into()).await.unwrap();
    assert_eq!(
        sessions,
        vec![SignalSessionRecord {
            device_id: 2,
            registration_id: bob.registration_id()
        }]
    );

    let first = alice
        .encrypt_cipher("bob".into(), 2, "xin chào".as_bytes().to_vec())
        .await
        .unwrap();
    assert_eq!(first.message_type, 3);
    let plain = bob
        .decrypt_cipher("alice".into(), 2, first.cipher)
        .await
        .unwrap();
    assert_eq!(plain, "xin chào".as_bytes());

    let reply = bob
        .encrypt_cipher("alice".into(), 2, b"hi".to_vec())
        .await
        .unwrap();
    assert_eq!(reply.message_type, 1);
    assert_eq!(
        alice
            .decrypt_cipher("bob".into(), 2, reply.cipher)
            .await
            .unwrap(),
        b"hi"
    );

    // Persist and reload both sides; the sessions keep working.
    let a2 = signal_init_or_restore(alice.export_store_json().await.unwrap())
        .await
        .unwrap();
    let b2 = signal_init_or_restore(bob.export_store_json().await.unwrap())
        .await
        .unwrap();
    assert_eq!(a2.registration_id(), alice.registration_id());
    let next = a2
        .encrypt_cipher("bob".into(), 2, b"again".to_vec())
        .await
        .unwrap();
    assert_eq!(
        b2.decrypt_cipher("alice".into(), 2, next.cipher)
            .await
            .unwrap(),
        b"again"
    );

    let keys = a2.refill_pre_keys(3).await.unwrap();
    assert_eq!(
        keys.iter().map(|k| k.id).collect::<Vec<_>>(),
        vec![26, 27, 28]
    );
    let again = signal_init_or_restore(a2.export_store_json().await.unwrap())
        .await
        .unwrap();
    assert!(again.restored());
}

#[tokio::test]
async fn errors_carry_class_only() {
    let alice = signal_init_or_restore(String::new()).await.unwrap();
    let err = alice
        .decrypt_cipher("secret-uid".into(), 2, "!!!not base64!!!".into())
        .await
        .unwrap_err();
    assert!(matches!(err, CoreError::Parse { .. }), "{err:?}");

    let junk = base64_junk();
    let err = alice
        .decrypt_cipher("secret-uid".into(), 2, junk)
        .await
        .unwrap_err();
    let text = err.to_string();
    assert!(!text.contains("secret-uid"), "{text}");

    assert!(signal_init_or_restore("{not json".into()).await.is_err());
    assert!(
        alice
            .encrypt_cipher("nobody".into(), 2, b"x".to_vec())
            .await
            .is_err()
    );
    assert!(
        alice
            .process_prekey_bundle("p".into(), 2, "{}".into())
            .await
            .is_err()
    );
}

fn base64_junk() -> String {
    // 0x03 + 0x33 + garbage: framed like a PreKeyWhisperMessage, undecodable body.
    let mut bytes = vec![3u8, 0x33];
    bytes.extend_from_slice(&[0xff; 30]);
    let table = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::new();
    for chunk in bytes.chunks(3) {
        let n = chunk
            .iter()
            .enumerate()
            .fold(0u32, |a, (i, b)| a | (u32::from(*b) << (16 - 8 * i)));
        for i in 0..4 {
            if i <= chunk.len() {
                out.push(char::from(table[((n >> (18 - 6 * i)) & 63) as usize]));
            } else {
                out.push('=');
            }
        }
    }
    out
}
