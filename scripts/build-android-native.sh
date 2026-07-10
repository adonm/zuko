#!/bin/sh
# Build every native library consumed by the Android app.
#
# Trust boundary: native sources are fetched at immutable commits, then built
# locally. Generated .so/.a files live under ignored android/ paths and are
# never accepted from an unverified release URL.
set -eu

# Use the physical path. Fedora Atomic desktops expose /home as /var/home;
# mixing those aliases makes Zig 0.15 generate invalid relative host-tool paths.
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
# Zig's host-tool path relativizer sees Fedora's /home and /var/home bind
# aliases as different roots. Keep every path on the /home spelling so build
# executables are launched from the location Zig encoded.
case "$ROOT" in
    /var/home/*) ROOT="/home/${ROOT#/var/home/}" ;;
esac
TMP="$ROOT/.tmp/android"
NATIVE="$ROOT/android/native"
JNI="$ROOT/android/app/src/main/jniLibs"

GHOSTTY_REPOSITORY=https://github.com/ghostty-org/ghostty.git
GHOSTTY_COMMIT=a23d90c89afa00fd5563a3db89d8a1cfab3e7573
IROH_REPOSITORY=https://github.com/n0-computer/iroh-ffi.git
IROH_COMMIT=afcb46d9f583eca81a592eddeae531efe91f3bd1
ANDROID_API=29
ANDROID_ABIS=${ANDROID_ABIS:-"arm64-v8a x86_64"}

if [ -z "${ANDROID_NDK_HOME:-}" ] || [ ! -d "$ANDROID_NDK_HOME" ]; then
    echo "build-android-native: ANDROID_NDK_HOME must point to Android NDK r29" >&2
    exit 1
fi
ndk_revision=$(sed -n 's/^Pkg.Revision[[:space:]]*=[[:space:]]*//p' "$ANDROID_NDK_HOME/source.properties")
if [ "$ndk_revision" != "29.0.14206865" ]; then
    echo "build-android-native: expected NDK 29.0.14206865, found ${ndk_revision:-unknown}" >&2
    exit 1
fi
for tool in git zig cargo cargo-ndk rustup; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "build-android-native: missing $tool (run through 'mise run build-android-native')" >&2
        exit 1
    }
done

mkdir -p "$TMP" "$NATIVE" "$JNI"

checkout() {
    repository=$1
    commit=$2
    destination=$3
    if [ ! -d "$destination/.git" ]; then
        git clone --filter=blob:none --no-checkout "$repository" "$destination"
    fi
    git -C "$destination" fetch --depth 1 origin "$commit"
    git -C "$destination" checkout --detach --force "$commit"
    actual=$(git -C "$destination" rev-parse HEAD)
    [ "$actual" = "$commit" ] || {
        echo "build-android-native: pin mismatch for $destination" >&2
        exit 1
    }
}

GHOSTTY="$TMP/ghostty"
IROH="$TMP/iroh-ffi"
checkout "$GHOSTTY_REPOSITORY" "$GHOSTTY_COMMIT" "$GHOSTTY"
checkout "$IROH_REPOSITORY" "$IROH_COMMIT" "$IROH"

echo "==> libghostty-vt ($GHOSTTY_COMMIT)"
for abi in $ANDROID_ABIS; do
    case "$abi" in
        arm64-v8a) target="aarch64-linux-android.$ANDROID_API" ;;
        x86_64) target="x86_64-linux-android.$ANDROID_API" ;;
        *) echo "build-android-native: unsupported ABI: $abi" >&2; exit 1 ;;
    esac
    prefix="$NATIVE/ghostty/$abi"
    rm -rf "$prefix"
    mkdir -p "$prefix"
    (
        cd "$GHOSTTY"
        PWD="$GHOSTTY" ZIG_LOCAL_CACHE_DIR="$GHOSTTY/.zig-cache-zuko" \
        zig build --prefix "$prefix" \
            -Demit-lib-vt \
            -Dtarget="$target" \
            -Doptimize=ReleaseFast \
            -Dsimd=false \
            -Dlib-version-string=0.1.0-dev+a23d90c
    )
    test -f "$prefix/lib/libghostty-vt.a"
done

echo "==> iroh-ffi ($IROH_COMMIT)"
iroh_targets=""
for abi in $ANDROID_ABIS; do
    case "$abi" in
        arm64-v8a)
            rust_target=aarch64-linux-android
            ;;
        x86_64)
            rust_target=x86_64-linux-android
            ;;
        *) exit 1 ;;
    esac
    rustup target add "$rust_target"
    rm -rf "${JNI:?}/$abi"
    iroh_targets="$iroh_targets -t $abi"
done
# shellcheck disable=SC2086 # cargo-ndk expects repeated words from the ABI list.
(cd "$IROH" && cargo ndk -p "$ANDROID_API" -o "$JNI" $iroh_targets build --release --locked --lib)

echo "==> zuko Rust FFI"
zuko_targets=""
for abi in $ANDROID_ABIS; do
    case "$abi" in
        arm64-v8a) rust_target=aarch64-linux-android ;;
        x86_64) rust_target=x86_64-linux-android ;;
        *) exit 1 ;;
    esac
    rustup target add "$rust_target"
    zuko_targets="$zuko_targets -t $abi"
done
# shellcheck disable=SC2086 # cargo-ndk expects repeated words from the ABI list.
(cd "$ROOT" && cargo ndk -p "$ANDROID_API" -o "$JNI" $zuko_targets build --release --locked --lib)

echo "==> UniFFI Kotlin binding"
(cd "$ROOT" && cargo build --locked --lib && cargo run --locked --bin uniffi-bindgen -- generate \
    --no-format \
    --language kotlin \
    --out-dir android/app/src/main/kotlin \
    --config uniffi.toml \
    --library target/debug/libzuko.so)
(cd "$ROOT" && python3 scripts/patch-android-uniffi.py)

echo "Android native libraries ready:"
for abi in $ANDROID_ABIS; do
    echo "  $abi: libiroh_ffi.so libzuko.so + libghostty-vt.a"
    test -f "$JNI/$abi/libiroh_ffi.so"
    test -f "$JNI/$abi/libzuko.so"
done
