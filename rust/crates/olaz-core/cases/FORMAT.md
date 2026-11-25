# Case format v1

Shared contract between the Swift recorder (U1a, Hydrogen) and the Rust replay runner (U1b, Neon). Copy it into the repo as `rust/crates/olaz-core/cases/FORMAT.md`; the repo copy becomes the source of truth once U1a merges. Change it only through Claude.

The oracle is what can be observed from outside the engine: the domain state the views read, the requests that reach the server, and the activities the engine hands to code it does not own yet. Neither side's internals appear in a case.

## Files

- `rust/crates/olaz-core/cases/<domain>.jsonl`: one case per line, sorted by `name`. Domains: `session`, `transport`, `conversations`, `conversation_actions`, `messages`, `bootstrap`.
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
- `poll_state` *(optional, `transport`, `conversations`, `conversation_actions`, `messages`, `bootstrap`)*: `null`, or `ZaloPollState` / `PollState` camelCase JSON (`{"lastActionId": "...", "lastActionIdOther": "...", "queues": {"1": {"lastId": "...", "ids": []}, ...}}`) seeded before long-polling starts.
- `ws_cursors` *(optional, `transport`, `conversations`, `conversation_actions`, `messages`, `bootstrap`)*: `null`, or a map of `"<cmd>_<subCmd>"` to `{"lastId": "...", "preIds": [...]}` (`ZaloWSQueueCursorSnapshot` / `WsQueueCursorSnapshot`) seeded before WebSocket connects.
- `suppress` *(optional, runner metadata, `transport`, `conversations`, `conversation_actions`, `messages`, `bootstrap`)*: array of transport names (`"ws"`, `"long_poll"`, or both) to suppress during the run. Both the recorder's `hostTrace` and the Rust replay obey it: `start_ws` / `start_long_poll` are still traced, `hostTrace` returns `false` for listed transports, a suppressed WS never connects, and a suppressed long-poll never ticks.
- `ws_auth` *(optional, `conversations`, `conversation_actions`, `messages`, `bootstrap`)*: `"manual"` (or omitted for auto-auth). When `"manual"`, the fake server does not send the initial `cmd == 1` auth reply automatically on WebSocket connect; instead, that `cmd == 1` `ws_frame` remains the first scripted `ws_frame` and is delivered by an explicit `ws_push` step (typically `await_host start_bootstrap` → `ws_push 1` → `await_host e2ee_connected`).
- `contacts` *(optional, `conversations`, `conversation_actions`, `messages`, `bootstrap`)*: `{"friends": [{"id", "name", "zalo_name", "avatar", "last_active_ms", "online", "section", "sort_key"}], "groups": [{"id", "name", "avatar", "members", "sort_key"}], "friends_loaded": <bool>, "groups_loaded": <bool>, "aliases": {"<uid>": "<alias>"}, "cached_profiles": {"<uid>": {"name", "avatar"}}, "cached_groups": {"<gid>": {"name", "avatar", "members"}}, "friend_global_ids": {"<uid>": "<gid>"}}`. Friends/groups populate `ContactsState`; aliases/profiles/groups/global-ids seed the corresponding store preferences before boot so `loadLocalAccountState` loads them.
- `pinned_ids`, `archived_ids`, `unread_marks`, `hidden_ids` *(optional, `conversations`, `conversation_actions`, `messages`, `bootstrap`)*: arrays of conversation ids seeded into SQLite `pinnedIds`, `archivedIds`, `unreadMarks`, `hiddenIds` preferences before boot.
- `hidden_pin_md5`, `hidden_pin_hash` *(optional, `conversation_actions`)*: `null` or digest hex string seeded into SQLite `hiddenPinMD5` / `hiddenPinHash` preferences before boot.
- `labels_pref` *(optional, `conversation_actions`)*: array of `{"id", "name", "color", "convIds"}` seeded into SQLite `labels` preference before boot.
- `activity_ranks` *(optional, `conversations`, `conversation_actions`, `messages`, `bootstrap`)*: map of `<convId>` to positive integer rank seeded into SQLite `activityRanks` preference before boot.
- `local_conversations` *(optional, `conversations`, `conversation_actions`, `messages`, `bootstrap`)*: array of `{"id", "is_group", "name", "avatar", "pinned", "members", "unread", "preview_text", "preview_ts_ms", "preview_from_me", "updated_at_ms"}` seeded into the SQLite `conversations` table before boot (`loadLocalAccountState` reads them before any network).
- `local_messages` *(optional, `conversations`, `conversation_actions`, `messages`, `bootstrap`)*: array of `{"id", "conv_id", "client_id", "sender_id", "sender_name", "sender_avatar", "is_mine", "text", "kind_tag", "ts_ms", "status", "raw_json"}` seeded into the SQLite `messages` table before boot.
- `open_conversation_id` *(optional, `conversations`, `conversation_actions`, `messages`, `bootstrap`)*: `null` or conversation id set as `openConversationId` before steps run.
- `history_full_refresh_at` *(optional, `messages`, `bootstrap`)*: `null`, or string/number seeded into SQLite `historyFullRefreshAt` preference before boot (stored as stringified epoch seconds).
- `history_freshness` *(optional, `messages`, `bootstrap`)*: `null`, or map of `<convId>` to `"up_to_date" | "stale"` pre-seeded into `ZaloEngine.historyFreshness` before steps run.

