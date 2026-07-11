#!/bin/bash
set -euo pipefail

if [ "$#" -ne 5 ]; then
  echo "usage: prepare-android-store-aab.sh <tag> <asset> <package> <version> <build>" >&2
  exit 2
fi

tag="$1"
asset="$2"
package="$3"
version="$4"
build="$5"
mkdir -p dist/android
input="staging/zuko-android-$tag-unsigned.aab"
output="dist/android/$asset"
scripts/android-prepare-aab.sh sign "$input" "$output"
(cd dist/android && sha256sum "$asset" > "$asset.sha256")
scripts/android-validate-aab.sh \
  "$output" \
  "dist/android/$asset.sha256" \
  "$package" \
  "$version" \
  "$build"
if [ -n "${GITHUB_ENV:-}" ]; then
  echo "AAB_SHA256=$(sha256sum "$output" | cut -d' ' -f1)" >> "$GITHUB_ENV"
fi
