# Zalo PC Bump Research: `26.10.20` (`zpw_ver 694`) → `26.11.20` (`zpw_ver 698`)

> [!WARNING]
> **Release age (`< 1 day`):** VNG published `26.11.20` on `2026-11-27 16:08` (< 24 hours before this analysis). Per the bump ticket rule, do not adopt it without coordinator/user sign-off because VNG occasionally pulls fresh builds; intermediate build `26.11.10` (`zpw_ver 695`) is also documented below for attribution and as a fallback target.

## Builds Compared

| Build | Source | `CFBundleVersion` | `getClientVersion` | Electron / Chromium | `DEACTIVATE_E2EE_GROUP` |
| --- | --- | --- | --- | --- | --- |
| `26.10.20` (pinned) | `~/Library/Application Support/Olaz/ZaloRuntime/current/Contents/Resources/app.asar` | `26.10.20.3253` | `694` | `22.3.9` / `108.0.5359.215` | 4/4 (`!0`) |
| `26.11.10` (intermediate) | `/Applications/Zalo.app/Contents/Resources/app.asar` | `26.11.10.3400` | `695` | `22.3.9` / `108.0.5359.215` | 4/4 (`!0`) |
| `26.11.20` (target DMG) | `ZaloSetup-universal-26.11.20.dmg` (SHA-256 `718d5093a458721dfb0a6d46461eb02058fc239d4890c99a6902455b2d968f36`, VNG team `CVB6BX97VM`) | `26.11.20.3672` | `698` | **`43.8.7` / `150.0.7871.250`** | 2/2 (`!0`) |

## Risk Summary & User-Decision Items

Sorted from highest to lowest risk to Olaz:

1. **HIGH (latent / server-gated) — New `ZaloAttest` / `z-attest` subsystem (`26.11.20` only):**
   - VNG added native daemon `Contents/MacOS/ZaloAttest` (25,730,832 bytes) + native addon `app.asar.unpacked/native/nativelibs/z-attest/`.
   - `getLoginInfo` now calls `await Object(W.a)(u)` before encrypting params. While server flag `z_attest_enforce` defaults to `!1` (`false`), it only fires background QoS telemetry and leaves `u` untouched. **If VNG flips `z_attest_enforce = true`**, `getLoginInfo` will require `u.app_attest` (or report `u.app_attest_err`), which Olaz cannot satisfy without spawning/integrating VNG's `ZaloAttest` daemon.
