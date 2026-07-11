#!/bin/bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: package-ios-preview.sh <version>" >&2
  exit 2
fi

version="$1"
(cd flutter && flutter pub get --enforce-lockfile)
(cd flutter && flutter build ios --simulator --debug --no-pub \
  --build-name "$version")
app=flutter/build/ios/iphonesimulator/Runner.app
test -d "$app"
plist="$app/Info.plist"
platform="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleSupportedPlatforms:0' "$plist")"
executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist")"
test "$platform" = iPhoneSimulator
lipo -archs "$app/$executable" | tr ' ' '\n' | grep -qx arm64
mkdir -p dist/ios-preview
ditto -c -k --sequesterRsrc --keepParent "$app" \
  dist/ios-preview/Zuko-Flutter-ios-simulator.zip
