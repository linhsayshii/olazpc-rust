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

