#![allow(clippy::unwrap_used, clippy::expect_used)]
//! Direction 2 and 3: Rust-produced ciphertexts and Rust-written records are consumed by the REAL
//! bundled JS library running in node (`tests/js/interop_server.js`).
//!
//! These tests need `node`; without it they print a note and pass (the JS fixtures in
//! `js_to_rust.rs` still cover direction 1).

mod common;

use futures_executor::block_on;
use olaz_signal::ZaloSignalStore;
use serde_json::{Value, json};

use common::{Node, now_ms, scenario};

fn node_or_skip() -> Option<Node> {
    let n = Node::start();
    if n.is_none() {
        eprintln!("SKIP: node not installed, JS interop test not run");
    }
    n
}

fn ok(v: &Value) -> &Value {
    assert_ne!(v["ok"], json!(false), "JS reported failure: {v}");
    v
}

fn js_decrypt(node: &mut Node, uid: &str, remote: &str, device: u32, cipher: &str) -> String {
    let r = node
        .call(json!({"cmd":"decrypt","uid":uid,"remote":remote,"device":device,"cipher":cipher}));
    ok(&r);
    r["text"].as_str().unwrap().to_owned()
}

fn js_encrypt(node: &mut Node, uid: &str, remote: &str, device: u32, text: &str) -> String {
    let r =
        node.call(json!({"cmd":"encrypt","uid":uid,"remote":remote,"device":device,"text":text}));
    ok(&r);
    r["cipher"].as_str().unwrap().to_owned()
}

fn rust_encrypt(store: &mut ZaloSignalStore, remote: &str, device: u32, text: &str) -> String {
    block_on(store.encrypt_cipher(remote, device, text.as_bytes()))
        .unwrap()
        .cipher
}

fn rust_decrypt(store: &mut ZaloSignalStore, remote: &str, device: u32, cipher: &str) -> String {
    let mut rng = rand::rng();
    let plain = block_on(store.decrypt_cipher(remote, device, cipher, &mut rng)).unwrap();
    String::from_utf8(plain).unwrap()
}

/// Rust Alice starts the session from a JS Bob's published bundle; messages flow both ways.
#[test]
fn rust_alice_and_js_bob_talk_both_ways() {
    let Some(mut node) = node_or_skip() else {
        return;
    };
    let mut rng = rand::rng();

    let bob = node.call(json!({"cmd":"init","uid":"bob-x"}));
    let mut alice = ZaloSignalStore::generate(&mut rng).unwrap();
    // Alice addresses Bob as device 1; Bob addresses Alice as device 2 (as in the JS fixtures).
    block_on(alice.process_bundle("bob-x", 1, &bob["bundlePayload"], &mut rng)).unwrap();

    // Round 1: Rust -> JS, PreKeyWhisperMessages, delivered 3, 1, 2.
    let a: Vec<String> = (1..=3)
        .map(|i| rust_encrypt(&mut alice, "bob-x", 1, &format!("rust→js {i} 😀")))
        .collect();
    for i in [3, 1, 2] {
        assert_eq!(
            js_decrypt(&mut node, "bob-x", "alice-x", 2, &a[i - 1]),
            format!("rust→js {i} 😀")
        );
    }

    // Round 2: JS -> Rust (DH ratchet step), delivered 2, 1.
    let b: Vec<String> = (1..=2)
        .map(|i| js_encrypt(&mut node, "bob-x", "alice-x", 2, &format!("js→rust {i}")))
        .collect();
    for i in [2, 1] {
        assert_eq!(
            rust_decrypt(&mut alice, "bob-x", 1, &b[i - 1]),
            format!("js→rust {i}")
        );
    }

    // Round 3: Rust -> JS as plain WhisperMessages, delivered 2, 3, 1.
    let c: Vec<String> = (1..=3)
        .map(|i| rust_encrypt(&mut alice, "bob-x", 1, &format!("rust→js r3 {i}")))
        .collect();
    for i in [2, 3, 1] {
        assert_eq!(
            js_decrypt(&mut node, "bob-x", "alice-x", 2, &c[i - 1]),
            format!("rust→js r3 {i}")
        );
    }

    // Round 4: JS -> Rust again, in order.
    let d = js_encrypt(&mut node, "bob-x", "alice-x", 2, "js→rust r4");
    assert_eq!(rust_decrypt(&mut alice, "bob-x", 1, &d), "js→rust r4");
}

