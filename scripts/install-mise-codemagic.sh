#!/bin/bash
set -euo pipefail

readonly VERSION=2026.7.5
case "$(uname -s):$(uname -m)" in
  Darwin:arm64)
    readonly EXPECTED_SHA256=a456c65907e8334619d77fa152bdcf9023fddc0daa03d47fbe86d032dbf565b0
    readonly NAME="mise-v${VERSION}-macos-arm64"
    ;;
  Linux:x86_64)
    readonly EXPECTED_SHA256=5f7ab76afdf0780d12edeaa67e908094e9ccf7924cfe203e415c1cfb87bbf778
    readonly NAME="mise-v${VERSION}-linux-x64"
    ;;
  *)
    echo "unsupported Codemagic runner: $(uname -s) $(uname -m)" >&2
    exit 1
    ;;
esac
readonly URL="https://github.com/jdx/mise/releases/download/v${VERSION}/${NAME}"
readonly BIN="$HOME/.local/bin/mise"

mkdir -p "$(dirname "$BIN")"
checksum() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

if [ ! -f "$BIN" ] || [ "$(checksum "$BIN")" != "$EXPECTED_SHA256" ]; then
  temporary="$(mktemp "${TMPDIR:-/tmp}/mise.XXXXXX")"
  trap 'rm -f "$temporary"' EXIT
  curl --fail --location --proto '=https' --tlsv1.2 "$URL" --output "$temporary"
  actual="$(checksum "$temporary")"
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
