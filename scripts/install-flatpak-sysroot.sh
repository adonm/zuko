#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: install-flatpak-sysroot.sh <aarch64> <destination>" >&2
  exit 2
fi

readonly arch=$1
readonly destination=$2
case "$arch" in
  aarch64)
    readonly sdk_commit=587b2f51b68cad07369c429e01584fd3b2b90523015e78acf5db11a8faac0604
    ;;
  *)
    echo "unsupported Flatpak target architecture: $arch" >&2
    exit 1
    ;;
esac

readonly ref="org.freedesktop.Sdk/$arch/25.08"
flatpak install --system --arch="$arch" --noninteractive --or-update \
  flathub "$ref" >/dev/null
flatpak update --system --arch="$arch" --noninteractive \
  --commit="$sdk_commit" "$ref" >/dev/null

actual=$(flatpak info --system --arch="$arch" --show-commit "$ref")
if [[ "$actual" != "$sdk_commit" ]]; then
  echo "Flatpak sysroot commit is $actual, expected $sdk_commit" >&2
  exit 1
fi

location=$(flatpak info --system --arch="$arch" --show-location "$ref")
rm -rf "$destination"
mkdir -p "$destination"
ln -s "$location/files" "$destination/usr"
ln -s usr/lib "$destination/lib"
test -d "$destination/usr/include"
test -d "$destination/usr/lib"
test -d "$destination/usr/lib/aarch64-linux-gnu/pkgconfig"
