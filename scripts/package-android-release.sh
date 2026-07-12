#!/bin/bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: package-android-release.sh <vX.Y.Z> <signing-mode>" >&2
  exit 2
fi

tag="$1"
mode="$2"
[ "$mode" = signed ] || { echo "Android release must be signed" >&2; exit 1; }
: "${ANDROID_HOME:?ANDROID_HOME is required}"

apk=flutter/build/app/outputs/flutter-apk/app-release.apk
aab=flutter/build/app/outputs/bundle/release/app-release.aab
"$ANDROID_HOME/build-tools/36.0.0/apksigner" verify --verbose "$apk"
aab_verify="$(jarsigner -verify "$aab" 2>&1)"
case "$aab_verify" in
  *"jar verified"*) echo "AAB JAR signature verified" ;;
  *) printf '%s\n' "$aab_verify" >&2; exit 1 ;;
esac

mkdir -p dist/android
cp "$apk" "dist/android/zuko-android-$tag-$mode.apk"
cp "$aab" "dist/android/zuko-android-$tag-$mode.aab"
cd dist/android
for asset in *.apk *.aab; do
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$asset" > "$asset.sha256"
  else
    shasum -a 256 "$asset" > "$asset.sha256"
  fi
done
