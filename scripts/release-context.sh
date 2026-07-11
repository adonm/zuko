#!/bin/bash
set -euo pipefail

if [ "$#" -gt 1 ]; then
  echo "usage: release-context.sh [vX.Y.Z]" >&2
  exit 2
fi

python3 scripts/check-release-metadata.py
version="$(scripts/version.sh)"
TAG="${1:-v$version}"
readonly TAG
sha="$(git rev-parse HEAD)"
readonly sha

if [[ ! "$TAG" =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
  echo "release tag must match vX.Y.Z: $TAG" >&2
  exit 1
fi
if [ "$TAG" != "v$version" ]; then
  echo "release tag $TAG does not match source version v$version" >&2
  exit 1
fi

# A supplied tag is a publication identity and must resolve to this exact
# checkout. Omitting it is reserved for non-publishing branch validation.
if [ "$#" -eq 1 ]; then
  tag_sha="$(git rev-parse "$TAG^{commit}" 2>/dev/null)" || {
    echo "release tag does not exist in this checkout: $TAG" >&2
    exit 1
  }
  if [ "$sha" != "$tag_sha" ]; then
    echo "release tag $TAG resolves to $tag_sha, not checked-out source $sha" >&2
    exit 1
  fi
fi

IFS=. read -r major minor patch <<< "$version"
version_code=$((1800000000 + major * 1000000 + minor * 1000 + patch))
if [ "$version_code" -gt 2100000000 ]; then
  echo "release version no longer fits the Google Play build-number range" >&2
  exit 1
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
  echo "ZUKO_BUILD_NUMBER=$version_code" >> "$GITHUB_ENV"
fi

echo "release context: $TAG from $sha"
