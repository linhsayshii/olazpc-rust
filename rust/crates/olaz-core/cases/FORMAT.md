# Case format v1

Shared contract between the Swift recorder (U1a, Hydrogen) and the Rust replay runner (U1b, Neon). Copy it into the repo as `rust/crates/olaz-core/cases/FORMAT.md`; the repo copy becomes the source of truth once U1a merges. Change it only through Claude.

The oracle is what can be observed from outside the engine: the domain state the views read, the requests that reach the server, and the activities the engine hands to code it does not own yet. Neither side's internals appear in a case.

## Files

- `rust/crates/olaz-core/cases/<domain>.jsonl`: one case per line, sorted by `name`. Domains: `session`, `transport`, `conversations`, `conversation_actions`, `messages`, `bootstrap`, `send`, `message_actions`, `contacts`, `groups`, `polls`, `pins`.
- `rust/crates/olaz-core/cases/<domain>.jsonl`: one case per line, sorted by `name`. Domains: `session`, `transport`, `conversations`, `conversation_actions`, `messages`, `bootstrap`, `send`, `message_actions`, `contacts`, `groups`, `polls`.
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

- `"slow": true` *(optional)*: test-runner metadata marking cases that exercise a real wall-clock timeout (such as `qr_timeout` or `typing_in_1_1_and_group`). It is not domain behavior. Default Swift recorder runs skip slow cases unless `OLAZ_SLOW_CASES=1` (printing `skipped slow: <name>`); `OLAZ_RECORD=1` and `scripts/gate-core.sh` always run every case.

### seed

