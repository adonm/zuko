#!/bin/sh
# Patch any embedded iOS framework whose Info.plist is missing a
# MinimumOSVersion key. Required for App Store validation:
#
#   "Invalid MinimumOSVersion ... MinimumOSVersion in 'Iroh.framework' is ''"
#
# iroh-ffi's binary XCFramework ships without MinimumOSVersion in its
# Info.plist (an upstream packaging bug). The legacy `project.yml` patched
# it via a `postBuildScripts` entry that ran after xcodebuild; xtool has no
# build-script hook, so this is the equivalent — run it AFTER `xtool dev
# build` produces the .app, before packaging/signing.
#
# Idempotent: only adds the key if absent (the `|| echo ""` + `-z` check
# matches the original postBuildScripts logic verbatim). Safe to run on
# already-patched frameworks.
#
# Usage:
#   sh scripts/patch-iroh-framework.sh path/to/Zuko.app
#   IPHONEOS_DEPLOYMENT_TARGET=26.0 sh scripts/patch-iroh-framework.sh path/to/Zuko.app
set -eu

if [ "$#" -ne 1 ]; then
    echo "usage: $0 <path/to/Zuko.app>" >&2
    exit 2
fi

APP="$1"
if [ ! -d "$APP" ]; then
    echo "patch-iroh-framework: $APP is not a directory" >&2
    exit 1
fi

# Default to the deployment target we ship for; the workflow overrides this
# with the env var xcodebuild would normally set (IPHONEOS_DEPLOYMENT_TARGET).
TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-26.0}"

FRAMEWORKS_DIR="$APP/Frameworks"
if [ ! -d "$FRAMEWORKS_DIR" ]; then
    echo "patch-iroh-framework: no Frameworks/ directory in $APP — nothing to patch"
    exit 0
fi

patched=0
for fw in "$FRAMEWORKS_DIR"/*.framework; do
    [ -d "$fw" ] || continue
    plist="$fw/Info.plist"
    [ -f "$plist" ] || continue
    min_os=$(/usr/libexec/PlistBuddy -c "Print :MinimumOSVersion" "$plist" 2>/dev/null || echo "")
    if [ -z "$min_os" ]; then
        echo "patch-iroh-framework: adding MinimumOSVersion=$TARGET to $(basename "$fw")"
        /usr/libexec/PlistBuddy -c "Add :MinimumOSVersion string $TARGET" "$plist"
        patched=$((patched + 1))
    fi
done

if [ "$patched" -eq 0 ]; then
    echo "patch-iroh-framework: nothing to patch (all frameworks already had MinimumOSVersion)"
fi
