#![allow(clippy::unwrap_used, clippy::expect_used)]
//! Direction 3: record round trips, no JS process needed.
//!
//! * JS -> Rust -> JS over every session record in the JS-written fixtures (semantic identity:
//!   only the synthesised timestamps may differ).
//! * Rust -> JS -> Rust over records produced by Rust itself.

mod common;

use futures_executor::block_on;
use olaz_signal::{
    ImportContext, JsSessionRecord, JsStore, SessionMeta, ZaloSignalStore, js_to_session,
    session_to_js,
};

use common::{now_ms, scenario};

/// Everything except the `added` clock of closed chains, order-insensitive.
fn normalized(rec: &JsSessionRecord) -> JsSessionRecord {
    let mut r = rec.clone();
    r.sessions.sort_by(|a, b| a.base_key.cmp(&b.base_key));
    for s in &mut r.sessions {
        s.chains.sort_by(|a, b| a.ratchet_key.cmp(&b.ratchet_key));
        let live: Vec<_> = s.chains.iter().map(|c| c.ratchet_key.clone()).collect();
        // JS keeps stale entries for chains it already deleted; those carry no information.
        s.old_ratchet.retain(|(_, k)| live.contains(k));
        for e in &mut s.old_ratchet {
            e.0 = 0;
        }
        s.old_ratchet.sort();
    }
    r
}

#[test]
fn js_written_records_survive_js_to_rust_to_js() {
    let sc = scenario();
    let mut sessions_checked = 0;
    let mut with_skipped_keys = 0;
    let mut with_archived = 0;
    let mut closed_chains = 0;
    for snap in sc["snapshots"].as_array().unwrap() {
        for who in ["alice", "bob"] {
            let store = JsStore::parse(snap[who].as_str().unwrap()).unwrap();
            let pair_pub = store.identity.pub_key.clone();
            let identity = libsignal_protocol_identity(&pair_pub);
            for (addr, text) in &store.sessions {
                let js = JsSessionRecord::parse(text).unwrap();
                let ctx = ImportContext {
                    local_identity: &identity,
                    local_registration_id: store.registration_id,
                    now_secs: 1,
                };
                let imported = js_to_session(&js, &ctx).unwrap();
                let exported = session_to_js(&imported.record, &imported.meta, 1_000).unwrap();
                assert_eq!(exported.dropped_message_keys, 0);
                assert_eq!(
                    normalized(&exported.record),
                    normalized(&js),
                    "{who} {addr}"
                );
                sessions_checked += 1;
                with_archived += usize::from(js.sessions.iter().any(|s| s.closed != -1));
                for s in &js.sessions {
                    with_skipped_keys +=
                        usize::from(s.chains.iter().any(|c| !c.message_keys.is_empty()));
                    closed_chains += s
                        .chains
                        .iter()
                        .filter(|c| c.chain_type == 2 && c.key.is_none())
                        .count();
                }
            }
        }
    }
    // The scenario must actually exercise the interesting shapes.
    assert!(sessions_checked >= 20, "{sessions_checked}");
    assert!(
        with_skipped_keys > 0,
        "no fixture session holds skipped message keys"
    );
    assert!(
        closed_chains > 0,
        "no fixture session has a closed receiver chain"
    );
    let _ = with_archived; // the scenario never archives a session (no session reset)
}

fn libsignal_protocol_identity(pub_key: &[u8]) -> libsignal_protocol::IdentityKey {
    libsignal_protocol::IdentityKey::decode(pub_key).unwrap()
}

#[test]
fn whole_store_json_round_trips_through_rust() {
    let sc = scenario();
    for snap in sc["snapshots"].as_array().unwrap() {
        for who in ["alice", "bob"] {
            let original = JsStore::parse(snap[who].as_str().unwrap()).unwrap();
            let rust =
                ZaloSignalStore::from_js_json(snap[who].as_str().unwrap(), now_ms()).unwrap();
            let again = JsStore::parse(&rust.to_js_json(now_ms() as i64).unwrap()).unwrap();
            // Key material is byte-identical.
            assert_eq!(again.identity, original.identity);
            assert_eq!(again.registration_id, original.registration_id);
            assert_eq!(again.next_pre_key_id, original.next_pre_key_id);
            assert_eq!(again.signed_pre_key_id, original.signed_pre_key_id);
            assert_eq!(again.pre_keys, original.pre_keys);
            assert_eq!(again.signed_pre_keys, original.signed_pre_keys);
            assert_eq!(again.trusted, original.trusted);
            assert_eq!(
                again.sessions.keys().collect::<Vec<_>>(),
                original.sessions.keys().collect::<Vec<_>>()
            );
        }
    }
}

