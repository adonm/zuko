#!/bin/bash
set -euo pipefail

readonly CODEMAGIC_VERSION=0.68.0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT
readonly VENV="${RUNNER_TEMP:-/tmp}/zuko-codemagic-cli"

python_version="$(python3 -c 'import platform; print(platform.python_version())')"
python3 - <<'PY'
import sys

if sys.version_info < (3, 8):
    raise SystemExit("Codemagic CLI Tools requires Python 3.8 or newer")
PY

python3 -m venv "$VENV"
"$VENV/bin/python" -m pip install \
  --disable-pip-version-check \
  --require-hashes \
  --only-binary=:all: \
  -r "$ROOT/scripts/codemagic-requirements.txt"
"$VENV/bin/python" -m pip check

installed_version="$("$VENV/bin/codemagic-cli-tools" --version)"
case "$installed_version" in
  *"$CODEMAGIC_VERSION"*) ;;
  *)
    echo "unexpected Codemagic CLI Tools version: $installed_version" >&2
    exit 1
    ;;
esac

if [ -n "${GITHUB_PATH:-}" ]; then
  printf '%s\n' "$VENV/bin" >> "$GITHUB_PATH"
fi
if [ -n "${CM_ENV:-}" ]; then
  printf 'PATH=%s:%s\n' "$VENV/bin" "$PATH" >> "$CM_ENV"
fi

echo "Codemagic CLI Tools $CODEMAGIC_VERSION installed from the hash-locked closure with Python $python_version"