### server

Scripted answers, in the order they are consumed. Each request takes the first unconsumed entry with the same `kind` and `path` (entries with `"repeat": true` are never consumed).

- HTTP: `{"kind": "http", "path": "/api/...", "method": "GET|POST", "response": {"status": 200, "json": {...}}}`. `json` is the plain body; the fake server encrypts it the way Zalo does for that endpoint (including ParamCipher endpoints and AES-CBC `data` encryption with `zpw_enk` for `/api/social/profile/me-v2` and long-poll `/`). Instead of `json`: `"raw": "<text>"`, or `"error": "timeout" | "refused" | "reset"`.
- WebSocket: `{"kind": "ws", "path": "...", "accept": true}`.
- WebSocket server frames (`ws_frame`): `{"kind": "ws_frame", "cmd": <int>, "sub_cmd": <int>, "payload": {...}}` (optional `"encrypt": <0|1|2|3>`, optional `"key": "<base64>"`, optional `"delay_ms": <int>`). Unless `seed.ws_auth == "manual"`, the initial auth reply (`cmd == 1` immediately following a `"ws"` entry) is sent automatically when that WebSocket connects; when `seed.ws_auth == "manual"`, and for every subsequent `ws_frame`, the frame waits for a `ws_push` step and is sent in script order on the active connection. `payload` is the plain JSON body; the fake server encodes it as Zalo and `olaz-ws` expect for that `cmd` inside an RFC 6455 binary frame (`u8 version(1) | u16 LE cmd | u8 sub_cmd | UTF-8 JSON envelope`): `cmd == 1` defaults to `encrypt: 0` with a base64 `"key"` and JSON-stringified `"data"`, `cmd == 602` defaults to `encrypt: 0` with JSON-stringified `"data"`, and other `cmd`s default to `encrypt: 2` (AES-GCM 16-byte nonce + zlib when the connection established a cipher key on `cmd == 1`) or `encrypt: 1` (zlib) unless `"encrypt"` is explicitly given.
- WebSocket server drop (`ws_close`): `{"kind": "ws_close"}` (optional `"delay_ms": <int>`). Sends an RFC 6455 Close frame (`1000`) and closes the socket when triggered by a `ws_push` step (used to trigger disconnect/reconnect such as `ws_auth_watch`).
- A request with no matching entry is answered `{"error_code": 0, "data": {}}` and recorded with `"unscripted": true`. A case with an unscripted request is a recorder bug.

### steps

Run in order:

- Session / transport `cmd` steps: `{"cmd": "start" | "refresh_qr" | "log_out" | "session_expired" | "drain_chat_polling", "args": {...}}`.
  - `session_expired` takes `{"reason": "<text>"}`.
  - `drain_chat_polling` (`transport`, `conversations`, `conversation_actions`, `messages`, `bootstrap`) calls `drainChatPolling(maxBatches, notifyIncoming)` with `{"max_batches": <int>, "notify_incoming": <bool>}`.
