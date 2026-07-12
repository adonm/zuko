#!/bin/bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: package-codemagic-android-unsigned.sh <vX.Y.Z>" >&2
  exit 2
fi
: "${ANDROID_HOME:?ANDROID_HOME is required}"

tag="$1"
version="$(scripts/version.sh)"
if [[ "$tag" != "v$version" ]]; then
  echo "Android package: tag must be v$version, got $tag" >&2
  exit 1
fi

apk=flutter/build/app/outputs/flutter-apk/app-release.apk
aab=flutter/build/app/outputs/bundle/release/app-release.aab
test -f "$apk"
test -f "$aab"
unzip -t "$apk" >/dev/null
unzip -t "$aab" >/dev/null
if "$ANDROID_HOME/build-tools/36.0.0/apksigner" verify "$apk" >/dev/null 2>&1; then
  echo "Android package: Codemagic APK must be unsigned" >&2
  exit 1
fi
if jarsigner -verify "$aab" 2>&1 | grep -q "jar verified"; then
  echo "Android package: Codemagic AAB must be unsigned" >&2
  exit 1
fi

mkdir -p dist/android
cp "$apk" "dist/android/zuko-android-$tag-unsigned.apk"
cp "$aab" "dist/android/zuko-android-$tag-unsigned.aab"
