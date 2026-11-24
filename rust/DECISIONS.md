# Rust port decisions

## ADR-001: Target platform is macOS only
Status: accepted (2026-11-22)
Context: Olaz is a macOS SwiftUI app. The owner wants better performance and smoother UI, on macOS only.
Decision: The Rust core targets `aarch64-apple-darwin` and `x86_64-apple-darwin`. No iOS/Android work.
Consequences: macOS-only crates and APIs (Keychain, Security.framework) are allowed in later units.

## ADR-002: Rust core + native SwiftUI UI
Status: accepted (2026-11-22)
Context: UI smoothness comes from SwiftUI; protocol, crypto, parsing and storage are pure logic that Rust can run off the main actor.
Decision: Port the protocol engine to a Rust core. Keep SwiftUI views. Swift calls Rust through UniFFI (one `olaz-ffi` crate, built as a static lib/XCFramework and linked from `Package.swift`).
Consequences: `Views/`, `Shell/`, `App/` stay Swift. `ZaloEngine` shrinks to a thin `@Observable` adapter over Rust state.

## ADR-003: First milestone is core chat
Status: accepted (2026-11-22)
Context: Porting all 53k lines at once is too risky.
Decision: Milestone 1 = crypto/signing/ParamCipher, lossless JSON, wire parser, `zpw_ws` framing, SQLite store, session HTTP client with failover, QR login, send/receive text. Later: media, poll, cloud, calls, E2EE, phone sync, migrators.
Consequences: E2EE (`libsignal-protocol.js`) and phone sync (libzproto WASM) stay in JavaScriptCore until their own wave.

## ADR-004: Cargo workspace under `rust/` in this repo
Status: accepted (2026-11-22)
Context: The Swift app must keep running while units move.
Decision: One workspace `rust/`, one crate per unit in `rust/crates/<name>`. The Swift app switches module by module to the Rust core; old Swift stays as reference until its unit is cut over.
Consequences: `rust/target/` is git-ignored.

## ADR-005: Equivalence bar = Swift behavior
Status: accepted (2026-11-22)
Context: `rust-anything` does not support Swift, so its `record`/`diff` cannot run. The Swift tests (`Tests/OlazTests`) hold inline fixtures shaped like real server payloads.
Decision: Each unit ports the relevant Swift test fixtures as Rust tests with identical expected values. Deterministic functions (hashing, AES-CBC with zero IV, signkey, ParamCipher, frame codec) also get golden vectors produced by running the Swift code. Byte-for-byte equality for crypto and wire formats; equal-after-parse for JSON.
Consequences: A mismatch is a bug in the port, never in the fixture.

## ADR-006: Same on-disk formats
Status: accepted (2026-11-22)
Context: Users already have `~/Library/Application Support/Olaz/ZaloData/` SQLite stores.
Decision: `olaz-store` opens the existing database with the exact same schema, table and column names, WAL mode, and migrations. No schema change in milestone 1.
Consequences: Swift and Rust can read the same DB during cutover.

## ADR-007: Crate choices
Status: accepted (2026-11-22)
Decision: `serde_json` with `arbitrary_precision` (lossless 64-bit ids, replaces `JSONLossless`); RustCrypto (`aes`, `cbc`, `aes-gcm`, `md-5`, `sha2`, `base64`, `hex`); `flate2` (zlib/gzip); `rusqlite` with `bundled`; `tokio` + `reqwest` (rustls) + `tokio-tungstenite` for networking; `uniffi` for FFI; `thiserror` for errors.
Consequences: No `unsafe` in unit crates. No `unwrap`/`expect` outside tests.

## ADR-008: Logging stays shape-only
Status: accepted (2026-11-22)
Context: `logs/engine.log` must never contain tokens or message bodies.
Decision: Rust logging (`tracing`) logs shapes and lengths only, same rule.

