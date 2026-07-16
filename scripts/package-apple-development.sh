#!/bin/bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: package-apple-development.sh <ios-simulator|macos>" >&2
  exit 2
fi

mkdir -p flutter/build/apple-artifacts
case "$1" in
  ios-simulator)
    source=flutter/build/ios/iphonesimulator/Runner.app
    archive=flutter/build/apple-artifacts/Zuko-Flutter-ios-simulator.zip
    test -d "$source"
    ;;
  macos)
    source="$(find flutter/build/macos/Build/Products/Release -maxdepth 1 -name '*.app' -type d -print -quit)"
    archive=flutter/build/apple-artifacts/Zuko-Flutter-macOS.zip
    test -n "$source"
    ;;
  *)
    echo "unsupported Apple package: $1" >&2
    exit 2
    ;;
esac
ditto -c -k --sequesterRsrc --keepParent "$source" "$archive"
digest="$(shasum -a 256 "$archive" | awk '{print $1}')"
printf '%s  %s\n' "$digest" "$(basename "$archive")" > "$archive.sha256"
