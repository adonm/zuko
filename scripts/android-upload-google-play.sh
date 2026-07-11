#!/bin/bash
set -euo pipefail

if [ "$#" -ne 6 ]; then
  echo "usage: android-upload-google-play.sh <bundle.aab> <sha256> <package> <track> <draft|release> <release-name>" >&2
  exit 2
fi

readonly BUNDLE="$1"
readonly EXPECTED_SHA256="$2"
readonly PACKAGE="$3"
readonly TRACK="$4"
readonly MODE="$5"
readonly RELEASE_NAME="$6"
readonly CREDENTIALS="${RUNNER_TEMP:?RUNNER_TEMP is required}/google-play-service-account.json"

test -f "$BUNDLE"
[[ "$EXPECTED_SHA256" =~ ^[0-9a-f]{64}$ ]]
test "$PACKAGE" = dev.adonm.zuko
case "$TRACK" in
  internal|alpha|beta|production) ;;
  *) echo "unsupported Google Play track: $TRACK" >&2; exit 2 ;;
esac
case "$MODE" in
  draft|release) ;;
  *) echo "publish mode must be draft or release" >&2; exit 2 ;;
esac
if [ -z "${GOOGLE_PLAY_SERVICE_ACCOUNT_JSON:-}" ]; then
  echo "GOOGLE_PLAY_SERVICE_ACCOUNT_JSON is required" >&2
  exit 1
fi

cleanup() {
  rm -f "$CREDENTIALS"
}
trap cleanup EXIT
umask 077
printf '%s' "$GOOGLE_PLAY_SERVICE_ACCOUNT_JSON" > "$CREDENTIALS"
python3 - "$CREDENTIALS" <<'PY'
import json
import pathlib
import sys

credentials = json.loads(pathlib.Path(sys.argv[1]).read_text())
required = {"type", "client_email", "private_key", "token_uri"}
if credentials.get("type") != "service_account" or not required <= credentials.keys():
    raise SystemExit("Google Play credentials are not a service-account JSON key")
PY

credentials_argument="@file:$CREDENTIALS"
google-play --silent --credentials "$credentials_argument" tracks get \
  --package-name "$PACKAGE" \
  --track "$TRACK" >/dev/null

actual_sha256="$(sha256sum "$BUNDLE" | cut -d' ' -f1)"
if [ "$actual_sha256" != "$EXPECTED_SHA256" ]; then
  echo "AAB changed after validation; refusing to upload" >&2
  exit 1
fi

publish_arguments=(
  --bundle "$BUNDLE"
  --track "$TRACK"
  --release-name "$RELEASE_NAME"
)
if [ "$MODE" = draft ]; then
  publish_arguments+=(--draft)
fi
google-play --silent --credentials "$credentials_argument" bundles publish \
  "${publish_arguments[@]}"

echo "Google Play accepted $PACKAGE SHA-256 $actual_sha256 on $TRACK ($MODE)"