2. **MEDIUM — Major Electron/Chromium jump (`22.3.9` / Chrome `108` → `43.8.7` / Chrome `150`, `26.11.20` only):**
   - Affects `olaz-client/src/headers.rs` (PR #27) `sec-ch-ua` header (`Chromium";v="108"` → `Chromium";v="150"` and updated GREASE brand `"Not;A=Brand";v="8"`).
   - Also adds Chromium-150 TLS/HTTP fingerprint shift expectations, though `User-Agent` format (`ZaloPC-darwin-23v698`) and `MAC_CLIENT_TYPE` (`23`) did not change.
3. **LOW — `libzproto_wasm_bg` recompile (`26.11.10`, unchanged in `26.11.20`):**
   - WASM file hash changed (`ecc0555ba9d0f8867a4699ce943ec745` → `5ea0fb2c9af4a45bc7882b71307b6f83`). Import/export index order shifted, but the exact sets of 39 imports and 41 exports are identical; zero missing imports in `Sources/Olaz/JSModules/zalo-zproto-sync.js`.
4. **LOW — `libsignal-protocol.static.js` re-minified (`26.11.20` only):**
   - File size `629,683` → `629,444` bytes (different Babel/Terser wrapper output), `libsignal.VERSION = 2` and all 15 `libsignal.*` exports unchanged. Note that Olaz currently loads its own vendored `Sources/Olaz/JSModules/vendor/libsignal-protocol.js` (630,285 bytes).
5. **NONE / COMPATIBLE — All 172 Olaz HTTP/API endpoints, `zsecureSecrets`, WebSocket framing/commands, `ZaloCall` IPC (`zcall-v2`), `DEACTIVATE_E2EE_GROUP`, emoji map, and built-in stickers:**
   - Zero wire protocol changes on Olaz endpoints, WS commands, AES keys, or `ZaloCall` socket framing.

### User Decisions Needed

- **Target build choice:** Proceed with `26.11.20` (`698`, `< 1 day` old, includes Chrome 150 + dormant `ZaloAttest`) or hold / target `26.11.10` (`695`, Chrome 108, no `ZaloAttest`)?
- **`sec-ch-ua` for Chrome 150 (if `26.11.20`):** Approve updating `olaz-client/src/headers.rs` (on #27) to `"\"Not;A=Brand\";v=\"8\", \"Chromium\";v=\"150\""`.
- **`ZaloAttest` posture:** Confirm whether Olaz ignores `ZaloAttest` while `z_attest_enforce == false` (current behavior) and logs if `getServerInfo` ever returns `features.attest.z_attest_enforce = true`.

---

## Detailed Findings (Ticket Items 1–7)

### 1. Identity, Headers, Chromium Version, and `ZaloAttest`

#### Identity & Headers
- `getClientVersion()` in `main-dist/main.js` module `iqBP`:
  - `26.10.20`: `main-dist/main.js@2667524` → `694` (`pc-dist` `apiVersion:694` at `@6815090`)
  - `26.11.10`: `main-dist/main.js@2681828` → `695` (`pc-dist` `apiVersion:695` at `@6976947`)
  - `26.11.20`: `main-dist/main.js@3273954` → **`698`** (`pc-dist` `apiVersion:698` at `@6986233`)
- `MAC_CLIENT_TYPE`: unchanged **`23`** (`iqBP@3273954`).
- `User-Agent`: unchanged template (`getName` + `process.platform` + `getClientType()` + `"v"` + `getClientVersion()`, `main-dist/main.js@259137` in `26.11.20`, `ua@3306844`) → **`ZaloPC-darwin-23v698`**.
- `onBeforeSendHeaders`: absent in `main-dist/main.js` across all 3 builds (headers come directly from Electron/Chromium).
- **Electron / Chromium version (`26.11.20` only):** `Electron Framework` strings confirm `Chrome/150.0.7871.250 Electron/43.8.7` (up from `Chrome/108.0.5359.215 Electron/22.3.9`).
  - Chromium's deterministic GREASE function `GetGreasedUserAgentBrandVersion(seed = 150)` (`greasey_chars = " (:-./);=?_"`, `greased_versions = ["8", "99", "24"]`) evaluates `150 % 11 = 7` (`';'`), `151 % 11 = 8` (`'='`), `150 % 3 = 0` (`"8"`), `150 % 2 = 0` (same 2-brand order as 108):
    - `26.10.20` (Chrome 108): `"Not?A_Brand";v="8", "Chromium";v="108"`
    - `26.11.20` (Chrome 150): `"Not;A=Brand";v="8", "Chromium";v="150"`

#### New `ZaloAttest` / `z-attest` Subsystem (`26.11.20` only)
- **Native artifacts:** `Zalo.app/Contents/MacOS/ZaloAttest` (25,730,832 bytes; absent in `26.11.10`) + unpacked addon `app.asar.unpacked/native/nativelibs/z-attest/index.js` + `darwin_{arm64,x64}/z_attest.node`.
- **Main-process IPC/launcher (`main-dist/main.js`):** modules around `@4747296`–`@4782976` (`z-attest-logger`, `ZPC_ATTESTD`, `z-attest-daemon-launcher`, `z-attest-native`, `z-attest-state-store`, `z-attest-daemon-reporter`, `z-attestd auth v1 daemon/client`).
- **Renderer (`pc-dist/lazy/default-login-main-startup-shared-worker.459bb6df1994a71d701b.js`):**
  - Config module `"5px/"` (`@2738088`, mirrored in `compact-app-pc@2970158`): defines `z_attest_enable` (default `!0`), `z_attest_enable_on_login` (default `!0`), **`z_attest_enforce` (default `!1`)**, `z_attest_enable_qos` (default `!0`).
  - `getServerInfo` reader (`bKKq` / settings store around `@11273210`, `login-startup.6f46af623c5aca11a149.js@449243`) reads `settings.features.attest` / `authentication.attest`.
  - Attestation helper `W` (`@2973065` / `@12332731`): injects `app_attest` or `app_attest_err` when `z_attest_enforce` is truthy; otherwise runs non-blocking QoS check only and does not alter params.
  - **`getLoginInfo` call site (`@12332731`):** invokes `W.a(u)` asynchronously immediately before `encryptParam(u, "getlogininfo")`.
  - **Companion linking (`login-startup.6f46af623c5aca11a149.js@15810`):** imports `"378F"` (main bundle `@1814529`) and invokes it during linking proof (QoS-only, non-blocking).

---

### 2. HTTP Endpoints, Encryption, and Request/Response Shapes

#### Secrets & Crypto Primitives
- **`zsecureSecrets` (module `bhjE`):** all 13 keys/values (`callV2TransportAesKey`, `paramCipherKey`, `passwordCipherKey`, `genServicesDecodeAesKey`, `genServicesDecryptAesKey`, `key`, `iv`, etc.) are **100% identical** across `26.10.20`, `26.11.10`, and `26.11.20`.
- **`getSignKey` & `ParamCipher` (`encryptParam` / `decryptResp`):** unchanged.

#### Endpoint Coverage (172 endpoints across `olaz-api`, `olaz-net`, `olaz-media`, and Swift `ZaloAPIService*`)
An automated AST/token scan (`diff_all_endpoints2.py`) across `pc-dist/` checked all 172 unique endpoints extracted from `rust/crates/olaz-api`, `rust/crates/olaz-net`, `rust/crates/olaz-media`, and `Sources/Olaz/ZaloRuntime/Protocol/ZaloAPIService*.swift`:

- **154 endpoints:** identical path, `commandId`, HTTP method, encryption wrapper (`_get`/`_post`/`encodeAES`), request keys, and response handling.
- **1 endpoint not in ASAR routing tables (by design):**
  - `/api/emoticon/pcweb/getAllCate` — Olaz's hardcoded fallback `DEFAULT_CATALOG_URL` (`rust/crates/olaz-api/src/stickers.rs:18`, `ZaloAPIService.swift:1279`) when `getStickerCategories` omits `dataUrlStr`; absent from both `26.10.20` and `26.11.20` JS bundles (`_getAllCates()` uses `getStickerCategories` dynamically).
- **17 remaining hits inspected manually (15 noise/refactor-only, 1 real diff + 1 shared helper):**
  1. **`/api/login/getLoginInfo` (`cmd 11134`, `26.10.20@2644311`/`@12137171` → `26.11.20@2826014`/`@12332731`) — BEHAVIOR DIFF (gated):**
     - Switched domain getter `i.default.authDomain` → `_.b.getAuthDomain()` (same domain).
     - Added `await Object(W.a)(u)` prior to `encryptParam(u, "getlogininfo")` (no-op unless `z_attest_enforce` becomes `true`, in which case `app_attest` / `app_attest_err` is added inside `u`).
  2. **`/api/login/reqqr` (`cmd 11133`, `26.10.20@2644005`/`@12133148` → `26.11.20@2825708`/`@12328718`) & `/api/setting/update` (`cmd 12033`, `@2825916`):**
     - Only `_.b.getAuthDomain()` helper refactor in `reqqr`; payload `{language, client_time, imei, computer_name, logged_uids, self_g, qr_form}` and response handling unchanged.
  3. **Adjacent/noise hits with zero request/response changes (14 endpoints):**
     - `/api/alias/list`, `/api/board/topic/createv2`, `/api/group/asyncfile/msg`, `/api/group/forward`, `/api/group/photo_original/send`, `/api/message/asyncfile/msg`, `/api/message/forward`, `/api/message/photo`, `/api/message/photo_original/send` — only ZLogger symbol IDs (`zsymb`) and Terser arrow-vs-function formatting changed.
     - `/api/emoticon/sticker/webpc` (`eid=20695` game icon), `/api/friendboard/multi_unpin`, `/api/voicecall/group/sharescreen`, `/cloudmedia/info/pc/v1/family-usage`, `/zalocloud/cloudinfopcweb/v1/info` — diff window touched unrelated neighboring code/constants; handler logic and routing entries unchanged.
- **`/api/e2ee/pc/*` (31 routes in routing table at `@2807366`, 14 call sites at `@12351979`–`@12433317`):** normalized AST diff of all 31 routing entries and all 14 call sites showed **zero changes** between `26.10.20` and `26.11.20`.

<details>
<summary>Full inventory of 172 Olaz endpoints verified across Rust &amp; Swift (grouped by domain)</summary>

- **Auth / Profile / Settings (8):** `/api/login/getServerInfo`, `/api/login/reqqr`, `/api/login/getLoginInfo`, `/api/social/profile/me-v2`, `/api/social/profile/getmute`, `/api/social/profile/setmute`, `/api/social/profile/reportabuse`, `/api/setting/me`, `/api/setting/update`
- **Conversations & Sync (18):** `/api/archivedchat/list`, `/api/archivedchat/update`, `/api/conv/addUnreadMark`, `/api/conv/removeUnreadMark`, `/api/conv/autodelete/getConvers`, `/api/conv/autodelete/updateConvers`, `/api/convlabel/get`, `/api/convlabel/update`, `/api/hiddenconvers/add-remove`, `/api/hiddenconvers/get-all`, `/api/hiddenconvers/reset`, `/api/hiddenconvers/update-pin`, `/api/pinconvers/list`, `/api/pinconvers/updatev2`, `/api/preloadconvers/get-last-msgs`, `/api/cm/getoldv2`, `/api/cm/getrecentv2`, `/api/cm/mget`
- **Friends & Aliases (13):** `/api/alias/list`, `/api/alias/remove`, `/api/alias/update`, `/api/friend/accept`, `/api/friend/block`, `/api/friend/blocklistv2`, `/api/friend/profile/get`, `/api/friend/recommendsv2/list`, `/api/friend/reject`, `/api/friend/requested/list`, `/api/friend/sendreq`, `/api/friend/unblock`, `/api/friend/undo`, `/api/social/friend/getfriends`, `/api/social/friend/getprofiles/v2`
- **Groups, Board, Polls & Quick Messages (42):** `/api/board/oneone/create`, `/api/board/pin/list`, `/api/board/pinv2`, `/api/board/unpinv2`, `/api/board/topic/createv2`, `/api/board/topic/getReminder`, `/api/board/topic/listResponseEvent`, `/api/board/topic/updateEventResponse`, `/api/friendboard/multi_unpin`, `/api/group/create/v2`, `/api/group/disperse`, `/api/group/getlg/v4`, `/api/group/getmg-v2`, `/api/group/invite/v2`, `/api/group/kickout`, `/api/group/leave`, `/api/group/link/detail`, `/api/group/link/disable`, `/api/group/link/join`, `/api/group/link/new`, `/api/group/pending-mems/list`, `/api/group/pending-mems/review`, `/api/group/setting/update`, `/api/group/upavatar`, `/api/group/updateinfo`, `/api/social/group/members`, `/api/poll/create`, `/api/poll/detail`, `/api/poll/end`, `/api/poll/option/add`, `/api/poll/share`, `/api/poll/vote`, `/api/quickmessage/create`, `/api/quickmessage/delete`, `/api/quickmessage/list`, `/api/quickmessage/update` (plus group admin/settings variants in `ZaloAPIService+GroupAdmin.swift` / `ZaloAPIService+GroupMgmt.swift`)
- **Messaging, Media, Stickers, GIFs & Cloud (47):** `/api/message/*` (`sms`, `quote`, `reaction`, `mention`, `contact`, `typing`, `seenv2`, `undo`, `deletemsg`, `delete`, `deleteconver`, `forward`, `photo`, `photo_original/upload`, `photo_original/send`, `asyncfile/upload`, `asyncfile/msg`, `sharefile_full`, `video/thumb/upload`, `video/file/upload`, `gif`, `giphy/search`, `giphy/trending`, `sticker`, `sticker/category/list/v2`, `sticker/category/sticker_detail`, `sticker/search`, `sticker/suggest/stickers`), `/api/group/*` matching messaging/media/sticker/gif equivalents, `/api/emoticon/pcweb/getAllCate` (fallback), `/api/emoticon/sticker/webpc`, `/cloudmedia/info/pc/v1/cloud-settings`, `/cloudmedia/info/pc/v1/family-usage`, `/cloudmedia/info/pc/v1/usage-mycloud`, `/cloudmedia/info/pc/v2/usage`, `/zalocloud/cloudinfopcweb/v1/info`
- **E2EE 1-1 & Group (`e2ee/pc/*`):** `/api/e2ee/pc/message/{endpoint}` (incl. `undo`), `/api/e2ee/pc/group/{endpoint}` (incl. `undoMsg`), `/api/e2ee/pc/message/file`
- **Voice/Video Calls & Noise (28):** `/api/voicecall/*`, `/api/voicecall/group/*`, `/api/znoise`

</details>

---

### 3. WebSocket & E2EE 1-1 Signal Flow

- **WebSocket commands (`26.10.20@7423868` → `26.11.20@7611941`) & `SignalCommands` (`@3196150` → `@3397280`):** **100% identical** (same command IDs `1`, `2`, `4`, `501`–`800`, `3000`, and Signal commands `514`–`519`, `535`, `540`–`582`).
- **Frame header & heartbeat:** 4-byte `_getHeader` (`u8 version | u16 LE cmd | u8 subCmd`) and 15s `pingInterval` are unchanged.
- **`encryptSendMsg` (`26.10.20@5215633` → `26.11.20@5416767`):** only ZLogger tag hashes changed; Signal payload assembly unchanged.
- **`pc-dist/libs/libsignal-protocol.static.js`:**
  - `26.10.20` & `26.11.10`: 629,683 bytes, SHA-256 `a53709c414c63eb2303859574d9fb1d2d082f746e6f76f9f51c7241f2402dec4`
  - `26.11.20`: 629,444 bytes, SHA-256 `85f96ace88fcd21a06a63a041370293577e4ca3a09905acca8b99d9e0708f8a0`
  - `libsignal.VERSION = 2` and all 15 `libsignal.*` exports match across `26.10.20`, `26.11.20`, and Olaz's vendored `Sources/Olaz/JSModules/vendor/libsignal-protocol.js` (630,285 bytes, SHA-256 `888ead4c1a8b2377...`). No changes required to `Sources/Olaz/JSModules/zalo-e2ee.js` or `ZaloE2EEManager.swift`.

---

### 4. `ZaloHelper.app` / `ZaloCall` (`zcall-v2`)

- **`ZaloHelper.app/Contents/Info.plist`:** identical keys (`CFBundleShortVersionString` / `CFBundleVersion` remain absent in all 3 builds); only `ElectronAsarIntegrity` changed.
- **Binaries recompiled (`ZaloCall` / `ZaloCap`):**
  - `ZaloCall` SHA-256: `f1ac81228f235e92...` (`26.10.20`) → `ad1c7b44ab149c9f...` (`26.11.10`) → `dd0990088cd060c8...` (`26.11.20`).
  - Note: `native/nativelibs/zcall/` (unused by Olaz) was removed from `26.11.20`'s `app.asar`; `ZaloHelper.app/Contents/MacOS/{ZaloCall,ZaloCap}` remains intact.
- **`zcall-v2` 2-socket IPC (`CallBridge.swift`, `CallTransport.swift`):**
  - `main-dist/main.js` (`26.10.20@312600`–`@314471` → `26.11.20@469300`–`@472911`) still spawns `ZaloCall` with `[recvSocket, sendSocket]` (`r(e,[v,y])`), encrypts/decrypts with `callV2TransportAesKey` (unchanged in `bhjE`), chunks with `$`, and routes identical JSON `type`/`command` values (`update`, `sendSignal`, `request`, `response`, `native-ready`, `killMe`, `callState`, `call-update`, `call-send-signal`, `call-request`, `call-response-*`).
  - All 16 protocol string literals present in `ZaloCall` binary (`callState`, `command`, `content`, `data`, `free`, `header`, `killMe`, `popup`, `recv`, `request`, `response`, `sendSignal`, `state`, `type`, `undefined`, `update`) remain present in `26.11.20`.

---

### 5. Phone Sync WASM (`AsarWasmReader` / `ZaloPhoneSync.swift`)

- **WASM binary (`pc-dist/libs/libzproto_wasm_bg.*.wasm`):**
  - `26.10.20`: `libzproto_wasm_bg.ecc0555ba9d0f8867a4699ce943ec745.wasm` (SHA-256 `3a868037a32739a4fcb3c22425150745613006f9dbc561f30fd705effaed55fa`)
  - `26.11.10` & `26.11.20` (byte-identical): `libzproto_wasm_bg.5ea0fb2c9af4a45bc7882b71307b6f83.wasm` (SHA-256 `398a2016ede72d1e604a6ac13bc7c62f2c44a43f0c1d7b996e968427380fc739`)
- **Imports & exports:** 39 imports and 41 exports (`zprotoSync2*`, `zprotoEd25519*`, `zprotosync*`, `zprotoed25519*`, `zprotoLoggerInitialize`, `__wbg_*`, `__wbindgen_*`, `memory`). Ordering shifted slightly, but `set(imports_10) ^ set(imports_20)` and `set(exports_10) ^ set(exports_20)` are both empty.
- **Olaz JS glue (`Sources/Olaz/JSModules/zalo-zproto-sync.js`):** all 39 WASM imports are present (`missing = []`). Note `AsarWasmReader` caches the WASM at `ZaloRuntime/libzproto_wasm_bg.wasm` during `ZaloRuntimeInstaller.stage`.

---

### 6. `DEACTIVATE_E2EE_GROUP` (U17 Backlog Rule)

All occurrences in `app.asar` remain `!0` (group E2EE stays disabled):
- `26.10.20`: 4 hits (`@54851520`, `@102679424`, `@133078287`, `@154757724`) — all `DEACTIVATE_E2EE_GROUP:!0`
- `26.11.10`: 4 hits (`@55083138`, `@103750517`, `@134984768`, `@157442841`) — all `DEACTIVATE_E2EE_GROUP:!0`
- `26.11.20`: 2 hits (`@66386474`, `@117498832`) — all `DEACTIVATE_E2EE_GROUP:!0` (chunk consolidation reduced duplicate copies from 4 to 2)

`U17` remains closed/backlogged.

---

### 7. Emoji Map & Built-In Stickers (`Emoticon.swift`, `olaz-api/src/stickers.rs`)

- **Emoji dictionaries (`pc-dist/lazy/default-login-main-startup-shared-worker*.js` & `main-dist/preload-sqlite.js`):**
  - `owK0` (`emojiMapPos`, 2,735 entries): `26.10.20@14180733` == `26.11.20@14477349` (parsed JSON 100% identical; string length grew only from `\xNN`/`\uXXXX` escaping in Terser output). All 89 shortcuts in `Sources/Olaz/Shell/Emoticon.swift` match `owK0`.
  - `l/2e` (`emojiData`, 1,636 entries): `@13565302` == `@13780447` (100% identical).
  - `sEKx` (`emojiDataInvert`, 1,636 entries): `@14690021` == `@15018824` (100% identical).
  - `tDit` (`emojiRC`, 2,735 entries): `@14963336` == `@15318225` (100% identical).
- **`xp5P` parser (`26.10.20@16038873` → `26.11.20@16419655`):**
  - `_valid` gained an extra `enable_emoji_mac_web_inputbox` guard alongside `disableSingleCharEmoji`. Since `Emoticon.swift` already treats `disableSingleCharEmoji = false`, behavior is identical.
- **Built-in `"Củ hành"` stickers (`vSga` + `ynGT` + `built_in_sticker`):**
  - `_builtInCate` (`26.10.20@15610053` → `26.11.20@15979991`), `ynGT` (`@16264069` → `@16646885`: `id=0`, `totalImage=30`, `version=2`), and `built_in_sticker.icon_url` (`@6797247` → `@6968045`) are **100% unchanged** (`rust/crates/olaz-api/src/stickers.rs`).

---

## Step 2 Implementation Checklist (When Approved, After PR #27)

1. Update `ZaloRuntime.pinned` in `Sources/Olaz/ZaloRuntime/ZaloRuntimeInstaller.swift` (`version: "26.11.20"`, URL `https://res-download-pc.zadn.vn/mac/ZaloSetup-universal-26.11.20.dmg`, SHA-256 `718d5093a458721dfb0a6d46461eb02058fc239d4890c99a6902455b2d968f36`).
2. Update unified identity in `olaz-client` (from #27):
   - `CLIENT_VERSION = "698"`, `USER_AGENT = "ZaloPC-darwin-23v698"`
   - `sec-ch-ua` = `"\"Not;A=Brand\";v=\"8\", \"Chromium\";v=\"150\""`
3. Deduplicate/align remaining `694` copies:
   - `Sources/Olaz/ZaloRuntime/ZaloPlatform.swift` (`clientVersion`)
   - `Sources/Olaz/ZaloRuntime/ZaloEngine.swift` & `ZaloEngine+Core.swift` (`"698 (Native)"`)
   - `Sources/Olaz/ZaloRuntime/Protocol/ZaloDomains.swift` (`zpwVer`, `userAgent`)
   - `Sources/Olaz/ZaloRuntime/PinnedHTTPSClient.swift` (`userAgent`)
   - `Sources/Olaz/Shell/Emoticon.swift` (comment `zpw_ver 698`)
   - `rust/crates/olaz-ws/src/consts.rs` (`ZPW_VER`, `USER_AGENT`) & `rust/crates/olaz-media/src/net.rs` (`USER_AGENT`)
   - Update unit test expectations (`olaz-api`, `olaz-ws`, `olaz-net`, `olaz-crypto`) and re-record affected cases (`zpw_ver` in URLs).
4. Run `scripts/check-client-version.py` (#27) and `scripts/check-e2ee-group-flag.py` against the `26.11.20` `app.asar`.
