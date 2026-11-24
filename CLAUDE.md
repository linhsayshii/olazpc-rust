# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Olaz is an unofficial, reverse-engineered native macOS Zalo client (SwiftUI + a Swift protocol engine with a Rust core exported via UniFFI). This repo is standalone (https://github.com/linhsayshii/olazpc-rust, no longer a fork) and continues the GPL-3.0 project by Quan Nguyen (qnguyen3/zalo-swift-re), whose app and reverse-engineering work it builds on; see `NOTICE.md`. The ongoing goal is feature parity with the official **Zalo PC for macOS** (client `zpw_ver=694`, Zalo PC 26.10.x): when implementing or fixing a feature, the official client's behavior, wording (Vietnamese UI strings) and server calls are the reference. See `README.md` and `REVERSE-ENGINEERING-NOTES.md` for the wire protocol (signing, ParamCipher, QR login, `zpw_ws` framing and cmd numbers, service-map failover).

Requirements: macOS 26+, Swift 6 toolchain (Xcode, not just CommandLineTools: SwiftUI macros need Xcode's plugins; the scripts auto-pick `/Applications/Xcode*.app` via `DEVELOPER_DIR`). No third-party SwiftPM dependencies. Rust via rustup (1.88+; `build-rust.sh` adds the arm64/x86_64 darwin targets); on a fresh checkout run `./scripts/build-rust.sh` before `swift build` (it produces the git-ignored `rust/build/OlazCoreFFI.xcframework`).

## Commands

```bash
./scripts/build-rust.sh                      # fresh checkout / after Rust changes: xcframework + Swift bindings
swift build                                  # debug build → .build/debug/Olaz
swift test                                   # all tests (Swift Testing: @Suite / @Test / #expect)
swift test --filter PollTests                # one suite
swift test --filter PollTests/detailParsing  # one test
./scripts/make-app.sh debug                  # bundle build/Olaz.app (ad-hoc signed with JIT entitlement)
open build/Olaz.app
./scripts/release.sh                         # Developer ID sign + notarize → dist/ (needs keychain profile)
```

CI/release workflows live in `.github/workflows/` (`ci.yml`, `release.yml`; see `docs/RELEASING.md`).

Run the bundled app (not the bare binary) for real use: the JIT entitlement in `scripts/Olaz.entitlements` is required for JavaScriptCore, and the SwiftPM resource bundle `Olaz_Olaz.bundle` (JSModules/, Resources/) is copied into the .app and located by `JSBridge/ResourceLocator.swift`.

Headless harness (`main.swift` → `ZaloRuntime/EngineProbe.swift`):

```bash
.build/debug/Olaz --engine-probe login 5        # live QR ticket + PNG
.build/debug/Olaz --engine-probe status 5       # validate saved Keychain session
.build/debug/Olaz --engine-probe audit
.build/debug/Olaz --engine-probe selftest-cloud
open build/Olaz.app --args --ui-smoke <outdir>  # GUI smoke: window screenshots + outline row counts
```

Env vars: `OLAZ_DEBUG_RESPONSES` (log raw API responses), `ZPROTO_WASM_PATH` (override libzproto WASM). `OLAZ_VERSION`, `OLAZ_BUILD`, `OLAZ_SIGN_IDENTITY`, `OLAZ_NOTARY_PROFILE` for the scripts.

Runtime data lives under `~/Library/Application Support/Olaz/`: `ZaloData/` (SQLite WAL store, session), `ZaloRuntime/` (official Zalo pieces, see below), `logs/engine.log` (shapes only, never tokens or message bodies; keep it that way). Bundle id `app.olaz.mac`.

Zalo allows one PC session per account: quit the official Zalo PC while testing Olaz live.

## Architecture

```
SwiftUI views (App/, Shell/, Views/)  ── @Environment(ZaloEngine.self), ShellModel
        │
ZaloEngine (@MainActor @Observable)   ── ZaloRuntime/ZaloEngine.swift + ZaloEngine+<Feature>.swift
        │
Protocol layer (ZaloRuntime/Protocol/) ── ZaloSessionClient → ZaloAPIService(+Cloud/+Features/+GroupMgmt/+Media)
        │                                 ZaloWebSocket, ZaloWireParser, ZaloSQLiteStore, ZaloE2EEManager, ZaloPhoneSync
        ▼
Rust core (Sources/OlazCore via UniFFI) ── rust/crates/olaz-* (crypto, wire, ws, net, store, api, media, signal, ffi)
        │
JSBridge/ (JavaScriptCore)            ── JSRuntime (WebCrypto shim over CryptoKit), SignalE2EE, JSModules/*.js
```

- **`ZaloEngine` is the single source of truth.** One instance is created in `App/OlazApp.swift` and injected with `.environment(engine)`. Its `phase` (`starting → preparing(RuntimeSetup) → login → signingIn → ready`) drives `App/RootView.swift`. Feature logic is split into `ZaloEngine+<Feature>.swift` extensions (Chat, Media, Poll, Cloud, Contacts, GroupCall, Transfer, Search, Stickers, Notifications, MessageActions, ConversationActions…); feature state structs live alongside (`ChatModels.swift`, `CardSheetModels.swift`, `Models.swift`). Adding a feature usually means: endpoint in a `ZaloAPIService` extension → parsing in `ZaloWireParser` → state + actions in a `ZaloEngine+X.swift` → view in `Views/` → a `Tests/OlazTests/*Tests.swift` suite.
- **`ShellModel`** (`Shell/ShellModel.swift`) owns navigation: sidebar destination → content column (conversation list variants: inbox/“Khác”/unread/stranger folder/hidden chats/label/Cloud) → detail column (chat + inspector). Shell names mirror the official tabs.
- **HTTP**: every Zalo API request goes through `ZaloSessionClient` (`get`/`post`/`postMultipart`/`rawRequest`/`rawDownloadData`/`downloadSyncBatch`), which delegates unconditionally to the Rust core (`CoreApi`, `CoreHttp`, `CoreRawHttp` in `olaz-api`/`olaz-net`), applying ParamCipher encryption, `signkey`, and per-service host failover from `ZaloDomains` (`SERVICE_MAP_V3`; fail over only on 404/5xx/network, never on `ZaloSessionError`). Don't build URLSession requests to Zalo directly.
- **Realtime**: `ZaloWebSocket` delegates connection management, `zpw_ws` binary frame decoding (header `u8 ver | u16 LE cmd | u8 subCmd`, AES-GCM + gzip/zlib), and queue cursors unconditionally to Rust `CoreWs` (`olaz-ws`); `ZaloEngine` dispatches by cmd. Message ids are 64-bit and exceed `Double` precision: Rust uses `serde_json` (`arbitrary_precision`), and Swift callers parse through `JSONLossless` (in `ZaloCrypto.swift`), never plain `JSONSerialization` on raw server bytes.
- **Storage**: `ZaloSQLiteStore` is an actor over SQLite3 (WAL) that delegates core message, conversation, search, and preference operations unconditionally to Rust `CoreStore` (`olaz-store`), while keeping unported repair/cloud-media helpers on `sqlite3`. `ZaloWebKitMigrator` reads the legacy WebKit IndexedDB from older Olaz/SwiftZalo builds; `App/LegacyMigration.swift` migrates the old `dev.swiftzalo.app` bundle id and must run before anything opens cookies/preferences.
- **E2EE**: 1-1 Signal E2EE runs Zalo's own `libsignal-protocol.js` in JavaScriptCore (`ZaloE2EEManager` + `SignalE2EE`), with Rust `olaz-signal` (`CoreSignal`) running shadow decrypt by default or authoritative mode behind `OLAZ_E2EE_RUST=1`, keys persisted in SQLite.
- **Phone → Mac history sync**: `ZaloPhoneSync` runs Zalo's `libzproto` WASM via `JSModules/zalo-zproto-sync.js` in JavaScriptCore. The WASM is pulled out of the official `app.asar`.
- **Official runtime**: `ZaloRuntimeInstaller` downloads the pinned official Zalo PC DMG from VNG (or copies an installed `Zalo.app` of the same version), verifies VNG's signature and keeps `app.asar` + `ZaloHelper.app` under `~/Library/Application Support/Olaz/ZaloRuntime/current/`. Olaz never redistributes VNG files; `.gitignore` excludes extracted assets (`reanalysis/app_extracted/`, `lang_vi.json`, Zalo logos).
- **Calls**: `CallBridge`/`CallTransport` launch VNG's signed `ZaloCall` (inside `ZaloHelper.app`) only for an active call, talk to it over an AES-128-CBC framed UNIX socket (`UnixSocketServer`), and terminate it when call state returns to `"free"`. No idle helper processes.
- **Media**: `MediaLoader`/`DownloadManager` load CDN media and files unconditionally through Rust `CoreMedia` (`olaz-media`, which owns DoH fallback for `*.zadn.vn`, pinned TLS, and the disk files cache; Swift keeps `URLCache` image bytes, ImageIO decode, `NSCache`, and quarantine); `DoHResolver` and `PinnedHTTPSClient` are kept solely for `ZaloRuntimeInstaller`.

## Gotchas

- Some doc comments (e.g. `ZaloPlatform.swift`, `ZaloRuntimeInstaller.swift`, `reanalysis/bridge-spec.md`) still describe the earlier WKWebView/Electron-preload host architecture. The current app has no WKWebView; treat those as historical context for how the official client behaves.
- `Parking/` is old code, not part of any SwiftPM target (targets build only `Sources/Olaz` and `Tests/OlazTests`).
- Tests use `@testable import Olaz` and exercise parsers/state with inline JSON fixtures shaped like real server payloads (plus local HTTP servers like `FakeZaloServer`); there are no live-network tests.
- UI strings are Vietnamese, matching the official client.
