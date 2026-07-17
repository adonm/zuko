#!/usr/bin/env bash
set -euo pipefail

if [[ -n ${CONTAINER_ENGINE:-} ]]; then
  engines=("$CONTAINER_ENGINE")
else
  engines=(docker podman)
fi

for engine in "${engines[@]}"; do
  if command -v "$engine" >/dev/null 2>&1 && "$engine" info >/dev/null 2>&1; then
    printf '%s\n' "$engine"
    exit 0
  fi
done

echo "container engine: no healthy Docker or Podman engine found" >&2
echo "set CONTAINER_ENGINE to select a compatible engine explicitly" >&2
exit 1
