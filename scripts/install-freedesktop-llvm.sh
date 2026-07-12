#!/usr/bin/env bash
set -euo pipefail

readonly ref=org.freedesktop.Sdk.Extension.llvm20//25.08
readonly commit=1fac8133086b2ee599d277ad48373c99e64acee7611fc05fbb15beb485b36702
readonly destination=${1:-/app/llvm}

# The pinned Freedesktop SDK is the ABI baseline used by FlatPark. This helper
# exposes its LLVM extension to Flutter without building or publishing a
# Flatpak in this repository.

flatpak install --system --noninteractive --or-update flathub "$ref" >/dev/null
flatpak update --system --noninteractive --commit="$commit" "$ref" >/dev/null

actual=$(flatpak info --system --show-commit "$ref")
if [[ "$actual" != "$commit" ]]; then
  echo "LLVM extension commit is $actual, expected $commit" >&2
  exit 1
fi

location=$(flatpak info --system --show-location "$ref")
mkdir -p "$(dirname "$destination")"
ln -sfn "$location/files" "$destination"
"$destination/bin/clang" --version
"$destination/bin/clang++" --version
