#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
mode=${1:-check}

case "$mode" in
  check | linux)
    target=$mode
    ;;
  bundle)
    target=linux-bundle
    ;;
  all)
    target=legacy-all
    ;;
  *)
    echo "usage: container-linux.sh <check|linux|bundle|all>" >&2
    exit 2
    ;;
esac

echo "container-linux.sh: compatibility wrapper; use scripts/container-flutter.sh $target" >&2
exec "$root/scripts/container-flutter.sh" "$target"
