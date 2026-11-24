//! The operations `ZaloE2EE.pc.*` exposes (`zalo-e2ee.js`), over [`ZaloSignalStore`].
//!
//! Wire framing of one Zalo cipher (`decryptCipher` / `encryptCipher` in the glue): base64 of
//! `[type: u8][libsignal message bytes]` where `type` is 3 for a PreKeyWhisperMessage and 1 for a
//! WhisperMessage, and the message bytes are the usual `version byte (0x33) | protobuf` (plus an
//! 8-byte MAC for a WhisperMessage; a PreKeyWhisperMessage embeds a full WhisperMessage).

use std::collections::BTreeMap;
use std::time::SystemTime;

use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use libsignal_protocol::{
    CiphertextMessage, DeviceId, GenericSignedPreKey, IdentityKey, IdentityKeyPair, KeyPair,
    PreKeyBundle, PreKeyId, PreKeyRecord, PreKeySignalMessage, ProtocolAddress, PublicKey,
    SessionStore, SignalMessage, SignalProtocolError, SignedPreKeyId, SignedPreKeyRecord,
    Timestamp, message_decrypt, message_encrypt, process_prekey_bundle,
};
use rand::Rng;
use serde_json::{Value, json};

use crate::error::{Result, format_err};
use crate::store::{
    MemIdentityStore, MemPreKeyStore, MemSessionStore, MemSignedPreKeyStore, NoKyberStore,
    ZaloSignalStore,
};

/// Device id Zalo PC registers its own prekey bundle under.
pub const PC_DEVICE_ID: u32 = 2;
const PC_PREKEY_BATCH: u32 = 25;

/// `zaloAddr(remoteUid, devId)`: name `<uid>_<dev>`, device `<dev>` (JS string form `<uid>_<dev>.<dev>`).
pub fn zalo_address(remote_uid: &str, device: u32) -> ProtocolAddress {
    ProtocolAddress::new(format!("{remote_uid}_{device}"), DeviceId::from(device))
}

pub struct CipherOut {
    /// base64 of `[type][message]`.
    pub cipher: String,
    /// 3 = PreKeyWhisperMessage, 1 = WhisperMessage (JS `message.type`).
    pub message_type: u8,
    /// Remote registration id of the session used (JS `message.registrationId`).
    pub registration_id: u32,
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .map(|d| u64::try_from(d.as_millis()).unwrap_or(0))
        .unwrap_or(0)
}

impl ZaloSignalStore {
    /// Fresh identity like `initOrRestore` without saved state: registration id, identity,
    /// signed prekey #1 and 25 one-time prekeys.
    pub fn generate<R: Rng + rand::CryptoRng>(rng: &mut R) -> Result<Self> {
        let pair = IdentityKeyPair::generate(rng);
        let registration_id = rng.random_range(1..16380u32);

        let mut pre_keys = MemPreKeyStore::default();
        for id in 1..=PC_PREKEY_BATCH {
            let kp = KeyPair::generate(rng);
            pre_keys
                .keys
                .insert(id, PreKeyRecord::new(PreKeyId::from(id), &kp));
        }
        let spk = KeyPair::generate(rng);
        let signature = pair
            .private_key()
            .calculate_signature(&spk.public_key.serialize(), rng)?;
        let mut signed_pre_keys = MemSignedPreKeyStore::default();
        signed_pre_keys.keys.insert(
            1,
            SignedPreKeyRecord::new(
                SignedPreKeyId::from(1),
                Timestamp::from_epoch_millis(now_ms()),
                &spk,
                &signature,
            ),
        );

        Ok(Self {
            sessions: MemSessionStore::default(),
            identity: MemIdentityStore {
                pair,
                registration_id,
                trusted: BTreeMap::new(),
            },
            pre_keys,
            signed_pre_keys,
            kyber: NoKyberStore,
            next_pre_key_id: PC_PREKEY_BATCH + 1,
            signed_pre_key_id: 1,
        })
    }

    /// `initOrRestore`: restores from the saved `zaloE2EEPCStoreV1` JSON, or generates a fresh
    /// identity when there is none (empty / shorter than 3 chars, as the JS check). Returns
    /// whether the store was restored.
    ///
    /// Deviation from JS: a non-empty value that fails to parse is an error, not a silent
    /// regeneration. Regenerating would replace the account's identity key and, once persisted,
    /// destroy every session; the caller decides what to do (the app falls back to the JS path).
    pub fn init_or_restore<R: Rng + rand::CryptoRng>(
        saved_json: &str,
        rng: &mut R,
    ) -> Result<(Self, bool)> {
        if saved_json.len() > 2 {
            Ok((Self::from_js_json(saved_json, now_ms())?, true))
        } else {
            Ok((Self::generate(rng)?, false))
        }
    }

