#!/usr/bin/env bash
set -euo pipefail

readonly APP_ID=dev.adonm.zuko
readonly RUNTIME_REPO=https://flathub.org/repo/flathub.flatpakrepo

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"

version=$(scripts/version.sh)
tag=${1:-v$version}
arch=$(uname -m)
case "$arch" in
  x86_64)
    flutter_arch=x64
    platform_commit=fdad08cc10905f9175f0224652a7b1c1b4d37fc1a5fa8c97843ccef846c642a0
    sdk_commit=30e83c31042c341df56dbca804ec2f1eef204145c513659b83d6c446b2e7b4f5
    ;;
  aarch64)
    flutter_arch=arm64
    platform_commit=dca273214da6c8760a2ddde6fd107e293a4a1fa5dbe4968444034930b1f1bb3e
    sdk_commit=587b2f51b68cad07369c429e01584fd3b2b90523015e78acf5db11a8faac0604
    ;;
  *)
    echo "flatpak package: unsupported architecture: $arch" >&2
    exit 1
    ;;
esac
readonly arch flutter_arch platform_commit sdk_commit
readonly PLATFORM_REF="org.freedesktop.Platform/$arch/25.08"
readonly SDK_REF="org.freedesktop.Sdk/$arch/25.08"
bundle=flutter/build/linux/$flutter_arch/release/bundle
work=build/flatpak
output_dir=dist/linux
output=$output_dir/zuko-linux-$tag-$arch.flatpak

for command in flatpak flatpak-builder sha256sum ldd git; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "flatpak package: required command not found: $command" >&2
    exit 1
  }
done
if [[ ! "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || [[ "$tag" != "v$version" ]]; then
  echo "flatpak package: tag must be v$version, got $tag" >&2
  exit 1
fi
if [[ $(flatpak --default-arch) != "$arch" ]]; then
  echo "flatpak package: host and Flatpak architectures do not match" >&2
  exit 1
fi
for required in "$bundle/zuko" "$bundle/data" "$bundle/lib"; do
  [[ -e "$required" ]] || {
    echo "flatpak package: missing Flutter release output: $required" >&2
    exit 1
  }
done

bash scripts/validate-flatpak.sh

verify_runtime() {
  local ref=$1 expected=$2 actual
  actual=$(flatpak info --show-commit "$ref" 2>/dev/null) || {
    echo "flatpak package: required runtime is not installed: $ref" >&2
    exit 1
  }
  if [[ "$actual" != "$expected" ]]; then
    echo "flatpak package: $ref must be commit $expected, got $actual" >&2
    exit 1
  fi
}
verify_runtime "$PLATFORM_REF" "$platform_commit"
verify_runtime "$SDK_REF" "$sdk_commit"

if [[ -z ${SOURCE_DATE_EPOCH:-} ]]; then
  SOURCE_DATE_EPOCH=$(git show -s --format=%ct HEAD)
fi
[[ $SOURCE_DATE_EPOCH =~ ^[0-9]+$ ]] || {
  echo "flatpak package: SOURCE_DATE_EPOCH must be an integer" >&2
  exit 1
}
export SOURCE_DATE_EPOCH TZ=UTC LC_ALL=C.UTF-8

rm -rf "$work" "$output_dir"
mkdir -p "$work/staging/bundle" "$work/app" "$work/repo" "$work/state" "$output_dir"
cp -a "$bundle/." "$work/staging/bundle/"
find "$work/staging" -exec touch --no-dereference --date="@$SOURCE_DATE_EPOCH" {} +

while IFS= read -r -d '' binary; do
  linkage=$(ldd "$binary")
  printf '%s\n' "$linkage"
  if [[ $linkage == *"not found"* ]]; then
    echo "flatpak package: unresolved dependency in $binary" >&2
    exit 1
  fi
done < <(find "$work/staging/bundle" -type f \( -name zuko -o -name '*.so' -o -name '*.so.*' \) -print0)

(
  cd "$work/staging"
  find bundle -type f -print0 | sort -z | xargs -0 sha256sum > ../input.sha256
)

flatpak-builder \
  --arch="$arch" \
  --default-branch=stable \
  --disable-download \
  --disable-rofiles-fuse \
  --disable-updates \
  --force-clean \
  --repo="$work/repo" \
  --state-dir="$work/state" \
  "$work/app" \
  flatpak/dev.adonm.zuko.json

flatpak build-bundle \
  --arch="$arch" \
  --runtime-repo="$RUNTIME_REPO" \
  "$work/repo" \
  "$output" \
  "$APP_ID" \
  stable

mapfile -t packages < <(find "$output_dir" -maxdepth 1 -type f -name '*.flatpak' -print)
if [[ ${#packages[@]} -ne 1 ]] || [[ ${packages[0]} != "$output" ]]; then
  echo "flatpak package: expected exactly one bundle at $output" >&2
  exit 1
fi
(
  cd "$output_dir"
  sha256sum "$(basename "$output")" > "$(basename "$output").sha256"
  sha256sum --check "$(basename "$output").sha256"
)

smoke_home=$root/$work/smoke-home
mkdir -p "$smoke_home"
HOME="$smoke_home" flatpak --user install --noninteractive "$output"
# The variables below intentionally expand inside the sandbox shell.
# shellcheck disable=SC2016
HOME="$smoke_home" flatpak run --user --env=NO_AT_BRIDGE=1 \
  --env="EXPECTED_ARCH=$arch" --command=sh "$APP_ID" -c '
  set -eu
  test "$(uname -m)" = "$EXPECTED_ARCH"
  test -x /app/bin/zuko
  test -d /app/bin/data
  export LD_LIBRARY_PATH=/app/bin/lib
  for binary in /app/bin/zuko /app/bin/lib/*.so /app/bin/lib/*.so.*; do
    test -e "$binary" || continue
    linkage=$(ldd "$binary" 2>&1)
    printf "%s\n" "$linkage"
    case "$linkage" in
      *"not found"*) exit 1 ;;
    esac
  done
'

echo "flatpak package: $output"
echo "flatpak package: $output.sha256"