- `saved_session`: `null`, or the `StoredNativeSession` JSON that `ZaloSessionClient.saveSession()` writes with `useKeychain: false` (`plainAccount` set, `sealedSecretsBase64` null). Its `domains` point every service at the fake server. The recorder writes it to `sessionFileURL`; the Rust runner hands it to the core through the fake host's `load_saved_session`.
- `domains`: the service map used when no session is saved (QR login), pointing every service at the fake server. The fake server's port is not stable, so cases store the host as `"http://fake"`; both sides substitute the real `http://127.0.0.1:<port>` when they run. Every case sets `"isolated": true` so neither side ever fails over to live Zalo hosts.
- `legacy_cookie`: `null`, or what `tryRestoreLegacyCookieSession` reads.
- `prefs`: store preference strings present before the run.
- `poll_state` *(optional, `transport`, `conversations`, `conversation_actions`, `messages`, `bootstrap`, `send`, `message_actions`)*: `null`, or `ZaloPollState` / `PollState` camelCase JSON (`{"lastActionId": "...", "lastActionIdOther": "...", "queues": {"1": {"lastId": "...", "ids": []}, ...}}`) seeded before long-polling starts.
- `ws_cursors` *(optional, `transport`, `conversations`, `conversation_actions`, `messages`, `bootstrap`, `send`, `message_actions`)*: `null`, or a map of `"<cmd>_<subCmd>"` to `{"lastId": "...", "preIds": [...]}` (`ZaloWSQueueCursorSnapshot` / `WsQueueCursorSnapshot`) seeded before WebSocket connects.
- `suppress` *(optional, runner metadata, `transport`, `conversations`, `conversation_actions`, `messages`, `bootstrap`, `send`, `message_actions`, `contacts`, `groups`, `polls`, `pins`)*: array of transport names (`"ws"`, `"long_poll"`, or both) to suppress during the run. Both the recorder's `hostTrace` and the Rust replay obey it: `start_ws` / `start_long_poll` are still traced, `hostTrace` returns `false` for listed transports, a suppressed WS never connects, and a suppressed long-poll never ticks.
- `ws_auth` *(optional, `conversations`, `conversation_actions`, `messages`, `bootstrap`, `send`, `message_actions`, `contacts`, `groups`, `polls`, `pins`)*: `"manual"` (or omitted for auto-auth). When `"manual"`, the fake server does not send the initial `cmd == 1` auth reply automatically on WebSocket connect; instead, that `cmd == 1` `ws_frame` remains the first scripted `ws_frame` and is delivered by an explicit `ws_push` step (typically `await_host start_bootstrap` → `ws_push 1` → `await_host e2ee_connected`).
- `contacts` *(optional, `conversations`, `conversation_actions`, `messages`, `bootstrap`, `send`, `message_actions`, `contacts`, `groups`, `polls`, `pins`)*: `{"friends": [{"id", "name", "zalo_name", "avatar", "last_active_ms", "online", "section", "sort_key"}], "groups": [{"id", "name", "avatar", "members", "sort_key"}], "received": [{"id", "name", "avatar", "message", "date_ms"}], "sent": [{"id", "name", "avatar", "message", "date_ms"}], "pending_request_count": <int>, "loading_requests": <bool>, "search": {"status", "error", "user"}, "notice": {"seq", "ok", "text"}, "friends_loaded": <bool>, "groups_loaded": <bool>, "aliases": {"<uid>": "<alias>"}, "cached_profiles": {"<uid>": {"name", "avatar"}}, "cached_groups": {"<gid>": {"name", "avatar", "members"}}, "friend_global_ids": {"<uid>": "<gid>"}, "gid_to_uid_map": {"<gid>": "<uid>"}}`. Friends/groups/requests/search/notice populate `ContactsState`; aliases/profiles/groups/global-ids seed the corresponding store preferences before boot so `loadLocalAccountState` loads them (in `contacts`, `friend_global_ids` `{"<uid>": "<gid>"}` is inverted into SQLite `gidToUidMap` if `gid_to_uid_map` is omitted).
- `blocked_users` *(optional, `contacts`)*: `null`, or array of `{"id": "<uid>", "name": "<str>", "avatar": <str|null>}` pre-seeding `ZaloEngine.blockedUsers` before steps run.
- `pinned_ids`, `archived_ids`, `unread_marks`, `hidden_ids` *(optional, `conversations`, `conversation_actions`, `messages`, `bootstrap`, `send`, `message_actions`, `contacts`, `groups`, `polls`, `pins`)*: arrays of conversation ids seeded into SQLite `pinnedIds`, `archivedIds`, `unreadMarks`, `hiddenIds` preferences before boot.
- `suppress` *(optional, runner metadata, `transport`, `conversations`, `conversation_actions`, `messages`, `bootstrap`, `send`, `message_actions`, `contacts`, `groups`, `polls`)*: array of transport names (`"ws"`, `"long_poll"`, or both) to suppress during the run. Both the recorder's `hostTrace` and the Rust replay obey it: `start_ws` / `start_long_poll` are still traced, `hostTrace` returns `false` for listed transports, a suppressed WS never connects, and a suppressed long-poll never ticks.
- `ws_auth` *(optional, `conversations`, `conversation_actions`, `messages`, `bootstrap`, `send`, `message_actions`, `contacts`, `groups`, `polls`)*: `"manual"` (or omitted for auto-auth). When `"manual"`, the fake server does not send the initial `cmd == 1` auth reply automatically on WebSocket connect; instead, that `cmd == 1` `ws_frame` remains the first scripted `ws_frame` and is delivered by an explicit `ws_push` step (typically `await_host start_bootstrap` → `ws_push 1` → `await_host e2ee_connected`).
- `contacts` *(optional, `conversations`, `conversation_actions`, `messages`, `bootstrap`, `send`, `message_actions`, `contacts`, `groups`, `polls`)*: `{"friends": [{"id", "name", "zalo_name", "avatar", "last_active_ms", "online", "section", "sort_key"}], "groups": [{"id", "name", "avatar", "members", "sort_key"}], "received": [{"id", "name", "avatar", "message", "date_ms"}], "sent": [{"id", "name", "avatar", "message", "date_ms"}], "pending_request_count": <int>, "loading_requests": <bool>, "search": {"status", "error", "user"}, "notice": {"seq", "ok", "text"}, "friends_loaded": <bool>, "groups_loaded": <bool>, "aliases": {"<uid>": "<alias>"}, "cached_profiles": {"<uid>": {"name", "avatar"}}, "cached_groups": {"<gid>": {"name", "avatar", "members"}}, "friend_global_ids": {"<uid>": "<gid>"}, "gid_to_uid_map": {"<gid>": "<uid>"}}`. Friends/groups/requests/search/notice populate `ContactsState`; aliases/profiles/groups/global-ids seed the corresponding store preferences before boot so `loadLocalAccountState` loads them (in `contacts`, `friend_global_ids` `{"<uid>": "<gid>"}` is inverted into SQLite `gidToUidMap` if `gid_to_uid_map` is omitted).
- `blocked_users` *(optional, `contacts`)*: `null`, or array of `{"id": "<uid>", "name": "<str>", "avatar": <str|null>}` pre-seeding `ZaloEngine.blockedUsers` before steps run.
- `pinned_ids`, `archived_ids`, `unread_marks`, `hidden_ids` *(optional, `conversations`, `conversation_actions`, `messages`, `bootstrap`, `send`, `message_actions`, `contacts`, `groups`, `polls`)*: arrays of conversation ids seeded into SQLite `pinnedIds`, `archivedIds`, `unreadMarks`, `hiddenIds` preferences before boot.
- `starred_ids` *(optional, `message_actions`)*: array of message ids seeded into SQLite `starredIds` preference before boot (`loadLocalAccountState` loads them into `cachedStarredIds`).
- `seen_reaction_event_ids` *(optional, `message_actions`)*: array of reaction dedupe keys seeded into SQLite `seenReactionEventIds` preference before boot (`loadLocalAccountState` loads them into `seenReactionEventIds` / `seenReactionEventOrder`).
- `hidden_pin_md5`, `hidden_pin_hash` *(optional, `conversation_actions`)*: `null` or digest hex string seeded into SQLite `hiddenPinMD5` / `hiddenPinHash` preferences before boot.
- `labels_pref` *(optional, `conversation_actions`)*: array of `{"id", "name", "color", "convIds"}` seeded into SQLite `labels` preference before boot.
- `activity_ranks` *(optional, `conversations`, `conversation_actions`, `messages`, `bootstrap`, `send`, `message_actions`, `contacts`, `groups`, `polls`, `pins`)*: map of `<convId>` to positive integer rank seeded into SQLite `activityRanks` preference before boot.
- `local_conversations` *(optional, `conversations`, `conversation_actions`, `messages`, `bootstrap`, `send`, `message_actions`, `contacts`, `groups`, `polls`, `pins`)*: array of `{"id", "is_group", "name", "avatar", "pinned", "members", "unread", "preview_text", "preview_ts_ms", "preview_from_me", "updated_at_ms"}` seeded into the SQLite `conversations` table before boot (`loadLocalAccountState` reads them before any network).
- `local_messages` *(optional, `conversations`, `conversation_actions`, `messages`, `bootstrap`, `send`, `message_actions`, `contacts`, `groups`, `polls`, `pins`)*: array of `{"id", "conv_id", "client_id", "sender_id", "sender_name", "sender_avatar", "is_mine", "text", "kind_tag", "ts_ms", "status", "raw_json"}` seeded into the SQLite `messages` table before boot.
- `open_conversation_id` *(optional, `conversations`, `conversation_actions`, `messages`, `bootstrap`, `send`, `message_actions`, `contacts`, `groups`, `polls`, `pins`)*: `null` or conversation id set as `openConversationId` before steps run.
- `activity_ranks` *(optional, `conversations`, `conversation_actions`, `messages`, `bootstrap`, `send`, `message_actions`, `contacts`, `groups`, `polls`)*: map of `<convId>` to positive integer rank seeded into SQLite `activityRanks` preference before boot.
- `local_conversations` *(optional, `conversations`, `conversation_actions`, `messages`, `bootstrap`, `send`, `message_actions`, `contacts`, `groups`, `polls`)*: array of `{"id", "is_group", "name", "avatar", "pinned", "members", "unread", "preview_text", "preview_ts_ms", "preview_from_me", "updated_at_ms"}` seeded into the SQLite `conversations` table before boot (`loadLocalAccountState` reads them before any network).
- `local_messages` *(optional, `conversations`, `conversation_actions`, `messages`, `bootstrap`, `send`, `message_actions`, `contacts`, `groups`, `polls`)*: array of `{"id", "conv_id", "client_id", "sender_id", "sender_name", "sender_avatar", "is_mine", "text", "kind_tag", "ts_ms", "status", "raw_json"}` seeded into the SQLite `messages` table before boot.
- `open_conversation_id` *(optional, `conversations`, `conversation_actions`, `messages`, `bootstrap`, `send`, `message_actions`, `contacts`, `groups`, `polls`)*: `null` or conversation id set as `openConversationId` before steps run.
- `history_full_refresh_at` *(optional, `messages`, `bootstrap`)*: `null`, or string/number seeded into SQLite `historyFullRefreshAt` preference before boot (stored as stringified epoch seconds).
- `history_freshness` *(optional, `messages`, `bootstrap`, `send`, `message_actions`, `pins`)*: `null`, or map of `<convId>` to `"up_to_date" | "stale"` pre-seeded into `ZaloEngine.historyFreshness` before steps run.
- `next_client_id` *(optional, `send`, `message_actions`)*: positive 64-bit integer seeding `nextClientId()` before steps run. Each `nextClientId()` call returns the current seeded value and increments it by 1.
- `auto_delete` *(optional, `send`, `message_actions`)*: map of `<convId>` to positive integer TTL milliseconds pre-seeded into `ZaloEngine.autoDelete` before steps run.
- `e2ee_threads` *(optional, `send`, `message_actions`)*: array of peer uid strings pre-seeded into SQLite `e2eeThreadsV1` preference before boot (`loadLocalAccountState` loads them into `e2eeManager`).
- `host_results` *(optional, `send`, `message_actions`)*: map of host call name (e.g. `"send_e2ee_text"`) to an ordered queue of scripted outcomes: `{"msg_id": "<str>", "cli_msg_id": "<str>", "ts_ms": <int64>}` on success, or `{"error": {"code": <int>, "message": "<str>", "url": "<str>"}}` (or `{"error": "<message>"}`) on failure. Consumed in order when the host boundary runs.
- `cached_group_details` *(optional, `groups`, `polls`, `pins`)*: map of `<cleanGrid>` to group detail dictionary pre-seeded into `ZaloEngine.cachedGroupDetails` before steps run.
- `group_member_cache` *(optional, `groups`, `polls`, `pins`)*: map of `<gid>` to `[{"id", "name", "avatar", "is_all"}]` pre-seeded into `ZaloEngine.groupMemberCache` before steps run.
- `polls` *(optional, `polls`)*: `{"details": {"<pollId>": <PollDetail JSON>}, "failed": ["<pollId>", ...], "pins": {"<pollId>": {"ready": <bool>, "can_pin": <bool>, "pinned": <bool>, "limit": <int>}}}` pre-seeding `ZaloEngine.polls` before steps run.
- `pins` *(optional, `polls`, `pins`)*: map of `<convId>` to `PinnedList` JSON (`{"convId": "<convId>", "ready": <bool>, "canPin": <bool>, "limit": <int>, "items": [{"ref", "kind", "title", "sender", "thumb", "msgId", "cliMsgId"}]}`) pre-seeding `ZaloEngine.pins` before steps run.
- `board_raw_topics` *(optional, `polls`, `pins`)*: map of `<convId>` to `{"version": <int64>, "topics": {"<topicId>": <raw topic JSON>}}` pre-seeding `ZaloEngine.cachedBoardRawTopics` before steps run.
- `cached_group_details` *(optional, `groups`, `polls`)*: map of `<cleanGrid>` to group detail dictionary pre-seeded into `ZaloEngine.cachedGroupDetails` before steps run.
- `group_member_cache` *(optional, `groups`, `polls`)*: map of `<gid>` to `[{"id", "name", "avatar", "is_all"}]` pre-seeded into `ZaloEngine.groupMemberCache` before steps run.
- `polls` *(optional, `polls`)*: `{"details": {"<pollId>": <PollDetail JSON>}, "failed": ["<pollId>", ...], "pins": {"<pollId>": {"ready": <bool>, "can_pin": <bool>, "pinned": <bool>, "limit": <int>}}}` pre-seeding `ZaloEngine.polls` before steps run.
- `pins` *(optional, `polls`)*: map of `<convId>` to `PinnedList` JSON (`{"convId": "<convId>", "ready": <bool>, "canPin": <bool>, "limit": <int>, "items": [{"ref", "kind", "title", "sender", "thumb", "msgId", "cliMsgId"}]}`) pre-seeding `ZaloEngine.pins` before steps run.
- `board_raw_topics` *(optional, `polls`)*: map of `<convId>` to `{"version": <int64>, "topics": {"<topicId>": <raw topic JSON>}}` pre-seeding `ZaloEngine.cachedBoardRawTopics` before steps run.
- `poll_clock` *(optional, `polls`)*: `{"watched": {"<pollId>": "<convId>"}, "last_attempt_ms": {"<pollId>": <int64>}, "seen_messages": ["<msgId>", ...]}` pre-seeding `PollClock` (`watched`, `lastAttempt`, `seenMessages`) before steps run.
- `watched_check_ids` *(optional, `polls`)*: array of poll id strings (`["<pollId>", ...]`) used when `watchPoll` exceeds 500 watched entries and drops an arbitrary key; see `## Polls domain state`.

