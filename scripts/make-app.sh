#!/bin/zsh
# Bundles the swift-build output into Olaz.app
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -z "${DEVELOPER_DIR:-}" && "$(xcode-select -p 2>/dev/null || true)" == "/Library/Developer/CommandLineTools" ]]; then
    for candidate in /Applications/Xcode.app/Contents/Developer /Applications/Xcode-beta.app/Contents/Developer; do
        if [[ -f "$candidate/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib" ]]; then
            export DEVELOPER_DIR="$candidate"
            break
        fi
    done
fi

CONFIG="${1:-release}"
# Bundle id. Cookies, WebKit storage (the synced message DB), preferences and privacy permissions are keyed by it;
# LegacyMigration.swift brings the session over from the SwiftZalo builds' `dev.swiftzalo.app`.
BUNDLE_ID="app.olaz.mac"
# Marketing version and build number; scripts/release.sh sets them for a tagged release.
VERSION="${OLAZ_VERSION:-1.0}"
BUILD_NUMBER="${OLAZ_BUILD:-$VERSION}"
./scripts/build-rust.sh
# OLAZ_UNIVERSAL=1 builds arm64 + x86_64 (release workflow); default is the host architecture only.
# Each architecture is built on its own and the slices are joined with lipo: a single multi-arch
# `swift build --arch arm64 --arch x86_64` fails to link the OlazCoreFFI xcframework on Xcode 26.6
# ("library not found for -lolaz_ffi"). Some build systems reuse one output directory for every
# architecture, so each slice is copied out before the next build.
if [[ "${OLAZ_UNIVERSAL:-0}" == 1 ]]; then
    mkdir -p build
    SLICES=()
    for arch in arm64 x86_64; do
        swift build -c "$CONFIG" --arch "$arch"
        BIN_DIR="$(swift build -c "$CONFIG" --arch "$arch" --show-bin-path)"
        cp "$BIN_DIR/Olaz" "build/Olaz-$arch"
        SLICES+=("build/Olaz-$arch")
    done
    lipo -create $SLICES -output build/Olaz-universal
    rm -f $SLICES
    BIN="build/Olaz-universal"
else
    swift build -c "$CONFIG"
    BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
    BIN="$BIN_DIR/Olaz"
fi

APP="build/Olaz.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/Olaz"
lipo -info "$APP/Contents/MacOS/Olaz"
cp Assets/olaz.icns "$APP/Contents/Resources/AppIcon.icns"

# SwiftPM resource bundle (JSModules/, Resources/) — found via ResourceLocator.
RES_BUNDLE="$BIN_DIR/Olaz_Olaz.bundle"
if [[ -d "$RES_BUNDLE" ]]; then
    cp -R "$RES_BUNDLE" "$APP/Contents/Resources/"
else
    echo "warning: $RES_BUNDLE missing — JS modules will not load" >&2
fi

cat > "$APP/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Olaz</string>
    <key>CFBundleDisplayName</key><string>Olaz</string>
    <key>CFBundleExecutable</key><string>Olaz</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.social-networking</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
    <key>NSUserActivityTypes</key>
    <array>
        <string>INSendMessageIntent</string>
    </array>
    <!-- Calls: the native call helper (ZaloCall, from the Zalo runtime Olaz installs) is started by Olaz, so macOS attributes
         its microphone / camera access to Olaz and shows these texts in the permission prompts. -->
    <key>NSMicrophoneUsageDescription</key>
    <string>Olaz cần dùng micro để bạn nói chuyện trong cuộc gọi Zalo. / Olaz needs the microphone so people can hear you in Zalo calls.</string>
    <key>NSCameraUsageDescription</key>
    <string>Olaz cần dùng camera để người khác nhìn thấy bạn trong cuộc gọi video Zalo. / Olaz needs the camera so people can see you in Zalo video calls.</string>
</dict>
</plist>
PLIST

# Sign with the JIT entitlement so JavaScriptCore can JIT the JS modules.
# OLAZ_SIGN_IDENTITY="Developer ID Application: ..." (set by scripts/release.sh) signs for distribution:
# hardened runtime + secure timestamp are what notarization requires. Unset = ad-hoc dev build.
# OLAZ_SIGN_NOTARIZABLE=0 signs with a fixed identity (the self-signed "Olaz Release Signing" cert) without the
# notarization extras: same runtime behavior as the ad-hoc build, but a stable designated requirement, so Keychain
# items and privacy permissions survive updates.
if [[ -n "${OLAZ_SIGN_IDENTITY:-}" && "${OLAZ_SIGN_NOTARIZABLE:-1}" == 0 ]]; then
    codesign --force --sign "$OLAZ_SIGN_IDENTITY" --entitlements scripts/Olaz.entitlements "$APP"
elif [[ -n "${OLAZ_SIGN_IDENTITY:-}" ]]; then
    codesign --force --timestamp --options runtime --sign "$OLAZ_SIGN_IDENTITY" \
        --entitlements scripts/Olaz.entitlements "$APP"
else
    codesign --force --sign - --entitlements scripts/Olaz.entitlements "$APP"
fi

echo "Bundled $APP"
echo "Launch with: open $APP"
