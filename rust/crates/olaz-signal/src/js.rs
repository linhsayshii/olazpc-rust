//! The JSON the JavaScript side writes: the `zaloE2EEPCStoreV1` preference (whole store) and the
//! per-peer session record strings inside it (`SessionRecord.serialize()` of the vendored
//! `libsignal-protocol.js`).
//!
//! JS keeps keys and chain ids as *binary strings* (one char per byte, code points 0..=255) inside
//! JSON; the store wrapper (`zalo-e2ee.js`) uses base64 for identity/prekey material.

use std::collections::BTreeMap;

use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use serde_json::{Map, Value, json};

use crate::error::{Result, format_err};

pub const CHAIN_SENDING: u8 = 1;
pub const CHAIN_RECEIVING: u8 = 2;
pub const BASE_KEY_OURS: u8 = 1;
pub const BASE_KEY_THEIRS: u8 = 2;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct JsKeyPair {
    pub pub_key: Vec<u8>,
    pub priv_key: Vec<u8>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct JsSignedPreKey {
    pub key_pair: JsKeyPair,
    /// Empty when the JS store never recorded one.
    pub signature: Vec<u8>,
}

/// The whole persisted store.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct JsStore {
    pub registration_id: u32,
    pub next_pre_key_id: u32,
    pub signed_pre_key_id: u32,
    pub identity: JsKeyPair,
    pub pre_keys: BTreeMap<u32, JsKeyPair>,
    pub signed_pre_keys: BTreeMap<u32, JsSignedPreKey>,
    /// `SignalProtocolAddress.toString()` (`name.deviceId`) -> raw JS session record JSON.
    pub sessions: BTreeMap<String, String>,
    /// Trusted identity key per address *name* (no device id).
    pub trusted: BTreeMap<String, Vec<u8>>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct JsChain {
    pub ratchet_key: Vec<u8>,
    pub chain_type: u8,
    /// Index of the last message key derived from this chain; `-1` before the first.
    pub counter: i64,
    /// `None` once JS closed the chain after a DH ratchet step.
    pub key: Option<Vec<u8>>,
    /// Skipped message keys: index -> 32-byte seed (HKDF input, not the expanded keys).
    pub message_keys: BTreeMap<u32, Vec<u8>>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct JsPendingPreKey {
    pub signed_key_id: u32,
    pub base_key: Vec<u8>,
    pub pre_key_id: Option<u32>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct JsSession {
    pub registration_id: Option<u32>,
    pub root_key: Vec<u8>,
    pub ephemeral: JsKeyPair,
    pub last_remote_ephemeral: Vec<u8>,
    pub previous_counter: u32,
    pub remote_identity: Vec<u8>,
    /// `-1` for the open session, else the archive time in ms.
    pub closed: i64,
    pub base_key: Vec<u8>,
    pub base_key_type: u8,
    /// `(added ms, ephemeral key)` of receiver chains JS closed.
    pub old_ratchet: Vec<(i64, Vec<u8>)>,
    pub pending: Option<JsPendingPreKey>,
    pub chains: Vec<JsChain>,
}

#[derive(Clone, Debug, PartialEq, Eq, Default)]
pub struct JsSessionRecord {
    pub sessions: Vec<JsSession>,
}

// MARK: binary strings

/// JS binary string -> bytes. Every char must be <= U+00FF.
pub fn bin(s: &str) -> Result<Vec<u8>> {
    s.chars()
        .map(|c| match u8::try_from(u32::from(c)) {
            Ok(b) => Ok(b),
            Err(_) => format_err("binary string has a char above U+00FF"),
        })
        .collect()
}

pub fn to_bin(bytes: &[u8]) -> String {
    bytes.iter().map(|&b| char::from(b)).collect()
}

// MARK: store

fn obj<'a>(v: &'a Value, what: &str) -> Result<&'a Map<String, Value>> {
    match v.as_object() {
        Some(m) => Ok(m),
        None => format_err(format!("{what} is not an object")),
    }
}

fn get_str<'a>(m: &'a Map<String, Value>, key: &str) -> Result<&'a str> {
    match m.get(key).and_then(Value::as_str) {
        Some(s) => Ok(s),
        None => format_err(format!("missing string `{key}`")),
    }
}

fn get_u32(m: &Map<String, Value>, key: &str) -> Result<u32> {
    match m.get(key).and_then(Value::as_u64).map(u32::try_from) {
        Some(Ok(n)) => Ok(n),
        _ => format_err(format!("missing u32 `{key}`")),
    }
}

