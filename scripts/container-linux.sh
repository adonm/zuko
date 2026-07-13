#!/usr/bin/env bash
set -euo pipefail

readonly IMAGE=localhost/zuko-flutter-linux:2026.07
readonly CONTAINERFILE=containers/flutter-linux.Containerfile
readonly IGNORE_FILE=containers/flutter-linux.ignore

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
mode=${1:-check}

command -v podman >/dev/null 2>&1 || {
  echo "container Flutter build: podman is required" >&2
  exit 1
}

case "$mode" in
  check)
    command='just flutter-check'
    ;;
  linux)
    command='rm -rf flutter/build/linux && just build-flutter-linux'
    ;;
  bundle)
    # shellcheck disable=SC2016 # Expanded by the container's bash.
    command='rm -rf flutter/build/linux && just build-flutter-linux && just package-linux-release "v$(scripts/version.sh)" HEAD'
    ;;
  all)
    # shellcheck disable=SC2016 # Expanded by the container's bash.
    command='just flutter-check && rm -rf flutter/build/linux && just build-flutter-linux && just package-linux-release "v$(scripts/version.sh)" HEAD'
    ;;
  *)
    echo "usage: container-linux.sh <check|linux|bundle|all>" >&2
    exit 2
    ;;
esac

podman build \
  --file "$root/$CONTAINERFILE" \
  --ignorefile "$root/$IGNORE_FILE" \
  --tag "$IMAGE" \
  "$root"

mkdir -p \
  "$root/.tmp/container-home" \
  "$root/.tmp/container-mise/cache" \
  "$root/.tmp/container-mise/config" \
  "$root/.tmp/container-mise/state"

exec podman run --rm --privileged \
  --security-opt label=disable \
  --env HOME=/workspace/.tmp/container-home \
  --env MISE_CACHE_DIR=/workspace/.tmp/container-mise/cache \
  --env MISE_CONFIG_DIR=/workspace/.tmp/container-mise/config \
  --env MISE_STATE_DIR=/workspace/.tmp/container-mise/state \
  --env CARGO_HOME=/var/cache/zuko/cargo \
  --env PUB_CACHE=/var/cache/zuko/pub \
  --env SOURCE_DATE_EPOCH="$(git -C "$root" show -s --format=%ct HEAD)" \
  --volume "$root:/workspace" \
  --volume zuko-flutter-cargo:/var/cache/zuko/cargo \
  --volume zuko-flutter-pub:/var/cache/zuko/pub \
  --workdir /workspace \
  "$IMAGE" \
  bash -lc "git config --global --add safe.directory /workspace && $command"