- Conversations `cmd` steps (`conversations` domain):
  - `apply_batch`: `{"payload": {...}, "default_cmd": <int>, "fallback_conv_id": <str|null>, "is_group_hint": <bool|null>, "increment_unread": <bool>, "notify_incoming": <bool>, "persist_conversations": <bool>}` — calls `applyBatchResponse`.
  - `ensure_known_contacts`: `{}` — calls `ensureKnownContactsInConversations()`, `rebuildConversationFlags()`, `rebuildConversationExtras()`.
  - `resolve_missing_names`: `{}` — awaits `resolveMissingConversationNames()`.
  - `refresh_mention_previews`: `{}` — awaits `refreshMentionPreviews()`.
  - `update_contacts`: same fields as `seed.contacts` — updates in-memory `contacts` / `cachedAliases` mid-scenario before `ensure_known_contacts`.
  - `open_conversation`: `{"id": <str|null>, "load": <bool, optional>}` — sets `openConversationId`; when `"load": true`, calls `openConversation(id)` and awaits its history/preview update.
- Conversation action `cmd` steps (`conversation_actions` domain):
  - Optional step-level deterministic inputs on `cmd` steps: `"now_ms": <int64>` and `"rand4": "<string>"` seed wall-clock milliseconds (`nowMs`) and 4-char random tags (`randomTag4`) for the duration of that single step.
  - `pin`: `{"id": "<convId>"}` — calls `pinConversation(id)` and awaits its completion (`toast` seq advance or `prompt == .pinBoard`).
  - `unpin`: `{"id": "<convId>"}` — calls `unpinConversation(id)` and awaits its completion (`toast` seq advance).
  - `pin_board`: `{"id": "<convId>"}` — awaits `pinBoard(for: id)` and records the result in `pin_board`.
  - `pin_replacing`: `{"unpin": ["..."], "id": "<convId>"}` — awaits `pinReplacing(unpin, pinning: id)` and records `last_action_result`.
  - `move`: `{"id": "<convId>", "to_other": <bool>}` — calls `moveConversation(id, toOther: to_other)` and awaits its completion.
  - `request_delete`: `{"id": "<convId>"}` — calls `requestDeleteConversation(id)`.
  - `confirm_delete`: `{"id": "<convId>"}` — calls `confirmDeleteConversation(id)` and awaits its completion.
  - `mark_read`: `{"id": "<convId>"}` — calls `markConversationRead(id)` and awaits SQLite/API completion.
  - `mark_unread`: `{"id": "<convId>"}` — calls `markConversationUnread(id)` and awaits SQLite/API completion.
  - `hide`: `{"id": "<convId>", "pin": "<pin>"}` — awaits `hideConversation(id, pin: pin)` and records `last_action_result`.
  - `hide_new_pin`: `{"id": "<convId>", "pin": "<pin>"}` — awaits `hideConversation(id, settingNewPIN: pin)` and records `last_action_result`.
  - `unhide`: `{"id": "<convId>", "pin": <str|null>}` — awaits `unhideConversation(id, pin: pin)` and records `last_action_result`.
  - `set_pin`: `{"pin": "<pin>", "changed": <bool>}` — awaits `setHiddenChatPIN(pin, changed: changed)` and records `last_action_result`.
  - `reset_pin`: `{}` — awaits `resetHiddenChatPIN()` and records `last_action_result`.
  - `sync_hidden`: `{}` — awaits `syncHiddenConversations()`.
  - `apply_server_hidden`: `{"pin": "<md5>", "thread_ids": ["..."]}` — awaits `applyServerHiddenConversations(...)`.
  - `hidden_search`: `{"query": "<str>"}` — awaits `hiddenConversations(matching: query)`.
  - `unlock_from_pin_search`: `{"id": "<convId>"}` — calls `unlockFromPINSearch(id)`.
  - `relock_hidden`: `{}` — calls `conversationUI.relock()`.
  - `handle_conversation_actions`: `{"state": {...}}` — calls `handleConversationActions(state: state)`.
  - `label_create`: `{"name": "...", "color_hex": "...", "conversation_ids": [...]}` (with step inputs `"now_ms": <int64>`, `"rand4": "<4-char string>"`) — sets the engine's `nowMs` / `randomTag4` seams for this step and calls `createConversationLabel(...)`, yielding deterministic id `"lbl_<now_ms>_<rand4>"`, then awaits store/API sync.
  - `label_update`: `{"id": "...", "name": "...", "color_hex": "..."}` — calls `updateConversationLabel(...)` and awaits store/API sync.
  - `label_delete`: `{"id": "..."}` — calls `deleteConversationLabel(id)` and awaits store/API sync.
  - `label_assign`: `{"conversation_id": "...", "label_id": <str|null>}` — calls `setConversationLabel(...)` and awaits store/API sync.
  - `label_reorder`: `{"ids": [...]}` — calls `reorderConversationLabels(ids)` and awaits store/API sync.
  - `set_filter`: `{"type": <int>, "label_ids": [...]}` — calls `setConversationFilter(...)`.
  - `sync_labels`: `{}` — awaits `syncConversationLabelsFromServer()`.
  - `handle_conversation_extras`: `{"state": {...}}` — calls `handleConversationExtras(state: state)`.
