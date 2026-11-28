# Cloud files investigation — Zalo PC 26.11.10

Status: **reported file-only failure not yet reproduced or fixed**. Offline inspection
confirms that Olaz's cloud list has less complete data sources than the official
client. It does not establish which missing source caused this account's report.

## Source and offset convention

Inspected `/Applications/Zalo.app/Contents/Resources/app.asar` locally, without
launching Zalo or issuing account requests. All renderer offsets below are
**zero-based UTF-8 byte offsets within**:

`pc-dist/lazy/default-login-main-startup-shared-worker-znotification.4bb5e1e2c2e9bab4f7b3.js`

They are not offsets in app.asar and not JavaScript UTF-16/string indices. No
vendor files are included in this repository.

## Two distinct official data paths

### zCloud → Cloud của tôi

- At byte **13349272**, the `MY_CLOUD` screen selects its media-list component with
  `sendToMeId` as the conversation. At **13210984**, the file control selects
  **`share.file`**.
- The list loader beginning around **13197308** calls
  `CloudService.filterAndSort`, with the selected conversation and type, an offset
  of `(page - 1) * limit`, and a limit. It supports size and date sorting.
- `CloudService.filterAndSort` at **63253** delegates to its model; the model
  at **25938** delegates to its local implementation.
- The local implementation at **21294** filters by **`zConv`** and **`zType`**,
  selecting the **CONV_SIZE / CONV_DATE** indexes. Its getAll operation ultimately
  queries **Core.ZCloud**, not the ordinary Message table (getAll at **17523557**).
- Thus zCloud's actual file screen consumes an independently populated cloud
  index. Its visible list call itself does not directly fetch Media Store pages.

### Conversation → Kho lưu trữ / shared media

- At **16342182**, the files category is defined with `cate: file`, `type: file`,
  and a dedicated files DB name.
- At **12422348**, the HTTP builder selects **media_store_send2me** and
  **GET /api/media/oneone/list**, command **12220**, for `sendToMeId`. The command
  registry also records this at **2690266**.
- The encrypted JSON `params` contains `media_type` (`file` for files), optional
  `limit` and `last_id`; optional numeric `lastFetchId` is also supported. Self
  requests omit `group_id` and `imei`; the group variant adds those and uses
  `/api/mediastore/list`, command 11841.
- Response handling at **12063154** decrypts and reads `items`, `has_more`, and
  `last_id`. Mapping at **12064248** preserves the record id, global/client message
  ids, owner, timestamp, filename/title/extension, size, source and thumbnail URLs,
  and file/folder metadata. The server record's **`type: file`** is separate from
  a chat message's `msgType` and from zCloud's `zType`.
- Paging at **12066683** follows `last_id` and `has_more`; results enter the
  official client's separate media index.
- Crucially, **11841197 / 11841393** select between this Media Store source and
  cloud-message history according to
  `media_settings.load_media_from_cloud_message.my_cloud`. The current account's
  flag value was not inspected. Media Store is not a universal replacement for
  the zCloud path above.

## What the Olaz source establishes

On base `b9ba165`:

- `ZaloEngine+Cloud.swift` calls the Rust cloud list when the core is present.
- `olaz-core/src/reduce/cloud.rs` builds local kind tags including `file`, merges
  SQLite results with in-memory messages, and does not ask either the official
  ZCloud index or a server media index for missing items.
- `olaz-store/src/store.rs::cloud_media_items` queries **messages**, allows `file`,
  and reads the name and size from the normalized file kind. There is no positive
  size requirement that would hide a zero-byte file.
- `olaz-wire/src/message.rs` already maps `share.file` to `Kind::File`. The separate
  ZDB numeric type mapping already recognizes both 19 and 23 as files. Changing
  the wire-message normalizer to additionally accept 23 has no demonstrated
  connection to this report and is not retained.
- `cloud_item_from_message` and `cloud_item_from_stored` both retain file items.
  Existing synthetic cloud cases `list_store_only`, `list_memory_merge`, and
  `fetch_and_thumbnail` cover local lists/file handling.
- `ZaloEngine+SharedMedia.swift` also reads only the local message index. This is
  a separate limitation; replacing that method is not evidence of fixing the
  zCloud screen.
- `olaz-api/src/history.rs::fetch_history` supports cloud-message history, but
  cloud listing does not page it to obtain media absent from local history.
- `olaz-api/src/cloud.rs` handles quota/settings snapshots, not the separate
  ZCloud item index consumed by the official zCloud list.

The missing data-source coverage is confirmed. Whether the tester's missing files
are absent locally, misparsed on receipt, or present only in a server/cloud index
is **not** established. The fact that other kinds appear does not distinguish
these possibilities.

## WIP disposition

Commit **8565c27** preserves the previous model's entire unverified implementation
(excluding skills/) and was pushed before review. It adds roughly 2,178 lines,
including an unwired Shared Media API/FFI surface, broad media mapping, file-list
caches, and the speculative numeric-23 normalization.

It cannot be accepted as a verified fix: it introduces account requests to a
source different from the actual zCloud list, has no test based on the reported
failure, and includes an arbitrary ten-page cap that can make global sorting
incomplete. Its new response-page Debug derivation also includes content-bearing
message fields and a raw cursor. A synthetic test expecting a Media Store fetch
would test that proposed implementation, not establish the cause of the report.

Commit **4c6d784** reverts that WIP. The WIP remains recoverable in branch history;
no speculative runtime code or wire changes remain. No recorded cases were
rewritten and no known-diffs entries were added.

An attempted baseline test shell was stopped while still queued in olaz-heavy,
before cargo started. Therefore it supplies **no failing-test evidence**.

## Minimum evidence that would settle the report

Under a separately authorized tester/coordinator run, inspect one missing file
while opening the actual Olaz and official zCloud file screens:

1. Establish whether its ordinary normalized message exists in Olaz SQLite and
   what kind tag it has. Only report presence, kind and parser shape; keep real
   identifiers/names/URLs local.
2. Establish whether the official copy is in Core.ZCloud, the separate File/media
   index, or both; record the account's My Cloud source-selector boolean.
3. For the selected source, capture only the relevant request/response **shape**,
   paging fields and item type. Remove credentials, cookies, keys, identifiers,
   URLs and content before making a synthetic fixture. For encrypted zCloud
   records, determine the existing client's decoding/mapping stage rather than
   requesting or publishing private keys.
4. Confirm the exact screen involved. Build a failing test from that sanitized
   shape, implement its supported source through pure reduce + effects, then run
   the requested Rust and Swift checks before claiming resolution.

No live run, account traffic, full gate, or real account capture was performed
for this investigation. A passing baseline suite must not be reported as live
acceptance of this unresolved file-only bug.
