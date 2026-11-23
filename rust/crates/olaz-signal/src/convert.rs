//! Field-by-field conversion between the JS session structure and libsignal's `SessionRecord`.
//!
//! Index conventions (the one subtle point): JS `chainKey.counter` is the index of the *last*
//! message key derived and `chainKey.key` is the chain key *after* that derivation (so a fresh
//! chain is `counter = -1`). libsignal's `ChainKey { index, key }` is the chain key that will
//! derive message `index` next. Hence `index = counter + 1`.
//!
//! What JS has and libsignal lacks (re-created by the sidecar [`SessionMeta`] or synthesised):
//! `baseKeyType` (we initiated or they did), `closed` archive time, `oldRatchetList[].added`.
//! What libsignal has and JS lacks (derived on import): `local_identity_public`,
//! `local_registration_id` (taken from the store), pending prekey timestamp (set to import time).

use std::collections::{BTreeMap, BTreeSet};

use libsignal_protocol::{IdentityKey, SessionRecord};
use prost::Message;

use crate::error::{Result, format_err};
use crate::js::{
    BASE_KEY_OURS, BASE_KEY_THEIRS, CHAIN_RECEIVING, CHAIN_SENDING, JsChain, JsKeyPair,
    JsPendingPreKey, JsSession, JsSessionRecord,
};
use crate::pb;

const SESSION_VERSION: u32 = 3;

/// JS-only bookkeeping that libsignal does not model, kept next to the record.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct SessionMeta {
    /// Base keys of sessions *we* initiated (JS `baseKeyType == OURS`).
    pub ours: BTreeSet<Vec<u8>>,
    /// Archive time (ms) per base key, for sessions JS had closed.
    pub closed: BTreeMap<Vec<u8>, i64>,
    /// JS `lastRemoteEphemeralKey` per base key. libsignal derives it from the newest receiver
    /// chain, which does not exist yet for a JS Alice that has not heard back (JS points it at the
    /// peer's signed prekey).
    pub last_remote: BTreeMap<Vec<u8>, Vec<u8>>,
}

pub struct ImportContext<'a> {
    pub local_identity: &'a IdentityKey,
    pub local_registration_id: u32,
    /// Seconds; stamps the pending-prekey age clock (libsignal expires unacked sessions).
    pub now_secs: u64,
}

pub struct ImportReport {
    pub record: SessionRecord,
    pub meta: SessionMeta,
}

/// JS record -> libsignal record (open session = current, closed ones = previous, newest first).
pub fn js_to_session(js: &JsSessionRecord, ctx: &ImportContext<'_>) -> Result<ImportReport> {
    let mut open: Option<&JsSession> = None;
    let mut archived: Vec<&JsSession> = Vec::new();
    for s in &js.sessions {
        if s.closed == -1 {
            if open.is_some() {
                return format_err("more than one open session");
            }
            open = Some(s);
        } else {
            archived.push(s);
        }
    }
    archived.sort_by_key(|s| std::cmp::Reverse(s.closed));

    let mut meta = SessionMeta::default();
    for s in &js.sessions {
        if s.base_key_type == BASE_KEY_OURS {
            meta.ours.insert(s.base_key.clone());
        }
        if s.closed != -1 {
            meta.closed.insert(s.base_key.clone(), s.closed);
        }
        meta.last_remote
            .insert(s.base_key.clone(), s.last_remote_ephemeral.clone());
    }

    let record = pb::RecordStructure {
        current_session: match open {
            Some(s) => Some(session_to_pb(s, ctx)?),
            None => None,
        },
        previous_sessions: archived
            .iter()
            .map(|s| session_to_pb(s, ctx).map(|p| p.encode_to_vec()))
            .collect::<Result<_>>()?,
    };
    Ok(ImportReport {
        record: SessionRecord::deserialize(&record.encode_to_vec())?,
        meta,
    })
}

