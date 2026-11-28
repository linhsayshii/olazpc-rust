# ZaloAttest (Zalo PC 26.11.20, `zpw_ver 698`): what it attests and whether Olaz can satisfy it

Follow-up to `reanalysis/zalo-bump-26.11.20.md` (risk item 1). Read-only static analysis of the 26.11.20 DMG
(`ZaloSetup-universal-26.11.20.dmg`, SHA-256 `718d5093…8f36`). Nothing was executed, and nothing was sent to
Zalo servers. Offsets are byte offsets in the 26.11.20 files:

- `main.js` = `app.asar` → `main-dist/main.js`
- `login.js` = `app.asar` → `pc-dist/lazy/default-login-main-startup-shared-worker.459bb6df1994a71d701b.js`
- `ZaloAttest` = `Zalo.app/Contents/MacOS/ZaloAttest` (universal; addresses below are the arm64 slice,
  SHA-256 of the fat file `40c96863…c6d6`)
- `z_attest.node` = `app.asar.unpacked/native/nativelibs/z-attest/darwin_arm64/z_attest.node` (`dd08173f…84f3`)

## Verdict

**No.** Olaz cannot satisfy the check by running VNG's `ZaloAttest` the way it runs `ZaloCall`. Confidence:
high on the mechanism, medium-high on the exact outcome. The exact requirement string is encrypted inside the
daemon and was not recovered; see Q4.

- `ZaloAttest` is a caller-attestation daemon: it signs a statement about the code signature of the process on
  the other end of its UNIX socket.
- It reads that process's audit token (`getsockopt(SOL_LOCAL, LOCAL_PEERTOKEN)`). It then checks the caller's
  dynamic code signature against a policy requirement (`SecCodeCopyGuestWithAttributes` →
  `SecCodeCheckValidityWithErrors`).
- It writes the result (`peer.trusted` 0/1 plus a reason) into an attestation signed with a key embedded in the
  daemon.
- If Olaz spawns the daemon and connects, the caller is Olaz, not VNG-signed `com.vng.zalo`. The attestation
  would then say "untrusted", signed by VNG's own key.
- `ZaloCall` works for Olaz because `ZaloCall` does not care who launched it. `ZaloAttest` exists precisely to
  care.
- The remaining options are relaying the official app's attestation or extracting the embedded key. Both
  present Olaz as the official client, so both are out of scope.

## Q1. What is attested?

**The code signature of the calling process (the Electron main process of Zalo.app), plus anti-tamper state of
the daemon itself.** It does not attest hardware, the user or a server challenge on the login path.

- **No hardware or Apple attestation.** `ZaloAttest` links only `Security`, `CoreFoundation`, `libiconv` and
  `libSystem` (`otool -L`).
  - No DeviceCheck, App Attest, IOKit or Secure Enclave usage.
  - Its entitlements are an empty dict (`codesign -d --entitlements`).
- **Signing of the daemon itself:**
  - `Identifier=com.vng.zalo.zaloattest`, `TeamIdentifier=CVB6BX97VM`, hardened runtime (`flags=0x10000`).
  - Designated requirement: `identifier "com.vng.zalo.zaloattest" and anchor apple generic and certificate
    1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate
    leaf[subject.OU] = CVB6BX97VM`.
  - Version `0.3.10` (`__info_plist`).
  - Rust binary, 13.7 MB of arm64 `__text` for a small program. Together with the "compromised" exit path
    (below), this looks like an obfuscated or anti-tamper build.
