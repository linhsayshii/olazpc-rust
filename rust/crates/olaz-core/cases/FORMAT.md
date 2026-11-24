# Case format v1

Shared contract between the Swift recorder (U1a, Hydrogen) and the Rust replay runner (U1b, Neon). Copy it into the repo as `rust/crates/olaz-core/cases/FORMAT.md`; the repo copy becomes the source of truth once U1a merges. Change it only through Claude.

The oracle is what can be observed from outside the engine: the domain state the views read, the requests that reach the server, and the activities the engine hands to code it does not own yet. Neither side's internals appear in a case.

## Files

- `rust/crates/olaz-core/cases/<domain>.jsonl`: one case per line, sorted by `name`. Domains: `session`, `transport`.
- `rust/crates/olaz-core/cases/known-diffs.jsonl`: intended differences, one line `{"domain", "name", "path", "actual", "reason"}` each. Only lines the user approved. A line whose case no longer differs fails the runner.
- Data is synthetic. Never content from a real account, never a real token.

## A case

```json
{
  "format": 1,
  "domain": "session",
  "name": "boot_saved_session_valid",
  "seed": { "saved_session": {}, "domains": {}, "legacy_cookie": null, "prefs": {} },
  "server": [],
  "steps": [],
  "expect": { "snapshots": {}, "final": {}, "requests": [], "host": [] }
}
```

- `"slow": true` *(optional)*: test-runner metadata marking cases that exercise a real wall-clock timeout (such as `qr_timeout`). It is not domain behavior. Default Swift recorder runs skip slow cases unless `OLAZ_SLOW_CASES=1` (printing `skipped slow: <name>`); `OLAZ_RECORD=1` and `scripts/gate-core.sh` always run every case.

### seed

- `saved_session`: `null`, or the `StoredNativeSession` JSON that `ZaloSessionClient.saveSession()` writes with `useKeychain: false` (`plainAccount` set, `sealedSecretsBase64` null). Its `domains` point every service at the fake server. The recorder writes it to `sessionFileURL`; the Rust runner hands it to the core through the fake host's `load_saved_session`.
- `domains`: the service map used when no session is saved (QR login), pointing every service at the fake server. The fake server's port is not stable, so cases store the host as `"http://fake"`; both sides substitute the real `http://127.0.0.1:<port>` when they run. Every case sets `"isolated": true` so neither side ever fails over to live Zalo hosts.
- `legacy_cookie`: `null`, or what `tryRestoreLegacyCookieSession` reads.
- `prefs`: store preference strings present before the run.
- `poll_state` *(optional, `transport` domain)*: `null`, or `ZaloPollState` / `PollState` camelCase JSON (`{"lastActionId": "...", "lastActionIdOther": "...", "queues": {"1": {"lastId": "...", "ids": []}, ...}}`) seeded before long-polling starts.
- `ws_cursors` *(optional, `transport` domain)*: `null`, or a map of `"<cmd>_<subCmd>"` to `{"lastId": "...", "preIds": [...]}` (`ZaloWSQueueCursorSnapshot` / `WsQueueCursorSnapshot`) seeded before WebSocket connects.
- `suppress` *(optional, runner metadata, `transport` domain)*: array of transport names (`"ws"`, `"long_poll"`, or both) to suppress during the run. Both the recorder's `hostTrace` and the Rust replay obey it: `start_ws` / `start_long_poll` are still traced, `hostTrace` returns `false` for listed transports, a suppressed WS never connects, and a suppressed long-poll never ticks.

### server

Scripted answers, in the order they are consumed. Each request takes the first unconsumed entry with the same `kind` and `path` (entries with `"repeat": true` are never consumed).

