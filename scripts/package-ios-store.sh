#!/bin/bash
set -euo pipefail

: "${ZUKO_VERSION:?ZUKO_VERSION is required}"
: "${ZUKO_BUILD_NUMBER:?ZUKO_BUILD_NUMBER is required}"
shopt -s nullglob
archives=(flutter/build/ios/archive/*.xcarchive)
ipas=(flutter/build/ios/ipa/*.ipa)
[ "${#archives[@]}" -eq 1 ] || { echo "expected one iOS archive" >&2; exit 1; }
[ "${#ipas[@]}" -eq 1 ] || { echo "expected one IPA" >&2; exit 1; }
archive="${archives[0]}"
ipa="${ipas[0]}"
scripts/apple-validate-package.sh "$archive" "$ipa" \
  "$ZUKO_VERSION" "$ZUKO_BUILD_NUMBER"
mkdir -p dist/flutter-ios
cp "$ipa" dist/flutter-ios/Zuko-Flutter.ipa
(cd dist/flutter-ios && shasum -a 256 Zuko-Flutter.ipa > Zuko-Flutter.ipa.sha256)
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "ipa=$PWD/dist/flutter-ios/Zuko-Flutter.ipa" >> "$GITHUB_OUTPUT"
fi