- **Peer check (Security imports and call sites, arm64):**
  - `getsockopt(fd, 0 /*SOL_LOCAL*/, 6 /*LOCAL_PEERTOKEN*/, buf, 32)` at `0x100b7f2ec`: the 32-byte audit
    token of the connecting process.
  - `SecCodeCopyGuestWithAttributes(NULL, attrs, 0, &code)` at `0x100846d20`, with attributes keyed by
    `kSecGuestAttributeAudit`/`kSecGuestAttributePid` (both imported).
  - `SecRequirementCreateWithStringAndErrors` at `0x100455e14`. Its wrapper turns a Rust `&str` into a
    `CFString`, so the requirement is a text requirement.
  - `SecCodeCheckValidityWithErrors(code, 0, requirement, &err)` at `0x1009321e4` and `0x100b27740`.
  - `SecCodeCopySigningInformation` reads `kSecCodeInfoIdentifier`, `TeamIdentifier`, `Certificates`,
    `EntitlementsDict`, `Status`, `Flags`, `PList` and `MainExecutable`.
  - Readonly strings: `" lacks CS_VALID"`, `" has CS_DEBUGGED"` (`0xcde238`/`0xcde25e`); `"peer euid "`,
    `" != "` (`0xce6d1a`), so the caller must run as the same uid; `" untrusted "`, `" reason="`,
    `" trusted "` (`0xce6c17`…); `" id="`, `" signer="`, `" version="` (`0xce6b38`…).
- **Policy (`struct Policy` with `MacPolicy` and `WinPolicy`), serde field names at `0xcde0e8`/`0xcd9940` and
  nearby:**
  - `macos`: `requirement`, `self_requirement`, `min_version`, `allow_debugged`, `validate_resources`,
    `require_hardened_runtime`, `self_require_hardened_runtime`, `deny_entitlements`.
  - `windows`: `pins` (`spki-sha256:` / `cert-sha256:`), `subject_names`, `original_filenames`, `revocation`
    (`cache_only` / `online`).
  - Denied entitlements visible in clear: `com.apple.security.get-task-allow`,
    `com.apple.security.cs.disable-library-validation`,
    `com.apple.security.cs.allow-dyld-environment-variables`.
  - Electron debug switches checked on the caller: `--remote-debugging-port`, `remote-debugging-pipe`.
  - The policy values (the requirement strings) are **not** in clear text anywhere in the binary.
    - `anchor apple` and `identifier "` appear only in the code-signature blob, not in `__TEXT`.
    - `CVB6BX97VM` appears only in the code-signature blob.
    - The policy is parsed with `serde_json` (its error strings are present), so it is stored encrypted and
      decoded at run time.
  - The CLI has `serve`, `check-file`, `check-pid`, `policy` and `attest-info` (`0xcd9940`); the `policy`
    subcommand would print it. Running it was out of bounds here.
- **Self-protection:**
  - `proc_pidinfo(getpid(), PROC_PIDTBSDINFO)` at `0x1002c3c28` tests `PROC_FLAG_TRACED` (anti-debug).
  - `SecCodeCopySelf` and `self_requirement` let the daemon check its own signature.
  - On tamper it prints `exit: compromised (<point>) <signals>` and exits with code 86. `main.js` then marks
    the daemon compromised and never starts it again (`main.js@4770664`, `recordCompromised`).
- **Signing key:**
  - An X.509 leaf certificate is embedded at file offset `0xcdcfbb`:
    - subject `CN=z-attest macos 0.3.10-1819087`, issuer `CN=z-attest CA`, ECDSA P-256;
    - valid 2026-11-17 → 2031-11-17;
    - SHA-256 `2EC784515ADFCB3119D4CC3B02871E243FA68B61B1F60133943F515EB627D161`.
  - The daemon reports its hash as `attest_cert_sha256` in its ready line.
  - The matching private key is therefore inside the daemon, protected only by the obfuscation.
  - The server verifies the attestation against `z-attest CA`.
- **The attestation (`main.js@4762810` `ve()`, `@4775828`):**
  - It is base64url CBOR `{fmt:"z-attest", alg, data, …}`, where `data` is CBOR
    `{v, req?, peer:{trusted:0|1, reason?, signature:{verified_by}}, …}`.
  - `verified_by`: `NONE=0`, `OS=1`, `OS_NO_ROOT=2`, `EMBEDDED=3`.
  - Supported `v` = `[1]`; no optional features (`const ue=[1],de=[]` at `@4756408`).
  - The client only decodes `data` to show trust in the debug status bar. It cannot verify the signature,
    which the code marks `unverified:!0`.
- **No server challenge on login:**
  - `W.a(u)` is called without a challenge, so the `challenge` field (1..64 bytes, base64url) stays unset for
    `getLoginInfo`.
  - The only caller that passes one is companion linking (`login.js@1818904`), which passes the linking data
    as challenge, QoS only.

