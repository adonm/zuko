#!/bin/bash
set -euo pipefail

mkdir -p flutter/build/apple-artifacts
ios_app=flutter/build/ios/iphonesimulator/Runner.app
test -d "$ios_app"
ditto -c -k --sequesterRsrc --keepParent \
  "$ios_app" flutter/build/apple-artifacts/Zuko-Flutter-ios-simulator.zip
mac_app="$(find flutter/build/macos/Build/Products/Release -maxdepth 1 -name '*.app' -type d -print -quit)"
test -n "$mac_app"
ditto -c -k --sequesterRsrc --keepParent \
  "$mac_app" flutter/build/apple-artifacts/Zuko-Flutter-macOS.zip
for archive in flutter/build/apple-artifacts/*.zip; do
  digest="$(shasum -a 256 "$archive" | awk '{print $1}')"
  printf '%s  %s\n' "$digest" "$(basename "$archive")" > "$archive.sha256"
done
