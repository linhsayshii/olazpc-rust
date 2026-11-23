# Zalo patch for libsignal-protocol

Upstream: `signalapp/libsignal`, tag `v0.73.0`, crate `rust/protocol` (AGPL-3.0-only, see `LICENSE`).
Why this tag: 0.74+ drops X3DH (protocol v3) and requires PQXDH + SPQR, which Zalo's Signal fork does
not speak. 0.73.0 is the last tag that still starts and accepts v3 sessions without Kyber.

Why a patch: Zalo's `libsignal-protocol.js` is a VNG fork of `libsignal-protocol-javascript` that
changed the KDF `info` strings and fixed the version byte at `0x33`. Everything else (X3DH secret
layout, HKDF-SHA256, AES-256-CBC, 8-byte HMAC-SHA256 MAC, protobuf messages, chain/message-key
derivation) matches libsignal v3.

The whole semantic diff is `zalo-source.patch` (5 changed lines):

| File | Upstream | Zalo |
|---|---|---|
| `src/ratchet.rs` X3DH `derive_keys` (no Kyber) | `"WhisperText"` | `"ZaloText"` |
| `src/ratchet/keys.rs` `create_chain` (DH ratchet step) | `"WhisperRatchet"` | `"ZaloRatchet"` |
| `src/ratchet/keys.rs` `MessageKeys::derive_keys` | `"WhisperMessageKeys"` | `"ZaloMessageKeys"` |
| `src/protocol.rs` `SignalMessage::new`, `PreKeySignalMessage::new` version byte | `(v << 4) \| 4` = `0x34` | `(v << 4) \| v` = `0x33` |
| `src/lib.rs` | | `#![allow(mismatched_lifetime_syntaxes)]` (new rustc lint, no behaviour) |

The decode side needed no change (libsignal only reads the high nibble; the MAC is computed over the
version byte as received).

Build-only changes (not behavioural): `Cargo.toml` rewritten with workspace-inherited keys inlined;
`build.rs` + `prost-build` replaced by the pre-generated prost output pasted into `src/proto/*.rs`
(no `protoc` needed); `tests/`, `benches/`, `examples/`, `fuzz/` not copied. `libsignal-core` and
`signal-crypto` come from the upstream git tag, unpatched.

Wiring: `rust/Cargo.toml` `[patch."https://github.com/signalapp/libsignal"]` swaps this crate in for
the git dependency declared in `rust/crates/olaz-signal/Cargo.toml`.

To rebase onto a newer upstream tag: copy `rust/protocol/src`, re-apply `zalo-source.patch`, re-run
`cargo test -p olaz-signal` (the JS fixtures are the oracle). Negative controls were run: restoring
`"WhisperText"` breaks JS->Rust decryption of the X3DH message, restoring `0x34` breaks Rust->JS.
