#!/bin/zsh
# Builds Olaz without notarization and packages it like scripts/release.sh does: dist/Olaz-<version>.dmg + .zip.
#
#   OLAZ_SIGN_IDENTITY=<sha1 or name>  sign with a fixed identity (the self-signed "Olaz Release Signing" cert):
#                                      stable signature, so Keychain items and privacy permissions survive updates.
#   unset                              ad-hoc signature, artifacts get an "-unsigned" suffix.
#
# Neither is notarized: users clear the quarantine attribute once (xattr -dr com.apple.quarantine /Applications/Olaz.app)
# or right-click → Open on first launch. Used by the release workflow when no Developer ID secrets are configured.
#
#   OLAZ_VERSION=1.2.0 OLAZ_UNIVERSAL=1 OLAZ_SIGN_IDENTITY=93B3E5FF... ./scripts/package.sh
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${OLAZ_VERSION:-1.0}"
APP="build/Olaz.app"
DIST="dist"
SUFFIX=""
[[ -z "${OLAZ_SIGN_IDENTITY:-}" ]] && SUFFIX="-unsigned"
ZIP="$DIST/Olaz-$VERSION$SUFFIX.zip"
DMG="$DIST/Olaz-$VERSION$SUFFIX.dmg"

OLAZ_VERSION="$VERSION" OLAZ_SIGN_NOTARIZABLE=0 ./scripts/make-app.sh release
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -d --entitlements - "$APP" 2>/dev/null | grep -q allow-jit || { echo "error: JIT entitlement missing" >&2; exit 1; }
codesign -dr - "$APP" 2>&1 | grep designated

mkdir -p "$DIST"
rm -f "$ZIP" "$DMG"
ditto -c -k --keepParent "$APP" "$ZIP"

STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Olaz" -srcfolder "$STAGE" -ov -quiet -format UDZO "$DMG"
rm -rf "$STAGE"
[[ -n "${OLAZ_SIGN_IDENTITY:-}" ]] && codesign --force --sign "$OLAZ_SIGN_IDENTITY" "$DMG"

echo "Release $VERSION ready (not notarized):"
ls -la "$DIST"
