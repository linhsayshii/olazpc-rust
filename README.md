# zalo-swift-re — Olaz

**A reverse-engineered, ultra-lightweight pure Swift native macOS client for [Zalo](https://zalo.me).**

Olaz pairs a native SwiftUI interface (`App/`, `Shell/`, `Views/`) with a **100% Pure Swift Native Protocol Engine** (`ZaloRuntime/Protocol/`): direct `URLSession` HTTP + `URLSessionWebSocketTask` binary realtime WebSocket (`zpw_ws`), `CryptoKit`/`CommonCrypto`, `KeychainCipher`, `SQLite3` WAL persistence, and in-process `JavaScriptCore` (`SignalE2EE`).

There is **zero `WKWebView`**, **zero `app.asar` (~340 MB Electron bundle)**, **zero Node.js sidecar**, and **zero idle helper processes**.

> [!IMPORTANT]
> **Unofficial project, not affiliated with or endorsed by VNG Corporation.** "Zalo" is a trademark of VNG.
> This is an interoperability and reverse-engineering research project. Using an unofficial client may
> conflict with Zalo's terms of service, so use it at your own risk with your own account.

## Architecture Comparison (`WKWebView` Host → Pure Swift Native)

Inspired by lightweight native client designs (such as `lebad280324/zalolite`), Olaz replaces the legacy Chromium/WKWebView + `app.asar` renderer host with direct wire-protocol communication:

| Component | Legacy (`app.asar` + `WKWebView`) | Pure Swift Native (Current) |
|---|---|---|
| **Protocol & Auth** | Headless `WKWebView` + 17 MB webpack bundle | `ZaloSessionClient` + `ZaloCrypto` (`zpw_ver=694`, `ParamCipher`, `signkey`) |
| **Realtime Transport** | Browser WebSocket shimmed via JS | `ZaloWebSocket` (`URLSessionWebSocketTask`, binary `zpw_ws`, AES-GCM-16 + gzip/zlib) |
| **Storage** | IndexedDB in WebKit data store | `ZaloSQLiteStore` (`SQLite3` WAL at `~/Library/Application Support/Olaz/ZaloData/`) |
| **Media & Screenshots** | CDN + `ZaloCap` helper binary | `MediaLoader` (DoH/SNI) + `AVFoundation` + native macOS `⌘V` clipboard paste |
| **Voice / Video Calls** | Background helper + JS IPC router | VNG `ZaloCall` (`CallBridge`) launched strictly **on-demand** during active calls |
| **E2EE** | `app.asar` libsignal | In-process `JavaScriptCore` `SignalE2EE` (`Sources/Olaz/JSModules/`) |

## Features

- **Real QR login** (`reqqr` → long-poll scan & confirm → `getLoginInfo` → Keychain-sealed `native-session.json` + legacy cookie migration)
- **Chat**: SQLite-backed offline history & load older, send text / quotes / `@mentions`, reactions, typing, read receipts (`seenv2`), real-time `zpw_ws` sync
- **Composer & Clipboard**: native macOS `⌘V` image/file paste (`PastedContentTests`), photo/file chunked upload, my contact card, reminders
- **Message actions**: copy, forward, recall (`undo`), delete with 5s undo, pin board, star
- **Voice / video calls**: on-demand `ZaloCall` (`ZaloHelper.app`) resolved from Olaz's runtime or `/Applications/Zalo.app`, automatically terminated when idle
- **Contacts, Groups, Polls, Stickers, Labels, Hidden Chats (SHA-256 PIN), Shared Media, Cloud summary, Native macOS Notifications**

## Requirements

- macOS 26 or later, Xcode toolchain (Swift 6+)
- A Zalo account and Zalo mobile app for QR login
- Optional for voice/video calls: `/Applications/Zalo.app` installed (or placed in Olaz's runtime directory for `ZaloHelper.app`)

Zalo allows **one desktop (PC) session per account**. If the official Zalo PC is also running, quit it while using Olaz.

## Build & Run

```bash
swift test                     # pure Swift protocol, crypto, SQLite WAL, wire parser & UI model tests
./scripts/make-app.sh debug    # builds build/Olaz.app (zero WebKit.framework, zero app.asar)
open build/Olaz.app            # real QR login — scan with Zalo on your phone
```

### Developer Harness

```bash
.build/debug/Olaz --engine-probe login 5    # tests live VNG QR ticket + PNG generation
.build/debug/Olaz --engine-probe status 5   # validates saved Keychain session status
```

* Engine diagnostics: `~/Library/Application Support/Olaz/logs/engine.log` (event shapes only, never tokens or message bodies).

## Architecture Overview

```
SwiftUI (Liquid Glass)                      Sources/Olaz/App/, Shell/, Views/
        │  @Observable ZaloEngine           Sources/Olaz/ZaloRuntime/ZaloEngine*.swift
        ▼
Pure Swift Protocol Layer                   Sources/Olaz/ZaloRuntime/Protocol/
  ├─ ZaloCrypto.swift        ── ParamCipher, signkey, AES-CBC/GCM-16, zlib/gzip, JSONLossless, CoreImage QR
  ├─ ZaloDomains.swift       ── SERVICE_MAP_V3 multi-host failover & server info updates
  ├─ ZaloSessionClient.swift ── QR flow, getLoginInfo, Keychain session, encrypted GET/POST/Multipart
  ├─ ZaloWebSocket.swift     ── URLSessionWebSocketTask binary framing (cmd=1/2/501/510/521/533/570/603/604)
  ├─ ZaloWireParser.swift    ── Zalo REST/WS JSON ↔ ChatMessage & StoredMessage mapper
  ├─ ZaloAPIService.swift    ── Chat, group, friend, sticker, poll, pin, mute, upload endpoints
  └─ ZaloSQLiteStore.swift   ── Actor-isolated SQLite3 WAL store + shared-media cursor index
```

## License

Olaz is free software, licensed under the [GNU General Public License v3.0](LICENSE).
Copyright © 2026 Quan Nguyen.