    /// `refillPreKeys`: generates `count` (at least 1) one-time prekeys with the next ids and
    /// returns `(id, base64 public key)` for the `opKeys` upload.
    pub fn refill_pre_keys<R: Rng + rand::CryptoRng>(
        &mut self,
        count: u32,
        rng: &mut R,
    ) -> Vec<(u32, String)> {
        let mut out = Vec::new();
        for _ in 0..count.max(1) {
            let id = self.next_pre_key_id;
            self.next_pre_key_id += 1;
            let kp = KeyPair::generate(rng);
            out.push((id, STANDARD.encode(kp.public_key.serialize())));
            self.pre_keys
                .keys
                .insert(id, PreKeyRecord::new(PreKeyId::from(id), &kp));
        }
        out
    }

    /// `listSessions`: devices 0...3 of `remote_uid` with an open session and the remote
    /// registration id of that session.
    pub async fn list_sessions(&self, remote_uid: &str) -> Vec<(u32, u32)> {
        let mut out = Vec::new();
        for device in 0..=3u32 {
            if self.has_session(remote_uid, device).await {
                let reg = self
                    .sessions
                    .sessions
                    .get(&zalo_address(remote_uid, device).to_string())
                    .and_then(|(rec, _)| rec.remote_registration_id().ok())
                    .unwrap_or(0);
                out.push((device, reg));
            }
        }
        out
    }

    /// `buildSubmitBundlePayload`: what Zalo's server stores for this device.
    pub fn bundle_payload(&self) -> Result<Value> {
        let spk = match self.signed_pre_keys.keys.get(&self.signed_pre_key_id) {
            Some(s) => s,
            None => return format_err("signed prekey missing"),
        };
        let mut op_keys = Vec::new();
        for (id, rec) in &self.pre_keys.keys {
            op_keys.push(json!({
                "id": id,
                "key": STANDARD.encode(rec.public_key()?.serialize()),
            }));
        }
        op_keys.truncate(PC_PREKEY_BATCH as usize);
        Ok(json!({
            "delSS": 0,
            "key": {
                "deviceId": PC_DEVICE_ID,
                "preKey": {
                    "iKey": {
                        "id": self.identity.registration_id,
                        "key": STANDARD.encode(self.identity.pair.public_key().serialize()),
                    },
                    "signature": STANDARD.encode(spk.signature()?),
                    "spKey": {
                        "id": self.signed_pre_key_id,
                        "key": STANDARD.encode(spk.public_key()?.serialize()),
                    },
                },
                "opKeys": op_keys,
            },
        }))
    }

    pub async fn has_session(&self, remote_uid: &str, device: u32) -> bool {
        match self
            .sessions
            .load_session(&zalo_address(remote_uid, device))
            .await
        {
            Ok(Some(rec)) => rec
                .has_usable_sender_chain(SystemTime::now())
                .unwrap_or(false),
            _ => false,
        }
    }

    /// `processPreKeyBundle`: accepts the server's `{key:{preKey:{iKey,spKey,signature},opKeys}}`
    /// shape (first one-time key is used) or the flat `{identityKey, signedPreKey, preKey}` one.
    pub async fn process_bundle<R: Rng + rand::CryptoRng>(
        &mut self,
        remote_uid: &str,
        device: u32,
        bundle: &Value,
        rng: &mut R,
    ) -> Result<()> {
        let bundle = parse_bundle(bundle, device)?;
        let addr = zalo_address(remote_uid, device);
        let first = process_prekey_bundle(
            &addr,
            &mut self.sessions,
            &mut self.identity,
            &bundle,
            SystemTime::now(),
            rng,
        )
        .await;
        match first {
            // The glue retries once after dropping the pinned key ("Identity key changed").
            Err(SignalProtocolError::UntrustedIdentity(_)) => {
                self.identity.trusted.remove(addr.name());
                process_prekey_bundle(
                    &addr,
                    &mut self.sessions,
                    &mut self.identity,
                    &bundle,
                    SystemTime::now(),
                    rng,
                )
                .await?;
            }
            other => other?,
        }
        // The new session is the one whose base key we generated.
        if let Some((rec, meta)) = self.sessions.sessions.get_mut(&addr.to_string()) {
            meta.ours.insert(rec.alice_base_key()?.to_vec());
        }
        Ok(())
    }