/// Drives a two-party Rust conversation that produces skipped keys and several ratchet turns,
/// then checks Rust -> JS -> Rust gives back byte-identical libsignal records.
#[test]
fn rust_written_records_survive_rust_to_js_to_rust() {
    let mut rng = rand::rng();
    let mut bob = ZaloSignalStore::generate(&mut rng).unwrap();
    let mut alice = ZaloSignalStore::generate(&mut rng).unwrap();
    let bundle = bob.bundle_payload().unwrap();
    block_on(alice.process_bundle("bob", 1, &bundle, &mut rng)).unwrap();

    let enc = |s: &mut ZaloSignalStore, to: &str, dev: u32, t: &str| {
        block_on(s.encrypt_cipher(to, dev, t.as_bytes()))
            .unwrap()
            .cipher
    };
    let dec = |s: &mut ZaloSignalStore, from: &str, dev: u32, c: &str| {
        let mut rng = rand::rng();
        String::from_utf8(block_on(s.decrypt_cipher(from, dev, c, &mut rng)).unwrap()).unwrap()
    };

    let a: Vec<_> = (1..=3)
        .map(|i| enc(&mut alice, "bob", 1, &format!("a{i}")))
        .collect();
    assert_eq!(dec(&mut bob, "alice", 2, &a[2]), "a3"); // skips 0 and 1
    let b: Vec<_> = (1..=3)
        .map(|i| enc(&mut bob, "alice", 2, &format!("b{i}")))
        .collect();
    assert_eq!(dec(&mut alice, "bob", 1, &b[1]), "b2"); // alice now holds skipped b1
    let c: Vec<_> = (1..=2)
        .map(|i| enc(&mut alice, "bob", 1, &format!("c{i}")))
        .collect();
    assert_eq!(dec(&mut bob, "alice", 2, &c[1]), "c2");
    let d = enc(&mut bob, "alice", 2, "d1");
    assert_eq!(dec(&mut alice, "bob", 1, &d), "d1");

    let now = now_ms() as i64;
    let mut converted = Vec::new();
    for (name, store) in [("alice", &alice), ("bob", &bob)] {
        let json = store.to_js_json(now).unwrap();
        let back = ZaloSignalStore::from_js_json(&json, now_ms()).unwrap();
        let again = back.to_js_json(now).unwrap();
        // Rust -> JS -> Rust -> JS is stable ...
        assert_eq!(
            JsStore::parse(&again).unwrap().sessions,
            JsStore::parse(&json).unwrap().sessions,
            "{name}"
        );
        // ... and a fixed point in libsignal form. The first hop may drop libsignal's unused
        // initial receiver chain (JS has no equivalent), so byte equality starts at the second.
        let back2 = ZaloSignalStore::from_js_json(&again, now_ms()).unwrap();
        for (addr, (rec, _)) in &back.sessions.sessions {
            let (rec2, _) = &back2.sessions.sessions[addr];
            assert_eq!(
                rec.serialize().unwrap(),
                rec2.serialize().unwrap(),
                "{name} {addr}"
            );
        }
        converted.push(back);
    }
    // The converted stores are functionally the same sessions: they keep talking to each other
    // and still hold the skipped keys (b1 for alice, a1/a2/c1 for bob).
    let [mut alice2, mut bob2]: [ZaloSignalStore; 2] = converted.try_into().ok().unwrap();
    assert_eq!(dec(&mut alice2, "bob", 1, &b[0]), "b1");
    assert_eq!(dec(&mut bob2, "alice", 2, &a[0]), "a1");
    assert_eq!(dec(&mut bob2, "alice", 2, &a[1]), "a2");
    assert_eq!(dec(&mut bob2, "alice", 2, &c[0]), "c1");
    let e = enc(&mut alice2, "bob", 1, "e1 from converted alice");
    assert_eq!(dec(&mut bob2, "alice", 2, &e), "e1 from converted alice");
    let f = enc(&mut bob2, "alice", 2, "f1 from converted bob");
    assert_eq!(dec(&mut alice2, "bob", 1, &f), "f1 from converted bob");
    // The state really holds skipped keys, so the equality above is not vacuous.
    let json = alice.to_js_json(now).unwrap();
    let store = JsStore::parse(&json).unwrap();
    let rec = JsSessionRecord::parse(store.sessions.values().next().unwrap()).unwrap();
    assert!(
        rec.sessions[0]
            .chains
            .iter()
            .any(|c| !c.message_keys.is_empty())
    );
    let _ = SessionMeta::default();
}
