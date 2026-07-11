#!/bin/bash
set -euo pipefail

: "${RUNNER_TEMP:?RUNNER_TEMP is required}"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"

variables=(KEYSTORE_BASE64 STORE_PASSWORD KEY_ALIAS KEY_PASSWORD)
for variable in "${variables[@]}"; do
  if [ -z "${!variable:-}" ]; then
    echo "required Android signing variable is missing: $variable" >&2
    exit 1
  fi
done

keystore="$RUNNER_TEMP/zuko-release.jks"
printf '%s' "$KEYSTORE_BASE64" | base64 --decode > "$keystore"
chmod 600 "$keystore"
printf 'mode=signed\npath=%s\n' "$keystore" >> "$GITHUB_OUTPUT"
