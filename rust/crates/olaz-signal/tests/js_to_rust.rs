#![allow(clippy::unwrap_used, clippy::expect_used)]
//! Direction 1: state and ciphertexts produced by the REAL bundled JS library (fixtures from
//! `tests/js/gen_fixtures.js`) are read and decrypted by Rust.

mod common;

use futures_executor::block_on;
use olaz_signal::ZaloSignalStore;

use common::{now_ms, scenario};

fn snapshot<'a>(sc: &'a serde_json::Value, before_step: usize, who: &str) -> &'a str {
    let snaps = sc["snapshots"].as_array().unwrap();
    let s = &snaps[before_step];
    assert_eq!(s["after_step"].as_u64().unwrap() as usize, before_step);
    s[who].as_str().unwrap()
}

#[test]
fn rust_decrypts_every_js_ciphertext_from_js_written_state() {
    let sc = scenario();
    let steps = sc["steps"].as_array().unwrap();
    let mut rng = rand::rng();
    // Per party: a Rust store carried across consecutive decrypts (same chain), reloaded from
    // the JS snapshot whenever that party encrypted in JS (the lineages then diverge).
    let mut alice: Option<ZaloSignalStore> = None;
    let mut bob: Option<ZaloSignalStore> = None;
    let mut decrypted = 0;
    let mut prekey_msgs = 0;

    for (j, step) in steps.iter().enumerate() {
        match step["op"].as_str().unwrap() {
            "encrypt" => match step["from"].as_str().unwrap() {
                "alice-test" => alice = None,
                _ => bob = None,
            },
            "process_bundle" => alice = None,
            "decrypt" => {
                let who = step["at"].as_str().unwrap();
                let (slot, key) = if who == "alice-test" {
                    (&mut alice, "alice")
                } else {
                    (&mut bob, "bob")
                };
                if slot.is_none() {
                    *slot = Some(
                        ZaloSignalStore::from_js_json(snapshot(&sc, j, key), now_ms()).unwrap(),
                    );
                }
                let store = slot.as_mut().unwrap();
                let cipher = step["cipher"].as_str().unwrap();
                if cipher.starts_with("AzM") {
                    prekey_msgs += 1; // base64 of 0x03 0x33
                }
                let plain = block_on(store.decrypt_cipher(
                    step["from"].as_str().unwrap(),
                    step["device"].as_u64().unwrap() as u32,
                    cipher,
                    &mut rng,
                ))
                .unwrap_or_else(|e| panic!("step {j} ({who}) failed: {e}"));
                assert_eq!(
                    String::from_utf8(plain).unwrap(),
                    step["plaintext"].as_str().unwrap(),
                    "step {j}"
                );
                decrypted += 1;
            }
            other => panic!("unknown op {other}"),
        }
    }
    assert_eq!(decrypted, 13, "scenario shape changed");
    assert_eq!(
        prekey_msgs, 3,
        "the three first-round messages are PreKeyWhisperMessages"
    );
}

#[test]
fn rust_delivers_the_in_flight_message_after_the_last_js_snapshot() {
    // The final snapshots have Bob's "late" r5 #1 undelivered: Alice holds its skipped message
    // key (seed) in JS form; Rust must find and use it.
    let sc = scenario();
    let steps = sc["steps"].as_array().unwrap();
    let late = steps
        .iter()
        .find(|s| s["plaintext"].as_str() == Some("bob r5 #1 (late)"))
        .unwrap();
    let last = sc["snapshots"].as_array().unwrap().last().unwrap();
    let mut alice =
        ZaloSignalStore::from_js_json(last["alice"].as_str().unwrap(), now_ms()).unwrap();
    let mut rng = rand::rng();
    let plain = block_on(alice.decrypt_cipher(
        "bob-test",
        sc["alice"]["remote_device_for_bob"].as_u64().unwrap() as u32,
        late["cipher"].as_str().unwrap(),
        &mut rng,
    ))
    .unwrap();
    assert_eq!(plain, b"bob r5 #1 (late)");
}

#[test]
fn rust_rejects_a_tampered_js_ciphertext() {
    let sc = scenario();
    let step = sc["steps"]
        .as_array()
        .unwrap()
        .iter()
        .enumerate()
        .find(|(_, s)| s["op"] == "decrypt")
        .unwrap();
    let (j, step) = step;
    let mut bob = ZaloSignalStore::from_js_json(snapshot(&sc, j, "bob"), now_ms()).unwrap();
    // Flip one byte in the middle of the (PreKey) message.
    use base64::Engine;
    let mut raw = base64::engine::general_purpose::STANDARD
        .decode(step["cipher"].as_str().unwrap())
        .unwrap();
    let mid = raw.len() - 12;
    raw[mid] ^= 0x01;
    let bad = base64::engine::general_purpose::STANDARD.encode(raw);
    let mut rng = rand::rng();
    let r = block_on(bob.decrypt_cipher("alice-test", 2, &bad, &mut rng));
    assert!(r.is_err());
}
