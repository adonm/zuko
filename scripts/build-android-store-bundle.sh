#!/bin/bash
set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "usage: build-android-store-bundle.sh <vX.Y.Z> <version> <build-number>" >&2
  exit 2
fi

tag="$1"
version="$2"
build_number="$3"
pushd flutter >/dev/null
flutter pub get --enforce-lockfile
flutter build appbundle --release --no-pub \
  --build-name "$version" \
  --build-number "$build_number"
popd >/dev/null
mkdir -p dist/android
cp flutter/build/app/outputs/bundle/release/app-release.aab \
  "dist/android/zuko-android-$tag-unsigned.aab"