- Messages & bootstrap `cmd` steps (`messages` and `bootstrap` domains):
  - Optional `"now_ms": <int64>` on `cmd` steps seeds `nowMs` for the duration of that step (used for daily full-refresh freshness checks and mute `startTime` fallback).
  - `open`: `{"id": "<convId>"}` — calls `openConversation(id)` and awaits its async cache/history/profile/pins/mark-read task (and any triggered SQLite conversation persist) to finish.
  - `close`: `{}` — calls `closeConversation()`.
  - `load_older`: `{"id": "<convId>"}` — calls `loadOlderMessages(id)` and awaits its completion (`history_ticks` increment).
  - `bootstrap`: `{}` — runs `performBootstrapSync()` and awaits completion (when `start_bootstrap` was suppressed or re-run after setup).
  - `apply_batch`: same signature as `conversations` domain — calls `applyBatchResponse` directly (`probe_freshness: <bool, optional>`).
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
- `host`: ordered list of activities handed to Swift-owned code, `{"call": "<name>", "args": {...}}`. While recording, the engine's trace hook records these and skips the real activity (except where a lifecycle hook in `transport` / `conversations` / `conversation_actions` / `messages` / `bootstrap` must permit `prepare_store`, `apply_batch`, `apply_parsed_events`, or WS/long-poll startup so the domain under test runs).
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
  - Messages and bootstrap domain names (Swift-owned U5–U16 boundaries):
    - `mark_read {conv_id}` *(U5 seen / unread handoff at the end of `openConversation`)*
    - `refresh_board_pins {conv_id}` *(U7 board pins refresh during `openConversation`)*
    - `apply_remote_reaction {conv_id, msg_id, cli_msg_id, sender_id, r_type, r_icon, event_id, react_client_id, sender_name}` *(U6 remote reaction handler)*
    - `apply_remote_recall {conv_id, msg_id, cli_msg_id}` *(U6 remote recall handler)*
    - `apply_remote_delete {conv_id, msg_id, cli_msg_id}` *(U6 remote delete handler)*
    - `apply_mutes {mutes: [{"conv_id", "start", "duration"}]}` *(U16 mute list handoff during `performBootstrapSync`; `start` falls back to `now_ms / 1000` when `startTime` is absent)*
    - `refresh_cloud {}` *(U11 cloud snapshot refresh at the end of `performBootstrapSync`)*

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

## Conversations and conversation actions domain state

Cases in `conversations` and `conversation_actions` extend the session domain state object with the following fields:

