#!/bin/bash
set -euo pipefail

if [ "$#" -lt 4 ] || [ "$#" -gt 5 ]; then
  echo "usage: apple-validate-package.sh <ios|macos> <archive-or-app> <package> <version> [build]" >&2
  exit 2
fi

readonly PLATFORM="$1"
readonly ARCHIVE="$2"
readonly PACKAGE="$3"
readonly EXPECTED_VERSION="$4"
readonly EXPECTED_BUILD="${5:-}"
readonly BUNDLE_ID=dev.adonm.zuko

fail() {
  echo "Apple package validation failed: $*" >&2
  exit 1
}

require_directory() {
  [ -d "$1" ] || fail "directory does not exist: $1"
}

require_file() {
  [ -f "$1" ] || fail "file does not exist: $1"
}

require_equal() {
  local description="$1"
  local actual="$2"
  local expected="$3"
  [ "$actual" = "$expected" ] || \
    fail "$description is '$actual', expected '$expected'"
}

validate_app() {
  local app="$1"
  local identifier version build executable signature_details team
  require_directory "$app"
  identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist" 2>/dev/null || /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")"
  version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist" 2>/dev/null || /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Info.plist")"
  build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist" 2>/dev/null || /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Info.plist")"
  require_equal "bundle identifier" "$identifier" "$BUNDLE_ID"
  require_equal "version" "$version" "$EXPECTED_VERSION"
  if [ -n "$EXPECTED_BUILD" ]; then
    require_equal "build number" "$build" "$EXPECTED_BUILD"
  fi
  codesign --verify --deep --strict --verbose=2 "$app"
  signature_details="$(codesign -d --verbose=4 "$app" 2>&1)"
  team="$(grep '^TeamIdentifier=' <<< "$signature_details" | cut -d= -f2-)"
  require_equal "signing team" "$team" "${TEAM_ID:?TEAM_ID is required}"

  if [ "$PLATFORM" = macos ]; then
    grep -Eq '^Authority=(3rd Party Mac Developer Application|Mac App Distribution):' <<< "$signature_details"
    test -f "$app/Contents/embedded.provisionprofile"
    entitlements="$(codesign -d --entitlements :- "$app" 2>/dev/null)"
    ENTITLEMENTS="$entitlements" python3 - <<'PY'
import os
import plistlib

entitlements = plistlib.loads(os.environ["ENTITLEMENTS"].encode())
required = (
    "com.apple.security.app-sandbox",
    "com.apple.security.network.client",
    "com.apple.security.network.server",
)
if any(entitlements.get(key) is not True for key in required):
    raise SystemExit("macOS archive is missing required sandbox entitlements")
PY
    executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist")"
    lipo -archs "$app/Contents/MacOS/$executable" | grep -Eqw 'arm64|x86_64'
  else
    grep -q '^Authority=Apple Distribution:' <<< "$signature_details"
    test -f "$app/embedded.mobileprovision"
    executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Info.plist")"
    lipo -archs "$app/$executable" | grep -qw arm64
    ghostty="$app/Frameworks/ghostty.framework/ghostty"
    test -f "$ghostty"
    lipo -archs "$ghostty" | grep -qw arm64
    ghostty_load_commands="$(otool -l "$ghostty")"
    grep -q LC_ENCRYPTION_INFO_64 <<< "$ghostty_load_commands"
    grep -A 5 LC_BUILD_VERSION <<< "$ghostty_load_commands" | grep -q 'minos 18.0'
  fi
}

case "$PLATFORM" in
  ios)
    # The xcarchive is an intermediate input to Xcode's export operation. The
    # exported app can have different signing metadata, so validate the App
    # Store artifact rather than rejecting an otherwise valid export because
    # of archive-only metadata.
    require_directory "$ARCHIVE"
    require_file "$PACKAGE"
    extracted="${RUNNER_TEMP:?RUNNER_TEMP is required}/validated-ipa"
    rm -rf "$extracted"
    ditto -x -k "$PACKAGE" "$extracted"
    shopt -s nullglob
    apps=("$extracted"/Payload/*.app)
    [ "${#apps[@]}" -eq 1 ] || \
      fail "IPA contains ${#apps[@]} application bundles, expected 1"
    validate_app "${apps[0]}"
    xcode-project ipa-info "$PACKAGE"
    echo "ios IPA metadata, signature, and store package are valid"
    ;;
  macos)
    require_directory "$ARCHIVE"
    require_file "$PACKAGE"
    validate_app "$ARCHIVE"
    package_signature="$(pkgutil --check-signature "$PACKAGE")"
    grep -q "${TEAM_ID:?TEAM_ID is required}" <<< "$package_signature"
    payload_files="$(pkgutil --payload-files "$PACKAGE")"
    grep -q '^./Zuko.app/' <<< "$payload_files"
    expanded="${RUNNER_TEMP:?RUNNER_TEMP is required}/validated-pkg"
    rm -rf "$expanded"
    pkgutil --expand "$PACKAGE" "$expanded"
    grep -q 'install-location="/Applications"' "$expanded"/*/PackageInfo
    xcode-project pkg-info "$PACKAGE"
    echo "macos archive metadata, signature, and store package are valid"
    ;;
  *)
    echo "platform must be ios or macos" >&2
    exit 2
    ;;
esac
