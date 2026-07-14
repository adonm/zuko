#!/usr/bin/env bash
set -euo pipefail

readonly IMAGE=localhost/zuko-flutter-ci:2026.07
readonly CONTAINERFILE=containers/flutter-ci.Containerfile
readonly IGNORE_FILE=containers/flutter-ci.ignore

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
mode=${1:-ci}

command -v podman >/dev/null 2>&1 || {
  echo "container Flutter build: podman is required" >&2
  exit 1
}
if [[ $(uname -m) != x86_64 ]]; then
  echo "container Flutter build: the pinned Flutter/Android image requires x86_64" >&2
  exit 1
fi

case "$mode" in
  check)
    command='mise exec -- just flutter-check'
    ;;
  preflight)
    command='mise exec -- just preflight'
    ;;
  quality)
    command='mise exec -- just lint-ci && mise exec -- just build-docs'
    ;;
  links)
    command='mise exec -- just lint-md'
    ;;
  e2e)
    command='mise exec -- just test-e2e'
    ;;
  web)
    command='mise exec -- just build-web'
    ;;
  android)
    command='rm -rf flutter/build/app && mise exec -- just build-flutter-android-debug'
    ;;
  android-release)
    command='rm -rf flutter/build/app && mise exec -- just build-flutter-android'
    ;;
  linux)
    command='rm -rf flutter/build/linux && mise exec -- just build-flutter-linux'
    ;;
  linux-bundle)
    # shellcheck disable=SC2016 # Expanded by the container's bash.
    command='rm -rf flutter/build/linux && mise exec -- just build-flutter-linux && mise exec -- just package-linux-release "v$(scripts/version.sh)" HEAD'
    ;;
  ci)
    command='mise exec -- just flutter-linux-ci'
    ;;
  all)
    command='mise exec -- just preflight && mise exec -- just lint-ci && mise exec -- just build-docs && mise exec -- just flutter-linux-builds'
    ;;
  legacy-all)
    # Compatibility for container-linux.sh all, which historically packaged Linux.
    # shellcheck disable=SC2016 # Expanded by the container's bash.
    command='mise exec -- just flutter-check && rm -rf flutter/build/linux && mise exec -- just build-flutter-linux && mise exec -- just package-linux-release "v$(scripts/version.sh)" HEAD'
    ;;
  *)
    echo "usage: container-flutter.sh <check|preflight|quality|links|e2e|web|android|android-release|linux|linux-bundle|ci|all>" >&2
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
  "$root/.tmp/container-mise/state" \
  "$root/dist" \
  "$root/flutter/build" \
  "$root/target"
plugins_metadata="$root/.tmp/container-flutter-plugins-dependencies"
: >"$plugins_metadata"

run_args=(
  --rm
  --security-opt label=disable
  --env HOME=/container-state/home
  --env MISE_CACHE_DIR=/container-state/mise/cache
  --env MISE_CONFIG_DIR=/container-state/mise/config
  --env MISE_STATE_DIR=/container-state/mise/state
  --env MISE_TRUSTED_CONFIG_PATHS=/workspace
  --env CARGO_HOME=/var/cache/zuko/cargo
  --env PUB_CACHE=/var/cache/zuko/pub
  --env GRADLE_USER_HOME=/var/cache/zuko/gradle
  --env GIT_OPTIONAL_LOCKS=0
  --env SOURCE_DATE_EPOCH="$(git -C "$root" show -s --format=%ct HEAD)"
  --volume "$root:/source:ro"
  --volume "$root/.git:/workspace/.git:ro"
  --volume "$root/.tmp/container-home:/container-state/home"
  --volume "$root/.tmp/container-mise/cache:/container-state/mise/cache"
  --volume "$root/.tmp/container-mise/config:/container-state/mise/config"
  --volume "$root/.tmp/container-mise/state:/container-state/mise/state"
  --volume "$root/dist:/workspace/dist"
  --volume "$root/flutter/build:/workspace/flutter/build"
  --volume "$root/target:/workspace/target"
  --volume zuko-flutter-cargo:/var/cache/zuko/cargo
  --volume zuko-flutter-dart-tool:/workspace/flutter/.dart_tool
  --volume zuko-flutter-pub:/var/cache/zuko/pub
  --volume zuko-flutter-gradle:/var/cache/zuko/gradle
  --volume "$plugins_metadata:/workspace/flutter/.flutter-plugins-dependencies"
  --workdir /workspace
)
if [[ $mode == links && -n ${GITHUB_TOKEN:-} ]]; then
  run_args+=(--env GITHUB_TOKEN)
fi

exec podman run "${run_args[@]}" "$IMAGE" bash -lc \
  "set -euo pipefail; tar -C /source \
    --exclude=./.git \
    --exclude=./.oy \
    --exclude=./.tmp \
    --exclude=./build \
    --exclude=./dist \
    --exclude=./flutter/.dart_tool \
    --exclude=./flutter/.flutter-plugins-dependencies \
    --exclude=./flutter/android/.gradle \
    --exclude=./flutter/android/app/src/main/java \
    --exclude=./flutter/android/gradle/wrapper/gradle-wrapper.jar \
    --exclude=./flutter/android/gradlew \
    --exclude=./flutter/android/gradlew.bat \
    --exclude=./flutter/android/local.properties \
    --exclude=./flutter/android/zuko_android.iml \
    --exclude=./flutter/build \
    --exclude=./flutter/ios/Flutter/Generated.xcconfig \
    --exclude=./flutter/ios/Flutter/ephemeral \
    --exclude=./flutter/ios/Flutter/flutter_export_environment.sh \
    --exclude=./flutter/ios/Runner/GeneratedPluginRegistrant.h \
    --exclude=./flutter/ios/Runner/GeneratedPluginRegistrant.m \
    --exclude=./flutter/linux/flutter/ephemeral \
    --exclude=./flutter/macos/Flutter/ephemeral \
    --exclude=./flutter/windows/flutter/ephemeral \
    --exclude=./target \
    -cf - . | tar -C /workspace -xf -; \
  cd /workspace; git config --global --add safe.directory /workspace; \
  flutter_root=\$(mise where http:flutter); \
  git config --global --add safe.directory \"\$flutter_root\"; $command"
