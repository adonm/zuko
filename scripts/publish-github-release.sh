#!/bin/bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: publish-github-release.sh <vX.Y.Z>" >&2
  exit 2
fi
+: "${GH_REPO:?GH_REPO is required}"
+: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
tag="$1"

echo "Publishing $tag with:"
ls -1 assets
if gh release view "$tag" >/dev/null 2>&1; then
  release_id="$(gh release view "$tag" --json databaseId --jq .databaseId)"
  gh release edit "$tag" --draft
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
