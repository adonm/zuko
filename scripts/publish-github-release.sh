#!/bin/bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: publish-github-release.sh <vX.Y.Z>" >&2
  exit 2
fi
: "${GH_REPO:?GH_REPO is required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
tag="$1"

expected_assets=(
  "zuko-aarch64-apple-darwin.tar.gz"
  "zuko-aarch64-apple-darwin.tar.gz.sha256"
  "zuko-aarch64-unknown-linux-gnu.tar.gz"
  "zuko-aarch64-unknown-linux-gnu.tar.gz.sha256"
  "zuko-android-$tag-signed.aab"
  "zuko-android-$tag-signed.aab.sha256"
  "zuko-android-$tag-signed.apk"
  "zuko-android-$tag-signed.apk.sha256"
  "zuko-linux-$tag-x86_64.flatpak"
  "zuko-linux-$tag-x86_64.flatpak.sha256"
  "zuko-windows-$tag-x86_64.zip"
  "zuko-windows-$tag-x86_64.zip.sha256"
  "zuko-x86_64-apple-darwin.tar.gz"
  "zuko-x86_64-apple-darwin.tar.gz.sha256"
  "zuko-x86_64-unknown-linux-gnu.tar.gz"
  "zuko-x86_64-unknown-linux-gnu.tar.gz.sha256"
)
mapfile -t actual_assets < <(find assets -maxdepth 1 -type f -printf '%f\n' | sort)
mapfile -t expected_assets < <(printf '%s\n' "${expected_assets[@]}" | sort)
if [[ ${actual_assets[*]} != "${expected_assets[*]}" ]]; then
  printf 'expected release assets:\n%s\n' "${expected_assets[*]}" >&2
  printf 'actual release assets:\n%s\n' "${actual_assets[*]}" >&2
  exit 1
fi
for sidecar in assets/*.sha256; do
  (cd assets && sha256sum --check "$(basename "$sidecar")")
done

echo "Publishing $tag with:"
ls -1 assets
if gh release view "$tag" >/dev/null 2>&1; then
  release_json="$(gh release view "$tag" --json databaseId,isDraft)"
  release_id="$(jq -r .databaseId <<< "$release_json")"
  if [ "$(jq -r .isDraft <<< "$release_json")" != true ]; then
    echo "refusing to modify published immutable release: $tag" >&2
    exit 1
  fi
else
  gh release create "$tag" --draft --title "$tag" --generate-notes --verify-tag
  release_id="$(gh release view "$tag" --json databaseId --jq .databaseId)"
fi

declare -A expected_names=()
for asset in assets/*; do
  expected_names["$(basename "$asset")"]=1
done
endpoint="repos/$GITHUB_REPOSITORY/releases/$release_id"
while IFS=$'\t' read -r asset_id name; do
  if [ -z "${expected_names[$name]+present}" ]; then
    gh api --method DELETE "repos/$GITHUB_REPOSITORY/releases/assets/$asset_id"
  fi
done < <(gh api "$endpoint" --jq '.assets[] | [.id, .name] | @tsv')

gh release upload "$tag" assets/* --clobber
for asset in assets/*; do
  name="$(basename "$asset")"
  expected="sha256:$(sha256sum "$asset" | cut -d' ' -f1)"
  actual="$(gh api "$endpoint" --jq \
    ".assets | map(select(.name == \"$name\")) | if length == 1 then .[0].digest else error(\"asset missing or duplicated\") end")"
  [ "$actual" = "$expected" ]
done
remote_count="$(gh api "$endpoint" --jq '.assets | length')"
[ "$remote_count" -eq "${#expected_names[@]}" ]
gh release edit "$tag" --draft=false --latest
