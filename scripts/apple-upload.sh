#!/bin/bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: apple-upload.sh <ios|macos> <ipa-or-pkg>" >&2
  exit 2
fi

readonly PLATFORM="$1"
readonly PACKAGE="$2"
readonly KEY_DIR="${RUNNER_TEMP:?RUNNER_TEMP is required}/app-store-connect"

case "$PLATFORM:$PACKAGE" in
  ios:*.ipa|macos:*.pkg) ;;
  *) echo "platform and package extension do not match" >&2; exit 2 ;;
esac

for variable in ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_CONTENT; do
  if [ -z "${!variable:-}" ]; then
    echo "required App Store Connect variable is missing: $variable" >&2
    exit 1
  fi
done
test -f "$PACKAGE"

mkdir -p "$KEY_DIR"
chmod 700 "$KEY_DIR"
key="$KEY_DIR/AuthKey_${ASC_KEY_ID}.p8"
umask 077
printf '%s\n' "$ASC_KEY_CONTENT" > "$key"
grep -q '^-----BEGIN PRIVATE KEY-----$' "$key"
grep -q '^-----END PRIVATE KEY-----$' "$key"

app-store-connect publish \
  --issuer-id @env:ASC_ISSUER_ID \
  --key-id @env:ASC_KEY_ID \
  --private-key "@file:$key" \
  --path "$PACKAGE" \
  --enable-package-validation

echo "$PLATFORM package validated and uploaded with Codemagic CLI Tools"