fn b64(m: &Map<String, Value>, key: &str) -> Result<Vec<u8>> {
    Ok(STANDARD.decode(get_str(m, key)?)?)
}

fn key_pair(v: &Value, what: &str) -> Result<JsKeyPair> {
    let m = obj(v, what)?;
    Ok(JsKeyPair {
        pub_key: b64(m, "pubKey")?,
        priv_key: b64(m, "privKey")?,
    })
}

impl JsStore {
    pub fn parse(text: &str) -> Result<Self> {
        let v: Value = serde_json::from_str(text)?;
        let root = obj(&v, "store")?;
        let identity = match root.get("identity") {
            Some(i) => key_pair(i, "identity")?,
            None => return format_err("missing identity"),
        };
        let mut pre_keys = BTreeMap::new();
        if let Some(m) = root.get("preKeys").and_then(Value::as_object) {
            for (id, kp) in m {
                pre_keys.insert(parse_id(id)?, key_pair(kp, "preKey")?);
            }
        }
        let mut signed_pre_keys = BTreeMap::new();
        if let Some(m) = root.get("signedPreKeys").and_then(Value::as_object) {
            for (id, v) in m {
                let o = obj(v, "signedPreKey")?;
                let signature = match o.get("signature").and_then(Value::as_str) {
                    Some(s) if !s.is_empty() => STANDARD.decode(s)?,
                    _ => Vec::new(),
                };
                signed_pre_keys.insert(
                    parse_id(id)?,
                    JsSignedPreKey {
                        key_pair: key_pair(v, "signedPreKey")?,
                        signature,
                    },
                );
            }
        }
        let mut sessions = BTreeMap::new();
        if let Some(m) = root.get("sessions").and_then(Value::as_object) {
            for (addr, v) in m {
                match v.as_str() {
                    Some(s) => sessions.insert(addr.clone(), s.to_owned()),
                    None => return format_err("session value is not a string"),
                };
            }
        }
        let mut trusted = BTreeMap::new();
        if let Some(m) = root.get("trusted").and_then(Value::as_object) {
            for (name, v) in m {
                match v.as_str() {
                    Some(s) => trusted.insert(name.clone(), STANDARD.decode(s)?),
                    None => return format_err("trusted value is not a string"),
                };
            }
        }
        Ok(Self {
            registration_id: get_u32(root, "registrationId")?,
            next_pre_key_id: get_u32(root, "nextPreKeyId").unwrap_or(100),
            signed_pre_key_id: get_u32(root, "signedPreKeyId").unwrap_or(1),
            identity,
            pre_keys,
            signed_pre_keys,
            sessions,
            trusted,
        })
    }

    pub fn to_json(&self) -> String {
        let kp = |k: &JsKeyPair| json!({ "pubKey": STANDARD.encode(&k.pub_key), "privKey": STANDARD.encode(&k.priv_key) });
        let pre_keys: Map<String, Value> = self
            .pre_keys
            .iter()
            .map(|(id, k)| (id.to_string(), kp(k)))
            .collect();
        let signed: Map<String, Value> = self
            .signed_pre_keys
            .iter()
            .map(|(id, s)| {
                (
                    id.to_string(),
                    json!({
                        "pubKey": STANDARD.encode(&s.key_pair.pub_key),
                        "privKey": STANDARD.encode(&s.key_pair.priv_key),
                        "signature": STANDARD.encode(&s.signature),
                    }),
                )
            })
            .collect();
        let sessions: Map<String, Value> = self
            .sessions
            .iter()
            .map(|(a, s)| (a.clone(), Value::String(s.clone())))
            .collect();
        let trusted: Map<String, Value> = self
            .trusted
            .iter()
            .map(|(n, k)| (n.clone(), Value::String(STANDARD.encode(k))))
            .collect();
        json!({
            "version": 1,
            "registrationId": self.registration_id,
            "nextPreKeyId": self.next_pre_key_id,
            "signedPreKeyId": self.signed_pre_key_id,
            "identity": kp(&self.identity),
            "preKeys": pre_keys,
            "signedPreKeys": signed,
            "sessions": sessions,
            "trusted": trusted,
        })
        .to_string()
    }
}

fn parse_id(s: &str) -> Result<u32> {
    match s.parse::<u32>() {
        Ok(n) => Ok(n),
        Err(_) => format_err(format!("bad key id `{s}`")),
    }
}

// MARK: session records

const FIXED_FIELDS: [&str; 5] = [
    "registrationId",
    "currentRatchet",
    "indexInfo",
    "oldRatchetList",
    "pendingPreKey",
];