fn session_to_pb(s: &JsSession, ctx: &ImportContext<'_>) -> Result<pb::SessionStructure> {
    let counter_to_index = |c: i64| -> Result<u32> {
        match u32::try_from(c + 1) {
            Ok(i) => Ok(i),
            Err(_) => format_err(format!("chain counter {c} out of range")),
        }
    };

    let sender = s
        .chains
        .iter()
        .find(|c| c.chain_type == CHAIN_SENDING && c.ratchet_key == s.ephemeral.pub_key);
    let sender_chain = pb::Chain {
        sender_ratchet_key: s.ephemeral.pub_key.clone(),
        sender_ratchet_key_private: s.ephemeral.priv_key.clone(),
        // A JS Bob that has not yet received anything has no sending chain; libsignal then has
        // no chain key either and refuses to encrypt, exactly like JS.
        chain_key: match sender.and_then(|c| c.key.as_ref().map(|k| (c, k))) {
            Some((c, k)) => Some(pb::ChainKey {
                index: counter_to_index(c.counter)?,
                key: k.clone(),
            }),
            None => None,
        },
        message_keys: Vec::new(),
    };

    // libsignal keeps receiver chains oldest first and trims from the front: closed JS chains in
    // the order they were closed, the current one (`lastRemoteEphemeralKey`) last.
    let mut receivers: Vec<&JsChain> = s
        .chains
        .iter()
        .filter(|c| c.chain_type == CHAIN_RECEIVING)
        .collect();
    let rank = |c: &JsChain| -> (bool, i64) {
        if c.ratchet_key == s.last_remote_ephemeral {
            return (true, 0);
        }
        let added = s
            .old_ratchet
            .iter()
            .filter(|(_, k)| *k == c.ratchet_key)
            .map(|(a, _)| *a)
            .max()
            .unwrap_or(i64::MIN);
        (false, added)
    };
    receivers.sort_by_key(|c| rank(c));

    let mut receiver_chains = Vec::new();
    for c in receivers {
        receiver_chains.push(pb::Chain {
            sender_ratchet_key: c.ratchet_key.clone(),
            sender_ratchet_key_private: Vec::new(),
            // A closed JS chain lost its key. Keep its skipped message keys, but any message
            // beyond them fails the MAC (as it fails in JS: "chain already closed").
            chain_key: Some(pb::ChainKey {
                index: counter_to_index(c.counter)?,
                key: c.key.clone().unwrap_or_else(|| vec![0; 32]),
            }),
            message_keys: c
                .message_keys
                .iter()
                .map(|(i, seed)| pb::MessageKey {
                    index: *i,
                    seed: seed.clone(),
                    ..Default::default()
                })
                .collect(),
        });
    }

    Ok(pb::SessionStructure {
        session_version: SESSION_VERSION,
        local_identity_public: ctx.local_identity.serialize().into_vec(),
        remote_identity_public: s.remote_identity.clone(),
        root_key: s.root_key.clone(),
        previous_counter: s.previous_counter,
        sender_chain: Some(sender_chain),
        receiver_chains,
        pending_pre_key: s.pending.as_ref().map(|p| pb::PendingPreKey {
            pre_key_id: p.pre_key_id,
            signed_pre_key_id: i32::try_from(p.signed_key_id).unwrap_or(i32::MAX),
            base_key: p.base_key.clone(),
            timestamp: ctx.now_secs,
        }),
        remote_registration_id: s.registration_id.unwrap_or(0),
        local_registration_id: ctx.local_registration_id,
        alice_base_key: s.base_key.clone(),
    })
}

pub struct ExportReport {
    pub record: JsSessionRecord,
    /// Skipped message keys libsignal holds in expanded form (no seed). JS cannot represent
    /// those, so they are dropped. libsignal 0.73 stores skipped keys as seeds, so this is
    /// expected to stay 0.
    pub dropped_message_keys: usize,
}

/// libsignal record -> JS record.
pub fn session_to_js(
    record: &SessionRecord,
    meta: &SessionMeta,
    now_ms: i64,
) -> Result<ExportReport> {
    let decoded = pb::RecordStructure::decode(record.serialize()?.as_slice())?;
    let mut dropped = 0usize;
    let mut sessions = Vec::new();
    if let Some(cur) = &decoded.current_session {
        sessions.push(pb_to_session(cur, meta, -1, now_ms, &mut dropped));
    }
    for (i, prev) in decoded.previous_sessions.iter().enumerate() {
        let p = pb::SessionStructure::decode(prev.as_slice())?;
        // Newest first in libsignal; keep that order observable through `closed`.
        let fallback = now_ms - 1 - i64::try_from(i).unwrap_or(0);
        sessions.push(pb_to_session(&p, meta, fallback, now_ms, &mut dropped));
    }
    Ok(ExportReport {
        record: JsSessionRecord { sessions },
        dropped_message_keys: dropped,
    })
}

