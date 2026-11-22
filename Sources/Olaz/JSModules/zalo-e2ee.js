/*
 * zalo-e2ee.js — Olaz glue around the vendored libsignal-protocol build.
 *
 * Loaded after vendor/libsignal-protocol.js inside JSRuntime (JavaScriptCore).
 * Publishes `globalThis.ZaloE2EE`; every function returns a Promise and takes or
 * returns only strings, numbers and plain objects so Swift can marshal them.
 *
 * Each local identity (the logged-in user plus demo peers) gets its own in-memory
 * SignalProtocolStore. A real engine would persist the stores and fetch prekey
 * bundles from the server; here bundles are read straight out of the peer's store.
 */
(function (g) {
  'use strict';
  const signal = g.libsignal;
  if (!signal) throw new Error('libsignal-protocol must be loaded before zalo-e2ee.js');

  const DEVICE_ID = 1;
  // Small batches keep first use fast; refilled when a peer drains them.
  const PREKEY_BATCH = 5;
  const SIGNED_PREKEY_ID = 1;
  const FINGERPRINT_ITERATIONS = 5200;

  // MARK: bytes helpers

  // libsignal hands keys around as ArrayBuffers, views, ByteBuffers *or* binary
  // strings (session records are stringified), so normalize before comparing.
  const toBytes = (k) => {
    if (k instanceof ArrayBuffer) return new Uint8Array(k);
    if (ArrayBuffer.isView(k)) return new Uint8Array(k.buffer, k.byteOffset, k.byteLength);
    if (typeof k === 'string') return Uint8Array.from(k, (c) => c.charCodeAt(0) & 0xff);
    if (k && typeof k.toArrayBuffer === 'function') return new Uint8Array(k.toArrayBuffer());
    throw new TypeError('Unsupported key representation');
  };
  const bytesEqual = (a, b) => {
    if (a === undefined || b === undefined) return false;
    const x = toBytes(a), y = toBytes(b);
    if (x.length !== y.length) return false;
    for (let i = 0; i < x.length; i++) if (x[i] !== y[i]) return false;
    return true;
  };
  const utf8 = new TextEncoder();
  const utf8d = new TextDecoder();
  const base64ToBuffer = (b64) => {
    const bin = atob(b64);
    const out = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
    return out.buffer;
  };

  // MARK: in-memory store (libsignal-protocol-javascript test/InMemorySignalProtocolStore)

  class MemoryStore {
    constructor() { this.store = {}; }
    get Direction() { return { SENDING: 1, RECEIVING: 2 }; }
    put(key, value) {
      if (key === undefined || value === undefined || key === null || value === null) {
        throw new Error('Tried to store undefined/null');
      }
      this.store[key] = value;
    }
    get(key, fallback) { return key in this.store ? this.store[key] : fallback; }
    remove(key) { delete this.store[key]; }

    getIdentityKeyPair() { return Promise.resolve(this.get('identityKey')); }
    getLocalRegistrationId() { return Promise.resolve(this.get('registrationId')); }

    isTrustedIdentity(identifier, identityKey /*, direction */) {
      if (identifier === null || identifier === undefined) {
        return Promise.reject(new Error('Tried to check identity key for undefined/null key'));
      }
      if (identityKey === undefined || identityKey === null) {
        return Promise.reject(new Error('Expected an identity key'));
      }
      const trusted = this.get('identityKey' + identifier);
      // Trust on first use, then pin.
      return Promise.resolve(trusted === undefined || bytesEqual(identityKey, trusted));
    }
    loadIdentityKey(identifier) {
      return Promise.resolve(this.get('identityKey' + identifier));
    }
    saveIdentity(identifier, identityKey) {
      const name = signal.SignalProtocolAddress.fromString(identifier).getName();
      const existing = this.get('identityKey' + name);
      this.put('identityKey' + name, toBytes(identityKey).slice().buffer);
      return Promise.resolve(existing !== undefined && !bytesEqual(existing, identityKey));
    }

    loadPreKey(keyId) {
      const res = this.get('25519KeypreKey' + keyId);
      return Promise.resolve(res === undefined ? undefined : { pubKey: res.pubKey, privKey: res.privKey });
    }
    storePreKey(keyId, keyPair) { return Promise.resolve(this.put('25519KeypreKey' + keyId, keyPair)); }
    removePreKey(keyId) { return Promise.resolve(this.remove('25519KeypreKey' + keyId)); }

    loadSignedPreKey(keyId) {
      const res = this.get('25519KeysignedKey' + keyId);
      return Promise.resolve(res === undefined ? undefined : { pubKey: res.pubKey, privKey: res.privKey });
    }
    storeSignedPreKey(keyId, keyPair) { return Promise.resolve(this.put('25519KeysignedKey' + keyId, keyPair)); }
    removeSignedPreKey(keyId) { return Promise.resolve(this.remove('25519KeysignedKey' + keyId)); }

    loadSession(identifier) { return Promise.resolve(this.get('session' + identifier)); }
    storeSession(identifier, record) { return Promise.resolve(this.put('session' + identifier, record)); }
    removeSession(identifier) { return Promise.resolve(this.remove('session' + identifier)); }

    // Zalo fork addition (synchronous): last session-reset timestamp for a peer.
    getSessionTs(/* name */) { return undefined; }
  }

  // MARK: parties

  const parties = new Map(); // id -> { store, registrationId, identity, signedPreKey, preKeys: [{keyId, keyPair}] }
  const pendingRegistrations = new Map();

  const party = (id) => {
    const p = parties.get(id);
    if (!p) throw new Error('Unknown identity "' + id + '" — call registerIdentity first');
    return p;
  };

  async function createParty(id) {
    const store = new MemoryStore();
    const KeyHelper = signal.KeyHelper;
    const registrationId = KeyHelper.generateRegistrationId();
    const identity = await KeyHelper.generateIdentityKeyPair();
    store.put('identityKey', identity);
    store.put('registrationId', registrationId);

    const signedPreKey = await KeyHelper.generateSignedPreKey(identity, SIGNED_PREKEY_ID);
    await store.storeSignedPreKey(signedPreKey.keyId, signedPreKey.keyPair);

    const p = { id, store, registrationId, identity, signedPreKey, preKeys: [], nextPreKeyId: 1 };
    await refillPreKeys(p);
    return p;
  }

  async function refillPreKeys(p) {
    for (let i = 0; i < PREKEY_BATCH; i++) {
      const preKey = await signal.KeyHelper.generatePreKey(p.nextPreKeyId++);
      await p.store.storePreKey(preKey.keyId, preKey.keyPair);
      p.preKeys.push(preKey);
    }
  }

  // What a server would hand out: identity + signed prekey + one one-time prekey.
  async function takePreKeyBundle(p) {
    if (p.preKeys.length === 0) await refillPreKeys(p);
    const preKey = p.preKeys.shift(); // one-time: each bundle consumes one
    const bundle = {
      identityKey: p.identity.pubKey,
      registrationId: p.registrationId,
      signedPreKey: {
        keyId: p.signedPreKey.keyId,
        publicKey: p.signedPreKey.keyPair.pubKey,
        signature: p.signedPreKey.signature,
      },
    };
    bundle.preKey = { keyId: preKey.keyId, publicKey: preKey.keyPair.pubKey };
    return bundle;
  }

  const address = (id) => new signal.SignalProtocolAddress(id, DEVICE_ID);
  const logger = {
    info: (...a) => console.debug('[libsignal]', ...a),
    debug: () => {},
    warn: (...a) => console.warn('[libsignal]', ...a),
    error: (...a) => console.error('[libsignal]', ...a),
  };

  // MARK: API

  g.ZaloE2EE = {
    version: signal.VERSION,

    /** Idempotent. Resolves to the identity's registration id. */
    registerIdentity(id) {
      if (typeof id !== 'string' || !id) return Promise.reject(new TypeError('identity id must be a non-empty string'));
      if (parties.has(id)) return Promise.resolve(parties.get(id).registrationId);
      if (!pendingRegistrations.has(id)) {
        pendingRegistrations.set(id, createParty(id).then((p) => {
          parties.set(id, p);
          pendingRegistrations.delete(id);
          return p.registrationId;
        }, (err) => { pendingRegistrations.delete(id); throw err; }));
      }
      return pendingRegistrations.get(id);
    },

    hasSession(from, to) {
      return new signal.SessionCipher(party(from).store, address(to), { logger }).hasOpenSession();
    },

    /** -> { type: 3 (PreKeyWhisper) | 1 (Whisper), body: base64, registrationId } */
    async encrypt(plaintext, from, to) {
      const sender = party(from);
      const recipientAddress = address(to);
      const cipher = new signal.SessionCipher(sender.store, recipientAddress, { logger });
      if (!(await cipher.hasOpenSession())) {
        const builder = new signal.SessionBuilder(sender.store, recipientAddress, { logger });
        await builder.processPreKey(await takePreKeyBundle(party(to)));
      }
      const message = await cipher.encrypt(utf8.encode(String(plaintext)).buffer);
      return { type: message.type, body: btoa(message.body), registrationId: message.registrationId };
    },

    /** Resolves to the UTF-8 plaintext; rejects on bad MAC / unknown session. */
    async decrypt(envelope, at, from) {
      const recipient = party(at);
      const cipher = new signal.SessionCipher(recipient.store, address(from), { logger });
      const body = base64ToBuffer(envelope.body);
      let plaintext;
      if (envelope.type === 3) plaintext = await cipher.decryptPreKeyWhisperMessage(body);
      else if (envelope.type === 1) plaintext = await cipher.decryptWhisperMessage(body);
      else throw new Error('Unknown Signal message type ' + envelope.type);
      return utf8d.decode(plaintext);
    },

    /** 60-digit safety number, identical from both sides, grouped in 5s. */
    async safetyNumber(a, b) {
      const pa = party(a), pb = party(b);
      const generator = new signal.FingerprintGenerator(FINGERPRINT_ITERATIONS);
      const digits = await generator.createFor(a, pa.identity.pubKey, b, pb.identity.pubKey);
      return digits.match(/.{1,5}/g).join(' ');
    },

    // MARK: Persistent Zalo PC Device (deviceId = 2) Runtime
    pc: (() => {
      const PC_DEVICE_ID = 2;
      const PC_PREKEY_BATCH = 25;
      const pcStates = new Map();

      const bufToB64 = (buf) => {
        const bytes = toBytes(buf);
        let bin = '';
        for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
        return btoa(bin);
      };
      const b64ToBytes = (b64) => new Uint8Array(base64ToBuffer(b64));
      const b64ToBuf = (b64) => base64ToBuffer(b64);

      const zaloAddr = (remoteUid, devId) => {
        const d = Number(devId);
        return new signal.SignalProtocolAddress(String(remoteUid) + '_' + d, d);
      };

      const serializeState = (st) => {
        const rawStore = st.store.store;
        const preKeysObj = {};
        const signedPreKeysObj = {};
        const sessionsObj = {};
        const trustedObj = {};
        for (const k of Object.keys(rawStore)) {
          const v = rawStore[k];
          if (k.startsWith('25519KeypreKey')) {
            const id = k.slice('25519KeypreKey'.length);
            preKeysObj[id] = { pubKey: bufToB64(v.pubKey), privKey: bufToB64(v.privKey) };
          } else if (k.startsWith('25519KeysignedKey')) {
            const id = k.slice('25519KeysignedKey'.length);
            signedPreKeysObj[id] = {
              pubKey: bufToB64(v.pubKey),
              privKey: bufToB64(v.privKey),
              signature: st.signatures[id] || '',
            };
          } else if (k.startsWith('session')) {
            const id = k.slice('session'.length);
            sessionsObj[id] = typeof v === 'string' ? v : JSON.stringify(v);
          } else if (k.startsWith('identityKey') && k !== 'identityKey') {
            const id = k.slice('identityKey'.length);
            trustedObj[id] = bufToB64(v);
          }
        }
        return JSON.stringify({
          version: 1,
          registrationId: st.registrationId,
          nextPreKeyId: st.nextPreKeyId,
          signedPreKeyId: st.signedPreKeyId,
          identity: {
            pubKey: bufToB64(st.identity.pubKey),
            privKey: bufToB64(st.identity.privKey),
          },
          preKeys: preKeysObj,
          signedPreKeys: signedPreKeysObj,
          sessions: sessionsObj,
          trusted: trustedObj,
        });
      };

      const buildSubmitBundlePayload = (st) => {
        const spk = st.store.get('25519KeysignedKey' + st.signedPreKeyId);
        const sigB64 = st.signatures[String(st.signedPreKeyId)] || '';
        const opKeys = [];
        for (const k of Object.keys(st.store.store)) {
          if (k.startsWith('25519KeypreKey')) {
            const kid = Number(k.slice('25519KeypreKey'.length));
            const kp = st.store.store[k];
            if (!isNaN(kid) && kp && kp.pubKey) {
              opKeys.push({ id: kid, key: bufToB64(kp.pubKey) });
            }
          }
        }
        opKeys.sort((a, b) => a.id - b.id);
        return {
          delSS: 0,
          key: {
            deviceId: PC_DEVICE_ID,
            preKey: {
              iKey: {
                id: st.registrationId,
                key: bufToB64(st.identity.pubKey),
              },
              signature: sigB64,
              spKey: {
                id: st.signedPreKeyId,
                key: bufToB64(spk.pubKey),
              },
            },
            opKeys: opKeys.slice(0, PC_PREKEY_BATCH),
          },
        };
      };

      return {
        async initOrRestore(uid, savedJSON) {
          if (savedJSON && typeof savedJSON === 'string' && savedJSON.length > 2) {
            try {
              const parsed = JSON.parse(savedJSON);
              if (parsed && parsed.identity && parsed.registrationId) {
                const store = new MemoryStore();
                const identity = {
                  pubKey: b64ToBuf(parsed.identity.pubKey),
                  privKey: b64ToBuf(parsed.identity.privKey),
                };
                store.put('identityKey', identity);
                store.put('registrationId', Number(parsed.registrationId));
                const signatures = {};
                const spks = parsed.signedPreKeys || {};
                for (const id of Object.keys(spks)) {
                  store.put('25519KeysignedKey' + id, {
                    pubKey: b64ToBuf(spks[id].pubKey),
                    privKey: b64ToBuf(spks[id].privKey),
                  });
                  if (spks[id].signature) signatures[id] = spks[id].signature;
                }
                const pks = parsed.preKeys || {};
                for (const id of Object.keys(pks)) {
                  store.put('25519KeypreKey' + id, {
                    pubKey: b64ToBuf(pks[id].pubKey),
                    privKey: b64ToBuf(pks[id].privKey),
                  });
                }
                const sess = parsed.sessions || {};
                for (const id of Object.keys(sess)) {
                  store.put('session' + id, sess[id]);
                }
                const trusted = parsed.trusted || {};
                for (const id of Object.keys(trusted)) {
                  store.put('identityKey' + id, b64ToBuf(trusted[id]));
                }
                const st = {
                  uid,
                  store,
                  identity,
                  registrationId: Number(parsed.registrationId),
                  signedPreKeyId: Number(parsed.signedPreKeyId || 1),
                  nextPreKeyId: Number(parsed.nextPreKeyId || 100),
                  signatures,
                };
                pcStates.set(uid, st);
                return {
                  restored: true,
                  registrationId: st.registrationId,
                  bundlePayload: buildSubmitBundlePayload(st),
                  storeJSON: serializeState(st),
                };
              }
            } catch (_) {}
          }

          const store = new MemoryStore();
          const registrationId = signal.KeyHelper.generateRegistrationId();
          const identity = await signal.KeyHelper.generateIdentityKeyPair();
          store.put('identityKey', identity);
          store.put('registrationId', registrationId);

          const signedPreKeyId = 1;
          const signedPreKey = await signal.KeyHelper.generateSignedPreKey(identity, signedPreKeyId);
          await store.storeSignedPreKey(signedPreKey.keyId, signedPreKey.keyPair);
          const signatures = { [String(signedPreKeyId)]: bufToB64(signedPreKey.signature) };

          let nextPreKeyId = 1;
          for (let i = 0; i < PC_PREKEY_BATCH; i++) {
            const pk = await signal.KeyHelper.generatePreKey(nextPreKeyId++);
            await store.storePreKey(pk.keyId, pk.keyPair);
          }

          const st = {
            uid,
            store,
            identity,
            registrationId,
            signedPreKeyId,
            nextPreKeyId,
            signatures,
          };
          pcStates.set(uid, st);
          return {
            restored: false,
            registrationId,
            bundlePayload: buildSubmitBundlePayload(st),
            storeJSON: serializeState(st),
          };
        },

        exportStore(uid) {
          const st = pcStates.get(uid);
          return st ? serializeState(st) : '';
        },

        async refillPreKeys(uid, count) {
          const st = pcStates.get(uid);
          if (!st) throw new Error('PC E2EE not initialized for ' + uid);
          const n = Math.max(1, Number(count || 30));
          const opKeys = [];
          for (let i = 0; i < n; i++) {
            const pk = await signal.KeyHelper.generatePreKey(st.nextPreKeyId++);
            await st.store.storePreKey(pk.keyId, pk.keyPair);
            opKeys.push({ id: pk.keyId, key: bufToB64(pk.keyPair.pubKey) });
          }
          return {
            registrationId: st.registrationId,
            opKeys,
            storeJSON: serializeState(st),
          };
        },

        async decryptCipher(uid, senderUid, deviceId, cipherB64, format) {
          const st = pcStates.get(uid);
          if (!st) return { ok: false, error: 'not_initialized' };
          try {
            const allBytes = b64ToBytes(cipherB64);
            if (allBytes.length < 16) return { ok: false, error: 'too_short' };
            const msgType = allBytes[0];
            const bodyBuf = allBytes.slice(1).buffer;
            const addr = zaloAddr(senderUid, deviceId);
            const cipher = new signal.SessionCipher(st.store, addr, { logger });
            let plainBuf;
            if (msgType === 3) {
              plainBuf = await cipher.decryptPreKeyWhisperMessage(bodyBuf, 'binary');
            } else {
              plainBuf = await cipher.decryptWhisperMessage(bodyBuf, 'binary');
            }
            const outBytes = toBytes(plainBuf);
            if (format === 'uint32') {
              if (outBytes.length < 4) return { ok: false, error: 'short_uint32' };
              const val = (
                (outBytes[0]) |
                (outBytes[1] << 8) |
                (outBytes[2] << 16) |
                (outBytes[3] << 24)
              ) >>> 0;
              return { ok: true, number: val };
            }
            return { ok: true, text: utf8d.decode(outBytes) };
          } catch (err) {
            return { ok: false, error: String(err && err.message ? err.message : err) };
          }
        },

        async hasSession(uid, remoteUid, deviceId) {
          const st = pcStates.get(uid);
          if (!st) return false;
          try {
            const addr = zaloAddr(remoteUid, deviceId);
            const cipher = new signal.SessionCipher(st.store, addr, { logger });
            return Boolean(await cipher.hasOpenSession());
          } catch (_) {
            return false;
          }
        },

        async listSessions(uid, remoteUid) {
          const st = pcStates.get(uid);
          if (!st) return [];
          const out = [];
          for (const devId of [0, 1, 2, 3]) {
            try {
              const addr = zaloAddr(remoteUid, devId);
              const cipher = new signal.SessionCipher(st.store, addr, { logger });
              if (await cipher.hasOpenSession()) {
                const regId = await cipher.getRemoteRegistrationId();
                out.push({ deviceId: devId, registrationId: Number(regId || 0) });
              }
            } catch (_) {}
          }
          return out;
        },

        async processPreKeyBundle(uid, remoteUid, deviceId, bundleObj) {
          const st = pcStates.get(uid);
          if (!st) return { ok: false, error: 'not_initialized' };
          if (!bundleObj || typeof bundleObj !== 'object') return { ok: false, error: 'invalid_bundle' };
          try {
            const toBuf = (val) => (typeof val === 'string' ? b64ToBuf(val) : toBytes(val).slice().buffer);
            const src = (bundleObj.key && bundleObj.key.preKey) ? bundleObj.key : bundleObj;
            let preKeyBundle;
            if (src.preKey && src.preKey.iKey && src.preKey.spKey) {
              const pk = src.preKey;
              const op = src.opKey || (Array.isArray(src.opKeys) && src.opKeys.length > 0 ? src.opKeys[0] : null);
              preKeyBundle = {
                registrationId: Number(pk.iKey.id),
                identityKey: toBuf(pk.iKey.key),
                signedPreKey: {
                  keyId: Number(pk.spKey.id),
                  publicKey: toBuf(pk.spKey.key),
                  signature: toBuf(pk.signature),
                },
                preKey: (op && op.key) ? {
                  keyId: Number(op.id),
                  publicKey: toBuf(op.key),
                } : undefined,
              };
            } else if (src.identityKey && src.signedPreKey) {
              preKeyBundle = {
                registrationId: Number(src.registrationId),
                identityKey: toBuf(src.identityKey),
                signedPreKey: {
                  keyId: Number(src.signedPreKey.keyId),
                  publicKey: toBuf(src.signedPreKey.publicKey),
                  signature: toBuf(src.signedPreKey.signature),
                },
                preKey: (src.preKey && src.preKey.publicKey) ? {
                  keyId: Number(src.preKey.keyId),
                  publicKey: toBuf(src.preKey.publicKey),
                } : undefined,
              };
            } else {
              return { ok: false, error: 'unrecognized_bundle_format' };
            }

            const addr = zaloAddr(remoteUid, deviceId);
            const builder = new signal.SessionBuilder(st.store, addr, { logger });
            try {
              await builder.processPreKey(preKeyBundle);
            } catch (err) {
              if (err && String(err.message || err).includes('Identity key changed')) {
                st.store.remove('identityKey' + addr.getName());
                await builder.processPreKey(preKeyBundle);
              } else {
                throw err;
              }
            }
            return {
              ok: true,
              registrationId: preKeyBundle.registrationId,
              storeJSON: serializeState(st),
            };
          } catch (err) {
            return { ok: false, error: String(err && err.message ? err.message : err) };
          }
        },

        async encryptCipher(uid, remoteUid, deviceId, value, format) {
          const st = pcStates.get(uid);
          if (!st) return { ok: false, error: 'not_initialized' };
          try {
            const addr = zaloAddr(remoteUid, deviceId);
            const cipher = new signal.SessionCipher(st.store, addr, { logger });
            let plainBytes;
            if (format === 'uint32') {
              const num = Number(value) >>> 0;
              plainBytes = new Uint8Array([
                num & 0xff,
                (num >>> 8) & 0xff,
                (num >>> 16) & 0xff,
                (num >>> 24) & 0xff,
              ]);
            } else {
              plainBytes = utf8.encode(String(value));
            }
            const plainBuf = plainBytes.buffer.slice(plainBytes.byteOffset, plainBytes.byteOffset + plainBytes.byteLength);
            const message = await cipher.encrypt(plainBuf);
            const bodyStr = message.body || '';
            const outBytes = new Uint8Array(1 + bodyStr.length);
            outBytes[0] = Number(message.type) & 0xff;
            for (let i = 0; i < bodyStr.length; i++) {
              outBytes[i + 1] = bodyStr.charCodeAt(i) & 0xff;
            }
            return {
              ok: true,
              cipher: bufToB64(outBytes),
              type: message.type,
              registrationId: message.registrationId,
            };
          } catch (err) {
            return { ok: false, error: String(err && err.message ? err.message : err) };
          }
        },

        async encryptBatch(uid, targets, values, formats) {
          const st = pcStates.get(uid);
          if (!st) return { ok: false, error: 'not_initialized' };
          const results = [];
          const valList = Array.isArray(values) ? values : [];
          const fmtList = Array.isArray(formats) ? formats : [];
          for (const t of (Array.isArray(targets) ? targets : [])) {
            if (!t || !t.userId || t.deviceId === undefined || t.deviceId === null) continue;
            try {
              const ciphers = [];
              let regId = 0;
              for (let i = 0; i < valList.length; i++) {
                const fmt = fmtList[i] || 'string';
                const enc = await this.encryptCipher(uid, t.userId, t.deviceId, valList[i], fmt);
                if (!enc || !enc.ok) {
                  throw new Error((enc && enc.error) || 'encrypt_failed');
                }
                ciphers.push(enc.cipher);
                regId = Number(enc.registrationId || regId);
              }
              results.push({
                userId: String(t.userId),
                deviceId: Number(t.deviceId),
                registrationId: regId,
                ciphers,
              });
            } catch (_) {}
          }
          return {
            ok: true,
            results,
            storeJSON: serializeState(st),
          };
        },
      };
    })(),
  };
})(globalThis);
