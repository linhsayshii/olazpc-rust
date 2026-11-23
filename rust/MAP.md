# Olaz Rust port map

Goal: move Olaz's protocol engine to a Rust core called from the existing SwiftUI app (macOS only), for speed and a smoother main thread. Decisions: [DECISIONS.md](DECISIONS.md) (ADR-001..008). Terms: [GLOSSARY.md](GLOSSARY.md).

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
| 4d | Delete Swift chat path | open (after commit + daily use) |

## Later waves (out of milestone 1)

Media/Download, Poll, Cloud, Contacts, GroupMgmt, Transfer, Search, Stickers, Notifications, Calls (CallBridge), E2EE, Phone sync (libzproto WASM), WebKit migrator.

## Kept in Swift

SwiftUI views (`App/`, `Shell/`, `Views/`), `ShellModel`, Keychain glue, QR PNG rendering (CoreImage).

## Open questions / debt

- Pre-existing bugs (both paths): typing indicator and in-message search do not work.

- Perf (2,000 msgs, debug Swift vs release Rust): parse 56 ms Swift vs 97 ms Rust incl. ChatMessage rebuild; save 13-17 vs 18-24 ms. The Rust path wins only by running off the MainActor. Real gains need typed records end to end (no JSON re-parse in Swift) and engine state moving into Rust.
- Timing flakes under full parallel `swift test`: `fastPhoneSyncPlanFiltersAndSortsNewestFirstAndBulkIngestsFast` (elapsed < 2.5 s; 0.1 s alone) and `MediaRecoveryTests/queueIsLIFOAndDropsCancelledWork`. Machine contention, not Rust.
- Off hot path still JSON: non-plain/E2EE ws envelopes, history HTTP results (Swift dict re-serialised), `message(...)` lookup and `findMessageForMedia`.

- Lossless JSON accessors are duplicated in `olaz-crypto`, `olaz-wire`, `olaz-ws` (`json.rs`), `olaz-store` (`helpers.rs`). Unify into `olaz-crypto::json` (or a tiny `olaz-json`) at the start of wave 2.
- Sorted JSON keys: server accepts them (live send ok 2026-11-22).
- Live check 2026-11-22 passed for WS auth, receive, send text. Not yet live-checked: history paging, seen/typing, recall, reactions, group mentions.
