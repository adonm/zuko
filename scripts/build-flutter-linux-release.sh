#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: build-flutter-linux-release.sh <git-sha> <linux-x64|linux-arm64> <sysroot>" >&2
  exit 2
fi

readonly sha=$1
readonly target=$2
readonly sysroot=$3
SOURCE_DATE_EPOCH=$(git show -s --format=%ct "$sha")
export SOURCE_DATE_EPOCH TZ=UTC LC_ALL=C.UTF-8

python3 scripts/patch-iroh-flutter.py flutter
cd flutter

if [[ "$target" == linux-x64 ]]; then
  exec flutter build linux --release --no-pub
fi
if [[ "$target" != linux-arm64 ]] || [[ ! -d "$sysroot/usr" ]]; then
  echo "invalid Linux target or sysroot: $target $sysroot" >&2
  exit 1
fi

python3 ../scripts/patch-flutter-linux-cross.py "$(command -v flutter)"
export PKG_CONFIG_ALLOW_CROSS=1
export PKG_CONFIG_SYSROOT_DIR="$sysroot"
export PKG_CONFIG_LIBDIR="$sysroot/usr/lib/aarch64-linux-gnu/pkgconfig:$sysroot/usr/share/pkgconfig"
unset PKG_CONFIG_PATH
export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER=clang
export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_RUSTFLAGS="-C link-arg=--target=aarch64-linux-gnu -C link-arg=--sysroot=$sysroot -C link-arg=-fuse-ld=lld"
export CC_aarch64_unknown_linux_gnu=clang
export CXX_aarch64_unknown_linux_gnu=clang++
export AR_aarch64_unknown_linux_gnu=llvm-ar
export CFLAGS_aarch64_unknown_linux_gnu="--target=aarch64-linux-gnu --sysroot=$sysroot"
export CXXFLAGS_aarch64_unknown_linux_gnu="$CFLAGS_aarch64_unknown_linux_gnu"
export CFLAGS="--sysroot=$sysroot"
export CXXFLAGS="$CFLAGS"
export LDFLAGS="--sysroot=$sysroot -fuse-ld=lld"

exec flutter build linux --release --no-pub \
  --target-platform linux-arm64 \
  --target-sysroot "$sysroot"
