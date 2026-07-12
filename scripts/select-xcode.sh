#!/bin/bash
set -euo pipefail

readonly XCODE_VERSION=26.3
if xcodebuild -version | grep -Fxq "Xcode $XCODE_VERSION"; then
  xcodebuild -version
  exit 0
fi

XCODE=''
for candidate in \
  "/Applications/Xcode_${XCODE_VERSION}.app" \
  "/Applications/Xcode-${XCODE_VERSION}.app"; do
  if [ -d "$candidate" ]; then
    XCODE="$candidate"
    break
  fi
done
readonly XCODE

test -n "$XCODE"
sudo xcode-select -s "$XCODE"
xcodebuild -version | grep -Fx "Xcode $XCODE_VERSION"
xcodebuild -version
