# Releasing Olaz

Releases are built by GitHub Actions on a `macos-26` runner. Workflows live in `.github/workflows/`.

## Workflows

| File | Trigger | What it does |
|---|---|---|
| `ci.yml` | push, pull request | Rust build and `cargo test`, `swift build`, `swift test` |
| `release.yml` | tag `v*` pushed, or manual run | builds a universal (arm64 + x86_64) `Olaz.app`, makes DMG and ZIP, publishes a GitHub Release with SHA-256 sums |

## Cutting a release

```bash
git tag v1.2.0
git push origin v1.2.0
```

Or run the `release` workflow manually from the Actions tab. The published release contains `Olaz-<version>.dmg` and `Olaz-<version>.zip` (named `Olaz-<version>-unsigned.*` when built without any certificate) plus `SHA256SUMS.txt`. Verify with `shasum -a 256 -c SHA256SUMS.txt`. A version with a suffix (`v1.2.0-beta.1`) is published as a pre-release.

## Signing modes

The workflow picks a mode from the secrets that exist:

| Mode | Secrets | Result |
|---|---|---|
| `notarized` | all five | Developer ID signature, hardened runtime, notarized and stapled. Opens without warnings. |
| `fixed` (current) | `MACOS_CERT_P12_BASE64` + `MACOS_CERT_PASSWORD` only | Signed with the self-signed **Olaz Release Signing** certificate. Every release has the same designated requirement (`identifier "app.olaz.mac" and certificate root = H"93b3e5ff88608c172c0278522ba2ec95f59581c1"`), so Keychain items and microphone/camera permissions survive updates. Not notarized. |
| `adhoc` | none | Ad-hoc signature, artifacts suffixed `-unsigned`. The signature changes on every build. Not notarized. |

For `fixed` and `adhoc`, users clear the quarantine attribute after each download (`xattr -dr com.apple.quarantine /Applications/Olaz.app`), or open the app once and click Open Anyway in System Settings → Privacy & Security. Right-click → Open no longer bypasses Gatekeeper on macOS 15 and later.

### The Olaz Release Signing certificate

- Self-signed, RSA 2048, Extended Key Usage `codeSigning`, valid until 2036-11-21. SHA-1 `93B3E5FF88608C172C0278522BA2EC95F59581C1`.
- The maintainer keeps the only copy of the private key outside the repository (`~/.olaz-signing/olaz.p12`, password in `olaz.p12.password`). Back it up in a password manager: losing it means the next release has a different signature and users get one Keychain prompt and re-grant permissions.
- Upload it as secrets:

  ```bash
  base64 -i ~/.olaz-signing/olaz.p12 | gh secret set MACOS_CERT_P12_BASE64
  gh secret set MACOS_CERT_PASSWORD < ~/.olaz-signing/olaz.p12.password
  ```

- Sign a local build with the same identity: `security import ~/.olaz-signing/olaz.p12 -P "$(cat ~/.olaz-signing/olaz.p12.password)" -T /usr/bin/codesign`, then `OLAZ_SIGN_IDENTITY=93B3E5FF88608C172C0278522BA2EC95F59581C1 ./scripts/package.sh`.
- Switching to a Developer ID later changes the designated requirement once.

The app is always signed with the JIT entitlement from `scripts/Olaz.entitlements` (needed by JavaScriptCore).

## Secrets

Add under Settings, Secrets and variables, Actions.

| Secret | Content |
|---|---|
| `MACOS_CERT_P12_BASE64` | Base64 of the signing certificate and private key (`.p12`): Developer ID Application, or the Olaz Release Signing cert |
| `MACOS_CERT_PASSWORD` | Password chosen when exporting the `.p12` |
| `APPLE_API_KEY_P8_BASE64` | Base64 of the App Store Connect API key (`AuthKey_XXXX.p8`) used by `notarytool` |
| `APPLE_API_KEY_ID` | Key ID of that API key |
| `APPLE_API_ISSUER_ID` | Issuer ID shown on the App Store Connect API keys page |

### Preparing them

1. In Keychain Access, export the "Developer ID Application: ..." identity as `cert.p12` with a password.
2. In App Store Connect, Users and Access, Integrations, create an API key (Developer access is enough for notarization) and download the `.p8` once.
3. Encode and copy:

   ```bash
   base64 -i cert.p12 | pbcopy      # MACOS_CERT_P12_BASE64
   base64 -i AuthKey_XXXX.p8 | pbcopy   # APPLE_API_KEY_P8_BASE64
   ```

4. Delete the local `.p12` and `.p8` copies when done.

## Local release

`./scripts/release.sh` does the Developer ID signing and notarization on your Mac (needs `OLAZ_SIGN_IDENTITY` and a notarytool keychain profile `OLAZ_NOTARY_PROFILE`). `./scripts/package.sh` builds the `fixed` (with `OLAZ_SIGN_IDENTITY`) or `adhoc` packages. Add `OLAZ_UNIVERSAL=1` for arm64 + x86_64.

## Troubleshooting

- **Build fails on Rust targets**: `build-rust.sh` runs `rustup target add` for `aarch64-apple-darwin` and `x86_64-apple-darwin`; the runner needs Rust 1.88 or newer.
- **Notarization rejected**: fetch the log with `xcrun notarytool log <submission-id>`; usual causes are a missing hardened runtime or an unsigned nested binary.
- **Gatekeeper blocks a `fixed` or `adhoc` build**: see "Signing modes" above.