    /// `encryptCipher` (string format).
    pub async fn encrypt_cipher(
        &mut self,
        remote_uid: &str,
        device: u32,
        plaintext: &[u8],
    ) -> Result<CipherOut> {
        let addr = zalo_address(remote_uid, device);
        let msg = message_encrypt(
            plaintext,
            &addr,
            &mut self.sessions,
            &mut self.identity,
            SystemTime::now(),
        )
        .await?;
        let (message_type, bytes) = match &msg {
            CiphertextMessage::PreKeySignalMessage(m) => (3u8, m.serialized().to_vec()),
            CiphertextMessage::SignalMessage(m) => (1u8, m.serialized().to_vec()),
            _ => return format_err("unexpected ciphertext message kind"),
        };
        let registration_id = self
            .sessions
            .sessions
            .get(&addr.to_string())
            .and_then(|(rec, _)| rec.remote_registration_id().ok())
            .unwrap_or(0);
        let mut out = Vec::with_capacity(1 + bytes.len());
        out.push(message_type);
        out.extend_from_slice(&bytes);
        Ok(CipherOut {
            cipher: STANDARD.encode(out),
            message_type,
            registration_id,
        })
    }

    /// `decryptCipher` (string format; returns the raw plaintext bytes).
    pub async fn decrypt_cipher<R: Rng + rand::CryptoRng>(
        &mut self,
        sender_uid: &str,
        device: u32,
        cipher_b64: &str,
        rng: &mut R,
    ) -> Result<Vec<u8>> {
        let all = STANDARD.decode(cipher_b64)?;
        if all.len() < 16 {
            return format_err("cipher too short");
        }
        let addr = zalo_address(sender_uid, device);
        let msg = if all[0] == 3 {
            CiphertextMessage::PreKeySignalMessage(PreKeySignalMessage::try_from(&all[1..])?)
        } else {
            CiphertextMessage::SignalMessage(SignalMessage::try_from(&all[1..])?)
        };
        Ok(message_decrypt(
            &msg,
            &addr,
            &mut self.sessions,
            &mut self.identity,
            &mut self.pre_keys,
            &self.signed_pre_keys,
            &mut self.kyber,
            rng,
        )
        .await?)
    }
}

fn b64_field(v: &Value, what: &str) -> Result<Vec<u8>> {
    match v.as_str() {
        Some(s) => Ok(STANDARD.decode(s)?),
        None => format_err(format!("bundle field `{what}` is not a string")),
    }
}

fn id_field(v: &Value, what: &str) -> Result<u32> {
    match v.as_u64().map(u32::try_from) {
        Some(Ok(n)) => Ok(n),
        _ => format_err(format!("bundle field `{what}` is not a u32")),
    }
}

fn parse_bundle(bundle: &Value, device: u32) -> Result<PreKeyBundle> {
    let src = match bundle.get("key") {
        Some(k) if k.get("preKey").is_some() => k,
        _ => bundle,
    };
    let (reg, identity, spk_id, spk_pub, sig, one_time) = if let Some(pk) = src.get("preKey")
        && let Some(ikey) = pk.get("iKey")
        && let Some(spkey) = pk.get("spKey")
    {
        let op = src
            .get("opKey")
            .or_else(|| src.get("opKeys").and_then(|a| a.get(0)))
            .filter(|o| o.get("key").is_some());
        let one_time = match op {
            Some(o) => Some((
                id_field(&o["id"], "opKey.id")?,
                b64_field(&o["key"], "opKey.key")?,
            )),
            None => None,
        };
        (
            id_field(&ikey["id"], "iKey.id")?,
            b64_field(&ikey["key"], "iKey.key")?,
            id_field(&spkey["id"], "spKey.id")?,
            b64_field(&spkey["key"], "spKey.key")?,
            b64_field(&pk["signature"], "signature")?,
            one_time,
        )
    } else if let Some(ik) = src.get("identityKey")
        && let Some(sp) = src.get("signedPreKey")
    {
        let one_time = match src.get("preKey").filter(|p| p.get("publicKey").is_some()) {
            Some(p) => Some((
                id_field(&p["keyId"], "preKey.keyId")?,
                b64_field(&p["publicKey"], "preKey.publicKey")?,
            )),
            None => None,
        };
        (
            id_field(&src["registrationId"], "registrationId")?,
            b64_field(ik, "identityKey")?,
            id_field(&sp["keyId"], "signedPreKey.keyId")?,
            b64_field(&sp["publicKey"], "signedPreKey.publicKey")?,
            b64_field(&sp["signature"], "signedPreKey.signature")?,
            one_time,
        )
    } else {
        return format_err("unrecognized_bundle_format");
    };

    let pre_key = match one_time {
        Some((id, key)) => Some((PreKeyId::from(id), PublicKey::deserialize(&key)?)),
        None => None,
    };
    Ok(PreKeyBundle::new(
        reg,
        DeviceId::from(device),
        pre_key,
        SignedPreKeyId::from(spk_id),
        PublicKey::deserialize(&spk_pub)?,
        sig,
        IdentityKey::decode(&identity)?,
    )?)
}
