//! In-memory libsignal stores over the records the JS side persists.
//!
//! The five libsignal store traits are implemented by five small structs so that
//! `message_decrypt` can borrow them mutably and disjointly (it takes a `&mut dyn SessionStore`
//! and a `&mut dyn IdentityKeyStore` at once). [`ZaloSignalStore`] owns them and converts the whole
//! `zaloE2EEPCStoreV1` JSON in both directions.

use std::collections::BTreeMap;

use async_trait::async_trait;
use libsignal_protocol::{
    Direction, GenericSignedPreKey, IdentityChange, IdentityKey, IdentityKeyPair, IdentityKeyStore,
    KeyPair, KyberPreKeyId, KyberPreKeyRecord, KyberPreKeyStore, PreKeyId, PreKeyRecord,
    PreKeyStore, PrivateKey, ProtocolAddress, PublicKey, SessionRecord, SessionStore,
    SignalProtocolError, SignedPreKeyId, SignedPreKeyRecord, SignedPreKeyStore, Timestamp,
};

use crate::convert::{ImportContext, SessionMeta, js_to_session, session_to_js};
use crate::error::Result;
use crate::js::{JsKeyPair, JsSessionRecord, JsSignedPreKey, JsStore};

#[derive(Default)]
pub struct MemSessionStore {
    /// Keyed by `ProtocolAddress::to_string()` (`name.deviceId`), the key JS uses too.
    pub sessions: BTreeMap<String, (SessionRecord, SessionMeta)>,
}

#[async_trait(?Send)]
impl SessionStore for MemSessionStore {
    async fn load_session(
        &self,
        address: &ProtocolAddress,
    ) -> std::result::Result<Option<SessionRecord>, SignalProtocolError> {
        Ok(self
            .sessions
            .get(&address.to_string())
            .map(|(rec, _)| rec.clone()))
    }

    async fn store_session(
        &mut self,
        address: &ProtocolAddress,
        record: &SessionRecord,
    ) -> std::result::Result<(), SignalProtocolError> {
        let entry = self
            .sessions
            .entry(address.to_string())
            .or_insert_with(|| (SessionRecord::new_fresh(), SessionMeta::default()));
        entry.0 = record.clone();
        Ok(())
    }
}

pub struct MemIdentityStore {
    pub pair: IdentityKeyPair,
    pub registration_id: u32,
    /// Trust on first use, keyed by address *name* (JS: `identityKey<name>`).
    pub trusted: BTreeMap<String, IdentityKey>,
}

#[async_trait(?Send)]
impl IdentityKeyStore for MemIdentityStore {
    async fn get_identity_key_pair(
        &self,
    ) -> std::result::Result<IdentityKeyPair, SignalProtocolError> {
        Ok(self.pair)
    }

    async fn get_local_registration_id(&self) -> std::result::Result<u32, SignalProtocolError> {
        Ok(self.registration_id)
    }

    async fn save_identity(
        &mut self,
        address: &ProtocolAddress,
        identity: &IdentityKey,
    ) -> std::result::Result<IdentityChange, SignalProtocolError> {
        let previous = self.trusted.insert(address.name().to_owned(), *identity);
        Ok(match previous {
            Some(old) if old != *identity => IdentityChange::ReplacedExisting,
            _ => IdentityChange::NewOrUnchanged,
        })
    }

    async fn is_trusted_identity(
        &self,
        address: &ProtocolAddress,
        identity: &IdentityKey,
        _direction: Direction,
    ) -> std::result::Result<bool, SignalProtocolError> {
        Ok(match self.trusted.get(address.name()) {
            None => true,
            Some(known) => known == identity,
        })
    }

    async fn get_identity(
        &self,
        address: &ProtocolAddress,
    ) -> std::result::Result<Option<IdentityKey>, SignalProtocolError> {
        Ok(self.trusted.get(address.name()).copied())
    }
}

#[derive(Default)]
pub struct MemPreKeyStore {
    pub keys: BTreeMap<u32, PreKeyRecord>,
}

#[async_trait(?Send)]
impl PreKeyStore for MemPreKeyStore {
    async fn get_pre_key(
        &self,
        id: PreKeyId,
    ) -> std::result::Result<PreKeyRecord, SignalProtocolError> {
        self.keys
            .get(&u32::from(id))
            .cloned()
            .ok_or(SignalProtocolError::InvalidPreKeyId)
    }

    async fn save_pre_key(
        &mut self,
        id: PreKeyId,
        record: &PreKeyRecord,
    ) -> std::result::Result<(), SignalProtocolError> {
        self.keys.insert(u32::from(id), record.clone());
        Ok(())
    }

    async fn remove_pre_key(
        &mut self,
        id: PreKeyId,
    ) -> std::result::Result<(), SignalProtocolError> {
        self.keys.remove(&u32::from(id));
        Ok(())
    }
}

#[derive(Default)]
pub struct MemSignedPreKeyStore {
    pub keys: BTreeMap<u32, SignedPreKeyRecord>,
}

#[async_trait(?Send)]
impl SignedPreKeyStore for MemSignedPreKeyStore {
    async fn get_signed_pre_key(
        &self,
        id: SignedPreKeyId,
    ) -> std::result::Result<SignedPreKeyRecord, SignalProtocolError> {
        self.keys
            .get(&u32::from(id))
            .cloned()
            .ok_or(SignalProtocolError::InvalidSignedPreKeyId)
    }

    async fn save_signed_pre_key(
        &mut self,
        id: SignedPreKeyId,
        record: &SignedPreKeyRecord,
    ) -> std::result::Result<(), SignalProtocolError> {
        self.keys.insert(u32::from(id), record.clone());
        Ok(())
    }
}

