#!/bin/bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: package-cli-release.sh <rust-target>" >&2
  exit 2
fi

target="$1"
artifact="zuko-$target.tar.gz"
mkdir -p dist
cp "target/$target/release/zuko" dist/zuko
chmod +x dist/zuko
tar_args=(zuko)
if [ "$target" = x86_64-unknown-linux-gnu ] && [ -d dist/cage ]; then
  tar_args+=(cage)
fi
tar -C dist -czf "$artifact" "${tar_args[@]}"
if command -v sha256sum >/dev/null 2>&1; then
  sha256sum "$artifact" > "$artifact.sha256"
else
  shasum -a 256 "$artifact" > "$artifact.sha256"
fi
tar -tzf "$artifact"
cat "$artifact.sha256"
