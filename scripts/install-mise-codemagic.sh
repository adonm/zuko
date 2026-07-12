#!/bin/bash
set -euo pipefail

readonly VERSION=2026.7.5
readonly EXPECTED_SHA256=a456c65907e8334619d77fa152bdcf9023fddc0daa03d47fbe86d032dbf565b0
readonly NAME="mise-v${VERSION}-macos-arm64"
readonly URL="https://github.com/jdx/mise/releases/download/v${VERSION}/${NAME}"
readonly BIN="$HOME/.local/bin/mise"

if [ "$(uname -s):$(uname -m)" != Darwin:arm64 ]; then
  echo "Codemagic toolchain installation requires an Apple Silicon macOS runner" >&2
  exit 1
fi

mkdir -p "$(dirname "$BIN")"
if [ ! -f "$BIN" ] || [ "$(shasum -a 256 "$BIN" | awk '{print $1}')" != "$EXPECTED_SHA256" ]; then
  temporary="$(mktemp "${TMPDIR:-/tmp}/mise.XXXXXX")"
  trap 'rm -f "$temporary"' EXIT
  curl --fail --location --proto '=https' --tlsv1.2 "$URL" --output "$temporary"
  actual="$(shasum -a 256 "$temporary" | awk '{print $1}')"
  if [ "$actual" != "$EXPECTED_SHA256" ]; then
    echo "mise SHA-256 is $actual, expected $EXPECTED_SHA256" >&2
    exit 1
  fi
  install -m 0755 "$temporary" "$BIN"
fi

"$BIN" --version | grep -F "$VERSION"
"$BIN" trust "$PWD/mise.toml"
"$BIN" install rust zig just 'http:flutter'
"$BIN" exec -- rustc --version
"$BIN" exec -- zig version
"$BIN" exec -- flutter --version
