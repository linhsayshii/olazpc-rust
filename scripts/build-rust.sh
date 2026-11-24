#!/bin/zsh
# Builds the Rust core (rust/crates/olaz-ffi) into rust/build/OlazCoreFFI.xcframework (universal arm64 + x86_64
# static library + UniFFI C header/modulemap) and regenerates the Swift bindings in Sources/OlazCore/OlazCore.swift.
# The generated Swift file IS committed: `swift build` only needs the (git-ignored) xcframework, so re-run this script
# after pulling Rust changes, and commit the regenerated Swift file when the exported API changed.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

export PATH="$HOME/.cargo/bin:$PATH"
if [[ -z "${DEVELOPER_DIR:-}" && "$(xcode-select -p 2>/dev/null || true)" == "/Library/Developer/CommandLineTools" ]]; then
    for candidate in /Applications/Xcode.app/Contents/Developer /Applications/Xcode-beta.app/Contents/Developer; do
        if [[ -f "$candidate/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib" ]]; then
            export DEVELOPER_DIR="$candidate"
            break
        fi
    done
fi
# Match Package.swift's platform so the linker sees no deployment-target mismatch.
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-26.0}"

TARGETS=(aarch64-apple-darwin x86_64-apple-darwin)
INSTALLED="$(rustup target list --installed)"
for t in $TARGETS; do
    if ! grep -qx "$t" <<<"$INSTALLED"; then
        echo "==> rustup target add $t"
        rustup target add "$t"
    fi
done

RUST="$ROOT/rust"
BUILD="$RUST/build"
XCF="$BUILD/OlazCoreFFI.xcframework"
rm -rf "$XCF" "$BUILD/universal" "$BUILD/bindings" "$BUILD/headers"
mkdir -p "$BUILD/universal" "$BUILD/bindings" "$BUILD/headers"

cd "$RUST"
for t in $TARGETS; do
    echo "==> cargo build --release -p olaz-ffi --target $t"
    cargo build --release -p olaz-ffi --target "$t"
done

LIBS=()
for t in $TARGETS; do LIBS+=("$RUST/target/$t/release/libolaz_ffi.a"); done
lipo -create $LIBS -output "$BUILD/universal/libolaz_ffi.a"

echo "==> uniffi-bindgen (Swift)"
cargo run --quiet --release -p uniffi-bindgen -- generate \
    --library "$RUST/target/aarch64-apple-darwin/release/libolaz_ffi.a" \
    --language swift --out-dir "$BUILD/bindings"

cp "$BUILD/bindings/OlazCoreFFI.h" "$BUILD/headers/OlazCoreFFI.h"
cp "$BUILD/bindings/OlazCoreFFI.modulemap" "$BUILD/headers/module.modulemap"

echo "==> xcodebuild -create-xcframework"
xcodebuild -create-xcframework \
    -library "$BUILD/universal/libolaz_ffi.a" -headers "$BUILD/headers" \
    -output "$XCF"

mkdir -p "$ROOT/Sources/OlazCore"
cp "$BUILD/bindings/OlazCore.swift" "$ROOT/Sources/OlazCore/OlazCore.swift"
echo "Built $XCF and Sources/OlazCore/OlazCore.swift"