## Q2. How is it called?

```
renderer (login.js)  --$zattest.get(challenge?)-->  main (ipc "zattest-get", main.js@1400761)
  --> launcher (Ge/Le/Ue, main.js@4747297..4783000)
  --> spawn  <Zalo.app>/Contents/MacOS/ZaloAttest serve --endpoint <sock>      (main.js@4756965)
  --> UNIX socket, 4-byte BE length + JSON frames (<=16384 B)                (main.js@4761250)
```

- **Launch (`_e`, `main.js@4756965`):**
  - Before spawning, `z_attest.node` `verifyDaemonFile(path)` checks the binary on disk. After the ready line,
    `verifyDaemonProcess(pid, path)` checks the running process (`main.js@4765133`).
  - The addon checks the daemon against `identifier "com.vng.zalo.zaloattest"`. It also requires that the
    daemon's leaf certificate equals **the host process's own** leaf certificate.
    - Addon strings: `identifier "`, `com.vng.zalo.zaloattest`, `" is not this process's "`,
      `signer_mismatch`, `host_unsigned`, `"no signing certificate (ad-hoc or unsigned)"`.
    - An unsigned or ad-hoc host gives `host_unsigned`, and the launcher disables itself.
  - Disabled when `!app.isPackaged` (`"dev build (production only)"`, `main.js@4768502`), when `ZPC_ATTESTD=0`
    (`@4753586`), or when the platform is not darwin or win32.
- **Socket:**
  - `<userData>/attestd/attestd.sock`, or `$TMPDIR/zalo-attestd-<uid>/attestd.sock` when the path exceeds
    103 bytes (`main.js@4754018`).
  - Daemon default: `~/Library/Application Support/ZaloAttest/attestd.sock` (`ZaloAttest 0xce6bda`).
- **Ready line (stdout):** `{"event":"ready","token":<64 hex>,"endpoint","pid","version","build",
  "attest_cert_sha256"}`, parsed at `main.js@4757804`. The pid must equal the child pid.
- **Handshake (`main.js@4756596`):**
  - The client sends `{op:"auth",nonce:<32 random B>}`. The daemon answers `{nonce, proof}`, where
    `proof = HMAC-SHA256(token, "z-attestd auth v1 daemon\0" ‖ client_nonce ‖ daemon_nonce)`.
  - The client then sends `{op:"auth_confirm",proof:HMAC(token,"z-attestd auth v1 client\0"‖…)}`.
  - This only proves both ends know the per-launch token. **It does not identify the caller; the daemon does
    that separately through the audit token (Q1).**
- **Request:** `{op:"attest", challenge?, v?, require?}` → `{ok:true, attestation:"<b64url>"}`, or
  `{ok:false, error, message, received?, supported?}` (`main.js@4760151`).
- **Timeouts:**
  - start 15 s; ready 5 s; connect 5 s; reply 20 s;
  - whole request budget 25 s (`REQUEST_BUDGET_MS`);
  - the renderer waits 3 s for main when enforced and 30 s on the QoS-only path; the bridge default is 5 s
    (`I=3e3`, `T=3e4`, `v=5e3` at `login.js@2742011`);
  - retries 100/400 ms; restart interval 30 s; prefetched attestation reused for at most 5 min.
- **Error codes:**
  - Launcher `code` (`login.js@2738088` `5px/`): `no_bridge`, `bad_reply`, `timeout`, `error`, `disabled`,
    `deactivated`, `not_started`, `not_running`, `stopped`, `native_unavailable`, `not_found`,
    `endpoint_too_long`, `daemon_untrusted`, `daemon_exited`, `bad_ready`, `bad_frame`, `bad_token`,
    `bad_request`, `auth_required`, `attest_unavailable`, `unsupported_attestation_version`,
    `unsupported_feature`, `unsupported_platform`, `host_unsigned`, `spawn_failed`, `verify_timeout`,
    `malformed`, `busy`, `closed`, `compromised`.
  - **`app_attest_err` value** = `h(code, mainAnswered)` (`login.js@1814771`), which maps those codes onto
    `disabled`, `no_daemon`, `no_key`, `daemon_untrusted`, `unreachable`, `protocol`, `no_bridge`,
    `bridge_failed`, `timeout`, `deactivated`, `unsupported`, `malformed`, `endpoint_too_long`, `no_native`,
    `no_binary`, `unsupported_platform`, `host_unsigned`, `compromised`, `error`.
  - QoS sends the numeric form (1–18, 99) under command ids 168003–168009.
