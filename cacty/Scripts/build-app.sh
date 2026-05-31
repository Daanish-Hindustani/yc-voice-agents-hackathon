#!/bin/bash
#
# Cacty — build the .app bundle from the SwiftPM `cacty-app` executable.
#
# SwiftPM doesn't directly produce .app bundles, but macOS needs a
# real bundle structure (Contents/{MacOS, Info.plist, ...}) for:
#   - TCC to honor NSMicrophoneUsageDescription / NSSpeechRecognitionUsageDescription
#     and show permission prompts instead of crashing
#   - LSUIElement to actually keep the app out of the Dock
#   - Codesigning to attach a stable identity for permission persistence
#
# This script:
#   1. swift builds the `cacty-app` executable
#   2. Creates `build/Cacty.app/Contents/{MacOS, Resources}`
#   3. Copies the binary and Info.plist into place
#   4. Ad-hoc codesigns the bundle (`-s -`) — enough for TCC on the
#      developer's machine. Production needs Developer ID signing
#      via Scripts/build-release.sh (Phase 4 polish).
#
# Usage:
#   ./Scripts/build-app.sh                   # debug build
#   ./Scripts/build-app.sh --release         # release build
#
# Then:
#   open build/Cacty.app
# or
#   build/Cacty.app/Contents/MacOS/Cacty     # foreground, log to stderr

set -euo pipefail

REPO_ROOT="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." &> /dev/null && pwd )"
cd "$REPO_ROOT"

CONFIG=debug
EXTRA_BUILD_FLAGS=()
if [[ "${1:-}" == "--release" ]]; then
    CONFIG=release
    EXTRA_BUILD_FLAGS+=("-c" "release")
fi

# Bundle is named CactyVoice.app (not Cacty.app) on purpose: the Privacy &
# Security lists label each row by the .app *filename*. With two "Cacty.app"
# bundles on disk, macOS showed indistinguishable "Cacty" / "Cacty2" rows, so
# you couldn't tell which to grant. A distinct bundle filename gives this build
# a clearly-labeled "CactyVoice" row.
APP_NAME="CactyVoice"
BUNDLE_DIR="build/${APP_NAME}.app"
EXECUTABLE_NAME="CactyVoice"  # matches CFBundleExecutable in Info.plist
SWIFTPM_PRODUCT="cacty-app"

echo "→ swift build --product ${SWIFTPM_PRODUCT} (${CONFIG})"
# Use `+` substitution rather than `[@]` so an empty array doesn't
# trip `set -u`.
swift build --product "$SWIFTPM_PRODUCT" ${EXTRA_BUILD_FLAGS[@]+"${EXTRA_BUILD_FLAGS[@]}"}

BUILD_DIR=".build/${CONFIG}"
BINARY_PATH="${BUILD_DIR}/${SWIFTPM_PRODUCT}"

if [[ ! -f "$BINARY_PATH" ]]; then
    echo "✗ Expected binary at $BINARY_PATH, didn't find it"
    exit 1
fi

echo "→ Creating bundle structure at $BUNDLE_DIR"
rm -rf "$BUNDLE_DIR"
mkdir -p "${BUNDLE_DIR}/Contents/MacOS"
mkdir -p "${BUNDLE_DIR}/Contents/Resources"

echo "→ Copying binary"
cp "$BINARY_PATH" "${BUNDLE_DIR}/Contents/MacOS/${EXECUTABLE_NAME}"

echo "→ Copying Info.plist"
cp "Sources/App/Info.plist" "${BUNDLE_DIR}/Contents/Info.plist"

# `PkgInfo` is a 8-byte vestigial file ('APPL????') — Apple's docs
# say it's optional for modern apps but some legacy tools still
# look for it; cheap to include.
echo "APPL????" > "${BUNDLE_DIR}/Contents/PkgInfo"

echo "→ Ad-hoc codesigning"
# NOTE: no `--options runtime` (hardened runtime). For an ad-hoc-signed local
# build, hardened runtime makes macOS TCC fail to persist Accessibility grants
# across relaunches and can trap at runtime during automation. Dropping it
# keeps a stable, grantable identity for local dev. (A notarized Developer ID
# release build would re-enable hardened runtime — see Scripts/build-release.sh.)
codesign \
    --force \
    --sign - \
    --identifier com.cactyvoice.app \
    "$BUNDLE_DIR"

echo "→ Verifying signature"
codesign --verify --verbose=2 "$BUNDLE_DIR" 2>&1 | sed 's/^/    /'

echo ""
echo "✓ Built $BUNDLE_DIR"
echo ""
echo "Run it:"
echo "  open $BUNDLE_DIR"
echo "  # or, to see stderr:"
echo "  ${BUNDLE_DIR}/Contents/MacOS/${EXECUTABLE_NAME}"