/// A session Rust created (and advanced) is written in JS format; a JS instance restored from that
/// JSON continues it, then Rust reads back what the JS instance wrote (Rust -> JS -> Rust).
#[test]
fn rust_written_records_are_continued_by_js_and_read_back_by_rust() {
    let Some(mut node) = node_or_skip() else {
        return;
    };
    let mut rng = rand::rng();

    let bob = node.call(json!({"cmd":"init","uid":"bob-y"}));
    let mut alice = ZaloSignalStore::generate(&mut rng).unwrap();
    block_on(alice.process_bundle("bob-y", 1, &bob["bundlePayload"], &mut rng)).unwrap();
    let first: Vec<String> = (1..=2)
        .map(|i| rust_encrypt(&mut alice, "bob-y", 1, &format!("first {i}")))
        .collect();
    assert_eq!(
        js_decrypt(&mut node, "bob-y", "alice-y", 2, &first[1]),
        "first 2"
    );
    assert_eq!(
        js_decrypt(&mut node, "bob-y", "alice-y", 2, &first[0]),
        "first 1"
    );
    // Bob replies twice; Rust receives one of them (so its state holds a skipped key) ...
    let replies: Vec<String> = (1..=3)
        .map(|i| js_encrypt(&mut node, "bob-y", "alice-y", 2, &format!("reply {i}")))
        .collect();
    assert_eq!(rust_decrypt(&mut alice, "bob-y", 1, &replies[2]), "reply 3");

    // ... and the state, now carrying a skipped message key, is handed to a JS "Alice".
    let exported = alice.to_js_json(now_ms() as i64).unwrap();
    let r = node.call(json!({"cmd":"init","uid":"alice-y","saved":exported}));
    assert_eq!(
        r["restored"],
        json!(true),
        "JS must accept the Rust-written store"
    );
    assert_eq!(
        js_decrypt(&mut node, "alice-y", "bob-y", 1, &replies[0]),
        "reply 1"
    ); // skipped key survived
    assert_eq!(
        js_decrypt(&mut node, "alice-y", "bob-y", 1, &replies[1]),
        "reply 2"
    );

    // JS Alice continues the Rust-created session: Bob (JS) decrypts.
    let more: Vec<String> = (1..=2)
        .map(|i| {
            js_encrypt(
                &mut node,
                "alice-y",
                "bob-y",
                1,
                &format!("from restored js alice {i}"),
            )
        })
        .collect();
    assert_eq!(
        js_decrypt(&mut node, "bob-y", "alice-y", 2, &more[0]),
        "from restored js alice 1"
    );
    assert_eq!(
        js_decrypt(&mut node, "bob-y", "alice-y", 2, &more[1]),
        "from restored js alice 2"
    );

    // Rust reads the store JS wrote after continuing (JS -> Rust) and decrypts a fresh Bob message.
    let js_alice = node.call(json!({"cmd":"export","uid":"alice-y"}));
    let mut alice2 =
        ZaloSignalStore::from_js_json(js_alice["storeJSON"].as_str().unwrap(), now_ms()).unwrap();
    let late = js_encrypt(&mut node, "bob-y", "alice-y", 2, "after the round trip");
    assert_eq!(
        rust_decrypt(&mut alice2, "bob-y", 1, &late),
        "after the round trip"
    );
    // and the other way: Rust encrypts from the JS-written state, Bob decrypts.
    let back = rust_encrypt(&mut alice2, "bob-y", 1, "rust again");
    assert_eq!(
        js_decrypt(&mut node, "bob-y", "alice-y", 2, &back),
        "rust again"
    );
}

/// Every JS-written snapshot of the fixture scenario is imported, re-exported as JS JSON by Rust
/// (no Rust crypto involved, a pure record conversion), loaded back into a JS instance, and that
/// instance decrypts the JS ciphertext that followed in the scenario.
#[test]
fn every_js_snapshot_survives_a_rust_conversion_and_js_still_decrypts() {
    let Some(mut node) = node_or_skip() else {
        return;
    };
    let sc = scenario();
    let steps = sc["steps"].as_array().unwrap();
    let mut checked = 0;
    for (j, step) in steps.iter().enumerate() {
        if step["op"] != "decrypt" {
            continue;
        }
        let who = step["at"].as_str().unwrap();
        let key = if who == "alice-test" { "alice" } else { "bob" };
        let snap = sc["snapshots"][j][key].as_str().unwrap();
        let converted = ZaloSignalStore::from_js_json(snap, now_ms())
            .unwrap()
            .to_js_json(now_ms() as i64)
            .unwrap();

        let uid = format!("{who}-{j}");
        let r = node.call(json!({"cmd":"init","uid":uid,"saved":converted}));
        assert_eq!(r["restored"], json!(true), "step {j}");
        let text = js_decrypt(
            &mut node,
            &uid,
            step["from"].as_str().unwrap(),
            step["device"].as_u64().unwrap() as u32,
            step["cipher"].as_str().unwrap(),
        );
        assert_eq!(text, step["plaintext"].as_str().unwrap(), "step {j}");
        checked += 1;
    }
    assert_eq!(checked, 13);
}