### server

Scripted answers, in the order they are consumed. Each request takes the first unconsumed entry with the same `kind` and `path` (entries with `"repeat": true` are never consumed).

- HTTP: `{"kind": "http", "path": "/api/...", "method": "GET|POST", "response": {"status": 200, "json": {...}}}` (optional `"hold": true`, default `false`). `json` is the plain body; the fake server encrypts it the way Zalo does for that endpoint (including ParamCipher endpoints and AES-CBC `data` encryption with `zpw_enk` for `/api/social/profile/me-v2` and long-poll `/`). Instead of `json`: `"raw": "<text>"`, or `"error": "timeout" | "refused" | "reset"`. When `"hold": true`, the fake server records and matches the request, then holds the HTTP reply open until an `{"http_release": k}` step releases it (used to observe in-flight `"sending"` state and echo-before-reply ordering deterministically without wall-clock delays).
- WebSocket: `{"kind": "ws", "path": "...", "accept": true}`.
- WebSocket server frames (`ws_frame`): `{"kind": "ws_frame", "cmd": <int>, "sub_cmd": <int>, "payload": {...}}` (optional `"encrypt": <0|1|2|3>`, optional `"key": "<base64>"`, optional `"delay_ms": <int>`). Unless `seed.ws_auth == "manual"`, the initial auth reply (`cmd == 1` immediately following a `"ws"` entry) is sent automatically when that WebSocket connects; when `seed.ws_auth == "manual"`, and for every subsequent `ws_frame`, the frame waits for a `ws_push` step and is sent in script order on the active connection. `payload` is the plain JSON body; the fake server encodes it as Zalo and `olaz-ws` expect for that `cmd` inside an RFC 6455 binary frame (`u8 version(1) | u16 LE cmd | u8 sub_cmd | UTF-8 JSON envelope`): `cmd == 1` defaults to `encrypt: 0` with a base64 `"key"` and JSON-stringified `"data"`, `cmd == 602` defaults to `encrypt: 0` with JSON-stringified `"data"`, and other `cmd`s default to `encrypt: 2` (AES-GCM 16-byte nonce + zlib when the connection established a cipher key on `cmd == 1`) or `encrypt: 1` (zlib) unless `"encrypt"` is explicitly given.
- WebSocket server drop (`ws_close`): `{"kind": "ws_close"}` (optional `"delay_ms": <int>`). Sends an RFC 6455 Close frame (`1000`) and closes the socket when triggered by a `ws_push` step (used to trigger disconnect/reconnect such as `ws_auth_watch`).
- A request with no matching entry is answered `{"error_code": 0, "data": {}}` and recorded with `"unscripted": true`. A case with an unscripted request is a recorder bug.

### steps

Run in order:

- Session / transport `cmd` steps: `{"cmd": "start" | "refresh_qr" | "log_out" | "session_expired" | "drain_chat_polling", "args": {...}}`.
  - `session_expired` takes `{"reason": "<text>"}`.
  - `drain_chat_polling` (`transport`, `conversations`, `conversation_actions`, `messages`, `bootstrap`, `send`, `message_actions`) calls `drainChatPolling(maxBatches, notifyIncoming)` with `{"max_batches": <int>, "notify_incoming": <bool>}`.
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
- Messages & bootstrap `cmd` steps (`messages` and `bootstrap` domains):
  - Optional `"now_ms": <int64>` on `cmd` steps seeds `nowMs` for the duration of that step (used for daily full-refresh freshness checks and mute `startTime` fallback).
  - `open`: `{"id": "<convId>"}` — calls `openConversation(id)` and awaits its async cache/history/profile/pins/mark-read task (and any triggered SQLite conversation persist) to finish.
  - `close`: `{}` — calls `closeConversation()`.
  - `load_older`: `{"id": "<convId>"}` — calls `loadOlderMessages(id)` and awaits its completion (`history_ticks` increment).
  - `bootstrap`: `{}` — runs `performBootstrapSync()` and awaits completion (when `start_bootstrap` was suppressed or re-run after setup).
  - `apply_batch`: same signature as `conversations` domain — calls `applyBatchResponse` directly (`probe_freshness: <bool, optional>`).
- Send `cmd` steps (`send` domain):
  - Optional `"now_ms": <int64>` on `cmd` steps seeds `nowMs` for the duration of that step (used for optimistic message `date` and `OutgoingTypingThrottle`).
  - `send_text`: `{"id": "<convId>", "text": "<str>", "quote_id": <str|null, optional>, "mentions": [{"uid", "pos", "len", "is_all"}, optional], "styles": [{"start", "len", "st"}, optional], "urgency": <int, optional>, "async": <bool, optional>}` — calls `sendText(...)` and records its boolean return in `last_send_result`. When `"async": true`, launches `sendText` in flight and waits until its optimistic row (and held HTTP request, if any) or immediate return is ready before continuing so callers can snapshot `"sending"` or push a WS echo prior to `http_release` + `await_send`.
  - `await_send`: `{}` — awaits an in-flight `async` `send_text` task, records its boolean return in `last_send_result`, and awaits any triggered SQLite conversation persist.
  - `open`, `close`, `apply_batch`: same as `messages` domain (`open` loads local/server messages while `hostTrace` skips U4 `mark_read` unless `mark_read` step is run explicitly).
  - `mark_read`: `{"id": "<convId>"}` — calls `ZaloEngine.markRead(id)` and awaits its SQLite unread-zero, unread-mark removal, and `sendSeenAPI` tasks (unlike `conversation_actions`, where `mark_read` calls `markConversationRead(id)`).
  - `notify_typing`: `{"id": "<convId>"}` — calls `notifyTyping(in: id)` and awaits any spawned `sendTypingAPI` task.
  - `handle_typing`: `{"state": {"typing": {"convId": "<convId>", "name": "<str>", "isPC": <bool>}}}` — calls `handleTyping(state: state)`.
  - `set_pref`: `{"key": "<prefKey>", "value": <bool|string|int|null>}` — sets a key in the isolated `UserDefaults` suite (e.g. `"olaz.sendTyping"`).
  - `clear_client_auth`: `{}` — clears session auth credentials (`zpwSek`) on `sessionClient` while keeping `ZaloEngine.phase == .ready`.
  - `await_typing_expiry`: `{"id": "<convId>"}` *(optional `"timeout_ms": N`)* — waits until `typing[id]` clears via its display timer (`TypingStatus.displaySeconds`, 10 s). Cases using this step carry `"slow": true`.
