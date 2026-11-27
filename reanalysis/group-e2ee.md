# Group E2EE (Sender Key) — Step 0 Feasibility & Gating Analysis

**Date:** 2026-11-27  
**Scope:** Read-only investigation for U17 (`rust-core-plan/u17-group-e2ee`) Step 0.  
**Bundles inspected (character offsets in minified JS):**
- **Pinned Olaz runtime:** `~/Library/Application Support/Olaz/ZaloRuntime/current/Contents/Resources/app.asar` (`package.json` version `26.10.20`), main renderer/worker bundle `pc-dist/lazy/default-login-main-startup-shared-worker-znotification.d9141cdf23123a5c2330.js` (`17,201,548` chars) and `pc-dist/lazy/lang-en.d1f111fc88da27995037.js`.
- **Installed official Zalo.app:** `/Applications/Zalo.app/Contents/Resources/app.asar` (`package.json` version `26.11.10`), bundle `pc-dist/lazy/default-login-main-startup-shared-worker-znotification.4bb5e1e2c2e9bab4f7b3.js`.

---

## 1. How a Group Gets Switched to E2EE

### 1.1 UI Entries in the Official PC Bundle

1. **Existing group — Conversation Info Rightbar (`$s` / `Zs`, pinned `@9406087–9410200`, official `@9622967`):**
   - Visibility component `$s` (`@9409908`) renders `Zs` only if:
     ```js
     t && u.default.e2ee.enable && !v.default.isOA(t) && t !== u.default.sendToMeId && !qs.q.isCommunityFromInfo(e)
     // and when n = String(t).startsWith("g"):
     !(n && !u.default.e2ee.enable_group) && !(n && u.default.e2ee.group.deactivated) && !u.default.e2ee.invisible
     ```
   - Clicking `Zs` invokes the `XsgR` hook (`@10089800–10091800`):
     1. Checks admin/owner (`Ws.b`, module `ymzo` `@16263012`) and member cap (`max_members >= totalMember`).
     2. Opens `E2EE_ONBOARDING` modal (`@3829072`), then on confirm opens `E2EE_SETUP` modal and runs `N()`:
        - Calls `getFullInfoGroupById(groupId)`, checks `memberIds.length >= e2ee.group.min_members` (`1`), and calls:
          ```js
          initSessionGroup(groupId, memberIds, GROUP_INIT_TYPE.CREATE, {handleUI: true, generateMsg: true})
          ```
2. **Group creation modal (`CREATE_GROUP_COMPOSE`, pinned `@8141648–8145000`, `@8154005`):**
   - Checkbox `STR_E2EE_GROUP_INIT_CHECKBOX_TITLE` ("End-to-end encryption") renders only if:
     ```js
     e2ee.enable_group && e2ee.group.can_enable_right_in_creation_step && !e2ee.group.deactivated
     ```
     (Both `can_enable_right_in_creation_step` (`false`) and `deactivated` (`true`) block this.)
   - On confirm (`needInitE2ee === true`, `@8142100`):
     1. Calls `getMemberIncompatibleInGroup([myUid, ...memberIds])` (`CHECK_COMPATIBLE_GROUP`, cmd `562`).
     2. If compatible (`errorCode === 0 && listUserIncompatible.length === 0`), creates a normal group via HTTP `GET /api/group/create/v2` (cmd `12443`, `@12147643`).
     3. Opens `E2EE_SETUP` and calls `initSessionGroup(conv.userId, topMemberIds, GROUP_INIT_TYPE.CREATE, {handleUI: true, generateMsg: true})`.

### 1.2 Protocol / API / WebSocket Commands

There is **no separate HTTP "upgrade group to E2EE" endpoint**. Switching an existing (or newly created) group to E2EE uses WebSocket `SignalCommands.INIT` (pinned `@3196266`, official `@3265354`):

1. **Compatibility check — `CHECK_COMPATIBLE_GROUP` (`cmd = 562`, `subCmd = 0`, pinned `@12293788`, official `@12562387`):**
   - Request payload: `{reqId, data: {uids, groupId, enableEE: 1}}` (where `groupId` is the numeric group ID without `"g"`, or `""` during pre-creation check).
   - Response: `{error_code: 0, data: {data: {err, compatible: [{uid, deviceId}], incompatible: [...]}}}`.
