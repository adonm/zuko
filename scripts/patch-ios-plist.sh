#!/bin/sh
# Bake the resolved version + build number into the iOS app's Info.plist.
#
# Why this exists: the legacy xcodebuild path threads MARKETING_VERSION +
# CURRENT_PROJECT_VERSION through `xcargs`, which surface as build settings
# and substitute `$(MARKETING_VERSION)` / `$(CURRENT_PROJECT_VERSION)`
# placeholders in Info.plist at link time. xtool has no equivalent — it
# loads Info.plist as a static file and merges it on top of its defaults
# (`PackLib/Planner.swift` lines 194-202). Static placeholders would land
# literally in the .ipa.
#
# Approach: resolve the version the same way the rest of the pipeline does
# (scripts/version.sh reads Cargo.toml as the single source of truth) and
# the build number from $ZUKO_BUILD_NUMBER (CI sets Unix seconds; local dev
# gets "1"), then sed-replace the placeholders in place. The workflow runs
# this *before* `xtool dev build`; the next `git checkout` restores the
# placeholders so the working tree stays clean.
#
# Idempotent: safe to run multiple times — each invocation overwrites with
# the current values. Also safe to run on the xcodebuild path: the sed
# rewrites `$(MARKETING_VERSION)` to a literal, which xcodebuild treats as
# a static value (its `xcargs` override still wins).
#
# Usage:
#   sh scripts/patch-ios-plist.sh                # uses defaults
#   ZUKO_BUILD_NUMBER=1781985219 sh scripts/patch-ios-plist.sh
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PLIST="$ROOT/ios/Zuko/Zuko/Info.plist"

VERSION="$(sh "$SCRIPT_DIR/version.sh")"
BUILD_NUMBER="${ZUKO_BUILD_NUMBER:-1}"

if [ ! -f "$PLIST" ]; then
    echo "patch-ios-plist: $PLIST not found" >&2
    exit 1
fi

# In-place sed with a portable backup extension. We use .bak so the same
# call works on GNU sed (Linux CI) and BSD sed (macOS). Trap removes the
# .bak regardless of outcome.
sed -i.bak \
    -e "s|\$(MARKETING_VERSION)|${VERSION}|g" \
    -e "s|\$(CURRENT_PROJECT_VERSION)|${BUILD_NUMBER}|g" \
    "$PLIST"
trap 'rm -f "${PLIST}.bak"' EXIT

echo "patch-ios-plist: baked MARKETING_VERSION=${VERSION} CURRENT_PROJECT_VERSION=${BUILD_NUMBER} into ${PLIST#${ROOT}/}"