- Message actions `cmd` steps (`message_actions` domain):
  - Optional `"now_ms": <int64>` on `cmd` steps seeds `nowMs` for the duration of that step (used for `PendingLocalReaction.createdAt`, `applyRemoteReaction` 20 s echo expiry, `performRecall` 24 h check, `DeleteUndo.deadline` + 5 s sleep, `setAutoDelete` system row `ms`, and `pruneExpiredMessages` cutoff).
  - Inherits `open`, `close`, `apply_batch`, `send_text`, `await_send`, `clear_client_auth`, `drain_chat_polling`.
  - `react`: `{"conv_id": "<str>", "msg_id": "<str>", "emoji": "<str>", "async": <bool, optional>}` — calls `performReact(emoji, to: msg_id, in: conv_id)`. When `"async": true`, launches `performReact` in flight and waits until its held HTTP request arrives or it completes so callers can snapshot the optimistic reaction before `http_release` + `await_action`.
  - `await_action`: `{}` — awaits any in-flight `async` `react` task and any triggered `messageActionTasks` / SQLite persist.
  - `remove_my_reactions`: `{"conv_id": "<str>", "msg_id": "<str>"}` — awaits `performReact("", to: msg_id, in: conv_id, removeAll: true)`.
  - `recall`: `{"conv_id": "<str>", "msg_id": "<str>"}` — looks up `msg_id` (by `id` or `clientId`) in `messages[conv_id]` and awaits `performRecall(msg)`.
  - `recall_many`: `{"conv_id": "<str>", "msg_ids": ["<str>", ...], "confirm": <bool, optional>}` — selects `msg_ids` in `conv_id` via `beginSelection` / `toggleSelection` and calls `recallSelection()` (when `confirm` is omitted or `true`), or awaits `recallMessages(list)` when `"confirm": false`.
  - `delete_for_me`: `{"conv_id": "<str>", "msg_id": "<str>", "confirmed": <bool, optional>}` — looks up `msg_id` in `messages[conv_id]` and calls `deleteForMe(msg, confirmed: confirmed ?? false)`.
  - `delete_many`: `{"conv_id": "<str>", "msg_ids": ["<str>", ...]}` — selects `msg_ids` in `conv_id` via `beginSelection` / `toggleSelection` and calls `deleteSelection()`.
  - `undo_delete`: `{}` — calls `undoDelete()`.
  - `dismiss_delete_undo`: `{}` — calls `dismissDeleteUndo()` and awaits spawned delete API / SQLite tasks.
  - `await_delete_undo_expiry`: `{}` *(optional `"timeout_ms": N`)* — waits until `deleteUndo` clears via its 5 s timer and awaits the resulting commit tasks (under the 10 s `slow` mark).
  - `answer_confirm`: `{"ok": <bool>}` — if `messageConfirm` is active, calls `answerMessageConfirm(confirm, ok: ok)` and awaits any spawned `messageActionTasks`.
  - `star`: `{"conv_id": "<str>", "msg_id": "<str>", "on": <bool>}` — looks up `msg_id` in `messages[conv_id]`, calls `setStarred(msg, on)`, and awaits SQLite `starredIds` / row save.
  - `load_auto_delete`: `{}` — awaits `loadAutoDelete()`.
  - `set_auto_delete`: `{"conv_id": "<str>", "ttl": <int64>}` — awaits `setAutoDelete(conv_id, ttl: ttl)` and any triggered SQLite conversation persist.
  - `prune_expired`: `{"conv_id": "<str>"}` — calls `pruneExpiredMessages(in: conv_id)` (reading `nowMs`), records the returned next-expiry timestamp in `prune_next_expiry_ms` (`Int64?` ms, or `null`), and awaits SQLite row deletes.
- Contacts `cmd` steps (`contacts` domain):
  - Optional `"now_ms": <int64>` on `cmd` steps seeds `nowMs` for the duration of that step.
  - Inherits `open` and `close`.
  - `contacts_sync`: `{}` — awaits `performContactsSync()` and any triggered reaction-name SQLite writes.
  - `accept_request`: `{"id": "<uid>"}` — calls `acceptFriendRequest(id)` and awaits its async task (including any triggered `refreshContacts()` resync).
  - `decline_request`: `{"id": "<uid>"}` — calls `declineFriendRequest(id)` and awaits its async task.
  - `cancel_request`: `{"id": "<uid>"}` — calls `cancelFriendRequest(id)` and awaits its async task.
  - `send_request`: `{"id": "<uid>", "message": "<str>"}` — calls `sendFriendRequest(to: id, message: message)` and awaits its async task (including any triggered `refreshContacts()` resync).
  - `find_by_phone`: `{"phone": "<str>"}` *(optional `"async": <bool>`)* — calls `findFriend(byPhone: phone)` and awaits its async task (when `"async": true`, waits until the held request arrives or the task finishes so callers can snapshot `"searching"`).
  - `reset_search`: `{}` — calls `resetFriendSearch()`.
  - `contacts_state`: `{"json": {...}}` — calls `handleContacts(state: json)` with the adapter payload.
  - `lookup`: `{"uid": "<str>"}` — calls `lookupPersonInfo(uid)` and records `{"name": <str>, "avatar": <str>}` or `null` under `lookups["<stepIndex>"]`.
  - `mention_name`: `{"uid": "<str>"}` — calls `mentionDisplayName(uid)` and records `{"name": <str>, "avatar": ""}` or `null` under `lookups["<stepIndex>"]`.
  - `load_blocked`: `{}` — awaits `loadBlockedUsers()`.
  - `set_blocked`: `{"uid": "<str>", "blocked": <bool>, "name": "<str, optional>"}` — awaits `setBlocked(uid, blocked: blocked, name: name ?? "")`.
  - `save_alias`: `{"uid": "<str>", "name": "<str>"}` — awaits `saveAlias(uid: uid, name: name)` and records the returned `(ok, text)` in `last_alias_result`.
