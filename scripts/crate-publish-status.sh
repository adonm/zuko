#!/bin/bash
set -euo pipefail

: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"
version="$(scripts/version.sh)"
status="$(curl --silent --show-error \
  --user-agent zuko-trusted-publisher \
  --output /dev/null \
  --write-out '%{http_code}' \
  "https://crates.io/api/v1/crates/zuko/$version")"
case "$status" in
  200) echo "published=true" >> "$GITHUB_OUTPUT" ;;
  404) echo "published=false" >> "$GITHUB_OUTPUT" ;;
  *) echo "Unexpected crates.io response: HTTP $status" >&2; exit 1 ;;
esac