```json
{
  "conversations": [
    {
      "id": "3000001",
      "is_group": false,
      "name": "Alice",
      "avatar": "https://cdn.example.invalid/a.jpg",
      "pinned": false,
      "members": 0,
      "unread": 1,
      "preview": { "text": "Hello", "date_ms": 1700000000000, "from_me": false }
    }
  ],
  "flags": {
    "loaded": true,
    "hidden_known": true,
    "hidden_enabled": true,
    "has_hidden_pin": false,
    "hidden_ids": [],
    "mark_unread_enabled": true,
    "flags": { "3000001": 1 },
    "left": {},
    "late_epoch": 0,
    "late_seq": 0,
    "unlocked_id": null,
    "pin_search_ids": [],
    "removal": null
  },
  "labels": {
    "loaded": true,
    "archived_enabled": true,
    "labels": [{ "id": "1", "name": "Khách hàng", "color_hex": "#0068FF", "conv_ids": [] }],
    "label_by_conversation": {},
    "type_filter": 0,
    "label_filter_ids": [],
    "list_ids": ["3000001"],
    "stranger_ids": [],
    "stranger_folder_ids": [],
    "stranger_box": { "chats": 0, "unread_chats": 0, "unread_messages": 0, "newest_id": null }
  },
  "store": null | {
    "conversations": [
      {
        "id": "3000001",
        "is_group": false,
        "name": "Alice",
        "avatar": "https://cdn.example.invalid/a.jpg",
        "pinned": false,
        "members": 0,
        "unread": 1,
        "preview_text": "Hello",
        "preview_ts_ms": 1700000000000,
        "preview_from_me": false,
        "updated_at_ms": "<volatile>"
      }
    ],
    "prefs": {
      "pinned_ids": [],
      "archived_ids": [],
      "unread_marks": [],
      "hidden_ids": [],
      "labels": [],
      "cached_profiles": {},
      "hidden_pin_md5": null,
      "hidden_pin_hash": null
    }
  },
  "toast": null | { "seq": 1, "kind": "success" | "neutral" | "failure", "ok": true, "text": "Đã ghim hội thoại" },
  "prompt": null | { "kind": "delete" | "pin_board" | "hide" | "unhide" | "unlock", "id": "3000001" },
  "pin_board": null | { "tab": 0, "limit": 10, "total": 10, "need": 1, "items": [] },
  "last_action_result": null | { "ok": true, "text": "", "full": false, "bad_pin": false, "pin_exists": false, "neutral": false }
}
```

- `conversations` is in current `ZaloEngine.conversations` display order; `preview` is `null` when absent, otherwise `{"text", "date_ms", "from_me"}` (`date_ms` is `Int64?` rounded epoch milliseconds).
- `flags.hidden_ids`, `flags.pin_search_ids`, `flags.removal.ids`, `labels.stranger_ids`, `store.prefs.pinned_ids`, `store.prefs.archived_ids`, `store.prefs.unread_marks`, and `store.prefs.hidden_ids` are sorted lexicographically so `Set` hash order never affects recordings.
- `store` is read back directly from `ZaloSQLiteStore` at each snapshot and at `final` (`null` if no store has been opened); `store.conversations` is sorted by `id` (`utf8` scalar order). `hidden_pin_md5` and `hidden_pin_hash` hold digests only, never plaintext PINs.

## Messages and bootstrap domain state

Cases in `messages` and `bootstrap` extend the Conversations and conversation actions domain state with the following fields:

```json
{
  "open_conversation_id": null,
  "messages": {
    "3000001": [
      {
        "id": "m1",
        "client_id": "c1",
        "conv_id": "3000001",
        "sender_id": "3000001",
        "sender_name": "Alice",
        "sender_avatar": "https://cdn.example.invalid/a.jpg",
        "date_ms": 1700000000000,
        "is_mine": false,
        "kind_tag": "text",
        "text": "Hello",
        "is_e2ee": false,
        "reactions": [
          { "icon": "❤️", "count": 1, "includes_me": false }
        ]
      }
    ]
  },
  "has_more_history": { "3000001": true },
  "history_ticks": { "3000001": 1 },
  "history_freshness": { "3000001": "up_to_date" },
  "bootstrap_logs": [],
  "store": {
    "conversations": [],
    "messages": [
      {
        "id": "m1",
        "conv_id": "3000001",
        "client_id": "c1",
        "sender_id": "3000001",
        "sender_name": "Alice",
        "sender_avatar": "",
        "is_mine": false,
        "text": "Hello",
        "kind_tag": "text",
        "ts_ms": 1700000000000,
        "status": "sent"
      }
    ],
    "prefs": {
      "pinned_ids": [],
      "archived_ids": [],
      "unread_marks": [],
      "hidden_ids": [],
      "labels": [],
      "cached_profiles": {},
      "hidden_pin_md5": null,
      "hidden_pin_hash": null,
      "history_full_refresh_at": null,
      "activity_ranks": {},
      "aliases": {}
    }
  }
}
```

- `messages` maps each conversation id to its in-memory `ZaloEngine.messages[convId]` window in order (`{id, client_id, conv_id, sender_id, sender_name, sender_avatar, date_ms, is_mine, kind_tag, text, is_e2ee, reactions}`; `sender_avatar` is a URL string or `null`).
- `history_freshness` maps each conversation id to `"up_to_date"` or `"stale"`.
- `bootstrap_logs` holds `"bootstrap: ..."` lines emitted via `EngineLog` (with the wall-clock `HH:mm:ss.SSS ` prefix stripped).
- `store.messages` holds all rows read back from SQLite `messages` sorted by `conv_id` (`utf8`), then `ts_ms`, then `id` (`utf8`).
- `store.prefs` adds `history_full_refresh_at` (string or `null`, from pref `historyFullRefreshAt`), `activity_ranks` (object map of `<convId>` to integer rank, from pref `activityRanks`), and `aliases` (object map of `<uid>` to alias string, from pref `aliases`).

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
| `store.conversations[]` | `updated_at_ms` | Wall-clock epoch milliseconds written by `persistConversationsToSQLite()` (`Date().timeIntervalSince1970 * 1000`). |

## Comparing

Values compare as canonical JSON: keys sorted, integers kept exact (64-bit ids stay integers or strings exactly as the source wrote them, see ADR-009), no float tolerance. Output per domain: `N/M cases match`, then each mismatch as `name: path: expected X, got Y`.

## Known diffs

`rust/crates/olaz-core/cases/known-diffs.jsonl` records user-approved, intentional divergences from the committed `cases/<domain>.jsonl` recordings (for example, fixing a verified bug in the pre-port Swift recording without rewriting the historical `cases/*.jsonl` file).

Each non-empty line is a JSON object with five fields:

```json
{"domain": "conversations", "name": "recall_preview_via_batch", "path": "final.conversations[0].preview.text", "actual": "Tin nhắn đã được thu hồi", "reason": "..."}
```

- `domain`, `name`: identify the case in `cases/<domain>.jsonl`.
- `path`: leaf path under `expect` using dot-separated object keys and `[index]` array subscripts (e.g. `final.conversations[0].preview.text`, `snapshots.after_delete_1_1.store.prefs.pinned_ids[0]`).
- `actual`: the port's exact canonical JSON value at `path`, copied from the runner's mismatch output (never hand-written). When a key or array element present in the recording is absent from the port's output, `actual` is the sentinel string `"<missing>"`.
- `reason`: short explanation referencing the user approval.

Both the Rust replay runner (`tests/cases.rs`) and the Swift recorder freshness tests (`CaseFile.compareCase` / `CaseFile.staleKnownDiffs`) enforce the same two rules:

1. **Exact-`actual` match only**: a mismatch at `(domain, name, path)` is accepted if and only if a `known-diffs.jsonl` entry exists for `(domain, name, path)` whose canonical `actual` equals the observed value exactly. Any other difference fails the run.
2. **Stale entries fail the gate**: every entry in `known-diffs.jsonl` belonging to an executed case in the tested domain must match an actual divergence. If the recording no longer differs at that path (or the case name does not exist), the runner fails so stale entries cannot linger.