- Groups `cmd` steps (`groups` domain):
  - Optional `"now_ms": <int64>` on `cmd` steps seeds `nowMs` for the duration of that step (used for `persistSingleGroupConversation` `updated_at_ms` and `handleGroupEventNotice` `ts == 0` fallback).
  - Inherits `start`, `open`, `close`.
  - `create_group`: `{"name": "<str>", "members": ["<uid>", ...], "avatar": null | {"jpeg_b64": "<b64>", "side": <int>}}` — awaits `createGroup(name: name, members: members, avatar: avatar)` plus any triggered `contactsTasks` (contacts resync) / `persistConversationsTask`, and records the `GroupCreateOutcome` (`{"status": "created", "id": "<gid>", "failed": [...]}` or `{"status": "failed", "title": <str|null>, "message": "<str>", "closes": <bool>}`) in `results["<stepIndex>"]`.
  - `rename_group`: `{"id": "<gid>", "name": "<str>"}` — awaits `renameGroup(id, to: name)`.
  - `invite`: `{"id": "<gid>", "members": ["<uid>", ...]}` — awaits `inviteMembers(members, to: id)`.
  - `kick`: `{"id": "<gid>", "member": "<uid>"}` — awaits `kickMember(member, from: id)`.
  - `leave_group`: `{"id": "<gid>", "silent": <bool, optional>}` — awaits `leaveGroup(id, silent: silent ?? false)`.
  - `refresh_group`: `{"id": "<gid>"}` — awaits `refreshGroupMetadata(id)`.
  - `load_members`: `{"id": "<gid>"}` — awaits `loadGroupMembers(in: id)` and records `[{"id", "name", "avatar", "is_all"}, ...]` in `results["<stepIndex>"]`.
  - `set_admin`: `{"id": "<gid>", "uid": "<uid>", "admin": <bool>}` — awaits `setGroupAdmin(id, uid: uid, admin: admin)`.
  - `change_owner`: `{"id": "<gid>", "uid": "<uid>"}` — awaits `changeGroupOwner(id, uid: uid)`.
  - `block_member`: `{"id": "<gid>", "uid": "<uid>"}` — awaits `blockGroupMember(id, uid: uid)`.
  - `pending`: `{"id": "<gid>"}` — awaits `groupPendingMembers(id)` and records `null` or `[{"id", "name", "avatar"}, ...]` in `results["<stepIndex>"]`.
  - `review_pending`: `{"id": "<gid>", "uids": ["<uid>", ...], "approve": <bool>}` — awaits `reviewGroupPending(id, uids: uids, approve: approve)`.
  - `join_approval`: `{"id": "<gid>", "on": <bool>}` — awaits `setGroupJoinApproval(id, on: on)`.
  - `group_link`: `{"id": "<gid>"}` — awaits `groupLink(id)` and records `null` or `{"link", "enabled"}` in `results["<stepIndex>"]`.
  - `set_group_link`: `{"id": "<gid>", "renew": <bool>}` — awaits `setGroupLink(id, renew: renew)` and records `null` or `{"link", "enabled"}` in `results["<stepIndex>"]`.
  - `group_notice`: `{"act": "<str>", "data": {...}, "ts": <int64>}` — awaits `handleGroupEventNotice(act: act, data: data, ts: ts)`.
- Polls `cmd` steps (`polls` domain):
  - Optional `"now_ms": <int64>` on `cmd` steps seeds `nowMs` (and sets the virtual debounce clock) for the duration of that step (used for `watchPoll` 5 s retry throttle, `notePollMessages` 120 s freshness check and 1.5 s debounce, and pure-model deadline checks).
  - Inherits `start`, `open`, `close`.
  - `watch_poll`: `{"id": "<pollId>", "conv_id": "<convId>"}` — calls `watchPoll(id, in: conv_id)` and awaits spawned `pollRefreshTasks`.
  - `retry_poll`: `{"id": "<pollId>", "conv_id": "<convId>"}` — calls `retryPoll(id, in: conv_id)` and awaits spawned `pollRefreshTasks`.
  - `rewatch_polls`: `{}` — calls `rewatchPolls()` and awaits spawned `pollRefreshTasks`.
  - `refresh_poll`: `{"id": "<pollId>"}` — calls `refreshPoll(id)` and awaits spawned `pollRefreshTasks`.
  - `poll_voters`: `{"id": "<pollId>"}` — awaits `pollVoters(id)` and records `null` or `{"restricted": <bool>, "groups": [{"id", "content", "votes", "users": [{"uid", "name", "avatar", "is_me"}]}]}` in `results["<stepIndex>"]`.
  - `refresh_poll_pin`: `{"id": "<pollId>", "conv_id": "<convId>"}` — awaits `refreshPollPin(id, in: conv_id)` and records `{"ready", "can_pin", "pinned", "limit", "offers_pin"}` in `results["<stepIndex>"]`.
  - `pin_poll`: `{"id": "<pollId>", "conv_id": "<convId>", "confirming": <str|null>}` — awaits `pinPoll(id, in: conv_id, confirming: confirming)` and records `{"status": "done"}` | `{"status": "needs_confirmation", "ref", "limit", "kind", "title", "message"}` | `{"status": "failed", "ok", "error", "pin_skipped", "message"}` in `results["<stepIndex>"]`.
  - `unpin_poll`: `{"id": "<pollId>", "conv_id": "<convId>"}` — awaits `unpinPoll(id, in: conv_id)` and records `{"ok", "error", "pin_skipped", "message"}` in `results["<stepIndex>"]`.
  - `vote_poll`: `{"id": "<pollId>", "conv_id": "<convId>", "detail_from": "state" | <PollDetail JSON>, "draft": {"toggle": [...], "added": [{"text": <str>, "voted": <bool>}]}}` — builds `PollVoteDraft`, awaits `votePoll(...)` + `pollRefreshTasks`, and records `{"ok", "error", "pin_skipped", "message", "request": {"new_options": [...], "voted_ids": [...]}, "applied": <PollDetail>, "has_changes", "votes_nothing", "has_duplicates", "can_submit"}` in `results["<stepIndex>"]`.
  - `lock_poll`: `{"id": "<pollId>", "conv_id": "<convId>"}` — awaits `lockPoll(id, in: conv_id)` + `pollRefreshTasks` and records `{"ok", "error", "pin_skipped", "message"}` in `results["<stepIndex>"]`.
  - `share_poll`: `{"id": "<pollId>", "conv_id": "<convId>"}` — awaits `sharePoll(id, in: conv_id)` and records `{"ok", "error", "pin_skipped", "message"}` in `results["<stepIndex>"]`.
  - `create_poll`: `{"conv_id": "<convId>", "can_pin": <bool>, "config": <PollConfig JSON | null>, "draft": {"question", "options": [...], "has_deadline": <bool>, "deadline_ms": <int64>, "pin": <bool>, "multi": <bool>, "allow_add": <bool>, "hide_preview": <bool>, "anonymous": <bool>}}` — awaits `createPoll(...)` and records `{"ok", "error", "pin_skipped", "message", "spec": <PollCreateDraft.spec>}` in `results["<stepIndex>"]`.
  - `note_poll_messages`: `{"conv_id": "<convId>", "ids": [{"id": "<msgId>", "poll_id": "<pollId>", "date_ms": <int64>, "question": <str, optional>}]}` — constructs `[ChatMessage]` with `.poll` kind, calls `notePollMessages(...)` (using `nowMs` and the virtual debounce sleep seam), and parks any 1.5 s debounce timers.
  - `advance_ms`: `{"ms": <int64>}` — advances the virtual debounce clock by `ms`, triggers expired debounces, and awaits spawned `pollRefreshTasks`.
  - `poll_state`: `{"json": {...}}` — calls `handlePoll(state: json)`.
  - `pins_state`: `{"json": {...}}` — calls `handlePins(state: json)` to update `ZaloEngine.pins` mid-scenario.
  - `reset_polls`: `{}` — calls `resetPolls()` and cancels pending virtual debounces.
  - `poll_model_checks`: `{"checks": [...]}` — exercises pure poll model branches unreachable from engine actions and records outputs in `results["<stepIndex>"]`.