- **What `W.a(u)` does (`login.js@1814529` module `378F`, export `a`; bound as `W=a("378F")` at
  `login.js@12321105`; call at `@12333079`):**
  - If `features.attest.enable` is false, or the build is a dev build, it does nothing.
  - If `enforce` is false, it fires a background `$zattest.get()` for QoS only (attach result, trust, renderer
    "runtime env bits") and does **not** touch `u`.
  - If `enforce` is true, it awaits the result (3 s cap):
    - `ok` → `u.app_attest = <attestation>`;
    - failure → `u.app_attest_err = <code>`, unless the code is "not applicable" (`alXS` `b`, used for
      `host_unsigned` in staging).
  - Either way, `getLoginInfo` is **still sent**; `u` then goes into `encryptParam(u,"getlogininfo")`.
- The renderer also computes "runtime env bits" (`login.js@5487529`): tamper probes on `window`, such as a
  foreign `$znode`, non-native `XMLHttpRequest`/`WebSocket`, `__zalo*` globals, or an injected
  `webpackJsonp`. These go to QoS only, not into the attestation.

## Q3. When does it apply?

- **Server source:** `setttings.features.attest` (Zalo's typo; Olaz already reads `setttings`). It is applied
  by `bKKq.applyServerConfig` (`login.js@11514787`) from two places:
  - the `getServerInfo` handler (`… n.features … .attest`, near `login.js@11273295`);
  - the post-login settings handler (the same `setttings.features` block that carries `network_service` and
    `b2s_config`, near `login.js@6903992`).
- **Key names (correction to the bump note):**
  - The server keys are `enable`, `enable_on_login`, `enforce`, `enable_qos`, `deactivated`.
  - `z_attest_enable` / `z_attest_enable_on_login` / `z_attest_enforce` / `z_attest_enable_qos` are only the
    **localStorage** keys the renderer caches them under (`login.js@2738088`).
  - Defaults: `enable` 1, `enable_on_login` 1, `enforce` 0, `enable_qos` 1. Values are `true`/`false`/`0`/`1`.
  - `deactivated:true` stops the daemon and persists that state in main (`main.js@4781666`).
- **Scope:**
  - The value is sticky on the client (cached until the server sends a different one).
  - `getServerInfo` is pre-login and keyed by `imei` and `client_version`. A value from there is per device and
    client version, or global.
  - The post-login reader means the value can also be set per account.
  - From the client alone it is not possible to tell which scope VNG will use. Clients older than 698 have no
    daemon, so enforcing on them would lock out every older client. Enforcement therefore realistically targets
    698+ (or comes together with a minimum-version cut).
- **When enforced and attestation fails:**
  - The client does not block locally. It sends `getLoginInfo` with `app_attest_err=<code>` and no
    `app_attest`.
  - Whether the server then refuses or degrades is decided server-side and is not visible in the client.
  - An Olaz-made attestation would not fail; it would succeed with `peer.trusted=0` (Q4). The server can tell
    that apart from a genuine one.

## Q4. Can Olaz run it the way it runs `ZaloCall`?

**Mechanically, Olaz could spawn it and get a token. The token would not vouch for Olaz.**

- **Spawning and IPC are reproducible.**
  - `ZaloAttest serve --endpoint <path>` needs no parent-process check before it prints its ready line. Olaz
    could run the HMAC handshake with the token from stdout.
  - Nothing in `main.js` ties launch to Zalo.app except the optional addon check, which is VNG's check of the
    daemon, not the daemon's check of the caller.
- **The caller check is what fails:**
  - The attestation's `peer` block is computed from the connecting process's audit token and signature.
  - With Olaz as the caller:
    - Olaz is signed ad-hoc (`make-app.sh`) or with a non-VNG Developer ID. It is not `com.vng.zalo` and not
      team `CVB6BX97VM`.
    - Olaz carries `com.apple.security.cs.allow-jit` (not in the visible deny list), and its main executable
      is not Electron.
  - The encrypted `policy.macos.requirement` is almost certainly the official app's requirement (bundle
    `com.vng.zalo` and/or leaf `subject.OU = CVB6BX97VM`). The evidence:
    - the addon pins the daemon to "same leaf certificate as this process";
    - the deny list targets the entitlements that would let another process inject code into Zalo;
    - the `--remote-debugging-port` check targets the Electron main process specifically.
  - So Olaz would get `peer.trusted = 0` (reason ≠ 0). That is a correctly signed statement that the caller is
    not Zalo.
  - Even if the requirement were loose, the attestation records the caller's identity (`id=`/`signer=` are
    logged), and the server can reject on that.
