#!/bin/sh
# Run zuko-host in the foreground (handy for testing / one-off sessions).
# Defaults match install.sh. Override with env vars or args.
set -eu

KEY="${ZUKO_KEY:-${HOME}/.config/zuko/key}"
SHELL_CMD="${ZUKO_SHELL:-${SHELL:-/bin/bash}}"

# Prefer the mise-installed shim, fall back to a local build for development.
if command -v zuko-host >/dev/null 2>&1; then
    BIN=zuko-host
elif [ -x "$(dirname "$0")/../target/debug/zuko-host" ]; then
    BIN="$(dirname "$0")/../target/debug/zuko-host"
elif [ -x "$(dirname "$0")/../target/release/zuko-host" ]; then
    BIN="$(dirname "$0")/../target/release/zuko-host"
else
    echo "zuko-host not found. Run scripts/install.sh (needs mise) or cargo build first." >&2
    exit 1
fi

mkdir -p "$(dirname "$KEY")"
exec "$BIN" --key "$KEY" --shell "$SHELL_CMD" "$@"