/// Zalo's E2EE is plain X3DH (protocol v3); there are no Kyber prekeys.
#[derive(Default)]
pub struct NoKyberStore;

#[async_trait(?Send)]
impl KyberPreKeyStore for NoKyberStore {
    async fn get_kyber_pre_key(
        &self,
        _id: KyberPreKeyId,
    ) -> std::result::Result<KyberPreKeyRecord, SignalProtocolError> {
        Err(SignalProtocolError::InvalidKyberPreKeyId)
    }

    async fn save_kyber_pre_key(
        &mut self,
        _id: KyberPreKeyId,
        _record: &KyberPreKeyRecord,
    ) -> std::result::Result<(), SignalProtocolError> {
        Ok(())
    }

    async fn mark_kyber_pre_key_used(
        &mut self,
        _id: KyberPreKeyId,
    ) -> std::result::Result<(), SignalProtocolError> {
        Ok(())
    }
}

/// All stores plus the counters the JS wrapper persists next to them.
pub struct ZaloSignalStore {
    pub sessions: MemSessionStore,
    pub identity: MemIdentityStore,
    pub pre_keys: MemPreKeyStore,
    pub signed_pre_keys: MemSignedPreKeyStore,
    pub kyber: NoKyberStore,
    pub next_pre_key_id: u32,
    pub signed_pre_key_id: u32,
}

fn to_key_pair(k: &JsKeyPair) -> Result<KeyPair> {
    Ok(KeyPair::new(
        PublicKey::deserialize(&k.pub_key)?,
        PrivateKey::deserialize(&k.priv_key)?,
    ))
}

fn from_key_pair(k: &KeyPair) -> JsKeyPair {
    JsKeyPair {
        pub_key: k.public_key.serialize().into_vec(),
        priv_key: k.private_key.serialize(),
    }
}

impl ZaloSignalStore {
    /// Loads the JSON the JS side persisted (`zaloE2EEPCStoreV1`). `now_ms` stamps what JS never
    /// recorded (signed prekey timestamp, pending-prekey age).
    pub fn from_js_json(text: &str, now_ms: u64) -> Result<Self> {
        let js = JsStore::parse(text)?;
        let pair = IdentityKeyPair::new(
            IdentityKey::decode(&js.identity.pub_key)?,
            PrivateKey::deserialize(&js.identity.priv_key)?,
        );
        let mut trusted = BTreeMap::new();
        for (name, key) in &js.trusted {
            trusted.insert(name.clone(), IdentityKey::decode(key)?);
        }
        let mut pre_keys = MemPreKeyStore::default();
        for (id, kp) in &js.pre_keys {
            pre_keys.keys.insert(
                *id,
                PreKeyRecord::new(PreKeyId::from(*id), &to_key_pair(kp)?),
            );
        }
        let mut signed_pre_keys = MemSignedPreKeyStore::default();
        for (id, spk) in &js.signed_pre_keys {
            signed_pre_keys.keys.insert(
                *id,
                SignedPreKeyRecord::new(
                    SignedPreKeyId::from(*id),
                    Timestamp::from_epoch_millis(now_ms),
                    &to_key_pair(&spk.key_pair)?,
                    &spk.signature,
                ),
            );
        }

        let ctx = ImportContext {
            local_identity: pair.identity_key(),
            local_registration_id: js.registration_id,
            now_secs: now_ms / 1000,
        };
        let mut sessions = MemSessionStore::default();
        for (addr, text) in &js.sessions {
            let rec = JsSessionRecord::parse(text)?;
            let report = js_to_session(&rec, &ctx)?;
            sessions
                .sessions
                .insert(addr.clone(), (report.record, report.meta));
        }

        Ok(Self {
            sessions,
            identity: MemIdentityStore {
                pair,
                registration_id: js.registration_id,
                trusted,
            },
            pre_keys,
            signed_pre_keys,
            kyber: NoKyberStore,
            next_pre_key_id: js.next_pre_key_id,
            signed_pre_key_id: js.signed_pre_key_id,
        })
    }

    /// Writes the store back in the exact shape `ZaloE2EE.pc.initOrRestore` reads.
    pub fn to_js_json(&self, now_ms: i64) -> Result<String> {
        let mut pre_keys = BTreeMap::new();
        for (id, rec) in &self.pre_keys.keys {
            pre_keys.insert(*id, from_key_pair(&rec.key_pair()?));
        }
        let mut signed_pre_keys = BTreeMap::new();
        for (id, rec) in &self.signed_pre_keys.keys {
            signed_pre_keys.insert(
                *id,
                JsSignedPreKey {
                    key_pair: from_key_pair(&rec.key_pair()?),
                    signature: rec.signature()?,
                },
            );
        }
        let mut sessions = BTreeMap::new();
        for (addr, (rec, meta)) in &self.sessions.sessions {
            let exported = session_to_js(rec, meta, now_ms)?;
            // JS `hasOpenSession` on a record with no sessions is false, same as no record.
            if !exported.record.sessions.is_empty() {
                sessions.insert(addr.clone(), exported.record.to_json());
            }
        }
        let trusted = self
            .identity
            .trusted
            .iter()
            .map(|(n, k)| (n.clone(), k.serialize().into_vec()))
            .collect();
        Ok(JsStore {
            registration_id: self.identity.registration_id,
            next_pre_key_id: self.next_pre_key_id,
            signed_pre_key_id: self.signed_pre_key_id,
            identity: JsKeyPair {
                pub_key: self.identity.pair.public_key().serialize().into_vec(),
                priv_key: self.identity.pair.private_key().serialize(),
            },
            pre_keys,
            signed_pre_keys,
            sessions,
            trusted,
        }
        .to_json())
    }
}