- Pins `cmd` steps (`pins` domain):
  - Optional `"now_ms": <int64>` on `cmd` steps seeds `nowMs` for the duration of that step.
  - Inherits `start`, `open`, `close`.
  - `refresh_board`: `{"conv_id": "<convId>"}` — awaits `refreshBoardPins(for: conv_id)`.
  - `pin_message`: `{"conv_id": "<convId>", "msg_id": "<msgId>"}` — locates the loaded message in `messages[conv_id]` and calls `pinMessage(message)` (and awaits any immediate pin task when `.allowed`).
  - `pin`: `{"conv_id": "<convId>", "msg_id": "<msgId>", "replacing": "<ref|null, optional>", "async": <bool, optional>}` — locates the loaded message in `messages[conv_id]` and calls `pin(message, replacing: replacing)`; when `"async": true`, returns as soon as the task parks on a held HTTP request so optimistic `pins` and busy-key suppression can be observed before `await_action`.
  - `await_action`: `{}` — awaits active message/pin action tasks and restores `nowMs`.
  - `request_unpin`: `{"conv_id": "<convId>", "ref": "<ref>"}` — locates the item in `pins[conv_id].items` and calls `requestUnpin(item, in: conv_id)`.
  - `request_unpin_message`: `{"conv_id": "<convId>", "msg_id": "<msgId>"}` — locates the loaded message in `messages[conv_id]` and calls `requestUnpin(message)`.
  - `answer_confirm`: `{"ok": <bool>, "async": <bool, optional>}` — calls `answerMessageConfirm(confirm, ok: ok)` for the active `messageConfirm`; when `"async": true`, returns once the triggered unpin/pin task hits held HTTP so optimistic removal/insertion can be observed before `await_action`.
  - `load_pinned`: `{"conv_id": "<convId>", "ref": "<ref>"}` — locates the item in `pins[conv_id].items`, awaits `loadPinnedMessage(item, in: conv_id)`, and records `<string|null>` in `results["<stepIndex>"]`.
  - `pin_event`: `{"act_type": "<str>", "act": "<str>", "data": {...}}` — evaluates `ZaloWireParser.pinTopicEventConversations(actType: act_type, act: act, data: data)`, records `[<convId>, ...]` in `results["<stepIndex>"]`, and calls `handlePinTopicEvent(conversationId:)` for each returned conversation id (awaiting triggered refresh tasks).
  - `pins_state`: `{"json": {...}}` — calls `handlePins(state: json)`.
  - `can_pin`: `{"conv_id": "<convId>", "msg_id": "<msgId>"}` — locates the loaded message in `messages[conv_id]`, calls `canPinMessage(message)`, and records `<bool>` in `results["<stepIndex>"]`.
  - `is_pinned`: `{"conv_id": "<convId>", "msg_id": "<msgId>"}` — locates the loaded message in `messages[conv_id]`, calls `isPinned(message)`, and records `<bool>` in `results["<stepIndex>"]`.
- `{"await": {"phase": "<kind>", "step": "<login step, optional>"}, "timeout_ms": 5000}`: wait until the state matches. The Rust runner instead runs the core until no input or effect is pending, then checks the same predicate.
- `{"await_host": "<call>", "timeout_ms": N}`: wait until the recorded `host` list contains `"<call>"` searching from the current host cursor, then advance the host cursor past that entry (`index + 1`). Used for deterministic ordering (for example awaiting `e2ee_connected` before `ws_push`).
- `{"ws_push": k}` (optional `"timeout_ms": N`): instruct the fake server to send the next `k` scripted `ws_frame` or `ws_close` entries in script order.
- `{"http_release": k}` *(optional `"timeout_ms": N`)*: instruct the fake server to send the next `k` held HTTP responses (`"hold": true`) in arrival order.
- `{"snapshot": "<label>"}`: record the state under `expect.snapshots[label]`.

### expect

- `snapshots`: label to state, as taken at each `snapshot` step.
- `final`: state after the last step, once nothing is pending.
- `requests`: every request that reached the fake server, canonical form, as a **sorted multiset** (sort by `kind`, then `path`, then the canonical JSON text). Concurrent requests have no stable order, so order is not compared.
  - HTTP: `{"kind": "http", "path", "method", "params": {...} | null, "query": {...}}`. `params` is the decrypted ParamCipher payload, keys sorted (`null` when absent or for unencrypted endpoints such as long-poll `GET /`). `query` is the plain query string, keys sorted. Signatures, encrypted blobs and the keys listed under Volatile become `"<volatile>"`.
  - WebSocket connect: `{"kind": "ws_connect", "path", "query": {...}}`.
  - WebSocket client→server frames (`ws_send`): `{"kind": "ws_send", "cmd": <int>, "sub_cmd": <int>, "payload": {...} | "<binary>"}`. `payload` is the decoded JSON body after the 4-byte binary header (`u8 version | u16 LE cmd | u8 sub_cmd`, `{}` when empty, `"<binary>"` when undecodable as UTF-8 JSON). Keepalive pings (`cmd == 2` and `cmd == 4`) are excluded because their count depends on wall time.
- `host`: ordered list of activities handed to Swift-owned code, `{"call": "<name>", "args": {...}}`. While recording, the engine's trace hook records these and skips the real activity (except where a lifecycle hook in `transport` / `conversations` / `conversation_actions` / `messages` / `bootstrap` / `send` / `message_actions` / `pins` must permit `prepare_store`, `apply_batch`, `apply_parsed_events`, `show_typing` in `send`, `apply_remote_reaction` / `apply_remote_recall` / `apply_remote_delete` in `message_actions`, `refresh_board_pins` / `pin_topic` in `pins`, or WS/long-poll startup so the domain under test runs).
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
    - `show_typing {conv_id, uid, on_pc}` *(traced at the call site with `uid`, before name lookup; skipped in earlier domains and allowed to run in `send`)*
    - `pin_topic {conv_id}` *(traced-and-skipped in `transport`, traced-and-allowed in `pins`)*
    - `group_notice {act, data, ts}`
    - `mute {conv_id, set, start, duration}`
    - `load_transport_state {}`
    - `persist_poll_state {state}`
    - `persist_ws_cursors {cursors}`
  - Messages and bootstrap domain names (Swift-owned U5–U16 boundaries):
    - `mark_read {conv_id}` *(U5 seen / unread handoff at the end of `openConversation`)*
    - `refresh_board_pins {conv_id}` *(U7 board pins refresh during `openConversation` and pin actions; traced-and-skipped in `messages`/`bootstrap`/`polls` and every other earlier domain, traced-and-allowed to run for real in `pins`)*
    - `apply_remote_reaction {conv_id, msg_id, cli_msg_id, sender_id, r_type, r_icon, event_id, react_client_id, sender_name}` *(U6 remote reaction handler; allowed to run in `message_actions`)*
    - `apply_remote_recall {conv_id, msg_id, cli_msg_id}` *(U6 remote recall handler; allowed to run in `message_actions`)*
    - `apply_remote_delete {conv_id, msg_id, cli_msg_id}` *(U6 remote delete handler; allowed to run in `message_actions`)*
    - `apply_mutes {mutes: [{"conv_id", "start", "duration"}]}` *(U16 mute list handoff during `performBootstrapSync`; `start` falls back to `now_ms / 1000` when `startTime` is absent)*
    - `refresh_cloud {}` *(U11 cloud snapshot refresh at the end of `performBootstrapSync`)*
  - Send domain names (Swift-owned U0b boundaries):
    - `send_e2ee_text {conv_id, text, client_id, quote}` *(E2EE 1-1 send boundary in `sendText`, invoked after the optimistic row is merged; `quote` is `null` or `{"msg_id", "cli_msg_id", "sender_id", "sender_name", "text", "ts_ms"}`, and the result is supplied by `seed.host_results.send_e2ee_text`)*
  - Message actions domain names (Swift-owned UI boundaries):
    - `show_card {conv_id, text}` *(banner notice shown via `CardActionCenter.shared.show(text, in: convId)` from U6 react, recall, delete undo, star, auto-delete, U7 pin/unpin/choose-many, U9 block/unblock, and U10 group admin / group link flows; `conv_id` is `<str|null>`; traced and skipped during recording)*
    - `show_card {conv_id, text}` *(banner notice shown via `CardActionCenter.shared.show(text, in: convId)` from U6 react, recall, delete undo, star, auto-delete, U9 block/unblock, and U10 group admin / group link flows; `conv_id` is `<str|null>`; traced and skipped during recording)*

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

## Send domain state

Cases in `send` extend the Messages and bootstrap domain state, adding per-message send metadata inside `messages[convId][]` and top-level send/typing fields:

```json
{
  "messages": {
    "3000001": [
      {
        "status": "sent",
        "quote": null | { "sender_name": "Alice", "text": "Hello", "msg_id": "1001", "cli_msg_id": "1001" },
        "mentions": [{ "uid": "3000001", "pos": 0, "len": 6, "is_all": false }],
        "text_styles": [{ "start": 0, "len": 5, "st": "b" }],
        "ttl_ms": 0,
        "urgency": 0,
        "menu": {
          "forward": "available",
          "recall": true,
          "delete": "for_me",
          "pin": false,
          "star": "star",
          "starred": false,
          "pinned": false,
          "protected": false
        }
      }
    ]
  },
  "typing": {
    "3000001": { "name": "Alice", "on_pc": false }
  },
  "last_send_result": true,
  "send_logs": []
}
```

- Each entry in `messages[convId][]` adds `status` (`"sending" | "sent" | "failed"`), `quote` (`null | {"sender_name", "text", "msg_id", "cli_msg_id"}`), `mentions` (`[{"uid", "pos", "len", "is_all"}]`), `text_styles` (`[{"start", "len", "st"}]`), `ttl_ms` (integer, `0` when off), `urgency` (`0 | 1 | 2`), and `menu` (`{"forward": "hidden" | "available" | "blocked", "recall": <bool>, "delete": null | "plain" | "for_me", "pin": <bool>, "star": null | "star" | "unstar" | "blocked", "starred": <bool>, "pinned": <bool>, "protected": <bool>}`).
- `typing` maps each conversation id with an active incoming indicator in `ZaloEngine.typing` to `{"name": <str>, "on_pc": <bool>}`.
- `last_send_result` is `null` before any `send_text` completes, then the boolean returned by the most recent `send_text` / `await_send`.
- `send_logs` holds `"sendText ..."` lines emitted via `EngineLog` (with the wall-clock `HH:mm:ss.SSS ` prefix stripped).

## Message actions domain state

Cases in `message_actions` extend the Send domain state, adding `buttons` to `messages[convId][]`, reaction/star fields to `store.messages[]` and `store.prefs`, and top-level message action state:

```json
{
  "messages": {
    "3000001": [
      {
        "buttons": [
          { "ref": "accept", "label": "Đồng ý", "enabled": true, "help": "" }
        ]
      }
    ]
  },
  "delete_undo": null | { "conv_id": "3000001", "count": 1, "deadline_ms": 1700000015000 },
  "message_confirm": null | {
    "conv_id": "3000001",
    "action": "delete_for_me" | "delete_many" | "recall_many" | "pin" | "unpin",
    "title": "Xóa tin nhắn",
    "message": "Tin nhắn sẽ chỉ bị xóa ở phía bạn.",
    "ok": "Xóa",
    "destructive": true
  },
  "auto_delete": null | { "3000001": 3600000 },
  "starred_ids": [],
  "prune_next_expiry_ms": null,
  "cached_profiles": {
    "3000001": { "name": "Alice", "avatar": "" }
  },
  "action_logs": [],
  "store": {
    "messages": [
      {
        "reactions": [{ "icon": "❤️", "count": 1, "includes_me": true }],
        "starred": false
      }
    ],
    "prefs": {
      "starred_ids": [],
      "seen_reaction_event_ids": []
    }
  }
}
```

- `messages[convId][].buttons` holds the message's `cardButtons` array (`[{"ref", "label", "enabled", "help"}]`).
- `delete_undo` is `null` or `{"conv_id", "count", "deadline_ms"}` (without the random `id` UUID).
- `message_confirm` is `null` or `{"conv_id", "action", "title", "message", "ok", "destructive"}`, where `action` is `"delete_for_me" | "delete_many" | "recall_many" | "pin" | "unpin"`.
- `auto_delete` is `null` before `loadAutoDelete` / `setAutoDelete` (unless seeded), otherwise a map of `<convId>` to TTL milliseconds.
- `starred_ids` is the sorted list of in-memory `cachedStarredIds`.
- `prune_next_expiry_ms` is `null` or the rounded epoch milliseconds returned by the most recent `prune_expired` step.
- `cached_profiles` mirrors in-memory `ZaloEngine.cachedProfiles` (`{"<uid>": {"name", "avatar"}}`).
- `action_logs` holds `"react failed..."`, `"recall failed..."`, and `"autodelete: ..."` lines emitted via `EngineLog` (with the wall-clock `HH:mm:ss.SSS ` prefix stripped).
- `store.messages[]` adds `reactions` (`[{"icon", "count", "includes_me"}]`) and `starred` (`<bool>`) decoded from `raw_json`.
- `store.prefs` adds `starred_ids` (sorted array from SQLite pref `starredIds`) and `seen_reaction_event_ids` (ordered array from SQLite pref `seenReactionEventIds`).

## Contacts domain state

Cases in `contacts` extend the Message actions domain state, adding `names` to `messages[convId][].reactions[]` and `store.messages[].reactions[]`, plus top-level contacts, identity, block, and alias state:

```json
{
  "contacts": {
    "friends": [
      {
        "id": "3000901",
        "name": "An Nguyễn",
        "zalo_name": "An Nguyễn",
        "avatar": "https://cdn.example.invalid/a.jpg",
        "last_active_ms": 1700000001000,
        "online": true,
        "section": "A",
        "sort_key": "an nguyen"
      }
    ],
    "groups": [
      {
        "id": "g500901",
        "name": "Nhóm A",
        "avatar": null,
        "members": 12,
        "sort_key": "nhom a"
      }
    ],
    "received": [
      {
        "id": "3000902",
        "name": "Bình",
        "avatar": null,
        "message": "Xin chào",
        "date_ms": 1700000002000
      }
    ],
    "sent": [],
    "pending_request_count": 1,
    "loading_requests": false,
    "search": {
      "status": "idle",
      "error": null,
      "user": null
    },
    "notice": null | { "seq": 1, "ok": true, "text": "Đã chấp nhận lời mời kết bạn." },
    "friends_loaded": true,
    "groups_loaded": true
  },
  "blocked_users": null | [{ "id": "3000905", "name": "Spam", "avatar": null }],
  "aliases": { "3000901": "Bạn thân" },
  "friend_global_ids": { "3000901": "gid_3000901" },
  "cached_group_details": ["500901"],
  "lookups": {
    "2": { "name": "Bạn thân", "avatar": "https://cdn.example.invalid/a.jpg" },
    "3": null
  },
  "last_alias_result": null | { "ok": true, "text": "Đã lưu tên gợi nhớ." }
}
```

- `contacts`: full snapshot of `ZaloEngine.contacts` (`ContactsState`). `search.user` when non-`null` is `{"id", "name", "zalo_name", "avatar", "bio", "is_friend", "is_self", "requested", "requesting", "default_message", "max_message"}`.
- `blocked_users`: `null` when `ZaloEngine.blockedUsers == nil`, otherwise an ordered list of `{"id", "name", "avatar"}`.
- `aliases`: map of `<uid>` to alias string (`ZaloEngine.cachedAliases`, keys sorted in canonical JSON).
- `friend_global_ids`: map of `<uid>` to `<globalId>` (`ZaloEngine.cachedFriendGlobalIds`, keys sorted in canonical JSON).
- `cached_group_details`: sorted array of clean group id keys in `ZaloEngine.cachedGroupDetails`.
- `lookups`: map of 0-based `steps` index string (`"0"`, `"1"`, ...) for each `lookup` or `mention_name` step executed so far to `{"name": <str>, "avatar": <str>}` or `null` (`mention_name` always records `avatar: ""` when non-`null`).
- `last_alias_result`: `null` before `save_alias`, otherwise `{"ok": <bool>, "text": <str>}` from the most recent `save_alias` step.
- `messages[convId][].reactions[]` and `store.messages[].reactions[]` add `"names": [<str>, ...]` (reactor display names refreshed by `refreshReactionNames()`).

## Groups domain state

