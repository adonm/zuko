#!/bin/sh
# Build the iOS app through xtool.
#
# This is the single local/CI entrypoint. It builds the Rust FFI XCFramework,
# bakes a concrete version into Info.plist for xtool, runs `xtool dev build`,
# restores Info.plist, then patches embedded frameworks that are missing
# MinimumOSVersion.
#
# (No SwiftTerm source patch is needed: libghostty-spm ships a pre-built
# XCFramework binary target so there's nothing to patch for the xtool
# Linux→iOS cross-compile.)
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IOS_DIR="$ROOT/ios"
PLIST="$ROOT/ios/Zuko/Zuko/Info.plist"

CONFIGURATION="${ZUKO_IOS_CONFIGURATION:-debug}"
TRIPLE="${ZUKO_IOS_TRIPLE:-arm64-apple-ios}"
BUILD_NUMBER="${ZUKO_BUILD_NUMBER:-1}"

case "$TRIPLE" in
    *simulator*) DEFAULT_DEVICE_ONLY=0 ;;
    *) DEFAULT_DEVICE_ONLY=1 ;;
esac
FFI_DEVICE_ONLY="${ZUKO_FFI_DEVICE_ONLY:-$DEFAULT_DEVICE_ONLY}"

if ! command -v xtool >/dev/null 2>&1; then
    echo "build-ios-xtool: xtool not found; run 'mise run setup-ios'" >&2
    exit 1
fi

sdk_status="$(xtool sdk status 2>&1 || true)"
if printf '%s\n' "$sdk_status" | grep -qi 'not installed'; then
    if [ "$(uname -s)" = "Linux" ]; then
        sh "$ROOT/scripts/setup-ios-sdk.sh"
    else
        echo "build-ios-xtool: Darwin Swift SDK not installed" >&2
        echo "  macOS: run 'xtool setup'" >&2
        exit 1
    fi
fi

echo "==> Building Zuko $(sh "$ROOT/scripts/version.sh") (build $BUILD_NUMBER) for $TRIPLE via xtool"

if [ "${ZUKO_BUILD_FFI:-1}" != "0" ]; then
    ZUKO_FFI_DEVICE_ONLY="$FFI_DEVICE_ONLY" sh "$ROOT/scripts/build-ffi.sh"
fi

plist_backup="$(mktemp)"
cp "$PLIST" "$plist_backup"
restore_plist() {
    cp "$plist_backup" "$PLIST"
    rm -f "$plist_backup"
}
trap restore_plist EXIT INT TERM

ZUKO_BUILD_NUMBER="$BUILD_NUMBER" sh "$ROOT/scripts/patch-ios-plist.sh"

cd "$IOS_DIR"
swift package resolve

xtool dev build --configuration "$CONFIGURATION" --triple "$TRIPLE"

app="xtool/Zuko.app"
if [ ! -d "$app" ]; then
    app="$(find xtool -name 'Zuko.app' -type d -print 2>/dev/null | sort | tail -1)"
fi
if [ -z "$app" ] || [ ! -d "$app" ]; then
    echo "build-ios-xtool: couldn't locate Zuko.app in xtool output" >&2
    exit 1
fi

IPHONEOS_DEPLOYMENT_TARGET="26.0" sh "$ROOT/scripts/patch-iroh-framework.sh" "$app"

echo "Built + patched: $IOS_DIR/$app"