- **What was not determined:**
  - The literal requirement string.
  - Whether the daemon refuses an untrusted peer outright (`"rejected: "` string, `0xce4ded`) or signs
    `trusted=0`. The client parser accepts both values.
  - Neither changes the verdict.
- **Paths that do not exist for Olaz:**
  - Making `SecCodeCheckValidityWithErrors` pass would need VNG's signing identity.
  - Producing a `trusted=1` attestation would need the embedded `z-attest` private key; extracting it means
    defeating the anti-tamper layer.
  - Asking the official Zalo.app to attest and forwarding its token would present Olaz as the official client.
    It also needs Zalo.app running, and Zalo allows one PC session per account anyway.
  - All three are spoofing and out of scope.
- **Paths that remain:**
  1. Stay on a client version the server does not enforce attestation for (today 695, and 694 on `main`).
  2. Watch the flags (Q5), and fail with a clear message instead of an opaque login error once enforcement
     reaches Olaz's version.
  3. If VNG ever publishes a supported third-party path, adopt it. None exists in the client.

## Q5. Detection for Olaz

Yes. Olaz already parses `getServerInfo` `setttings` (`rust/crates/olaz-net/src/login.rs:180`,
`ZaloSessionClient.swift:736`) and the `getLoginInfo` settings. To add detection:

- Read `setttings.features.attest` from both responses, and log its shape: `enable`, `enable_on_login`,
  `enforce`, `enable_qos` and `deactivated` as booleans only, into `engine.log`.
- When `enforce` is truthy for Olaz's `client_version`, show a non-blocking warning instead of letting
  `getLoginInfo` fail with an unexplained error. Suggested wording: "Zalo yêu cầu xác thực ứng dụng chính thức
  cho phiên bản này; Olaz có thể không đăng nhập được."
- Treat a `getLoginInfo` error that follows `enforce=true` as "attestation required", not as a generic login
  failure.
- Olaz must not send `app_attest` or `app_attest_err`. Both are claims about a ZaloAttest run that did not
  happen.
- A caveat: the official client may already hold a cached `enforce` before VNG sends it to everyone, so the
  first sign in Olaz may be the `getLoginInfo` failure itself. Logging the field on every `getServerInfo`
  makes that visible.

## Recommendation: when Olaz may move to 698

- **Not as a way to satisfy ZaloAttest.** At 698+, Olaz is exactly as exposed as an official client with a
  broken daemon.
  - While `enforce=false`, Olaz's wire behaviour at 698 is the same as the official client's: no `app_attest`
    params.
  - Two differences remain: the official client also sends QoS events 168003–168009, which Olaz would lack;
    and the Chrome 150 `sec-ch-ua`.
  - Once VNG flips `enforce` for 698, Olaz at 698 loses login.
- **Stay on 695 (beta.7) while the server still accepts it.**
  - 695 cannot be enforced without locking out every official 26.11.10 install. The risk there is a version
    retirement, which can be detected (forced-update or version errors).
  - At 698 the risk is a silent server flag.
- **Move to 698 only when the server forces it,** meaning a minimum-version cut or an update-required error for
  695. Ship the Q5 detection first, so a later flip shows a clear message.
- Re-check this note when VNG ships a ZaloAttest version other than `0.3.10`, or an attestation `v` other than
  `1`.

## Sources not committed

No VNG content is committed. `app.asar` was extracted into a scratch directory outside the repo, and only short
snippets are quoted above, with offsets.
