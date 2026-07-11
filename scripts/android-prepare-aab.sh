#!/bin/bash
set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "usage: android-prepare-aab.sh <preserve|sign> <input.aab> <output.aab>" >&2
  exit 2
fi

readonly MODE="$1"
readonly INPUT="$2"
readonly OUTPUT="$3"
readonly KEYSTORE="${RUNNER_TEMP:?RUNNER_TEMP is required}/zuko-android-upload.jks"

case "$MODE:$INPUT:$OUTPUT" in
  preserve:*.aab:*.aab|sign:*.aab:*.aab) ;;
  *) echo "mode must be preserve or sign and both packages must be AAB files" >&2; exit 2 ;;
esac
test -f "$INPUT"

for variable in ANDROID_KEYSTORE_BASE64 ANDROID_KEYSTORE_PASSWORD ANDROID_KEY_ALIAS ANDROID_KEY_PASSWORD; do
  if [ -z "${!variable:-}" ]; then
    echo "required Android signing variable is missing: $variable" >&2
    exit 1
  fi
done

cleanup() {
  rm -f "$KEYSTORE"
}
trap cleanup EXIT
umask 077
printf '%s' "$ANDROID_KEYSTORE_BASE64" | base64 --decode > "$KEYSTORE"
test -s "$KEYSTORE"

android-keystore verify \
  --keystore "$KEYSTORE" \
  --keystore-pass @env:ANDROID_KEYSTORE_PASSWORD \
  --alias "$ANDROID_KEY_ALIAS"

expected_fingerprint="$({
  keytool -exportcert -rfc \
    -keystore "$KEYSTORE" \
    -storepass:env ANDROID_KEYSTORE_PASSWORD \
    -alias "$ANDROID_KEY_ALIAS" 2>/dev/null
} | openssl x509 -noout -fingerprint -sha256 | cut -d= -f2 | tr -d ':')"
[[ "$expected_fingerprint" =~ ^[0-9A-F]{64}$ ]]

mkdir -p "$(dirname "$OUTPUT")"
input_checksum="$(sha256sum "$INPUT" | cut -d' ' -f1)"
if [ "$INPUT" != "$OUTPUT" ]; then
  cp "$INPUT" "$OUTPUT"
fi

android-app-bundle validate --bundle "$OUTPUT" >/dev/null
case "$MODE" in
  preserve)
    android-app-bundle is-signed --bundle "$OUTPUT" >/dev/null
    ;;
  sign)
    if android-app-bundle is-signed --bundle "$OUTPUT" >/dev/null 2>&1; then
      echo "refusing to add another signature to an already signed rebuild" >&2
      exit 1
    fi
    android-app-bundle sign \
      --bundle "$OUTPUT" \
      --ks "$KEYSTORE" \
      --ks-pass @env:ANDROID_KEYSTORE_PASSWORD \
      --ks-key-alias "$ANDROID_KEY_ALIAS" \
      --key-pass @env:ANDROID_KEY_PASSWORD
    ;;
esac

jarsigner -verify "$OUTPUT" >/dev/null 2>&1
actual_fingerprint="$({
  keytool -printcert -jarfile "$OUTPUT" -rfc 2>/dev/null
} | openssl x509 -noout -fingerprint -sha256 | cut -d= -f2 | tr -d ':')"
if [ "$actual_fingerprint" != "$expected_fingerprint" ]; then
  echo "AAB signer does not match the configured Google Play upload key" >&2
  exit 1
fi
if [ "$MODE" = preserve ]; then
  test "$(sha256sum "$OUTPUT" | cut -d' ' -f1)" = "$input_checksum"
fi

echo "AAB signature matches the configured Google Play upload key"
