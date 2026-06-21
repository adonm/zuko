#!/bin/sh
# Install the Darwin Swift SDK bundle used by xtool on Linux CI/local builds.
#
# The bundle is produced by .github/workflows/bootstrap-xtoolsdk.yml and stored
# as a GitHub Release asset. This script is idempotent: if xtool already sees an
# installed SDK, it exits without network access.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TAG="${XTOOLSDK_TAG:-xtoolsdk-v1}"
REPO="${GITHUB_REPOSITORY:-}"
ARCH="${XTOOLSDK_ARCH:-$(uname -m)}"
CACHE_DIR="${XTOOLSDK_CACHE_DIR:-$HOME/.cache/zuko/xtoolsdk/$TAG/$ARCH}"

sdk_installed() {
    status="$(xtool sdk status 2>&1 || true)"
    ! printf '%s\n' "$status" | grep -qi 'not installed'
}

if ! command -v xtool >/dev/null 2>&1; then
    echo "setup-ios-sdk: xtool not found; run 'mise run setup-ios' first" >&2
    exit 1
fi
if ! command -v swift >/dev/null 2>&1; then
    echo "setup-ios-sdk: swift not found; run 'mise run setup-ios' first" >&2
    exit 1
fi

if sdk_installed; then
    xtool sdk status
    exit 0
fi

case "$(uname -s)" in
    Linux) ;;
    Darwin)
        echo "setup-ios-sdk: SDK is not installed. On macOS run: xtool setup" >&2
        exit 1
        ;;
    *)
        echo "setup-ios-sdk: unsupported OS $(uname -s)" >&2
        exit 2
        ;;
esac

if [ -z "$REPO" ]; then
    if command -v gh >/dev/null 2>&1; then
        REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
    fi
fi
if [ -z "$REPO" ]; then
    remote="$(git -C "$ROOT" remote get-url origin 2>/dev/null || true)"
    case "$remote" in
        git@github.com:*) REPO="${remote#git@github.com:}"; REPO="${REPO%.git}" ;;
        https://github.com/*) REPO="${remote#https://github.com/}"; REPO="${REPO%.git}" ;;
    esac
fi
if [ -z "$REPO" ]; then
    echo "setup-ios-sdk: couldn't determine GitHub repo for SDK release" >&2
    exit 1
fi

mkdir -p "$CACHE_DIR"
bundle_dir="$(find "$CACHE_DIR" -maxdepth 1 -type d \( -name 'darwin.artifactbundle' -o -name 'darwin.xtoolsdk' \) -print | head -1)"

if [ -z "$bundle_dir" ]; then
    asset="darwin-$ARCH.tar.gz"
    tarball="$CACHE_DIR/$asset"
    echo "==> downloading $REPO $TAG/$asset"
    if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
        gh release download "$TAG" \
            --repo "$REPO" \
            --pattern "$asset" \
            --output "$tarball"
    else
        curl -fL "https://github.com/$REPO/releases/download/$TAG/$asset" \
            -o "$tarball"
    fi
    tar -C "$CACHE_DIR" --warning=no-unknown-keyword -xzf "$tarball"
    rm -f "$tarball"
    bundle_dir="$(find "$CACHE_DIR" -maxdepth 1 -type d \( -name 'darwin.artifactbundle' -o -name 'darwin.xtoolsdk' \) -print | head -1)"
fi

if [ -z "$bundle_dir" ]; then
    echo "setup-ios-sdk: no Darwin SDK bundle found in $CACHE_DIR" >&2
    exit 1
fi

echo "==> installing Darwin Swift SDK: $bundle_dir"
case "$bundle_dir" in
    *.artifactbundle) swift sdk install "$bundle_dir" ;;
    *) xtool sdk install "$bundle_dir" || swift sdk install "$bundle_dir" ;;
esac

xtool sdk status
