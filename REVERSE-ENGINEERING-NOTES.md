# Zalo for macOS — Reverse Engineering Notes

## 1. Official Zalo PC (`ZaloSetup-universal-26.10.20.dmg`)

| Fact | Value |
|---|---|
| Bundle ID | `com.vng.zalo` |
| Version | 26.10.20 (build 26.10.20.3253) |
| Runtime | **Electron 22.3.9** (Chromium 108), universal (arm64 + x64) |
| App size | 762 MB installed; `app.asar` 180 MB |
| Native Helpers | `ZaloHelper.app/Contents/MacOS/ZaloCall` (Qt/VoIP), `ZaloCap` (screenshot) |

## 2. Architecture Study: `lebad280324/zalolite`

Static analysis of `/Applications/Zalolite.app/Contents/Helpers/ctdozlite-core` (SHA-256 `69a0ff55473c16c9650bd9514fa964587f2f97c4b0112d0a66d5ca2d40e15242`, Universal arm64/x86_64):
- Links only **15 macOS system frameworks/dylibs** (AppKit, CoreGraphics, OpenGL, CoreAudio, AudioUnit, CoreVideo, Carbon, etc.) with **zero WebKit, Chromium, Node.js, or Electron helpers**.
- Uses a pure native protocol core talking directly to Zalo's Web/PC APIs (`zpw_ver=694`, `zpw_type=30` / `23`) over HTTPS + binary `zpw_ws` WebSockets + local SQLite storage.

## 3. Zalo Wire Protocol Implemented in Olaz (`Sources/Olaz/ZaloRuntime/Protocol/`)

### 3.1 Handshake & Request Signing (`ZaloCrypto.swift`, `ZaloSessionClient.swift`)
- **IMEI:** `<lowercase-uuid>-<md5(userAgent)>` (69 chars).
- **`signkey`:** `MD5("zsecure" + tag + sortedParamValuesJoined)`.
- **ParamCipher v2:** Derives 16/32-byte key + encrypts JSON payload via AES-CBC PKCS#7 Base64, URL-safe transport via `zcid`, `zcid_ext`, `enc_ver=v2`.
- **64-bit IDs:** Server `msgId`/`cliMsgId`/`globalMsgId`/`uidFrom`/`idTo` exceed `Double` integer precision (`2^53`); `JSONLossless` quotes `>= 15`-digit integers prior to `JSONSerialization`.

### 3.2 QR Authentication Flow
1. `GET https://wpa.chat.zalo.me/api/login/reqqr` (`signkey` tag `"reqqr"`) -> `token_id`, `qr_cnt`, `chk_wait_scan`, `chk_wait_cfirm`.
2. Long-poll `chk_wait_scan` (HTTP `408` = retry) -> user profile preview.
3. Long-poll `chk_wait_cfirm` (HTTP `408` / `error_code=18012` = waiting confirmation) -> `zpw_sek` cookie.
4. `GET /api/login/getLoginInfo` (`signkey` tag `"getlogininfo"`, `zpw_ver=694`, `zpw_type=30`) -> decrypt AES response for `zpw_enk`, `dkey`, `send2me_id`, `zpw_service_map_v3`, and `zpw_ws`.

### 3.3 Realtime WebSocket (`ZaloWebSocket.swift`)
- URL must include `/` before query string (`wss://ws*-msg.chat.zalo.me/?zpw_ver=694&zpw_type=30&t=<ms>`).
- Binary frame header: `u8 version | u16 LE cmd | u8 subCmd | UTF-8 JSON envelope`.
- Key commands: `1` (`AUTHEN` -> returns `cipherKey`, `ctrl_qCmds`, `qCmds`), `2`/`4` (ping keep-alive every 15s), `501` / `521` (1-1 / group push), `510` / `511` / `513..518` (pull queues, paginated via `more == 1`), `533` -> `570` (`GET_MSG`), `601..604` (control/typing/seen/VoIP).
- Payload encryption (`encrypt`): `0` = plain JSON, `1` = AES-GCM-16 (`iv(16)|aad(16)|ct||tag(16)`), `2`/`3` = AES-GCM-16 + gzip/zlib inflate (after URL percent-decode + Base64 decode).

### 3.4 Multi-Host Failover (`ZaloDomains.swift`)
- Routes per logical service (`chat`, `group`, `friend`, `profile`, `file`, `sticker`, `reaction`, `conversation`, `group_board`, `group_poll`, `group_cloud_message`, `alias`) across `SERVICE_MAP_V3` candidates; promotes winning host and fails over only on HTTP `404`/`5xx` or network errors (never on `ZaloSessionError`).

### 3.5 On-Demand Native Call Helper (`CallBridge.swift`, `ZaloEngine+CallHook.swift`)
- VNG's signed `ZaloCall` (`ZaloHelper.app`) communicates over encrypted UNIX domain sockets (`AES-128-CBC` `$`-framed chunks).
- Olaz launches `ZaloCall` **only** when placing or receiving a call and calls `reset()` to terminate it as soon as `callState` returns to `"free"`.