- HTTP: `{"kind": "http", "path": "/api/...", "method": "GET|POST", "response": {"status": 200, "json": {...}}}`. `json` is the plain body; the fake server encrypts it the way Zalo does for that endpoint (including ParamCipher endpoints and AES-CBC `data` encryption with `zpw_enk` for `/api/social/profile/me-v2` and long-poll `/`). Instead of `json`: `"raw": "<text>"`, or `"error": "timeout" | "refused" | "reset"`.
- WebSocket: `{"kind": "ws", "path": "...", "accept": true}`.
- WebSocket server frames (`ws_frame`): `{"kind": "ws_frame", "cmd": <int>, "sub_cmd": <int>, "payload": {...}}` (optional `"encrypt": <0|1|2|3>`, optional `"key": "<base64>"`, optional `"delay_ms": <int>`). Only the initial auth reply (`cmd == 1` immediately following a `"ws"` entry) is sent automatically when that WebSocket connects; every subsequent `ws_frame` waits for a `ws_push` step and is sent in script order on the active connection. `payload` is the plain JSON body; the fake server encodes it as Zalo and `olaz-ws` expect for that `cmd` inside an RFC 6455 binary frame (`u8 version(1) | u16 LE cmd | u8 sub_cmd | UTF-8 JSON envelope`): `cmd == 1` defaults to `encrypt: 0` with a base64 `"key"` and JSON-stringified `"data"`, `cmd == 602` defaults to `encrypt: 0` with JSON-stringified `"data"`, and other `cmd`s default to `encrypt: 2` (AES-GCM 16-byte nonce + zlib when the connection established a cipher key on `cmd == 1`) or `encrypt: 1` (zlib) unless `"encrypt"` is explicitly given.
- WebSocket server drop (`ws_close`): `{"kind": "ws_close"}` (optional `"delay_ms": <int>`). Sends an RFC 6455 Close frame (`1000`) and closes the socket when triggered by a `ws_push` step (used to trigger disconnect/reconnect such as `ws_auth_watch`).
- A request with no matching entry is answered `{"error_code": 0, "data": {}}` and recorded with `"unscripted": true`. A case with an unscripted request is a recorder bug.

### steps

Run in order:

- `{"cmd": "start" | "refresh_qr" | "log_out" | "session_expired" | "drain_chat_polling", "args": {...}}`.
  - `session_expired` takes `{"reason": "<text>"}`.
  - `drain_chat_polling` (`transport` domain) calls `drainChatPolling(maxBatches, notifyIncoming)` with `{"max_batches": <int>, "notify_incoming": <bool>}`.
- `{"await": {"phase": "<kind>", "step": "<login step, optional>"}, "timeout_ms": 5000}`: wait until the state matches. The Rust runner instead runs the core until no input or effect is pending, then checks the same predicate.
- `{"await_host": "<call>", "timeout_ms": N}`: wait until the recorded `host` list contains `"<call>"` searching from the current host cursor, then advance the host cursor past that entry (`index + 1`). Used for deterministic ordering (for example awaiting `e2ee_connected` before `ws_push`).
- `{"ws_push": k}` (optional `"timeout_ms": N`): instruct the fake server to send the next `k` scripted `ws_frame` or `ws_close` entries in script order.
- `{"snapshot": "<label>"}`: record the state under `expect.snapshots[label]`.

### expect

- `snapshots`: label to state, as taken at each `snapshot` step.
- `final`: state after the last step, once nothing is pending.
- `requests`: every request that reached the fake server, canonical form, as a **sorted multiset** (sort by `kind`, then `path`, then the canonical JSON text). Concurrent requests have no stable order, so order is not compared.
  - HTTP: `{"kind": "http", "path", "method", "params": {...} | null, "query": {...}}`. `params` is the decrypted ParamCipher payload, keys sorted (`null` when absent or for unencrypted endpoints such as long-poll `GET /`). `query` is the plain query string, keys sorted. Signatures, encrypted blobs and the keys listed under Volatile become `"<volatile>"`.
  - WebSocket connect: `{"kind": "ws_connect", "path", "query": {...}}`.
  - WebSocket client→server frames (`ws_send`): `{"kind": "ws_send", "cmd": <int>, "sub_cmd": <int>, "payload": {...} | "<binary>"}`. `payload` is the decoded JSON body after the 4-byte binary header (`u8 version | u16 LE cmd | u8 sub_cmd`, `{}` when empty, `"<binary>"` when undecodable as UTF-8 JSON). Keepalive pings (`cmd == 2` and `cmd == 4`) are excluded because their count depends on wall time.
