#!/bin/bash
set -euo pipefail

readonly XCODE_VERSION=26.3
readonly XCODE="/Applications/Xcode_${XCODE_VERSION}.app"

test -d "$XCODE"
sudo xcode-select -s "$XCODE"
xcodebuild -version | grep -Fx "Xcode $XCODE_VERSION"
xcodebuild -version
