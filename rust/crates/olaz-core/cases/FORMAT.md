# Case format v1

Shared contract between the Swift recorder (U1a, Hydrogen) and the Rust replay runner (U1b, Neon). Copy it into the repo as `rust/crates/olaz-core/cases/FORMAT.md`; the repo copy becomes the source of truth once U1a merges. Change it only through Claude.

The oracle is what can be observed from outside the engine: the domain state the views read, the requests that reach the server, and the activities the engine hands to code it does not own yet. Neither side's internals appear in a case.

## Files

- `rust/crates/olaz-core/cases/<domain>.jsonl`: one case per line, sorted by `name`. First domain: `session`.
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

### server

Scripted answers, in the order they are consumed. Each request takes the first unconsumed entry with the same `kind` and `path` (entries with `"repeat": true` are never consumed).

- HTTP: `{"kind": "http", "path": "/api/...", "method": "GET|POST", "response": {"status": 200, "json": {...}}}`. `json` is the plain body; the fake server encrypts it the way Zalo does for that endpoint. Instead of `json`: `"raw": "<text>"`, or `"error": "timeout" | "refused" | "reset"`.
- WebSocket: `{"kind": "ws", "path": "...", "accept": true}`.
- A request with no matching entry is answered `{"error_code": 0, "data": {}}` and recorded with `"unscripted": true`. A case with an unscripted request is a recorder bug.

### steps

Run in order:

- `{"cmd": "start" | "refresh_qr" | "log_out" | "session_expired", "args": {...}}`. `session_expired` takes `{"reason": "<text>"}`.
- `{"await": {"phase": "<kind>", "step": "<login step, optional>"}, "timeout_ms": 5000}`: wait until the state matches. The Rust runner instead runs the core until no input or effect is pending, then checks the same predicate.
- `{"snapshot": "<label>"}`: record the state under `expect.snapshots[label]`.

### expect

- `snapshots`: label to state, as taken at each `snapshot` step.
- `final`: state after the last step, once nothing is pending.
- `requests`: every request that reached the fake server, canonical form, as a **sorted multiset** (sort by `kind`, then `path`, then the canonical JSON text). Concurrent requests have no stable order, so order is not compared.
  - HTTP: `{"kind": "http", "path", "method", "params": {...} | null, "query": {...}}`. `params` is the decrypted ParamCipher payload, keys sorted. `query` is the plain query string, keys sorted. Signatures, encrypted blobs and the keys listed under Volatile become `"<volatile>"`.
  - WebSocket: `{"kind": "ws_connect", "path", "query": {...}}`.
- `host`: ordered list of activities handed to Swift-owned code, `{"call": "<name>", "args": {...}}`. Session domain names: `prepare_store {user_id}`, `start_ws {endpoints}`, `start_long_poll {}`, `start_bootstrap {}`, `offer_first_login_transfer {force}`, `reset_domains {}`, `persist_session {}`, `clear_session {}`, `mark_expired {}`. While recording, the engine's trace hook records these and does not start the real activity.

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
| `query`, `params` | `ts` | Wall-clock epoch milliseconds at `getLoginInfo` time |
| `query` | `zcid` | `ParamCipher` encrypted `type,imei,firstLaunchTimeMs` (depends on wall clock and `imei`) |
| `query` | `zcid_ext` | Random 10-hex-character nonce per `ParamCipher` |
| `query` | `signkey` | MD5 signature computed over volatile `imei`, `zcid`, `zcid_ext`, `params`, etc. |
| `query` | `params` | Encrypted `ParamCipher` / AES-CBC payload blob (depends on volatile keys/IV/timestamps; decrypted payload is compared separately in `request.params`) |

## Comparing

Values compare as canonical JSON: keys sorted, integers kept exact (64-bit ids stay integers or strings exactly as the source wrote them, see ADR-009), no float tolerance. Output per domain: `N/M cases match`, then each mismatch as `name: path: expected X, got Y`.