Cases in `groups` extend the Contacts domain state (`cached_group_details` overrides the key-list array with the full detail dictionary map, and `store.prefs` adds `cached_groups`), adding group metadata, roles, navigation, and step results:

```json
{
  "cached_group_details": {
    "500901": { "name": "Nhóm A", "creatorId": "3000000" }
  },
  "group_member_cache": {
    "g500901": [
      { "id": "-1", "name": "All", "avatar": null, "is_all": true },
      { "id": "3000901", "name": "An Nguyễn", "avatar": null, "is_all": false }
    ]
  },
  "cached_groups": {
    "g500901": { "name": "Nhóm A", "avatar": "", "members": 2 }
  },
  "group_roles": {
    "g500901": { "owner": "3000000", "admins": ["3000901"], "join_approval": false }
  },
  "navigation_request": null | "g500901",
  "results": {
    "0": { "status": "created", "id": "g500901", "failed": [] },
    "1": [{ "id": "3000901", "name": "An Nguyễn", "avatar": null, "is_all": false }]
  },
  "group_logs": [],
  "store": {
    "prefs": {
      "cached_groups": {
        "g500901": { "name": "Nhóm A", "avatar": "", "members": 2 }
      }
    }
  }
}
```

- `cached_group_details`: map of `<cleanGrid>` to the full `ZaloEngine.cachedGroupDetails[cleanGrid]` dictionary (keys sorted in canonical JSON, URLs normalized).
- `group_member_cache`: map of `<gid>` to `ZaloEngine.groupMemberCache[gid]` (`[{"id", "name", "avatar", "is_all"}]`, preserving array order).
- `cached_groups`: map of `<gid>` to `{"name", "avatar", "members"}` from `ZaloEngine.cachedGroups`.
- `group_roles`: map of `<gid>` (all group ids present across `cached_group_details`, `contacts.groups`, `cached_groups`, `group_member_cache`, and group entries in `conversations`) to `{"owner": <str>, "admins": [<sorted str>], "join_approval": <bool>}` returned by `ZaloEngine.groupRoles(gid)`.
- `navigation_request`: `ZaloEngine.navigationRequest` string or `null`.
- `results`: map of 0-based `steps` index string (`"0"`, `"1"`, ...) for each `create_group`, `load_members`, `pending`, `group_link`, or `set_group_link` step executed so far.
- `group_logs`: holds `"group create failed: ..."`, `"group avatar upload failed: ..."`, `"rename group failed: ..."`, `"invite group members failed: ..."`, `"kick group member failed: ..."`, `"leave group failed: ..."`, and `"group admin: failed code=..."` lines emitted via `EngineLog` (with the wall-clock `HH:mm:ss.SSS ` prefix stripped).
- `store.prefs.cached_groups`: decoded JSON object from SQLite pref `"cachedGroups"` (`{}` when absent).

## Polls domain state

Cases in `polls` extend the Groups domain state with `polls`, `pins`, and `poll_clock` (`results` records poll action and pure-model step outcomes):

```json
{
  "polls": {
    "details": {
      "9001": {
        "id": "9001",
        "group_id": "g500101",
        "question": "Ăn trưa gì?",
        "creator": "2001001",
        "creator_name": "Polls User",
        "created_ms": null,
        "expires_ms": 1700086400000,
        "closed": false,
        "joined": true,
        "multi": true,
        "allow_add": true,
        "anonymous": false,
        "hide_preview": false,
        "voter_count": 2,
        "can_close": true,
        "total_votes": 2,
        "results_hidden": false,
        "voters_visible": true,
        "options": [
          { "id": "1", "content": "Phở", "votes": 1, "voted": true, "weight": 0.5 },
          { "id": "2", "content": "Bún", "votes": 1, "voted": false, "weight": 0.5 }
        ]
      }
    },
    "failed": [],
    "pins": {
      "9001": { "ready": true, "can_pin": true, "pinned": true, "limit": 5, "offers_pin": true }
    }
  },
  "pins": {
    "g500101": {
      "ready": true,
      "can_pin": true,
      "limit": 5,
      "items": [
        { "ref": "9001", "kind": "poll", "title": "Ăn trưa gì?", "sender": "Polls User", "thumbnail": null, "msg_id": "", "cli_msg_id": "" }
      ]
    }
  },
  "poll_clock": {
    "watched": ["9001"],
    "watched_count": 1,
    "watched_contains": null,
    "last_attempt_ms": { "9001": 1700010001000 },
    "seen_messages_count": 0,
    "pending_refresh_ids": []
  }
}
```

- `polls.details`: map of `<pollId>` to normalized `PollDetail` (including derived `total_votes`, `results_hidden`, `voters_visible`, and option `weight`).
- `polls.failed`: sorted array of poll ids in `ZaloEngine.polls.failed`.
- `polls.pins`: map of `<pollId>` to `PollPinState` (`{"ready", "can_pin", "pinned", "limit", "offers_pin"}`).
- `pins`: map of `<convId>` to `PinnedList` (`{"ready", "can_pin", "limit", "items": [{"ref", "kind", "title", "sender", "thumbnail", "msg_id", "cli_msg_id"}]}`).
- `poll_clock`: process-wide `PollClock` state (reset before and after every case):
  - `watched` is the sorted array of poll ids in `PollClock.watched` while its size stays `<= 500` and no 501st-entry eviction occurred (`!didEvictWatched`), or `null` once eviction occurred.
  - `watched_count` is `PollClock.watched.count`.
  - `watched_contains` is `null` until eviction occurs, at which point (if `seed.watched_check_ids` is set) it maps each named id to `<bool>` (verifying newly watched ids are kept without exposing the hash-arbitrary evicted key).
  - `last_attempt_ms` maps `<pollId>` to rounded epoch ms from `PollClock.lastAttempt` (filtered to `seed.watched_check_ids` once eviction has occurred).
  - `rewatchPolls` iteration order is harmless because `expect.requests` is compared as a sorted multiset.
- `refresh_board_pins` boundary: `refresh_board_pins` remains the U4 `traceU4Host` call (recorded in `expect.host` and skipped during recording without `host_results`); `pins` stays as seeded via `seed.pins` or updated via `pins_state` until U7 owns the board refresh.

## Pins domain state

Cases in `pins` extend the Groups domain state with `pins`, `cached_board_raw_topics`, and `pin_logs` (`results` records `load_pinned`, `pin_event`, `can_pin`, and `is_pinned` step outcomes; `message_confirm` and `messages` / `has_more_history` / `store.messages` capture pin confirmations and `load_pinned` reads):

```json
{
  "pins": {
    "g500701": {
      "ready": true,
      "can_pin": true,
      "limit": 3,
      "items": [
        {
          "ref": "88001",
          "kind": "message",
          "title": "Ghim 1",
          "sender": "An Nguyễn",
          "thumbnail": null,
          "msg_id": "9001001",
          "cli_msg_id": "6000001"
        }
      ]
    }
  },
  "cached_board_raw_topics": {
    "g500701": {
      "version": 4,
      "topic_ids": ["88001"]
    }
  },
  "pin_logs": []
}
```

- `pins`: map of `<convId>` to `PinnedList` (`{"ready", "can_pin", "limit", "items": [{"ref", "kind", "title", "sender", "thumbnail", "msg_id", "cli_msg_id"}]}`).
- `cached_board_raw_topics`: map of `<convId>` to `{"version": <int64>, "topic_ids": [<sorted string>]}` mirroring `ZaloEngine.cachedBoardRawTopics`.
- `pin_logs`: `"pins: ..."` lines emitted via `EngineLog` (with the wall-clock `HH:mm:ss.SSS ` prefix stripped).
- `refresh_board_pins` execution: in `pins`, `hostTrace` records `refresh_board_pins {conv_id}` in `expect.host` and returns `true` so `refreshBoardPins` fetches and parses the board for real; in all other domains `hostTrace` returns `false` and skips the fetch.

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