fn get_i64(m: &Map<String, Value>, key: &str) -> Result<i64> {
    let v = match m.get(key) {
        Some(v) => v,
        None => return format_err(format!("missing number `{key}`")),
    };
    if let Some(n) = v.as_i64() {
        return Ok(n);
    }
    match v.as_f64() {
        // JS numbers are doubles; whole values only.
        Some(f) if f.fract() == 0.0 && f.abs() < 9.0e15 => Ok(f as i64),
        _ => format_err(format!("bad number `{key}`")),
    }
}

fn bin_field(m: &Map<String, Value>, key: &str) -> Result<Vec<u8>> {
    bin(get_str(m, key)?)
}

impl JsSessionRecord {
    pub fn parse(text: &str) -> Result<Self> {
        let v: Value = serde_json::from_str(text)?;
        let root = obj(&v, "session record")?;
        let sessions = match root.get("sessions") {
            Some(s) => obj(s, "sessions")?,
            None => return format_err("record has no `sessions`"),
        };
        let mut out = Vec::new();
        for (base_key, s) in sessions {
            out.push(parse_session(base_key, s)?);
        }
        Ok(Self { sessions: out })
    }

    pub fn to_json(&self) -> String {
        let mut sessions = Map::new();
        for s in &self.sessions {
            sessions.insert(to_bin(&s.base_key), session_to_value(s));
        }
        json!({ "sessions": sessions, "version": "v1" }).to_string()
    }
}

fn parse_session(base_key_str: &str, v: &Value) -> Result<JsSession> {
    let s = obj(v, "session")?;
    let cr = match s.get("currentRatchet") {
        Some(c) => obj(c, "currentRatchet")?,
        None => return format_err("session has no currentRatchet"),
    };
    let eph = match cr.get("ephemeralKeyPair") {
        Some(e) => obj(e, "ephemeralKeyPair")?,
        None => return format_err("currentRatchet has no ephemeralKeyPair"),
    };
    let ii = match s.get("indexInfo") {
        Some(i) => obj(i, "indexInfo")?,
        None => return format_err("session has no indexInfo"),
    };
    let base_key = bin_field(ii, "baseKey")?;
    if bin(base_key_str)? != base_key {
        return format_err("session map key differs from indexInfo.baseKey");
    }

    let mut old_ratchet = Vec::new();
    if let Some(list) = s.get("oldRatchetList").and_then(Value::as_array) {
        for e in list {
            let o = obj(e, "oldRatchetList entry")?;
            old_ratchet.push((get_i64(o, "added")?, bin_field(o, "ephemeralKey")?));
        }
    }
    let pending = match s.get("pendingPreKey") {
        Some(Value::Object(p)) => Some(JsPendingPreKey {
            signed_key_id: get_u32(p, "signedKeyId")?,
            base_key: bin_field(p, "baseKey")?,
            pre_key_id: p
                .get("preKeyId")
                .and_then(Value::as_u64)
                .and_then(|n| u32::try_from(n).ok()),
        }),
        _ => None,
    };

    let mut chains = Vec::new();
    for (id, c) in s {
        if FIXED_FIELDS.contains(&id.as_str()) {
            continue;
        }
        let c = obj(c, "chain")?;
        let ck = match c.get("chainKey") {
            Some(k) => obj(k, "chainKey")?,
            None => return format_err("chain has no chainKey"),
        };
        let chain_type = match c.get("chainType").and_then(Value::as_u64) {
            Some(1) => CHAIN_SENDING,
            Some(2) => CHAIN_RECEIVING,
            _ => return format_err("bad chainType"),
        };
        let mut message_keys = BTreeMap::new();
        if let Some(mk) = c.get("messageKeys").and_then(Value::as_object) {
            for (idx, seed) in mk {
                let seed = match seed.as_str() {
                    Some(s) => bin(s)?,
                    None => return format_err("message key is not a string"),
                };
                message_keys.insert(parse_id(idx)?, seed);
            }
        }
        chains.push(JsChain {
            ratchet_key: bin(id)?,
            chain_type,
            counter: get_i64(ck, "counter")?,
            key: match ck.get("key").and_then(Value::as_str) {
                Some(k) => Some(bin(k)?),
                None => None,
            },
            message_keys,
        });
    }

    Ok(JsSession {
        registration_id: s
            .get("registrationId")
            .and_then(Value::as_u64)
            .and_then(|n| u32::try_from(n).ok()),
        root_key: bin_field(cr, "rootKey")?,
        ephemeral: JsKeyPair {
            pub_key: bin_field(eph, "pubKey")?,
            priv_key: bin_field(eph, "privKey")?,
        },
        last_remote_ephemeral: bin_field(cr, "lastRemoteEphemeralKey")?,
        previous_counter: get_u32(cr, "previousCounter").unwrap_or(0),
        remote_identity: bin_field(ii, "remoteIdentityKey")?,
        closed: get_i64(ii, "closed")?,
        base_key,
        base_key_type: match get_i64(ii, "baseKeyType")? {
            1 => BASE_KEY_OURS,
            _ => BASE_KEY_THEIRS,
        },
        old_ratchet,
        pending,
        chains,
    })
}