2. **Sender Key creation & fan-out — `INIT_SESSION_GROUP` (`cmd = 561`, `subCmd = 0`, pinned `@5008170–5010100`, `@5038050`, `@12294199`):**
   - `GroupSession.init` (`@5009689`) resolves compatible `(uid, deviceId)` pairs (excluding self's current `(userId, deviceId)`), creates a Signal `SenderKeyDistributionMessage` via `sessionBuilder.create(senderKeyName)` (`@5009000`), and serializes it.
   - For each `(uid, deviceId)` in `DeviceIds` (`MOBILE: 0`, `WEB: 1`, `PC: 2`, `SYSTEM: 3`), `sendInitSessionGroupToUser` (`@5030429`) ensures a 1-1 Signal session (`ensureTargetSession`), encrypts the `SenderKeyDistributionMessage` bytes with `encryptMessageAsync`, and sends `cmd = 561`:
     ```json
     {
       "cmd": 561,
       "subCmd": 0,
       "data": {
         "reqId": "<reqId>",
         "data": {
           "type": 0,
           "uidTo": "<uid>",
           "data": [{"deviceId": 0, "data": "<cipher>", "ts": "<timestamp_ms>"}],
           "tId": "<numericGroupId>"
         }
       }
     }
     ```
     (`GROUP_INIT_TYPE`: `CREATE = 0`, `REINIT = 1`, `RESPONSE = 2`, `@3201676`).
   - Once sent, `initSessionGroup` marks the group enabled locally (`setEnableE2ee(groupId)`, `@5039000`).
3. **Peer handling & other group E2EE commands:**
   - Recipients of `cmd = 561` (`type: 0` `CREATE`, `onReceiveInitGroup`, `@5032100–5034131`) decrypt the 1-1 cipher, call `sessionBuilder.process(senderKeyName, SenderKeyDistributionMessage)`, reply with `cmd = 561` (`type: 2` `RESPONSE`), and call `setEnableE2ee(groupId)`.
   - Server list sync: `GET /api/group/getlg/e2ee` (`cmd = 12146`, `getE2eeGroupList`, `@12140660`).
   - Downgrade / error acks: `DOWNGRADE_E2EE_GROUP` (`cmd = 582`, `@12303144`), `ACK_PROCESS_INIT_GROUP_FAILED` (`cmd = 559`), `ACK_GROUP_SESSIONS_STALE` (`cmd = 546`).
   - Group E2EE message send paths: `CHAT_E2EE_GROUP` (`16100–16113`, `16203–16204`, `@2625900–2626500`).

### 1.3 Who May Switch a Group & Member/Version Conditions

- **Role (`In0l.a`, `@In0l`, via `ymzo` `@16263012`):** Only the **group owner (`creatorId`) or an admin (`isAdmin: true` in `topMember`)**. Non-admins see `STR_E2EE_GROUP_NOT_GROUP_OWNER_OR_ADMINS` ("Only available for group owner or admins") in the UI and receive `ERR_COMPATIBLE.NO_ADMIN_RIGHTS (-6)` from `CHECK_COMPATIBLE_GROUP`.
- **Group type:** Normal groups only; OA and Community groups are excluded (`!isOA(t) && !isCommunityFromInfo(e)`, `$s` `@9409908`).
- **Member count (`NDmK` `@6805860`):** `min_members: 1` (checked in `XsgR`) to `max_members: 10` (checked in `Ws.b`, `validateBeforeInit` `@5034131`, and `CREATE_GROUP_COMPOSE` `@8136277`). Note `CREATE_GROUP_COMPOSE` also requires selecting `> 1` invitees (`enableConfirm: s.length > 1`, `@8139224`) when creating a brand-new group.
- **Server compatibility errors (`E2EE_GROUP.ERR_COMPATIBLE`, `@3200121`):**
  - `-2` (`NOT_IN_BETA`): member not in server's E2EE group beta allowlist (`STR_E2EE_NOT_EXIST_IN_BETA_USERS`).
  - `-3` (`VERSION_NOT_SUPPORT`) / `-5` (`MY_SUBDEVICES_NOT_SUPPORT`): one or more members or one of the initiator's own subdevices (`MOBILE`/`PC`/`WEB`) is on an unsupported app version.
  - `-9` (`MY_SUBDEVICES_BUNDLE_KEY_NOT_EXIST`): initiator's subdevice missing uploaded Signal prekey bundle.
  - `-7` (`USER_NOT_ACCESS_ANY_DEVICES_FOR_A_LONG_TIME`): member inactive for too long without accessible devices.
  - `-10` (`USER_IN_BLACKLIST`) / `-11` (`I_AM_IN_BLACKLIST`): E2EE blacklist.
  - `-6` (`NO_ADMIN_RIGHTS`): caller is not owner/admin.

### 1.4 Can the PC Client Switch a Group to E2EE, or Only the Phone?

**The official Zalo PC client CANNOT switch a group to E2EE** (verified in both pinned `26.10.20` and installed `Zalo.app` `26.11.10`):

- Module `A9FD` hardcodes **`DEACTIVATE_E2EE_GROUP: !0`** (`true`) at pinned `@3205550` / official `@3274638`.
- `mergeGroupSetting(e)` (pinned `@10354271` / official `@10583932`) unconditionally runs:
  ```js
  u.i.DEACTIVATE_E2EE_GROUP && (o.group.debug.enable = !1, o.group.deactivated = !0)
  ```
- As a result, `e2ee.group.deactivated` is **always `true`** on PC regardless of server config:
  - Both UI entry points (`$s` `@9409908` and `CREATE_GROUP_COMPOSE` `@8154005`) return `null` / hide the option.
  - `GroupManager.isOnE2ee(e)` (`@5050840`) and `e2eGroupManager.isOnE2ee(e)` (`@7412294`) always return `false`.
  - `validateBeforeInit` (`@5034131`) and `getCompatibleMembersFromServer` (`@5031340`) immediately throw `DEACTIVATED`.
- Therefore, switching a group to E2EE (if still enabled on the server at all) can **only be done on mobile (phone)** or via a custom client speaking `cmd 562` / `cmd 561`. (Note: PC with `DEACTIVATE_E2EE_GROUP: !0` cannot even send/receive E2EE group messages.)

---

## 2. Gating Flags & Server Config Sources

### 2.1 Client Defaults (`NDmK`, pinned `@6804182–6806500`, official `@6966037+`)

| Flag | Default in `NDmK` | Effective on PC |
|---|---|---|
| `e2ee.enable` | `false` | Overridden by `settings.features.e2ee.enable` |
| `e2ee.enable_group` | `false` | Overridden by `settings.features.e2ee.group_enable` |
| `e2ee.invisible` | `false` | Overridden by `settings.features.e2ee.invisible` |
| `e2ee.group.deactivated` | `true` | **Forced `true`** by `A9FD.DEACTIVATE_E2EE_GROUP = true` |
| `e2ee.group.can_enable_right_in_creation_step` | `false` | Merged from `settings.features.e2ee.group`, still blocked by `deactivated` |
| `e2ee.group.max_members` | `10` | Overridden by `settings.features.e2ee.group_max_members` or `group.max_members` |
| `e2ee.group.min_members` | `1` | Merged from `settings.features.e2ee.group` |
| `e2ee.group.can_disable` | `true` | Merged from `settings.features.e2ee.group` |
| `e2ee.group.debug.enable` | `false` | **Forced `false`** by `A9FD.DEACTIVATE_E2EE_GROUP = true` |

### 2.2 Where Server Values Come From

`mergeSetting(e)` (pinned `@10352745`, official `@10582911`) -> `mergeGroupSetting(e)` (pinned `@10354271`, official `@10583932`) is fed by two endpoints:

1. **Pre-login `GET /api/login/getServerInfo`** (pinned `@6726591`):
   - Reads `response.setttings.features.e2ee` (note Zalo's triple-`t` key `setttings`) and calls `mergeSetting(t.setttings.features.e2ee)`.
2. **Authenticated login `GET /api/login/getLoginInfo`** (`cmd = 11134`, pinned `@11819726`, `@12137288`):
   - Reads `response.data.data.settings.features.e2ee` (`t.config.settings.features.e2ee`) and calls `mergeSetting(t.config.settings.features.e2ee)`.

Field mapping inside `mergeSetting` / `mergeGroupSetting`:
- `e2ee.enable` ← `settings.features.e2ee.enable`
- `e2ee.enable_group` ← `settings.features.e2ee.group_enable` (if `!= null`)
- `e2ee.group` ← `{...default.group, ...(settings.features.e2ee.group || {})}`
- `e2ee.group.max_members` ← `settings.features.e2ee.group_max_members` (if truthy)
- `e2ee.group.deactivated` ← **unconditionally overwritten to `true`** (`u.i.DEACTIVATE_E2EE_GROUP && (o.group.debug.enable = !1, o.group.deactivated = !0)`).

### 2.3 `isOnE2ee(convId)`

- **Group path (`GroupManager.isOnE2ee` `@5050840` & `e2eGroupManager.isOnE2ee` `@7412294`):**
  ```js
  isOnE2ee(e) {
    return !A.default.e2ee.group.deactivated && this.store.checkGroupE2ee(e);
  }
  ```
- `this.store.checkGroupE2ee(e)` checks `this.enabledGroups` (`Set`), populated from:
  1. Local DB record `COMMON_INFO_ID` (`"g1000"`, `syncDataFromDb` `@4960341`), gated on `!e2ee.group.deactivated`.
  2. Server sync `GET /api/group/getlg/e2ee` (`cmd = 12146`, `fetchAllFromServer` `@5018684`).
  3. Incoming `INIT_SESSION_GROUP` (`cmd = 561`, `type: 0` `CREATE`) or `groupInfo.e2ee` change (`onGroupInfoChange` `@5024186`), cleared on `DOWNGRADE_E2EE_GROUP` (`cmd = 582`).

---

## 3. Local Olaz State (Shapes Only, No User Identifiers)

### 3.1 Server Settings in Olaz

Inspected `Sources/Olaz/ZaloRuntime/Protocol/ZaloSessionClient.swift`, `Sources/Olaz/ZaloRuntime/Protocol/ZaloE2EEManager.swift`, `native-session.json`, and `UserDefaults`:

- Olaz parses `getServerInfo` and `getLoginInfo` **only in memory** for service-map domains, `trusted_device` (`qr_format_trust_device`, `self_g`), and profile metadata.
- Olaz **does not persist `settings.features` or `settings.features.e2ee`** anywhere on disk (`native-session.json` stores only session/domain bootstrap fields).
- Consequently, server-returned `settings.features.e2ee` flags (`group_enable`, `group.deactivated`, `enable`, etc.) are **not stored locally by Olaz**.

### 3.2 SQLite `preferences` (Read-Only Shape Summary)

Opened local account SQLite preference tables read-only; no identifiers, keys, or tokens are recorded:

- **Account A:**
  - `e2eeThreadsV1`: `13` one-to-one entries, `0` groups (verified against `conversations.is_group`).
  - `zaloE2EEPCStoreV1`: Signal store present (`19` prekeys, `7` sessions).
  - `cachedGroups`: `103` groups, `0` entries with an `e2ee` flag.
- **Account B:**
  - `e2eeThreadsV1`: absent (`0` entries).
  - `zaloE2EEPCStoreV1`: Signal store present (`25` prekeys, `0` sessions).

---

## 4. Could a Two-Account Test Group Be Switched to E2EE?

- **Via official Zalo PC (`26.10.20` / `26.11.10`) or current Olaz:** **No.**
  - Official PC hardcodes `DEACTIVATE_E2EE_GROUP = true`, forcing `e2ee.group.deactivated = true` and disabling both UI triggers and `CHECK_COMPATIBLE_GROUP` / `INIT_SESSION_GROUP`. Olaz currently rejects all group IDs in `ZaloE2EEManager`.
- **Via mobile (phone) or a custom client:** **Unknown without a live check (cannot be confirmed from local Olaz files alone).**
  - **Known satisfied locally:** Both accounts (account A and account B) have active Signal stores in Olaz, and a 2-account group (note: Zalo PC's group creation UI requires selecting `>= 2` invitees / `>= 3` total members, though removing the 3rd member leaves 2) meets `min_members (1) <= N <= max_members (10)` and has an owner/admin.
  - **Unknowns requiring a phone check or live server response (`getLoginInfo` / `CHECK_COMPATIBLE_GROUP` `562`):**
    1. Whether the mobile Zalo app still exposes group E2EE at all (given PC hardcoded `DEACTIVATE_E2EE_GROUP: !0`, Zalo may have discontinued or gated group E2EE server-side).
    2. Whether the server allows both accounts (`settings.features.e2ee.group_enable` and no `NOT_IN_BETA: -2` / `VERSION_NOT_SUPPORT: -3` / `MY_SUBDEVICES_NOT_SUPPORT: -5` / `MY_SUBDEVICES_BUNDLE_KEY_NOT_EXIST: -9` across the accounts' mobile, web, and PC subdevices).
