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

Or run the `release` workflow manually from the Actions tab. The published release contains `Olaz-<version>.dmg` and `Olaz-<version>.zip` (named `Olaz-<version>-unsigned.*` when built without signing secrets) plus `SHA256SUMS.txt`. Verify with `shasum -a 256 -c SHA256SUMS.txt`. A version with a suffix (`v1.2.0-beta.1`) is published as a pre-release.

## Signed vs unsigned builds

- **All five secrets set**: the app is signed with a Developer ID Application certificate, notarized and stapled.
- **Secrets missing**: the workflow publishes an ad-hoc signed "unsigned" build and labels it so. Users must right-click, Open on first launch, or run `xattr -dr com.apple.quarantine /Applications/Olaz.app`.

The app is always signed with the JIT entitlement from `scripts/Olaz.entitlements` (needed by JavaScriptCore).

## Secrets

Add under Settings, Secrets and variables, Actions.

| Secret | Content |
|---|---|
| `MACOS_CERT_P12_BASE64` | Base64 of the exported Developer ID Application certificate and private key (`.p12`) |
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

`./scripts/release.sh` does the same signing and notarization on your Mac (needs `OLAZ_SIGN_IDENTITY` and a notarytool keychain profile `OLAZ_NOTARY_PROFILE`). Run `./scripts/build-rust.sh` first.

## Troubleshooting

- **Build fails on Rust targets**: `build-rust.sh` runs `rustup target add` for `aarch64-apple-darwin` and `x86_64-apple-darwin`; the runner needs Rust 1.88 or newer.
- **Notarization rejected**: fetch the log with `xcrun notarytool log <submission-id>`; usual causes are a missing hardened runtime or an unsigned nested binary.
- **Gatekeeper blocks an unsigned build**: see "Signed vs unsigned builds" above.
