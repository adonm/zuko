#!/bin/bash
set -euo pipefail

: "${ZUKO_VERSION:?ZUKO_VERSION is required}"
: "${ZUKO_BUILD_NUMBER:?ZUKO_BUILD_NUMBER is required}"
: "${MACOS_INSTALLER_IDENTITY:?MACOS_INSTALLER_IDENTITY is required}"
shopt -s nullglob
apps=(flutter/build/macos/Build/Products/Release/*.app)
[ "${#apps[@]}" -eq 1 ] || { echo "expected one macOS application" >&2; exit 1; }
app="${apps[0]}"
mkdir -p dist/flutter-macos
package="$PWD/dist/flutter-macos/Zuko-Flutter.pkg"
xcrun productbuild \
  --component "$app" /Applications \
  --sign "$MACOS_INSTALLER_IDENTITY" \
  "$package"
scripts/apple-validate-package.sh macos "$app" "$package" \
  "$ZUKO_VERSION" "$ZUKO_BUILD_NUMBER"
(cd dist/flutter-macos && shasum -a 256 Zuko-Flutter.pkg > Zuko-Flutter.pkg.sha256)
