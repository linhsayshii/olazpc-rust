# Global sender ID recovery after phone sync

Offline investigation on Zalo PC 26.11.10, using
`/Applications/Zalo.app/Contents/Resources/app.asar`. Offsets below are byte offsets
inside `pc-dist/compact-app-pc.cfeba43a9a8e4e40dda3.js`; the member begins at
archive byte 51311022.

- `getGlobalNoiseId` starts at 15069707 (endpoint literal at 15069908): GET
  `/api/gid/encrypt`, AES-encrypted object with `noiseUids` as an array.
- `getUidFromGlobalNoiseId` starts at 15069931 (endpoint literal at 15070156):
  GET `/api/gid/decrypt`, AES-encrypted object with `globalUids` as a JSON array
  encoded into a string.
- `_get` at 15062027 appends URL parameters; `_request` at 15060617 sets
  the HTTP method to `get` for that path.
- `getGlobalIdFromServer` at 19842315 and `getUserIdFromServer` at 19842721
  each retry once after an error. `getUserId` at 19843338 and `getGlobalId` at
  19843557 filter cached entries and pass the remaining array to those helpers;
  these helpers impose no fixed batch cap. The sync-v2 sub-worker contains the
  same endpoint implementations (endpoint literals at 15298628 and 15298876).

The old Olaz implementation already used 200-ID GET batches and skipped failed
chunks before PR #27 (present at e5a52a4). The regression test sends 200 synthetic
32-character global IDs through the real query builder: the resulting URL is
over 8 KiB. A local fake proxy rejecting that size reproduces an empty result in
the old Swift implementation. HTTP/2 carries the same query in `:path`, which
can also count toward a header-field limit. This proves a pre-existing oversized
request and missing recovery; it does not establish whether HTTP/2 introduced a
new limit on the production route. No live account traffic was used.

The fix preserves GET and both official parameter types. Batches are capped at
50 IDs and a 2048-byte serialized payload before encryption. These are Olaz
safety limits, not a claim about an official cap. HTTP 414/431 split recursively;
transient HTTP/network errors retry once and then split to a bounded depth.
Authentication/cancellation stop immediately. Failed leaves are not cached and
can be retried on a later sync/open.

On a failed transfer lookup, the importer intentionally preserved the global
sender ID in the message. Later profile lookup sanitized that opaque ID away,
so opening the conversation could never resolve it. The core now resolves the
stored 32-byte Sync2 sender IDs before fetching profiles, replaces sender IDs
with canonical UIDs in the visible window, and saves repaired rows. The repair
persists even if profile fetching is temporarily unavailable; the next open can
then fetch profiles directly. It preserves message/client IDs, body, and the
existing reaction-preservation option. Existing rows repair as their chat or
older history is opened; this is not an eager rewrite of the whole database.

Other batch lookup paths were checked: `/api/social/group/members` and its
`getprofiles/v2` fallback are POSTs with 50 IDs per batch; group metadata
`/api/group/getmg-v2` is POST with 50 groups; preload
`/api/preloadconvers/get-last-msgs` is GET capped at 25 thread IDs. `gid/encrypt`
shares the new bounded/splitting policy. No transport headers or cookie policy
were changed by this fix, and no IDs, names, or response data were added to logs.
