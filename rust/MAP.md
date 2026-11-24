# Olaz Rust port map

Goal: move Olaz's protocol engine to a Rust core called from the existing SwiftUI app (macOS only), for speed and a smoother main thread. Decisions: [DECISIONS.md](DECISIONS.md) (ADR-001..018). Terms: [GLOSSARY.md](GLOSSARY.md).

Workflow per unit: claim here, port into its own crate, port Swift fixtures as Rust tests, `cargo fmt --check && cargo clippy -p <crate> -- -D warnings && cargo test -p <crate>` green, mark done with test counts.

## Milestone 1: core chat

| Wave | Unit | Swift source | Crate | State |
|---|---|---|---|---|
| 1 | Crypto, signkey, ParamCipher, inflate, WS frame decrypt, lossless JSON | `Protocol/ZaloCrypto.swift` | `olaz-crypto` | done 2026-11-22 (25 tests, 16 Swift-golden) |
| 1 | Wire parser (messages, conversations, events) | `Protocol/ZaloWireParser.swift` | `olaz-wire` | done 2026-11-22 (29 tests, 11 Swift fixtures) |
| 1 | `zpw_ws` frame codec + queue cursors (pure part, no socket) | `Protocol/ZaloWebSocket.swift` | `olaz-ws` | done 2026-11-22 (34 tests, Swift-golden frames) |
| 1 | SQLite store (same schema) | `Protocol/ZaloSQLiteStore.swift` | `olaz-store` | done 2026-11-22 (23 tests, schema byte-identical, real DB copies compat) |
| 2 | Unify lossless JSON helpers into `olaz-json` | 4 duplicated copies | `olaz-json` | done 2026-11-22 (6 tests; workspace 113) |
| 2 | Service map + session HTTP client with failover | `ZaloDomains.swift`, `ZaloSessionClient.swift` | `olaz-net` | done 2026-11-22 (65 tests, 11 Swift-golden) |
| 2 | WebSocket transport (tokio-tungstenite) on top of `olaz-ws` | `ZaloWebSocket.swift` | `olaz-ws` | done 2026-11-22 (49 tests, 15 local-server transport) |
| 3 | API service: login QR, send/receive text, history | `ZaloAPIService.swift` (core subset) | `olaz-api` | done 2026-11-22 (40 tests, probe example not run live) |
| 3 | UniFFI bridge infra (store, wire, crypto, ws) + build glue | `Package.swift`, `scripts/build-rust.sh` | `olaz-ffi` | done 2026-11-22 (swift test 423 green, make-app ok) |
| 3 | FFI: session + olaz-api exports; rusqlite on system SQLite | `ZaloSessionClient.swift`, `ZaloAPIService.swift` | `olaz-ffi` | done 2026-11-22 (ffi 16 tests, swift 427, system SQLite 3.54) |
| 3 | Swift cutover of chat path behind `OLAZ_RUST_CORE` flag | `ZaloEngine.swift`, `ZaloEngine+Chat.swift` | Swift | done 2026-11-22 behind flag (swift 437 green both modes; live 2026-11-22: Rust WS auth ok, receive + send text ok) |

## Wave 4

| Unit | Scope | State |
|---|---|---|
| 4a | Typed records across FFI on hot paths (ws events -> parsed wire events in Rust, ChatMessage record, store rows); release-mode benchmark | done 2026-11-23 (rust 256, swift 443 both modes; realtime 70.9->51.5 ms, history 56.6->40.0 ms per 2,000 vs Swift; conv list 0.5 vs 3.5 ms, plain save 13.1 vs 14.5 ms still slower) |
| 4b | Chat state (conversation list merge/sort/unread, per-conversation message window) in Rust; Swift gets diffs | deferred (small remaining gain) |
| 4c | Flip `OLAZ_RUST_CORE` default on (ADR-012) | done 2026-11-23 (swift 443 both modes) |
| 4d | Delete Swift chat path | done 2026-11-24 as U0a |
| U0a | Delete Swift fallback of all Rust-ported layers (`RustCore.isEnabled`, `useRustCore`, HTTP/API/WS/Store/Wire/Media fallbacks); move `URLProtocol` tests to `FakeZaloServer` and `:memory:` DB tests to temp files; port remaining parity fixtures to Rust (ADR-017) | done 2026-11-24 (`Sources/` −3,626 / +382, `Tests/` −1,354 / +362, `rust/` +411 golden tests; `swift test` 579/98 → 555/97, `SessionRecorderTests` slow green with 0 diff on `session.jsonl`) |
| 5a | typed history/lookup/envelopes | done 2026-11-23 (rust 258, swift 449 both modes; non-plain ws envelopes stay raw, ADR-013) |
| 5b | generic signed HTTP seam (all feature endpoints) + timeout fix | done 2026-11-23 (rust 271 = +8 golden/seam, +2 timeout, +5 ffi; swift 452 both modes). `CoreHttp` (`request`, `post_multipart`, `post_multipart_file`) over `olaz_net::GenericCall`; Swift `ZaloSessionClient.get/post/postMultipart` delegate to it when `useRustCore`. Still Swift: `rawGetJSON`/`rawRequest` callers (QR/login already Rust), `zCloudGet` (cloud-viewer-key header, no ParamCipher), `rawDownloadData`, `downloadSyncBatch` |

