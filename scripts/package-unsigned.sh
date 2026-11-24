#!/bin/zsh
# Builds an ad-hoc signed (not notarized) Olaz and packages it like scripts/release.sh does:
# dist/Olaz-<version>-unsigned.dmg and dist/Olaz-<version>-unsigned.zip.
# Used by the release workflow when no Developer ID secrets are configured. Users must clear the quarantine
# attribute (xattr -dr com.apple.quarantine /Applications/Olaz.app) or right-click → Open on first launch.
#
#   OLAZ_VERSION=1.2.0 OLAZ_UNIVERSAL=1 ./scripts/package-unsigned.sh
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${OLAZ_VERSION:-1.0}"
APP="build/Olaz.app"
DIST="dist"
ZIP="$DIST/Olaz-$VERSION-unsigned.zip"
DMG="$DIST/Olaz-$VERSION-unsigned.dmg"

unset OLAZ_SIGN_IDENTITY
OLAZ_VERSION="$VERSION" ./scripts/make-app.sh release
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -d --entitlements - "$APP" 2>/dev/null | grep -q allow-jit || { echo "error: JIT entitlement missing" >&2; exit 1; }

mkdir -p "$DIST"
rm -f "$ZIP" "$DMG"
ditto -c -k --keepParent "$APP" "$ZIP"

STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Olaz" -srcfolder "$STAGE" -ov -quiet -format UDZO "$DMG"
rm -rf "$STAGE"

echo "Unsigned release $VERSION ready:"
ls -la "$DIST"
