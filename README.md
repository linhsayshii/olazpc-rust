# Olaz

**An unofficial, reverse-engineered native macOS client for [Zalo](https://zalo.me).**

Olaz is a SwiftUI app on top of a protocol engine that is being moved into a Rust core. There is no `WKWebView`, no Electron bundle (`app.asar`), no Node.js sidecar and no idle helper process.

- **UI and app logic**: Swift 6 / SwiftUI (`Sources/Olaz/App`, `Shell`, `Views`, `ZaloRuntime`).
- **Protocol core**: a Rust workspace (`rust/`, crates `olaz-api`, `olaz-crypto`, `olaz-ffi`, `olaz-json`, `olaz-media`, `olaz-net`, `olaz-signal`, `olaz-store`, `olaz-wire`, `olaz-ws`) exported to Swift through UniFFI (`Sources/OlazCore`, `rust/build/OlazCoreFFI.xcframework`). It covers signing and `ParamCipher`, the `zpw_ws` WebSocket, HTTP with service-map failover, the SQLite store, media download and cache, and Signal E2EE. The Swift engine still exists and is used as a fallback and for features not yet ported (see `rust/MAP.md`).
- **JavaScriptCore**: still used in-process for two Zalo JS modules in `Sources/Olaz/JSModules/`: the Signal E2EE library (`zalo-e2ee.js`, being replaced by the Rust `olaz-signal`) and the phone-to-Mac history sync (`zalo-zproto-sync.js`, which runs Zalo's `libzproto` WASM).

> [!IMPORTANT]
> **Unofficial project, not affiliated with or endorsed by VNG Corporation.** "Zalo" is a trademark of VNG.
> This is an interoperability and reverse-engineering research project. Using an unofficial client may
> conflict with Zalo's terms of service, so use it at your own risk with your own account.

## Tiếng Việt

Olaz là ứng dụng Zalo không chính thức, viết native cho macOS (giao diện SwiftUI, lõi giao thức bằng Rust qua UniFFI, một số module JS chạy trong JavaScriptCore). Dự án nghiên cứu khả năng tương tác, không liên kết với VNG; dùng với tài khoản của bạn và tự chịu rủi ro.

- Yêu cầu macOS 26 (Tahoe) trở lên. Bản phát hành là universal (Apple Silicon và Intel).
- Cài đặt: tải file DMG mới nhất ở [Releases](https://github.com/linhsayshii/olazpc-rust/releases/latest), kéo Olaz vào Applications. Bản phát hành được ký bằng chứng chỉ cố định của Olaz (giữ quyền Keychain, micro, camera qua các lần cập nhật) nhưng chưa notarize, nên lần mở đầu sẽ bị Gatekeeper chặn. Chạy `xattr -dr com.apple.quarantine /Applications/Olaz.app`, hoặc mở app một lần rồi vào System Settings → Privacy & Security → Open Anyway. Mỗi file DMG/ZIP tải mới cần làm lại bước này.
- Zalo chỉ cho một phiên PC trên mỗi tài khoản: hãy tắt Zalo PC chính thức khi dùng Olaz.
- Giấy phép GPL-3.0. Mã gốc và phần nghiên cứu giao thức do Quan Nguyen ([zalo-swift-re](https://github.com/qnguyen3/zalo-swift-re)); xem mục Credits.

## Supported platforms

| Item | Support |
|---|---|
| Operating system | macOS 26 Tahoe or later only (`LSMinimumSystemVersion` 26.0, `Package.swift` `.macOS("26.0")`). Older macOS is not supported. |
| Architectures | Release builds are universal: Apple Silicon (arm64) and Intel (x86_64). |
| Apple Silicon Macs | M1 or later: MacBook Air, MacBook Pro, Mac mini, iMac, Mac Studio, Mac Pro (2023). |
| Intel Macs | Only those that can run macOS 26: MacBook Pro 16-inch (2019), MacBook Pro 13-inch (2020, four Thunderbolt 3 ports), iMac (2020), Mac Pro (2019). Best-effort, less tested than Apple Silicon. |
| Not supported | iOS, iPadOS, Windows, Linux. |
| Zalo protocol reference | Official Zalo PC for macOS 26.10.x (`zpw_ver=694`). |
| Sessions | Zalo allows one PC session per account. Quit the official Zalo PC while using Olaz. |
| Calls | Need VNG's official Zalo runtime (downloaded automatically on first launch) and microphone/camera permissions. |
| Account | A Zalo account and the Zalo mobile app for QR login. |

## Install

1. Download the latest DMG from [GitHub Releases](https://github.com/linhsayshii/olazpc-rust/releases/latest).
2. Open it and drag **Olaz** to **Applications**.
3. Releases are signed with Olaz's own fixed certificate ("Olaz Release Signing"), so Keychain access and permissions carry over between updates, but they are not notarized by Apple. macOS blocks the first launch (right-click → Open no longer bypasses Gatekeeper since macOS 15). Either run:

   ```bash
   xattr -dr com.apple.quarantine /Applications/Olaz.app
   ```

   or open Olaz once, then go to **System Settings → Privacy & Security** and click **Open Anyway**. Repeat after each new download.

Releases list SHA-256 sums for every artifact.

## Features

- **Real QR login** (`reqqr`, long-poll scan and confirm, `getLoginInfo`, Keychain-sealed session)
- **Chat**: SQLite-backed offline history and load older, text / quotes / `@mentions`, reactions, typing, read receipts, real-time `zpw_ws` sync
- **1-1 E2EE** (Signal, Zalo's variant)
- **Composer**: `⌘V` image/file paste, photo/file chunked upload, contact card, reminders
- **Message actions**: copy, forward, recall, delete with undo, pin board, star
- **Voice / video calls**: on-demand VNG `ZaloCall`, terminated when idle
- **Contacts, groups, polls, stickers, labels, hidden chats (PIN), shared media, Cloud, native notifications**
- **Phone to Mac history sync**

## Build from source

Requirements: Xcode 26 (the full app, not only CommandLineTools: SwiftUI macros need Xcode's plugins), and Rust via [rustup](https://rustup.rs) (`rust-version` 1.88 or newer). `scripts/build-rust.sh` adds the `aarch64-apple-darwin` and `x86_64-apple-darwin` targets itself.

```bash
./scripts/build-rust.sh        # fresh checkout: builds rust/build/OlazCoreFFI.xcframework + regenerates Sources/OlazCore
swift build                    # debug build
swift test                     # Swift tests (Swift Testing)
( cd rust && cargo test )      # Rust tests
./scripts/make-app.sh debug    # bundles build/Olaz.app
open build/Olaz.app            # QR login, scan with Zalo on your phone
```

Run the bundled app, not the bare binary: the JIT entitlement is required for JavaScriptCore and the resource bundle is copied into the `.app`. Re-run `build-rust.sh` after pulling Rust changes. `./scripts/release.sh` produces a Developer ID signed and notarized build (needs a keychain profile).

Developer harness:

```bash
.build/debug/Olaz --engine-probe login 5    # live QR ticket + PNG
.build/debug/Olaz --engine-probe status 5   # validate saved Keychain session
```

Engine diagnostics: `~/Library/Application Support/Olaz/logs/engine.log` (event shapes only, never tokens or message bodies).

## CI/CD

- `.github/workflows/ci.yml` runs on every push and pull request on a `macos-26` runner: Rust build and `cargo test`, `swift build`, `swift test`.
- `.github/workflows/release.yml` runs when a tag `v*` is pushed, or manually. It builds a universal `Olaz.app`, makes a DMG and a ZIP, and publishes a GitHub Release with SHA-256 sums.

  ```bash
  git tag v1.2.0 && git push origin v1.2.0
  ```

  Signing depends on the secrets: Developer ID + notarization, the fixed self-signed "Olaz Release Signing" certificate (current), or ad-hoc.

Secrets, setup and troubleshooting: [docs/RELEASING.md](docs/RELEASING.md).

## Architecture overview

```
SwiftUI (Liquid Glass)                  Sources/Olaz/App, Shell, Views
        |  @Observable ZaloEngine       Sources/Olaz/ZaloRuntime/ZaloEngine*.swift
        v
Protocol layer (Swift)                  Sources/Olaz/ZaloRuntime/Protocol/
        |  UniFFI                       Sources/OlazCore (generated) + rust/build/OlazCoreFFI.xcframework
        v
Rust core                               rust/crates/olaz-*  (crypto, wire, ws, net, store, api, media, signal)
JavaScriptCore                          Sources/Olaz/JSBridge + JSModules (E2EE fallback, phone sync WASM)
```

Rust port status and units: [rust/MAP.md](rust/MAP.md); decisions: [rust/DECISIONS.md](rust/DECISIONS.md); wire protocol: [REVERSE-ENGINEERING-NOTES.md](REVERSE-ENGINEERING-NOTES.md).

## Credits / Origin

This repository is an independent continuation, no longer a GitHub fork, at <https://github.com/linhsayshii/olazpc-rust>.

- **Original project**: the Olaz app (name and original Swift codebase) and the original Zalo reverse-engineering work (wire protocol, QR login, `zpw_ws` framing, `ParamCipher`, signing, service-map failover; see [REVERSE-ENGINEERING-NOTES.md](REVERSE-ENGINEERING-NOTES.md)) come from [zalo-swift-re](https://github.com/qnguyen3/zalo-swift-re) by **Quan Nguyen** (GPL-3.0). The first commit of this history is his (`76eb26d`, 2026-11-07).
- **This repository**: the Rust core and later features are by linhsayshii and contributors.
- **Design inspiration**: [lebad280324/zalolite](https://github.com/lebad280324/zalolite), a lightweight native client design.
- **Signal protocol**: `rust/vendor/libsignal-protocol` is a vendored, patched copy of Signal's `libsignal` (tag v0.73.0, AGPL-3.0-only; the patch is described in its `ZALO-PATCH.md`).
- **VNG / Zalo**: no VNG files are redistributed. The official runtime (`app.asar`, `ZaloHelper.app`) is downloaded from VNG at first launch and its signature is verified. "Zalo" is a VNG trademark; Olaz is not affiliated with VNG.

See [NOTICE.md](NOTICE.md) for details.

## License

Olaz is free software under the [GNU General Public License v3.0](LICENSE).

Copyright © 2026 Quan Nguyen.
Copyright © 2026 linhsayshii and contributors.

The vendored `rust/vendor/libsignal-protocol` stays under AGPL-3.0-only. GPL-3.0 section 13 permits combining GPL-3.0 and AGPL-3.0 works.
