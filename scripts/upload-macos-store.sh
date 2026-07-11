#!/bin/bash
set -euo pipefail

: "${TEAM_ID:?TEAM_ID is required}"
cd dist/flutter-macos
shasum -a 256 -c Zuko-Flutter.pkg.sha256
package_signature="$(pkgutil --check-signature Zuko-Flutter.pkg)"
grep -q "$TEAM_ID" <<< "$package_signature"
xcode-project pkg-info Zuko-Flutter.pkg
cd ../..
scripts/apple-upload.sh macos dist/flutter-macos/Zuko-Flutter.pkg
