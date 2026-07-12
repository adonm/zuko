#!/bin/bash
set -euo pipefail

if [ "$#" -ne 4 ]; then
  echo "usage: apple-validate-package.sh <xcarchive> <ipa> <version> <build>" >&2
  exit 2
fi

readonly ARCHIVE="$1"
readonly IPA="$2"
readonly EXPECTED_VERSION="$3"
readonly EXPECTED_BUILD="$4"
readonly BUNDLE_ID=dev.adonm.zuko

fail() {
  echo "iOS package validation failed: $*" >&2
  exit 1
}

require_equal() {
  local description="$1"
  local actual="$2"
  local expected="$3"
  [ "$actual" = "$expected" ] || \
    fail "$description is '$actual', expected '$expected'"
}

[ -d "$ARCHIVE" ] || fail "archive does not exist: $ARCHIVE"
[ -f "$IPA" ] || fail "IPA does not exist: $IPA"

extracted="${RUNNER_TEMP:?RUNNER_TEMP is required}/validated-ipa"
rm -rf "$extracted"
ditto -x -k "$IPA" "$extracted"
shopt -s nullglob
apps=("$extracted"/Payload/*.app)
[ "${#apps[@]}" -eq 1 ] || \
  fail "IPA contains ${#apps[@]} application bundles, expected 1"
app="${apps[0]}"
info="$app/Info.plist"
[ -f "$info" ] || fail "application Info.plist does not exist: $info"

identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info")"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info")"
build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info")"
require_equal "bundle identifier" "$identifier" "$BUNDLE_ID"
require_equal "version" "$version" "$EXPECTED_VERSION"
require_equal "build number" "$build" "$EXPECTED_BUILD"

codesign --verify --deep --strict --verbose=2 "$app"
signature_details="$(codesign -d --verbose=4 "$app" 2>&1)"
team="$(grep '^TeamIdentifier=' <<< "$signature_details" | cut -d= -f2-)"
require_equal "signing team" "$team" "${TEAM_ID:?TEAM_ID is required}"
grep -q '^Authority=Apple Distribution:' <<< "$signature_details"
[ -f "$app/embedded.mobileprovision" ] || fail "embedded provisioning profile is missing"

executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$info")"
lipo -archs "$app/$executable" | grep -qw arm64

ghostty="$app/Frameworks/ghostty.framework/ghostty"
[ -f "$ghostty" ] || fail "Ghostty framework is missing"
lipo -archs "$ghostty" | grep -qw arm64
ghostty_load_commands="$(otool -l "$ghostty")"
grep -q LC_ENCRYPTION_INFO_64 <<< "$ghostty_load_commands"
grep -A 5 LC_BUILD_VERSION <<< "$ghostty_load_commands" | grep -q 'minos 18.0'

xcode-project ipa-info "$IPA"
echo "iOS IPA metadata, signature, and store package are valid"
