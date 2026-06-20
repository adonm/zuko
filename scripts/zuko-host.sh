#!/bin/sh
# Run `zuko host` in the foreground (handy for testing / one-off sessions).
# Defaults match `zuko install`. Override with env vars or args (passed after).
#
# This is a development convenience — for production use `zuko install` to set
# up the systemd/launchd user service that keeps the daemon alive across
# reboots. The script just execs the binary directly so you get the ticket
# banner on stderr and can pair a device with `zuko share`.
set -eu

KEY="${ZUKO_KEY:-${HOME}/.config/zuko/key}"
SHELL_CMD="${ZUKO_SHELL:-${SHELL:-/bin/bash}}"

# Prefer the mise-installed shim, fall back to a local build for development.
if command -v zuko >/dev/null 2>&1; then
    BIN=zuko
elif [ -x "$(dirname "$0")/../target/debug/zuko" ]; then
    BIN="$(dirname "$0")/../target/debug/zuko"
elif [ -x "$(dirname "$0")/../target/release/zuko" ]; then
    BIN="$(dirname "$0")/../target/release/zuko"
else
    echo "zuko not found. Install it with 'mise use --global github:adonm/zuko'" >&2
    echo "or build from source: 'cargo build'." >&2
    exit 1
fi

mkdir -p "$(dirname "$KEY")"
exec "$BIN" host --key "$KEY" --shell "$SHELL_CMD" "$@"
