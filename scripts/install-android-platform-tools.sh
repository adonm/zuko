#!/usr/bin/env bash
set -euo pipefail

readonly VERSION=37.0.0
readonly SHA256=198ae156ab285fa555987219af237b31102fefe8b9d2bc274708a8d4f2865a07

sdk_root=${1:-${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}}
if [[ -z $sdk_root ]]; then
  echo "install Android platform tools: pass SDK_ROOT or set ANDROID_SDK_ROOT" >&2
  exit 2
fi

properties="$sdk_root/platform-tools/source.properties"
if [[ -f $properties ]] && grep -qx "Pkg.Revision=$VERSION" "$properties"; then
  exit 0
fi

mkdir -p "$sdk_root"
staging=$(mktemp -d "$sdk_root/.platform-tools.XXXXXX")
archive="$staging/platform-tools.zip"
cleanup() {
  rm -rf "$staging"
}
trap cleanup EXIT HUP INT TERM

curl --fail --location --retry 3 \
  "https://dl.google.com/android/repository/platform-tools_r${VERSION}-linux.zip" \
  --output "$archive"
printf '%s  %s\n' "$SHA256" "$archive" | sha256sum --check -
unzip -q "$archive" -d "$staging/unpacked"
replacement="$staging/unpacked/platform-tools"
if [[ ! -f $replacement/source.properties ]] ||
  ! grep -qx "Pkg.Revision=$VERSION" "$replacement/source.properties"; then
  echo "install Android platform tools: archive has an unexpected layout or version" >&2
  exit 1
fi
rm -rf "$sdk_root/platform-tools"
mv "$replacement" "$sdk_root/platform-tools"
