#!/bin/bash
set -euo pipefail

if [ "$#" -ne 5 ]; then
  echo "usage: android-validate-aab.sh <bundle.aab> <checksum> <package> <version> <version-code>" >&2
  exit 2
fi

readonly BUNDLE="$1"
readonly CHECKSUM="$2"
readonly EXPECTED_PACKAGE="$3"
readonly EXPECTED_VERSION="$4"
readonly EXPECTED_VERSION_CODE="$5"

test -f "$BUNDLE"
test -f "$CHECKSUM"
[[ "$EXPECTED_PACKAGE" =~ ^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$ ]]
[[ "$EXPECTED_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
[[ "$EXPECTED_VERSION_CODE" =~ ^[1-9][0-9]*$ ]]

checksum_line="$(<"$CHECKSUM")"
expected_digest="${checksum_line%% *}"
expected_name="${checksum_line#*  }"
[[ "$expected_digest" =~ ^[0-9a-f]{64}$ ]]
test "$expected_name" = "$(basename "$BUNDLE")"
actual_digest="$(sha256sum "$BUNDLE" | cut -d' ' -f1)"
test "$actual_digest" = "$expected_digest"

android-app-bundle is-signed --bundle "$BUNDLE" >/dev/null
android-app-bundle validate --bundle "$BUNDLE" >/dev/null
jarsigner -verify "$BUNDLE" >/dev/null 2>&1

package="$(android-app-bundle dump manifest \
  --bundle "$BUNDLE" \
  --xpath '/manifest/@package')"
version="$(android-app-bundle dump manifest \
  --bundle "$BUNDLE" \
  --xpath '/manifest/@android:versionName')"
version_code="$(android-app-bundle dump manifest \
  --bundle "$BUNDLE" \
  --xpath '/manifest/@android:versionCode')"

test "$package" = "$EXPECTED_PACKAGE"
test "$version" = "$EXPECTED_VERSION"
test "$version_code" = "$EXPECTED_VERSION_CODE"

echo "AAB package, version, signature, and SHA-256 checksum are valid ($actual_digest)"