| 5c | media/download network + disk cache (`olaz-media`) | done 2026-11-23 (rust +50: olaz-media 19 unit + 26 local-server/TLS, ffi 5; swift 462 both modes, 6 new in `RustMediaTests`). `CoreMedia` (`data`, `local_file`, `download_with_headers`, `download_to`, `evict`, `uses_doh`) behind `MediaLoader`/`DownloadManager`; 200 parallel local fetches via `MediaLoader` 0.07-0.17 s on the Rust path (Swift path cannot reach a plain-http server: ATS upgrade). See ADR-014 |

| 6a | raw HTTP paths (`rawRequest`, `rawDownloadData`, `downloadSyncBatch`) | done 2026-11-23. `CoreRawHttp` (`request`, `download`, `download_sync_batch`; olaz-ffi `raw_http.rs`) over session-free `olaz_net::{send_raw, download_data, download_sync_batch_with}` (the `SessionClient` methods now delegate to them). It needs no `CoreSession`: Swift passes its own `zpwSek` / user id per call (login runs before an account exists) and gets `(status, body, zpw_sek cookie)` back with no status mapping. Moved: `fetchServerInfo`, QR/login-info flow, `rawGetJSON`, the failover loops' `rawRequest`, `zCloudGet` (custom `cloud-viewer-key` header), `rawDownloadData`, phone-sync `downloadSyncBatch`. Still Swift: injected-`URLSession` tests, `OLAZ_RUST_CORE=0` fallback, `ZaloRuntimeInstaller`, `DoHResolver`, `MediaLoader` URLSession fallback. There was never a cookie jar (Swift session was ephemeral, `httpCookieAcceptPolicy = .never`), so `Set-Cookie` is only read out and Swift's `zpwSek` stays the single owner. Differences: rustls with webpki roots instead of the macOS keychain; reqwest redirect policy (10 hops, strips `Cookie` cross-origin) instead of URLSession's |

Live check 2026-11-23 (release 5e274ba, wave 5c): image-heavy chat scrolling noticeably smoother (user report); engine.log has no `rust: error` lines.

Live check 2026-11-23 (release build 9c47e82, merged 5a+5b): clean engine.log, no `rust: error` lines; the periodic `network timeout` is gone. Found on the way: `/api/friend/received/list` 404 on both paths (endpoint does not exist; fixed to `recommendsv2/list`). One startup `http status=429` from a typed endpoint (no path logged) seen once, not reproduced.

## Wave 6 (E2EE)

| Unit | Scope | State |
|---|---|---|
| 6b | E2EE compatibility spike: `olaz-signal` = libsignal-protocol v0.73.0 (vendored + 5-line Zalo patch) over the JS-persisted `zaloE2EEPCStoreV1` records; fixtures from the real bundled JS library; NOT wired, no FFI | done 2026-11-23 (verdict: compatible both ways, see ADR-015; olaz-signal 20 tests: 3 unit, 3 JS->Rust, 3 round-trip, 3 Rust->JS via node, 8 store; workspace 291) |
| 6c | `CoreSignal` FFI (`olaz-ffi/src/signal.rs`) wired into `ZaloE2EEManager`: shadow decrypt by default (JS authoritative, Rust compares a copy, counters + `e2ee-shadow:` log lines), `OLAZ_E2EE_RUST=1` / `olaz.e2eeRust` makes Rust authoritative for decrypt+encrypt and persist, JS restore from the Rust-written JSON tested; JS runtime kept | done 2026-11-23 (not yet live-checked; ffi 3 new tests, Swift 6 new in `RustE2EEModeTests`; workspace 354; see ADR-015) |

## Core engine migration (U1+)

| Unit | Scope | State |
|---|---|---|
| U1b | `olaz-core` skeleton (single tokio actor, pure `reduce(&mut CoreState, Input) -> (Vec<Effect>, DirtyKeys)`, `ChangeStream`, serial `CoreHost` runner, Case format v1 replay runner `tests/cases.rs`) + session domain (`boot`, QR login, logout, expiry, profile) cutover in `ZaloEngine` + `ZaloEngine+Core.swift` | done 2026-11-24 (olaz-core: 13 unit + 20 scenario + 20/20 recorded `cases/session.jsonl`; olaz-ffi: 45 passed; `gate-core.sh session` 6/6 pass incl. `OLAZ_SLOW_CASES=1 SessionRecorderTests`; release `next_changes()` delivery min=33.4 us, p50=41.9 us, p95=78.5 us, max=730.8 us; see ADR-016) |
| U2 | Transport domain in `olaz-core`: WS lifecycle (`WsDriver` + `watch_authed`), serialized HTTP long-poll (`4 s` ticks + `drain_chat_polling`), WS frame & control classification (`classify`), cursors & `poll_state` ownership, `CoreHost` transport callbacks, `ZaloEngine` / `ZaloWebSocket` cutover | done 2026-11-25 (olaz-core: 29 unit + 20 session + 29 transport scenario + 20/20 `cases/session.jsonl` + 26/26 `cases/transport.jsonl`; olaz-ffi: 50 passed; `gate-core.sh transport` & `session` 6/6 pass; release MainActor WS frame CPU `typed_chat_501` 81.12→72.43 µs (−10.7%), `control_mix_601` 83.03→46.06 µs (−44.5%), `protocol_noop_cmd1` 53.37→0.20 µs (−99.6%); see ADR-018) |

