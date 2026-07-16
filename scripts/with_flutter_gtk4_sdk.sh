#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "usage: with_flutter_gtk4_sdk.sh <sdk-directory> <command> [args...]" >&2
  exit 2
fi

SDK=$(realpath -m -- "$1")
readonly SDK
shift

python3 "$(dirname "${BASH_SOURCE[0]}")/install_flutter_gtk4_sdk.py" "$SDK"
export PATH="$SDK/bin:$PATH"
export FLUTTER_PREBUILT_ENGINE_VERSION=469f2b34de41cab5f677ba84d6e9099c0e682d1e
exec "$@"