## ADR-009: Never rely on serde_json Map order
Status: accepted (2026-11-22)
Context: `olaz-wire` enables serde_json `preserve_order`; Cargo unifies features across the workspace, which silently changed `olaz-ws` key order and broke a golden test.
Decision: Code that needs a key order sorts explicitly; code that needs insertion order relies on `preserve_order` being on workspace-wide. MSRV is 1.88 (`sha2` 0.11).
Consequences: Unit tests must run with `cargo test --workspace`, not only `-p`, before a unit is marked done.

## ADR-010: One SQLite library per process
Status: accepted (2026-11-22)
Context: Swift links the system `libsqlite3`; `olaz-store` used rusqlite `bundled`, a second SQLite copy in the same process. Two copies on the same WAL file break POSIX advisory locking (closing a connection in one copy drops the other's locks), which can corrupt the DB.
Decision: rusqlite links the system SQLite (no `bundled`). Same library, same locks.
Consequences: SQLite version = the macOS one. Swift and Rust may share the DB file during cutover.

## ADR-011: Cutover behind a flag
Status: accepted (2026-11-22)
Context: No live check has run yet; Zalo allows one PC session per account.
Decision: The Rust chat path is enabled by `OLAZ_RUST_CORE=1` (env) or the `olaz.rustCore` UserDefaults bool. Default off until the live check passes; then default on, then delete the Swift path.
Consequences: Both paths must build and pass tests until the Swift path is deleted.

## ADR-012: Rust chat path on by default
Status: accepted (2026-11-23), supersedes the default in ADR-011
Context: Live check on 2026-11-23 passed for receive (1-1, group, media), history paging, send text/mention/quote, seen, reactions, recall, delete-for-me, restart persistence. Typing and in-message search fail on both paths (pre-existing bugs, not port regressions).
Decision: `RustCore.isEnabled` defaults to true. `OLAZ_RUST_CORE=0` or `olaz.rustCore=false` falls back to Swift. The Swift chat path is deleted only after a commit and a period of daily use.
Consequences: Tests run with the Rust path unless they set the flag; `OLAZ_RUST_CORE=0 swift test` covers the fallback.

## ADR-013: Typed history and lookups; non-plain ws envelopes stay raw
Status: accepted (2026-11-23), wave 5a
Context: After 4a only the realtime path was typed end to end. History HTTP answers crossed as lossless JSON that Swift parsed to a dictionary, re-serialised and handed back to the core; the single-message store lookup returned a raw row that Swift re-decoded.
Decision:
- `CoreApi.fetch_history` returns `HistoryRecord { has_more, is_old, last_msg_id, uids, batch }`. `batch` is a `HistoryBatch` object that keeps the parsed answer in Rust; Swift resolves `uids` to contact names (a MainActor lookup) and calls `batch.events(my_uid, options)` for the typed `WireEvent`s, the same two-phase shape as `WirePayload`. `batch.raw_json()` remains only for the callers that read raw fields (`applyBatchResponse` seeding, cloud-message lookups, `EngineProbe`); no hot-path caller uses it. The Swift path wraps its dictionary in the same `ZaloHistoryPage`.
- `CoreStore.message_chat` returns the typed `StoredChat`; Swift uses it where it only needs a `ChatMessage` (`findMessageForMedia`, remote reactions). `CoreStore.message` stays for `resolveServerAndClientIds`, which needs the raw `client_id` column and the raw JSON fallback.
- Non-plain `zpw_ws` envelopes stay raw (`WsListener.on_event`, `payload_json`). They are: E2EE cmds 535/551/552 and any envelope with a Signal cipher (decrypted by the Swift/JS Signal layer, which needs the JSON), `error_code != 0` (duplicate login), control/sync items (typing, mute, voip: parsed in Swift, there is no Rust parser for them), mobile-sync events (`ZaloPhoneSync`, Swift/WASM), 534/570, and the auth answer (cmd 1). The only ones Rust already interprets itself are auth (queue seeding) and `file_done`/`video_done` (waiter wake-up inside `olaz-ws`); Swift reads only `error_code` of the former and re-records the latter redundantly. They occur a handful of times per session, none on the message hot path, so typing them would add FFI surface without a measurable gain until the E2EE and control consumers move to Rust.
Consequences: History pages parsed in Rust never exist as a Swift dictionary on the Rust path. `HistoryRecord` lost its `raw_json` field and its `Eq` derive (it holds an object handle). Polling results (`fetch_chat_from_polling`) still cross as JSON (fallback path, not the chat hot path).


## ADR-014: Media layer in Rust; explicit cancellation token; webpki roots
Status: accepted (2026-11-23), wave 5c
Context: `MediaLoader` / `DownloadManager` network and disk work ran on Swift actors. UniFFI's Swift bindings do NOT cancel the Rust future when the awaiting Swift `Task` is cancelled (`uniffiRustCallAsync` only frees it after completion), so "drop on cancel" does not hold. `rustls-tls-native-roots` cost ~1.4 s per reqwest client on first use (keychain trust evaluation).
Decision:
- `olaz-media` owns fetch, DNS policy (system probe, DoH fallback, dead hosts, same endpoints/TTLs), pinned TLS (a reqwest client whose resolver is the DoH answer: SNI and certificate validation stay on the real hostname), single-flight that aborts when the last waiter leaves, a 6-slot semaphore, deadlines and idle timeouts, the files cache with the unchanged `<stableHash>.<ext>` layout, part files, atomic rename, LRU trim, and `SecureStream` decrypt.
- Every async `CoreMedia` export takes a `MediaCancel`; Swift wraps calls in `withTaskCancellationHandler` and calls `cancel()`. A cancelled call returns at once and the work future is dropped, which aborts the transfer and removes temp files (tested in Rust and Swift: the server sees the connection close).
- Swift keeps `ZaloMediaURL` parsing, ImageIO decode, `NSCache`, the image-bytes `URLCache`, and quarantine (a `MediaPublishHook` called before the final rename). The error enum is `MediaCoreError` (`MediaFailure` already exists in `RemoteImage.swift`).
- webpki roots only, matching `olaz-net`.
Consequences: clients are built lazily on the first Rust fetch; `OLAZ_RUST_CORE=0` restores the URLSession / Network.framework path.

## ADR-015: E2EE in Rust = libsignal v0.73.0, vendored with a 5-line Zalo patch; JS-format records stay the interchange format
Status: accepted for the cutover plan (2026-11-23), wave 6b (compatibility spike). Wave 6c (2026-11-23) landed steps 1-3 of the cutover plan: shadow decrypt on by default, authoritative switch behind a flag, JS fallback tested (see "Wave 6c: what landed"). Step 3's deletion of the JS runtime is NOT done: JS stays in the tree.
Context: 1-1 Signal E2EE runs Zalo's own `libsignal-protocol.js` in JavaScriptCore (`ZaloE2EEManager` + `zalo-e2ee.js`). The owner chose the official `libsignal-protocol` crate (AGPL-3.0, GPL-3.0 repo, acceptable). Question: can it read what JS persisted, produce ciphertexts JS accepts, and write records JS reads back, so the JS path can stay as a fallback during rollout?

### What JS stores and sends (read from `vendor/libsignal-protocol.js` and `zalo-e2ee.js`)
- Library: VNG's fork of `libsignal-protocol-javascript` (Zalo PC 26.10.20 `app.asar`), protocol v3, X3DH, `libsignal.VERSION = 2`. Fork changes that matter: KDF `info` strings `ZaloText` (X3DH), `ZaloRatchet` (DH ratchet step), `ZaloMessageKeys` (per-message keys) instead of `Whisper*`; version byte fixed at `0x33`; `getSessionTs` hook (the Olaz glue returns `undefined`, so inert).
- Persistence: ONE SQLite `preferences` value, key `zaloE2EEPCStoreV1`, a JSON text written by `ZaloE2EE.pc.serializeState`: `{version:1, registrationId, nextPreKeyId, signedPreKeyId, identity:{pubKey,privKey} (base64, 33-byte 0x05-prefixed public, 32-byte private), preKeys:{id:{pubKey,privKey}}, signedPreKeys:{id:{pubKey,privKey,signature}} (signature base64, 64 bytes), sessions:{"<uid>_<dev>.<dev>": "<JS SessionRecord.serialize() text>"}, trusted:{"<uid>_<dev>": base64 identity key}}`. The PC device is deviceId 2; peer addresses are `name = "<uid>_<dev>"`, `device = <dev>`, string form `name.dev`; identity trust is keyed by name (TOFU). `e2eeThreadsV1` (the list of E2EE conversations) is unrelated and stays Swift.
- Session record (`SessionRecord.serialize()`): JSON `{"sessions": {<baseKey>: S}, "version": "v1"}`, keys and chain ids are binary strings (one char per byte, U+0000..U+00FF). `S = {registrationId (remote), currentRatchet:{rootKey, lastRemoteEphemeralKey, previousCounter, ephemeralKeyPair:{pubKey,privKey}}, indexInfo:{remoteIdentityKey, closed (-1 open, else ms), baseKey, baseKeyType (1 ours, 2 theirs)}, oldRatchetList:[{added, ephemeralKey}], pendingPreKey?:{signedKeyId, baseKey, preKeyId?}, <chainId = ratchet pubkey>: {chainType (1 sending, 2 receiving), chainKey:{counter, key?}, messageKeys:{<index>: <32-byte seed>}}}`. `chainKey.counter` is the index of the LAST derived message key (-1 on a fresh chain) and `key` is the chain key after it; closed receiver chains lose `key` but keep skipped `messageKeys` (seeds, not expanded keys).
- Wire (cmd 535/551/552 envelopes stay raw JSON, ADR-013): a cipher is base64 of `[type: 3 PreKeyWhisperMessage | 1 WhisperMessage][0x33 | protobuf]`; a WhisperMessage ends with an 8-byte MAC = HMAC-SHA256(macKey, senderIK33 || receiverIK33 || 0x33 || protobuf)[..8]; body is AES-256-CBC, keys from HKDF-SHA256(seed, salt 0, `ZaloMessageKeys`) = cipher 32 | mac 32 | iv 16. PreKeyWhisperMessage proto: preKeyId=1, baseKey=2, identityKey=3, message=4, registrationId=5, signedPreKeyId=6.

### Compatibility result
Same as libsignal v3 except the four labels/bytes below, so a Rust implementation is possible with a tiny patch.
- libsignal-protocol 0.74+ is unusable: X3DH is rejected ("X3DH no longer supported") and SPQR is mandatory. v0.73.0 is the last tag that starts and accepts v3 sessions. Pinned there.
- Upstream does NOT interoperate unpatched: it derives with `WhisperText` / `WhisperRatchet` / `WhisperMessageKeys` and writes version byte `0x34` (low nibble = current version 4), which JS rejects (`(v & 15) > 3`) and which changes the MAC input. A negative control confirmed both: restoring `WhisperText` breaks JS->Rust decryption of an X3DH message; restoring `0x34` breaks every Rust->JS message.
- Patch (`rust/vendor/libsignal-protocol/zalo-source.patch`, 5 changed lines, applied through `[patch."https://github.com/signalapp/libsignal"]` so `olaz-signal` still declares the git tag): the three labels, and the low nibble of the version byte in `SignalMessage::new` / `PreKeySignalMessage::new`. The decode side needed no change. Vendoring also replaced `build.rs`/`prost-build` with pre-generated prost code (no `protoc` needed) and inlined the workspace manifest.
- Verdicts (fixtures from the REAL bundled JS library run in node, fresh test keys; `rust/crates/olaz-signal/tests/`):
  - JS -> Rust: PASS. Rust loads JS-written stores (identity, prekeys, signed prekeys, sessions with skipped keys and closed chains) and decrypts all 13 JS ciphertexts of the scenario from the JS snapshot taken just before each one: X3DH with a one-time prekey, three PreKeyWhisperMessages delivered 2,1,3, replies delivered out of order, five-message bursts delivered 4,2,5,1,3, several DH ratchet turns, a skipped key held across a snapshot, plus a tamper check.
  - Rust -> JS: PASS. Rust Alice starts from a JS Bob's bundle (XEdDSA signature verified both ways), PreKey and plain messages decrypt in JS, out of order, and Bob's replies decrypt in Rust. A Rust-created, Rust-advanced store (holding a skipped key) written as `zaloE2EEPCStoreV1` JSON is accepted by `initOrRestore`, JS decrypts the skipped message from it, JS continues the session, and Rust reads the JS-rewritten store and keeps talking.
  - Record round trip: JS -> Rust -> JS is semantically identical for all 52 session records in the 29 snapshots (7 with skipped message keys, 23 closed receiver chains) (only synthesised `oldRatchetList.added` clocks differ); every JS snapshot, converted by Rust without any Rust crypto, is accepted by JS which then decrypts the next ciphertext. Rust -> JS -> Rust -> JS is a fixed point and the converted sessions keep working (including skipped keys).
- Field mapping (convert.rs): `index = counter + 1` for every chain; `session_version = 3`; `alice_base_key = indexInfo.baseKey`; `remote_registration_id = registrationId`; JS sessions closed != -1 become libsignal previous sessions (newest first); libsignal keeps receiver chains oldest first (newest last, trimmed at 5), JS's current one is `lastRemoteEphemeralKey`; skipped keys map 1:1 because libsignal 0.73 also stores them as seeds. Derived on import: `local_identity_public`, `local_registration_id` (from the store), pending-prekey timestamp (import time).
- Losses and the rules that cover them: (1) `baseKeyType`, `closed`, `lastRemoteEphemeralKey` have no libsignal field; they are recoverable from the JS JSON itself on re-import, so the JSON is a complete carrier and nothing is lost across a Rust write/JS read/Rust read cycle; (2) libsignal Alice's unused initial receiver chain is dropped when writing JS; (3) a Bob that has not yet received anything has no sending chain in JS and none in the import (libsignal then refuses to encrypt, as JS does); (4) JS closed receiver chains (no key) import with an all-zero chain key placeholder and export back as closed; messages beyond their skipped keys fail MAC in both; (5) timestamps JS never had (signed prekey age) are set to import time.

### Cutover plan (wave 6c)
1. Shadow decrypt (no behaviour change): in `ZaloE2EEManager`, for every incoming cipher JS stays authoritative; in parallel Rust loads the JS store snapshot taken just before the JS decrypt (cache the parsed store by JSON hash), decrypts, and only compares plaintext; never persists. Log shapes only (match / mismatch / Rust error class), no bodies, no keys (ADR-008). Exit criterion: a week of daily use with zero mismatches.
2. Switch decrypt, then encrypt, behind a flag (`OLAZ_E2EE_RUST`, UserDefaults `olaz.e2eeRust`): Rust becomes authoritative and persists `to_js_json()` into the SAME `zaloE2EEPCStoreV1` key, so JS can read it back any time. Move `initOrRestore`, `refillPreKeys`, bundle building, `processPreKeyBundle`, `encryptBatch`, `listSessions` onto the Rust store (the API of `ratchet_ops.rs` mirrors `ZaloE2EE.pc`).
3. Fallback: flipping the flag off makes JS restore from the last Rust-written JSON (tested: `rust_written_records_are_continued_by_js_and_read_back_by_rust`). Keep the JS runtime and `libsignal-protocol.js` loadable until two releases pass clean, then delete (this also retires a JavaScriptCore context and the `window` shim).
4. Keep the fixture generator (`tests/js/gen_fixtures.js`) and the node interop tests; they are the regression oracle if the patch is ever rebased.

### Wave 6c: what landed
- FFI: `olaz-ffi/src/signal.rs`. `signal_init_or_restore(saved_json) -> CoreSignal` (`""` generates), `CoreSignal.{restored, registration_id, bundle_payload_json, export_store_json, refill_pre_keys, decrypt_cipher, encrypt_cipher, process_prekey_bundle, has_session, list_sessions}`, and the free `signal_shadow_decrypt(store_json, sender_uid, device, cipher_b64)`. Mapping to `ZaloE2EE.pc.*`: initOrRestore/exportStore/refillPreKeys/decryptCipher/encryptCipher/hasSession/listSessions/processPreKeyBundle one to one; `encryptBatch` (per target, per value, a failing target is dropped) and the text / uint32 framing stay in Swift (`ZaloE2EEManager`). Errors are `CoreError.Parse` / `.Crypto` carrying only a class name (`SignalError::kind`, e.g. `protocol_invalidmessage`), never uids or keys. Work runs on the blocking pool (libsignal store futures are `?Send` and never suspend); calls are milliseconds, so no `MediaCancel`-style token.
- One deliberate deviation from JS: `initOrRestore` on a non-empty saved value that fails to parse is an error, not a silent new identity. The manager then logs `e2ee: rust init failed kind=...`, uses JS for that launch and does not overwrite the stored JSON.
- `ZaloE2EEManager(mode:logSink:)`; `E2EERustMode` is `.off` / `.shadow` / `.authoritative` (`ZaloE2EEShadow.swift`).
- Shadow (default whenever `RustCore.isEnabled`): before each JS decrypt attempt the manager takes the JS store JSON as of that moment (`ZaloE2EE.pc.exportStore`, cached until a JS operation mutates the store), starts a detached utility task that calls `signal_shadow_decrypt` (store loaded from the snapshot, never persisted, dropped), runs the JS decrypt, then a second detached task awaits Rust and compares: string format against the JS text, uint32 against the first 4 bytes. At most 8 shadow jobs in flight; more are counted as skipped. JS remains the only writer of `zaloE2EEPCStoreV1` (a test asserts the persisted value equals JS's own export and that no Rust store exists). Cost on the real path: one `exportStore` per mutation plus task creation.
- Log shapes: `e2ee-shadow: match type=<prekey|whisper>`, `e2ee-shadow: mismatch type=... reason=<plaintext_differs|js_failed_rust_ok|rust_error_<parse|crypto_<kind>|internal|other>>`, `e2ee-shadow: totals matches=.. mismatches=.. errors=.. skipped=.. bothFailed=..` (on `reset()`, and on demand). Both-failed attempts (the manager tries devices 2/0/1 in turn, wrong ones fail) are counted, not logged.
- Reading the counters: `engine.e2eeShadowCounters` (`E2EEShadowStats.Snapshot`: matches, mismatches, errors = shadow plumbing failures, skipped, bothFailed), `engine.logE2EEShadowTotals()`, or grep `e2ee-shadow:` in `engine.log`. Exit criterion stays: a week of daily use with zero `mismatch` lines.
- Switch: `OLAZ_E2EE_RUST=1` or `defaults write app.olaz.mac olaz.e2eeRust -bool true` (read once per manager; `OLAZ_E2EE_RUST=0` forces shadow). `OLAZ_RUST_CORE=0` turns both modes off. Authoritative: decrypt, encrypt, bundle processing, prekey refill and `listSessions` run on `CoreSignal`; the JS runtime is not even loaded. Persistence keeps the JS path's timing: export at init, after each envelope / init-session batch when something decrypted (dirty flag), immediately after `encryptBatch` and after a prekey refill, all via `setPreferenceString(zaloE2EEPCStoreV1)`. Flip the flag off and JS restores from the Rust-written JSON (tests: Rust-authoritative conversation, then a JS-only manager continues it and a Rust manager continues after that).
- Tests: `olaz-ffi/src/signal_tests.rs` (13 fixture decrypts through the FFI and shadow entry, generate/exchange/export/reload, error classes), `Tests/OlazTests/RustE2EEModeTests.swift` (shadow counts + no writes + no plaintext in logs, switch with a JavaScriptCore peer and JS reading the store, switch-off restore, corrupt-store fallback, flag resolution, comparator).
- Not done: group/uint32 orchestration is unchanged Swift; no live traffic has been shadowed yet; deleting the JS runtime waits for the two clean releases of step 3.

### Risks
- A patched, vendored third-party crate (AGPL-3.0; the repo is GPL-3.0, compatible). The patch is 5 lines and negative-controlled, but a rebase onto a newer tag is impossible while Zalo stays on v3 (0.74+ removed it); v0.73.0 gets no upstream fixes. Mitigation: Zalo's protocol is frozen; the crate has no network or parsing of untrusted structure beyond protobuf messages.
- Behavioural differences not proven against live Zalo traffic: libsignal trims receiver chains at 5 (JS 10) and previous sessions at 40; max forward jump 25,000 (JS 2,000); unacknowledged pending-prekey sessions older than 30 days refuse to encrypt (JS never expires; import resets the clock); a missing one-time prekey id errors instead of JS's log-and-continue (both fail MAC anyway); JS `getSessionTs`/`onPreventPromoteSession` is not modelled (inert in Olaz). The shadow phase exists to catch these.
- Rust writing a record may drop skipped keys on chains beyond the 5th (JS would have kept them); acceptable (messages that old are not decryptable after fallback).
- Two writers of `zaloE2EEPCStoreV1` during shadow/fallback: shadow never writes; switching is one-way per launch; never run JS and Rust authoritative at once.
- Test coverage gaps: no real Zalo ciphertext (privacy rule: test keys only); no group E2EE (Zalo groups are not Signal here); uint32-format ciphers (`format: 'uint32'`) and `encryptBatch` multi-target orchestration are Swift/glue logic not ported yet.

### Build cost (measured 2026-11-23, M-series, release, `scripts/build-rust.sh`, both targets arm64 + x86_64)
Measured with a temporary FFI probe that linked `olaz-signal` into `olaz-ffi` (reverted; the committed `olaz-ffi` does not depend on it, so the shipped xcframework is unchanged by this wave):
- Builds for macOS arm64 and x86_64 (the script builds both and lipo-merges): yes, both compiled and linked.
- Build time: cold `./scripts/build-rust.sh` baseline 192 s; warm baseline (relink only) 59 s; with the Signal stack linked 283 s while the new crates compiled cold, so about +3.5 min on a cold cache (about +110 s per architecture) and an unmeasured, small increment once cached. New dependency crates: libsignal-protocol, libsignal-core, signal-crypto, libcrux-ml-kem, rayon, curve25519-dalek, x25519-dalek, prost (no `boring`, no C code, no `protoc`).
- Size: universal static lib 149,965,944 -> 182,053,112 bytes (+32 MB, +21%); xcframework 143 MB -> 174 MB. A static archive keeps every object, so that overstates the shipped cost: an isolated release binary of the whole Signal stack (generate, X3DH, encrypt, decrypt, JSON export), stripped, is 1.16 MB on arm64, so expect about +1 MB per architecture in the final app binary after dead-stripping. The `rayon` and `libcrux-ml-kem` (Kyber) code is dead weight for v3 and can be trimmed later by vendoring away the `kyber`/`rayon` parts if size matters.
- Debug `cargo build -p olaz-signal` from scratch: 33 s. `cargo test --workspace` adds about 1 s of test time (the node interop tests spawn one node process each).

## ADR-016: `olaz-core` actor, pure reducer, change stream, and session domain (U1b)

- **Context**: Waves 1–6 moved protocol primitives (crypto, wire parser, WS, SQLite, HTTP, media, E2EE) into Rust crates, but domain state and orchestration (`bootSession`, QR login flow, expiry, logout, and later chat/contacts/groups/polls) still live in `@MainActor ZaloEngine`. Moving domains one by one needs a deterministic, testable core architecture (plan decisions D1–D9) that shares the existing `CoreSession` with remaining Swift-owned feature calls and replays recorded Swift behavior cases verbatim.
- **Decision**:
  1. **Single tokio actor + pure reducer (`olaz-core`)**: One tokio actor (`actor.rs`) owns `CoreState` and processes `Input` (external `Command` + internal `Event`) from an unbounded `mpsc` channel on `olaz-ffi`'s shared multi-thread runtime (`runtime.rs`). All domain logic lives in pure functions `reduce(&mut CoreState, Input) -> (Vec<Effect>, DirtyKeys)` with no I/O, clock, or randomness inside `reduce`.
  2. **Pull-based `ChangeStream` (D2/D3)**: Dirty keys (`DirtyKey::Session` for U1b; high-frequency keys like messages/conversations coalesce in place in `O(dirty keys)` memory) advance a monotonic `version: u64`. Low-frequency `Session` lifecycle transitions are buffered in a bounded queue (cap 64, consecutive-duplicate coalescing) so fast loopback or local responses never drop intermediate `waiting_confirm` / `signing_in` / `ready` snapshots before Swift pulls. Swift runs a single `@MainActor` `while let batch = try await core.nextChanges()` loop. `apply_account_profile` is async end-to-end (returns the reduced `version: u64`; Swift awaits mirror application of that version), and `current_version()` lets host lifecycle gates wait for mirror drain without blocking the actor.
  3. **Ordered `CoreHost` worker vs concurrent network effects**: `EffectRunner` (`runner.rs`) runs `Effect::Host(...)` calls serially in emitted order on a dedicated single-consumer worker (preserving exact `host` ordering, e.g. `clear_session` then `reset_domains` before cleanup), while network effects (`RequestQr`, `WaitQrScan`, `WaitQrConfirm`, `CompleteLogin`, `CheckSessionStatus`, `SyncProfileMe`) run as generation-tagged spawned tasks aborted on cancellation/logout/expiry. The actor loop never awaits I/O or host callbacks inline.
  4. **Single `CoreSession` credential owner + typed errors**: `ZaloSessionClient.sharedCoreSession()` creates one `CoreSession::with_config(imei, computer_name, domains_json)` shared by `CoreEngine`, `CoreApi`, and `CoreHttp`. Keychain / local vault sealing (`0x4A` / legacy `0x49`) and `native-session.json` file I/O remain in Swift via `CoreHost` (`load_saved_session`, `persist_session`, `mark_expired`, `clear_session`); credential snapshot JSON crosses FFI only and is redacted in manual `Debug` impls. Session failure reasons stay typed (`FailReason::Text(String) | Core(CoreFailKind)`) until Swift renders `.core` through `RustCore.mapError(...).localizedDescription`, preserving locale-accurate Foundation descriptions.
  5. **Replay runner (`tests/cases.rs`)**: Plugs a `ScriptedTransport` directly into `olaz_net::SessionClient` (reusing the real request builders and `ParamCipher`/AES crypto) under `tokio::time::pause()`, so 60 s QR deadlines and multi-host failover execute faithfully in milliseconds.
- **Consequences**:
  - `phase`, `profile`, `signOutNotice`, and `selfConversationId` on `ZaloEngine` are now a pure mirror written exclusively from `CoreEngine.nextChanges()` (`ZaloEngine.swift` / `ZaloEngine+Core.swift`); SwiftUI views are untouched.
  - `OLAZ_RUST_CORE=0` no longer drives the session flow (old Swift `bootSession` / `startQRLoginFlow` deleted; U0a removes remaining Swift fallback code).
  - Release-build round-trip delivery (`applyAccountProfile` -> actor reduce -> `next_changes()` -> `@MainActor` mirror) measures min 33.4 us, p50 41.9 us, p95 78.5 us, max 730.8 us (n=100, arm64 macOS).