## Later waves (out of milestone 1)

Media/Download, Poll, Cloud, Contacts, GroupMgmt, Transfer, Search, Stickers, Notifications, Calls (CallBridge), E2EE, Phone sync (libzproto WASM), WebKit migrator.

## Kept in Swift

SwiftUI views (`App/`, `Shell/`, `Views/`), `ShellModel`, Keychain glue, QR PNG rendering (CoreImage).

## Open questions / debt

- `rust: error network timeout` every ~16 s (found 2026-11-23, fixed in 5b). Cause: the HTTP chat long-poll (`fetchChatFromPolling`, 12 s timeout, `conversations.rs` `raw_get_json(.., 12 s)`) is run by `startLongPollLoop` as `sleep 4 s` + poll, so a quiet server times out every 4 + 12 = 16 s. The Swift path times out identically but silently (`drainChatPolling` has `catch { break }` and `rawGetJSON` logs nothing), while `RustCore.mapError` logs every `.Network` error. Fix: `mapError(quietTimeout: true)` for the poll (an expected timeout is not an error). Separate real divergence also fixed: `ReqwestTransport` used reqwest's per-request `.timeout()` (TOTAL deadline) where Swift `URLRequest.timeoutInterval` is an inactivity timer (restarts on bytes), so slow uploads/downloads over the 35 s default died early; now `tokio::time::timeout` wraps the header wait and every body chunk, with the 180 s total cap kept client-wide (= `timeoutIntervalForResource`).
- Rust seam keeps failover winners (`rememberWinner`) only in the core session; Swift's persisted `domains` no longer learn them from feature calls (typed endpoints already behaved so). Cost: first call after launch may try the default host order once.

- Typing indicator fixed 2026-11-23: 1-1 pings sent `destType: 0` (official `DEST_TYPING.USER` is 3), and the "trên máy tính" (`isPC`) variant was missing. In-message search works again (user live check 2026-11-23, after wave 5).

- Perf (2,000 msgs, debug Swift vs release Rust): parse 56 ms Swift vs 97 ms Rust incl. ChatMessage rebuild; save 13-17 vs 18-24 ms. The Rust path wins only by running off the MainActor. Real gains need typed records end to end (no JSON re-parse in Swift) and engine state moving into Rust.
- Timing flakes under full parallel `swift test`: `fastPhoneSyncPlanFiltersAndSortsNewestFirstAndBulkIngestsFast` (elapsed < 2.5 s; 0.1 s alone) and `MediaRecoveryTests/queueIsLIFOAndDropsCancelledWork`. Machine contention, not Rust.
- Off hot path still JSON (ADR-013): non-plain ws envelopes (E2EE 535/551/552, control/typing/mute/voip, mobile sync, auth), HTTP polling results, raw `message(...)` lookup used by `resolveServerAndClientIds`, and the `raw_json()` of a history page for dictionary-reading callers. History pages, single-message decode and `findMessageForMedia` are typed.

- Lossless JSON accessors are duplicated in `olaz-crypto`, `olaz-wire`, `olaz-ws` (`json.rs`), `olaz-store` (`helpers.rs`). Unify into `olaz-crypto::json` (or a tiny `olaz-json`) at the start of wave 2.
- Sorted JSON keys: server accepts them (live send ok 2026-11-22).
- Live check 2026-11-22 passed for WS auth, receive, send text. Not yet live-checked: history paging, seen/typing, recall, reactions, group mentions.

- Wave 5c debt: the image-bytes cache stays Swift `URLCache` (lookup/store on the `MediaLoader` actor; Apple's on-disk format cannot be shared) so existing caches stay valid. `forget_failures` stays Swift (failure memory is keyed by decode key). Quarantine xattr, ImageIO decode, `NSCache` and `stills` stay Swift. `encrypt_e2ee_file` exists in Rust (`media_encrypt_e2ee_file`, tested) but the Swift upload caller still uses CryptoKit. GCM with an IV other than 12/16 bytes is rejected in Rust (Swift accepted any >= 12). DoH/pinned trust uses webpki roots (like `olaz-net`), not the macOS keychain: a TLS-intercepting proxy CA is not trusted on the Rust path. `MediaDiagnostics.report` is not emitted on the Rust staged-download path. Redirect budget is 3 hops for data/files (as the Swift DoH path), 10 for header downloads.