fn pb_to_session(
    s: &pb::SessionStructure,
    meta: &SessionMeta,
    closed_fallback: i64,
    now_ms: i64,
    dropped: &mut usize,
) -> JsSession {
    let mut chains = Vec::new();

    // JS keeps a sending chain for the current ephemeral. A libsignal Bob that never received
    // anything has index 0 and no receiver chains; JS represents that with no sending chain.
    let (eph_pub, eph_priv, sender_chain_key) = match &s.sender_chain {
        Some(c) => (
            c.sender_ratchet_key.clone(),
            c.sender_ratchet_key_private.clone(),
            c.chain_key.clone(),
        ),
        None => (Vec::new(), Vec::new(), None),
    };
    let ours = meta.ours.contains(&s.alice_base_key);
    if let Some(ck) = &sender_chain_key
        && !(!ours && s.receiver_chains.is_empty() && ck.index == 0)
    {
        chains.push(JsChain {
            ratchet_key: eph_pub.clone(),
            chain_type: CHAIN_SENDING,
            counter: i64::from(ck.index) - 1,
            key: Some(ck.key.clone()),
            message_keys: BTreeMap::new(),
        });
    }

    let mut old_ratchet = Vec::new();
    let n = s.receiver_chains.len();
    for (i, r) in s.receiver_chains.iter().enumerate() {
        let Some(ck) = &r.chain_key else { continue };
        let mut message_keys = BTreeMap::new();
        for mk in &r.message_keys {
            if mk.seed.is_empty() {
                *dropped += 1;
            } else {
                message_keys.insert(mk.index, mk.seed.clone());
            }
        }
        // libsignal Alice starts with an unused receiver chain (index 0, no skipped keys) for the
        // peer's signed prekey; JS has no such chain, only `lastRemoteEphemeralKey`.
        let vestigial = ck.index == 0 && message_keys.is_empty();
        if vestigial {
            continue;
        }
        chains.push(JsChain {
            ratchet_key: r.sender_ratchet_key.clone(),
            chain_type: CHAIN_RECEIVING,
            counter: i64::from(ck.index) - 1,
            // The all-zero key is our stand-in for a chain JS closed (see `session_to_pb`).
            key: if ck.key.iter().all(|b| *b == 0) {
                None
            } else {
                Some(ck.key.clone())
            },
            message_keys,
        });
        // Every chain but the newest (last) is a closed one in JS terms, oldest first.
        if i + 1 < n {
            let age = i64::try_from(n - 1 - i).unwrap_or(0);
            old_ratchet.push((now_ms - age, r.sender_ratchet_key.clone()));
        }
    }

    let last_remote = match (
        s.receiver_chains.last(),
        meta.last_remote.get(&s.alice_base_key),
    ) {
        (Some(c), _) => c.sender_ratchet_key.clone(),
        (None, Some(k)) => k.clone(),
        (None, None) => s.alice_base_key.clone(),
    };
    let closed = if closed_fallback == -1 {
        -1
    } else {
        meta.closed
            .get(&s.alice_base_key)
            .copied()
            .unwrap_or(closed_fallback)
    };

    JsSession {
        registration_id: Some(s.remote_registration_id),
        root_key: s.root_key.clone(),
        ephemeral: JsKeyPair {
            pub_key: eph_pub,
            priv_key: eph_priv,
        },
        last_remote_ephemeral: last_remote,
        previous_counter: s.previous_counter,
        remote_identity: s.remote_identity_public.clone(),
        closed,
        base_key: s.alice_base_key.clone(),
        base_key_type: if ours { BASE_KEY_OURS } else { BASE_KEY_THEIRS },
        old_ratchet,
        pending: s.pending_pre_key.as_ref().map(|p| JsPendingPreKey {
            signed_key_id: u32::try_from(p.signed_pre_key_id).unwrap_or(0),
            base_key: p.base_key.clone(),
            pre_key_id: p.pre_key_id,
        }),
        chains,
    }
}