fn session_to_value(s: &JsSession) -> Value {
    let mut m = Map::new();
    if let Some(r) = s.registration_id {
        m.insert("registrationId".into(), json!(r));
    }
    m.insert(
        "currentRatchet".into(),
        json!({
            "rootKey": to_bin(&s.root_key),
            "lastRemoteEphemeralKey": to_bin(&s.last_remote_ephemeral),
            "previousCounter": s.previous_counter,
            "ephemeralKeyPair": {
                "pubKey": to_bin(&s.ephemeral.pub_key),
                "privKey": to_bin(&s.ephemeral.priv_key),
            },
        }),
    );
    m.insert(
        "indexInfo".into(),
        json!({
            "remoteIdentityKey": to_bin(&s.remote_identity),
            "closed": s.closed,
            "baseKey": to_bin(&s.base_key),
            "baseKeyType": s.base_key_type,
        }),
    );
    let old: Vec<Value> = s
        .old_ratchet
        .iter()
        .map(|(added, k)| json!({ "added": added, "ephemeralKey": to_bin(k) }))
        .collect();
    m.insert("oldRatchetList".into(), Value::Array(old));
    if let Some(p) = &s.pending {
        let mut pm = Map::new();
        pm.insert("signedKeyId".into(), json!(p.signed_key_id));
        pm.insert("baseKey".into(), Value::String(to_bin(&p.base_key)));
        if let Some(id) = p.pre_key_id {
            pm.insert("preKeyId".into(), json!(id));
        }
        m.insert("pendingPreKey".into(), Value::Object(pm));
    }
    for c in &s.chains {
        let mut ck = Map::new();
        ck.insert("counter".into(), json!(c.counter));
        if let Some(k) = &c.key {
            ck.insert("key".into(), Value::String(to_bin(k)));
        }
        let mk: Map<String, Value> = c
            .message_keys
            .iter()
            .map(|(i, seed)| (i.to_string(), Value::String(to_bin(seed))))
            .collect();
        m.insert(
            to_bin(&c.ratchet_key),
            json!({
                "messageKeys": mk,
                "chainKey": Value::Object(ck),
                "chainType": c.chain_type,
            }),
        );
    }
    Value::Object(m)
}

#[cfg(test)]
#[allow(clippy::unwrap_used)]
mod tests {
    use super::*;

    #[test]
    fn binary_strings_round_trip_every_byte() {
        let all: Vec<u8> = (0..=255).collect();
        assert_eq!(bin(&to_bin(&all)).unwrap(), all);
    }

    #[test]
    fn binary_string_above_latin1_is_rejected() {
        assert!(bin("a\u{0100}").is_err());
    }

    #[test]
    fn session_record_json_round_trips_through_the_typed_form() {
        let key = vec![5u8; 33];
        let rec = JsSessionRecord {
            sessions: vec![JsSession {
                registration_id: Some(7),
                root_key: vec![1; 32],
                ephemeral: JsKeyPair {
                    pub_key: key.clone(),
                    priv_key: vec![2; 32],
                },
                last_remote_ephemeral: vec![5, 9],
                previous_counter: 3,
                remote_identity: vec![5; 33],
                closed: -1,
                base_key: vec![5, 0xff, 0x80],
                base_key_type: BASE_KEY_THEIRS,
                old_ratchet: vec![(12, vec![5, 1])],
                pending: Some(JsPendingPreKey {
                    signed_key_id: 1,
                    base_key: vec![5, 3],
                    pre_key_id: None,
                }),
                chains: vec![JsChain {
                    ratchet_key: key,
                    chain_type: CHAIN_SENDING,
                    counter: -1,
                    key: Some(vec![9; 32]),
                    message_keys: BTreeMap::from([(4, vec![8; 32])]),
                }],
            }],
        };
        assert_eq!(JsSessionRecord::parse(&rec.to_json()).unwrap(), rec);
    }
}