- `host`: ordered list of activities handed to Swift-owned code, `{"call": "<name>", "args": {...}}`. While recording, the engine's trace hook records these and skips the real activity (except where a lifecycle hook in `transport` cases must permit WS/long-poll startup so the transport runs under test).
  - Session domain names: `prepare_store {user_id}`, `start_ws {endpoints}`, `start_long_poll {}`, `start_bootstrap {}`, `offer_first_login_transfer {force}`, `reset_domains {}`, `persist_session {}`, `clear_session {}`, `mark_expired {}`.
  - Transport domain names:
    - `apply_batch {cmd, increment_unread, notify_incoming, payload}` *(`cmd` is an integer on the WS path and `null` on the long-poll path)*
    - `apply_parsed_events {cmd, increment_unread, notify_incoming, events}`
    - `mobile_sync {events}`
    - `e2ee_signal {cmd, payload}`
    - `e2ee_deliver_reports {cmd, payload}`
    - `e2ee_connected {uid}`
    - `e2ee_disconnected {}`
    - `voip_control {act, raw_data, data}`
    - `show_typing {conv_id, uid, on_pc}` *(traced at the call site with `uid`, before name lookup)*
    - `pin_topic {conv_id}`
    - `group_notice {act, data, ts}`
    - `mute {conv_id, set, start, duration}`
    - `load_transport_state {}`
    - `persist_poll_state {state}`
    - `persist_ws_cursors {cursors}`

## Session domain state

```json
{
  "phase": {"kind": "starting"}
         | {"kind": "login", "step": "generating" | "waiting_scan" | "waiting_confirm" | "expired" | "failed",
            "qr": "<QR payload string or null>", "name": "<only waiting_confirm>", "avatar": "<only waiting_confirm, or null>",
            "message": "<only failed>"}
         | {"kind": "signing_in"}
         | {"kind": "ready"},
  "profile": null | {"user_id": "", "display_name": "", "avatar": null, "phone": null},
  "sign_out_notice": null,
  "self_conversation_id": null,
  "prefs": {"didOfferInitialSync": "0"}
}
```

- `qr` is the QR payload the PNG is rendered from, never PNG bytes.
- `prefs` holds only the keys this domain writes.
- Optional keys are left out when they do not apply, never written as `null`, except where the schema shows `null`.

## Volatile

Replaced by `"<volatile>"` before comparing: `imei`, `client_time`, `ts`, `signkey`, `zpw_ver`-independent nonces, ParamCipher IVs, cookies, anything derived from the wall clock or a random source. The recorder documents each key it adds to this list in the repo copy, with the reason. Never mark a key volatile to make a mismatch go away.

Keys marked `"<volatile>"` by the recorder:

| Location | Key | Reason |
|---|---|---|
| `query`, `params` | `imei` | Generated per-install random UUID (`ZaloSessionClient.generateIMEI()`) persisted in `UserDefaults` |
| `query`, `params` | `computer_name` | Derived from `Host.current().localizedName` when unseeded (differs across local Macs and CI runners) |
| `query`, `params` | `client_time` | Wall-clock epoch seconds at `requestQR` time |
| `query`, `params` | `ts` | Wall-clock epoch milliseconds at `getLoginInfo` time (and epoch seconds on long-poll `GET /`) |
| `query` | `t` | Wall-clock epoch milliseconds appended to the WebSocket handshake URL (`olaz-ws/src/policy.rs`) |
| `query` | `zcid` | `ParamCipher` encrypted `type,imei,firstLaunchTimeMs` (depends on wall clock and `imei`) |
| `query` | `zcid_ext` | Random 10-hex-character nonce per `ParamCipher` |
| `query` | `signkey` | MD5 signature computed over volatile `imei`, `zcid`, `zcid_ext`, `params`, etc. |
| `query` | `params` | Encrypted `ParamCipher` / AES-CBC payload blob (depends on volatile keys/IV/timestamps; decrypted payload is compared separately in `request.params`). Plain cursor `params` on long-poll `GET /` (`<lastActionId>,<lastActionIdOther>,<b64>,1`) is deterministic and kept verbatim. |
| `ws_send` (`payload`) | `ts`, `client_time`, `timestamp` | Any wall-clock timestamp fields carried inside client→server `ws_send` JSON payloads |
| `host` (`mute`) | `start` | Only when `startTime` and `systemTime` are both absent from a `mute` control payload and `start` falls back to `Date().timeIntervalSince1970`. |

## Comparing

Values compare as canonical JSON: keys sorted, integers kept exact (64-bit ids stay integers or strings exactly as the source wrote them, see ADR-009), no float tolerance. Output per domain: `N/M cases match`, then each mismatch as `name: path: expected X, got Y`.
