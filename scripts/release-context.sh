#!/bin/bash
set -euo pipefail

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  echo "usage: release-context.sh <vX.Y.Z> [android-build-number|apple-build-number]" >&2
  exit 2
fi

readonly TAG="$1"
readonly BUILD_NUMBER_MODE="${2:-}"

case "$BUILD_NUMBER_MODE" in
  ""|android-build-number|apple-build-number) ;;
  *) echo "unknown release context mode: $BUILD_NUMBER_MODE" >&2; exit 2 ;;
esac

if [[ ! "$TAG" =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
  echo "release label must match vX.Y.Z: $TAG" >&2
  exit 1
fi
if [ -n "${GITHUB_ACTIONS:-}" ] && [ "${GITHUB_EVENT_NAME:-}" = workflow_dispatch ] \
  && [ "${GITHUB_REF:-}" != refs/heads/main ]; then
  echo "recovery releases must be dispatched from main" >&2
  exit 1
fi

python3 scripts/check-release-metadata.py
version="$(scripts/version.sh)"
if [ "$TAG" != "v$version" ]; then
  echo "release label $TAG does not match source version v$version" >&2
  exit 1
fi

sha="$(git rev-parse HEAD)"
IFS=. read -r major minor patch <<< "$version"
version_code=$((major * 1000000 + minor * 1000 + patch))
if [ "$BUILD_NUMBER_MODE" = android-build-number ]; then
  version_code="$(date -u +%s)"
  if [ "$version_code" -gt 2100000000 ]; then
    echo "timestamp no longer fits the Google Play version-code range" >&2
    exit 1
  fi
fi

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "tag=$TAG"
    echo "sha=$sha"
    echo "version=$version"
    echo "version_code=$version_code"
    echo "package=dev.adonm.zuko"
    echo "asset=zuko-android-$TAG-signed.aab"
  } >> "$GITHUB_OUTPUT"
fi

if [ -n "${GITHUB_ENV:-}" ]; then
  echo "ZUKO_VERSION=$version" >> "$GITHUB_ENV"
  if [ "$BUILD_NUMBER_MODE" = apple-build-number ]; then
    echo "ZUKO_BUILD_NUMBER=$(date -u +%s)" >> "$GITHUB_ENV"
  fi
fi

echo "release context: $TAG from $sha"
