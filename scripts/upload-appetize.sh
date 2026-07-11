#!/bin/sh
# Upload one already-built mobile package to Appetize.
# Required environment: APPETIZE_API_TOKEN. Pass an existing public key to
# update a stable app, or `-` to bootstrap a new app and print its public key.
set -eu

if [ "$#" -lt 3 ] || [ "$#" -gt 4 ]; then
    echo "usage: upload-appetize.sh <android|ios> <file> <public-key|-> [note]" >&2
    exit 2
fi

PLATFORM=$1
APP_FILE=$2
PUBLIC_KEY=$3
NOTE=${4:-}

case "$PLATFORM" in
    android)
        case "$APP_FILE" in *.apk) ;; *) echo "Appetize Android uploads must be APK files" >&2; exit 2 ;; esac
        ;;
    ios)
        case "$APP_FILE" in *.zip|*.tar.gz) ;; *) echo "Appetize iOS uploads must be compressed Simulator .app bundles" >&2; exit 2 ;; esac
        ;;
    *)
        echo "platform must be android or ios" >&2
        exit 2
        ;;
esac

if [ ! -f "$APP_FILE" ]; then
    echo "Appetize upload file does not exist: $APP_FILE" >&2
    exit 1
fi
if [ -z "${APPETIZE_API_TOKEN:-}" ]; then
    echo "APPETIZE_API_TOKEN is required" >&2
    exit 1
fi
if [ -z "$PUBLIC_KEY" ]; then
    echo "pass an Appetize public key or '-' to create an app" >&2
    exit 1
fi
case "$PUBLIC_KEY" in
    -) ;;
    *[!A-Za-z0-9_-]*) echo "the Appetize public key contains invalid characters" >&2; exit 2 ;;
esac

HEADER_FILE=$(mktemp)
RESPONSE_FILE=$(mktemp)
trap 'rm -f "$HEADER_FILE" "$RESPONSE_FILE"' EXIT HUP INT TERM
chmod 600 "$HEADER_FILE" "$RESPONSE_FILE"
printf 'X-API-KEY: %s\n' "$APPETIZE_API_TOKEN" > "$HEADER_FILE"

if [ "$PUBLIC_KEY" = "-" ]; then
    APP_URL="https://api.appetize.io/v1/apps"
    echo "Uploading $PLATFORM package to a new Appetize app…"
else
    APP_URL="https://api.appetize.io/v1/apps/$PUBLIC_KEY"
    echo "Uploading $PLATFORM package to existing Appetize app…"
fi

curl --fail-with-body --silent --show-error \
    --retry 3 --retry-all-errors \
    --request POST "$APP_URL" \
    --header "@$HEADER_FILE" \
    --form "file=@$APP_FILE" \
    --form "platform=$PLATFORM" \
    --form "note=$NOTE" \
    --output "$RESPONSE_FILE"

python3 - "$RESPONSE_FILE" "$PUBLIC_KEY" "$PLATFORM" <<'PY'
import json
import os
import pathlib
import sys

response = json.loads(pathlib.Path(sys.argv[1]).read_text())
public_key = response.get("publicKey")
if not public_key:
    raise SystemExit("Appetize did not return a public key")
if sys.argv[2] != "-" and public_key != sys.argv[2]:
    raise SystemExit("Appetize returned an unexpected public key")

url = f"https://appetize.io/app/{public_key}"
print(f"Appetize accepted the build: {url}")

if output_path := os.environ.get("GITHUB_OUTPUT"):
    with pathlib.Path(output_path).open("a") as stream:
        stream.write(f"public_key={public_key}\n")

if summary_path := os.environ.get("GITHUB_STEP_SUMMARY"):
    with pathlib.Path(summary_path).open("a") as stream:
        stream.write(f"\n{sys.argv[3].title()} Appetize build: {url}\n")
PY
