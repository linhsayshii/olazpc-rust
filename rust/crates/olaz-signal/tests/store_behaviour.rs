#![allow(clippy::unwrap_used, clippy::expect_used)]
//! Store semantics that must match the JS wrapper: one-time prekey consumption, bundle shapes,
//! TOFU identity pinning, JSON shape of a freshly generated store.

mod common;

use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use futures_executor::block_on;
use olaz_signal::{JsStore, ZaloSignalStore, zalo_address};
use serde_json::json;

use common::now_ms;

fn pair() -> (ZaloSignalStore, ZaloSignalStore) {
    let mut rng = rand::rng();
    (
        ZaloSignalStore::generate(&mut rng).unwrap(),
        ZaloSignalStore::generate(&mut rng).unwrap(),
    )
}

#[test]
fn generated_store_has_the_js_shape_and_loads_back() {
    let (alice, _) = pair();
    let json = alice.to_js_json(now_ms() as i64).unwrap();
    let js = JsStore::parse(&json).unwrap();
    assert_eq!(js.pre_keys.len(), 25);
    assert_eq!(js.next_pre_key_id, 26);
    assert_eq!(js.signed_pre_key_id, 1);
    assert_eq!(js.identity.pub_key.len(), 33);
    assert_eq!(js.identity.pub_key[0], 5);
    assert_eq!(js.identity.priv_key.len(), 32);
    assert_eq!(js.signed_pre_keys[&1].signature.len(), 64);
    let back = ZaloSignalStore::from_js_json(&json, now_ms()).unwrap();
    assert_eq!(
        JsStore::parse(&back.to_js_json(now_ms() as i64).unwrap()).unwrap(),
        js
    );
}

#[test]
fn bundle_payload_has_the_server_shape() {
    let (alice, _) = pair();
    let b = alice.bundle_payload().unwrap();
    assert_eq!(b["key"]["deviceId"], json!(2));
    assert_eq!(b["key"]["opKeys"].as_array().unwrap().len(), 25);
    assert_eq!(b["key"]["opKeys"][0]["id"], json!(1));
    assert_eq!(b["key"]["preKey"]["spKey"]["id"], json!(1));
    assert_eq!(
        STANDARD
            .decode(b["key"]["preKey"]["signature"].as_str().unwrap())
            .unwrap()
            .len(),
        64
    );
}

#[test]
fn a_one_time_prekey_is_consumed_by_the_first_prekey_message() {
    let (mut alice, mut bob) = pair();
    let mut rng = rand::rng();
    let bundle = bob.bundle_payload().unwrap();
    block_on(alice.process_bundle("bob", 1, &bundle, &mut rng)).unwrap();
    let c = block_on(alice.encrypt_cipher("bob", 1, b"hi")).unwrap();
    assert_eq!(c.message_type, 3);
    assert!(bob.pre_keys.keys.contains_key(&1));
    let plain = block_on(bob.decrypt_cipher("alice", 2, &c.cipher, &mut rng)).unwrap();
    assert_eq!(plain, b"hi");
    assert!(
        !bob.pre_keys.keys.contains_key(&1),
        "prekey 1 must be removed"
    );
    let js = JsStore::parse(&bob.to_js_json(now_ms() as i64).unwrap()).unwrap();
    assert!(!js.pre_keys.contains_key(&1));
    assert_eq!(js.pre_keys.len(), 24);
}

#[test]
fn flat_bundle_without_a_one_time_key_works() {
    let (mut alice, bob) = pair();
    let mut rng = rand::rng();
    let b = bob.bundle_payload().unwrap();
    let pk = &b["key"]["preKey"];
    let flat = json!({
        "registrationId": pk["iKey"]["id"],
        "identityKey": pk["iKey"]["key"],
        "signedPreKey": {"keyId": pk["spKey"]["id"], "publicKey": pk["spKey"]["key"], "signature": pk["signature"]},
    });
    block_on(alice.process_bundle("bob", 1, &flat, &mut rng)).unwrap();
    let c = block_on(alice.encrypt_cipher("bob", 1, b"no one-time key")).unwrap();
    assert_eq!(c.message_type, 3);
    let mut bob = bob;
    let plain = block_on(bob.decrypt_cipher("alice", 2, &c.cipher, &mut rng)).unwrap();
    assert_eq!(plain, b"no one-time key");
}

#[test]
fn bad_signed_prekey_signature_is_rejected() {
    let (mut alice, bob) = pair();
    let mut rng = rand::rng();
    let mut b = bob.bundle_payload().unwrap();
    let mut sig = STANDARD
        .decode(b["key"]["preKey"]["signature"].as_str().unwrap())
        .unwrap();
    sig[0] ^= 1;
    b["key"]["preKey"]["signature"] = json!(STANDARD.encode(sig));
    assert!(block_on(alice.process_bundle("bob", 1, &b, &mut rng)).is_err());
}

#[test]
fn identity_is_pinned_trust_on_first_use_and_stored_by_address_name() {
    let (mut alice, bob) = pair();
    let mut rng = rand::rng();
    block_on(alice.process_bundle("bob", 1, &bob.bundle_payload().unwrap(), &mut rng)).unwrap();
    assert!(
        alice.identity.trusted.contains_key("bob_1"),
        "JS keys trust by `<uid>_<dev>`"
    );
    let js = JsStore::parse(&alice.to_js_json(now_ms() as i64).unwrap()).unwrap();
    assert_eq!(
        js.trusted["bob_1"],
        bob.identity.pair.public_key().serialize().to_vec()
    );
    assert!(
        js.sessions.contains_key("bob_1.1"),
        "session key is `<name>.<device>`"
    );
    assert_eq!(zalo_address("bob", 1).to_string(), "bob_1.1");
}

#[test]
fn a_changed_identity_in_a_new_bundle_is_accepted_like_the_glue_does() {
    // zalo-e2ee.js drops the pinned key and retries when the peer reinstalled.
    let (mut alice, bob) = pair();
    let mut rng = rand::rng();
    block_on(alice.process_bundle("bob", 1, &bob.bundle_payload().unwrap(), &mut rng)).unwrap();
    let new_bob = ZaloSignalStore::generate(&mut rng).unwrap();
    block_on(alice.process_bundle("bob", 1, &new_bob.bundle_payload().unwrap(), &mut rng)).unwrap();
    let mut new_bob = new_bob;
    let c = block_on(alice.encrypt_cipher("bob", 1, b"to the new device")).unwrap();
    let plain = block_on(new_bob.decrypt_cipher("alice", 2, &c.cipher, &mut rng)).unwrap();
    assert_eq!(plain, b"to the new device");
    // The old session is archived, not lost.
    let js = JsStore::parse(&alice.to_js_json(now_ms() as i64).unwrap()).unwrap();
    let rec = olaz_signal::JsSessionRecord::parse(&js.sessions["bob_1.1"]).unwrap();
    assert_eq!(rec.sessions.len(), 2);
    assert_eq!(rec.sessions.iter().filter(|s| s.closed == -1).count(), 1);
}

#[test]
fn a_session_is_not_usable_before_it_exists() {
    let (alice, _) = pair();
    assert!(!block_on(alice.has_session("nobody", 1)));
    let mut alice = alice;
    assert!(block_on(alice.encrypt_cipher("nobody", 1, b"x")).is_err());
}
