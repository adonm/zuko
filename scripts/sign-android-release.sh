#!/bin/bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: sign-android-release.sh <vX.Y.Z> <artifact-directory>" >&2
  exit 2
fi
: "${ANDROID_HOME:?ANDROID_HOME is required}"
: "${RUNNER_TEMP:?RUNNER_TEMP is required}"

tag="$1"
directory="$2"
version="$(scripts/version.sh)"
if [[ "$tag" != "v$version" ]]; then
  echo "Android signing: tag must be v$version, got $tag" >&2
  exit 1
fi
for variable in ANDROID_KEYSTORE_BASE64 ANDROID_KEYSTORE_PASSWORD ANDROID_KEY_ALIAS ANDROID_KEY_PASSWORD; do
  if [ -z "${!variable:-}" ]; then
    echo "Android signing: required variable is missing: $variable" >&2
    exit 1
  fi
done

unsigned_apk="$directory/zuko-android-$tag-unsigned.apk"
unsigned_aab="$directory/zuko-android-$tag-unsigned.aab"
signed_apk="$directory/zuko-android-$tag-signed.apk"
signed_aab="$directory/zuko-android-$tag-signed.aab"
keystore="$RUNNER_TEMP/zuko-codemagic-release.jks"
aligned_apk="$RUNNER_TEMP/zuko-codemagic-aligned.apk"
cleanup() {
  rm -f "$keystore" "$aligned_apk"
}
trap cleanup EXIT
umask 077
printf '%s' "$ANDROID_KEYSTORE_BASE64" | base64 --decode > "$keystore"
test -s "$keystore"

expected_fingerprint="$({
  keytool -exportcert -rfc \
    -keystore "$keystore" \
    -storepass:env ANDROID_KEYSTORE_PASSWORD \
    -alias "$ANDROID_KEY_ALIAS" 2>/dev/null
} | openssl x509 -noout -fingerprint -sha256 | cut -d= -f2 | tr -d ':' | tr A-F a-f)"
[[ "$expected_fingerprint" =~ ^[0-9a-f]{64}$ ]]

build_tools="$ANDROID_HOME/build-tools/36.0.0"
"$build_tools/zipalign" -p -f 4 "$unsigned_apk" "$aligned_apk"
"$build_tools/apksigner" sign \
  --ks "$keystore" \
  --ks-pass env:ANDROID_KEYSTORE_PASSWORD \
  --ks-key-alias "$ANDROID_KEY_ALIAS" \
  --key-pass env:ANDROID_KEY_PASSWORD \
  --v4-signing-enabled false \
  --out "$signed_apk" \
  "$aligned_apk"
test ! -e "$signed_apk.idsig"
apk_verification="$("$build_tools/apksigner" verify --verbose --print-certs "$signed_apk")"
printf '%s\n' "$apk_verification"
actual_fingerprint="$(sed -n 's/^Signer #1 certificate SHA-256 digest: //p' <<< "$apk_verification" | tr -d ':' | tr A-F a-f)"
test "$actual_fingerprint" = "$expected_fingerprint"

scripts/android-prepare-aab.sh sign "$unsigned_aab" "$signed_aab"
rm -f "$unsigned_apk" "$unsigned_aab"
(
  cd "$directory"
  sha256sum "$(basename "$signed_apk")" > "$(basename "$signed_apk").sha256"
  sha256sum "$(basename "$signed_aab")" > "$(basename "$signed_aab").sha256"
  sha256sum --check "$(basename "$signed_apk").sha256"
  sha256sum --check "$(basename "$signed_aab").sha256"
)

build_number="$(python3 scripts/release_metadata.py build-number)"
scripts/android-validate-aab.sh \
  "$signed_aab" "$signed_aab.sha256" \
  dev.adonm.zuko "$version" "$build_number"
