#!/usr/bin/env bash
set -euo pipefail

readonly APP_ID=dev.adonm.zuko
readonly IMAGE=localhost/zuko-flutter-ci:2026.07
readonly FLATPARK_URL=https://github.com/flatpark/flatpark.git
readonly FLATPARK_COMMIT=0ec1341c6c52ab75f9c0929654f3e530f8745422
readonly RUNTIME_REPO=https://dl.flathub.org/repo/flathub.flatpakrepo

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"

for command in git podman python3 sha256sum strings tar; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "FlatPark test bundle: required command not found: $command" >&2
    exit 1
  }
done
if [[ $(uname -m) != x86_64 ]]; then
  echo "FlatPark test bundle: only x86_64 builds are supported" >&2
  exit 1
fi

version=$(scripts/version.sh)
tag=v$version
branch=test-$tag
archive=dist/linux/zuko-linux-$tag-x86_64.tar.gz
work=build/flatpark-test
source_dir=$work/source
output_dir=dist/flatpak
output=$output_dir/zuko-linux-$tag-x86_64-test.flatpak
flatpark_ref=.tmp/ref/flatpark

# Build and package the same relocatable Linux payload used by GitHub Releases.
bash scripts/container-flutter.sh linux-bundle
(
  cd "$(dirname "$archive")"
  sha256sum --check "$(basename "$archive").sha256"
)
archive_sha=$(sha256sum "$archive" | cut -d' ' -f1)

# FlatPark owns the production wrapper and permissions. Consume an inspected,
# immutable registry revision instead of copying that packaging into this repo.
if [[ ! -d $flatpark_ref/.git ]]; then
  mkdir -p "$(dirname "$flatpark_ref")"
  git clone --filter=blob:none --no-checkout "$FLATPARK_URL" "$flatpark_ref"
fi
if ! git -C "$flatpark_ref" cat-file -e "$FLATPARK_COMMIT^{commit}" 2>/dev/null; then
  git -C "$flatpark_ref" fetch --filter=blob:none origin main
fi
[[ $(git -C "$flatpark_ref" rev-parse "$FLATPARK_COMMIT^{commit}") == "$FLATPARK_COMMIT" ]] || {
  echo "FlatPark test bundle: pinned registry commit is unavailable" >&2
  exit 1
}

rm -rf "$work/app" "$work/repo" "$work/verify" "$source_dir" "$output_dir"
mkdir -p "$source_dir" "$output_dir"
git -C "$flatpark_ref" archive "$FLATPARK_COMMIT" registry/$APP_ID \
  | tar -x -C "$source_dir" --strip-components=2
cp "$archive" "$source_dir/"

python3 - "$source_dir/$APP_ID.yml" "$source_dir/$APP_ID.metainfo.xml" \
  "$(basename "$archive")" "$archive_sha" "$version" \
  "$(git show -s --format=%cs HEAD)" <<'PY'
from __future__ import annotations

import pathlib
import re
import sys

manifest_path = pathlib.Path(sys.argv[1])
metainfo_path = pathlib.Path(sys.argv[2])
archive, archive_sha, version, release_date = sys.argv[3:]

manifest = manifest_path.read_text()
build_marker = "    build-commands:\n"
if manifest.count(build_marker) != 1:
    raise SystemExit("unsupported FlatPark Zuko build-command layout")
manifest = manifest.replace(
    build_marker,
    build_marker
    + "      - mkdir -p /app/lib/zuko\n"
    + "      - cp -a bundle /app/lib/zuko/bundle\n",
)
source_pattern = re.compile(
    r"      # BEGIN MANAGED EXTRA-DATA\n.*?      # END MANAGED EXTRA-DATA\n",
    re.DOTALL,
)
local_source = (
    "      # BEGIN MANAGED EXTRA-DATA\n"
    "      - type: archive\n"
    f"        path: {archive}\n"
    f"        sha256: {archive_sha}\n"
    "        strip-components: 0\n"
    "      # END MANAGED EXTRA-DATA\n"
)
manifest, replacements = source_pattern.subn(local_source, manifest)
if replacements != 1:
    raise SystemExit("unsupported FlatPark Zuko extra-data layout")
manifest_path.write_text(manifest)

# /app/extra is reserved for Flatpak's install-time extra-data mount and is
# omitted from a normal self-contained bundle. Only the local wrapper path
# differs from production; the upstream payload remains byte-for-byte intact.
wrapper_path = manifest_path.parent / "zuko-wrapper"
wrapper = wrapper_path.read_text()
old_exec = "exec /app/extra/bundle/zuko \"$@\""
new_exec = "exec /app/lib/zuko/bundle/zuko \"$@\""
if wrapper.count(old_exec) != 1:
    raise SystemExit("unsupported FlatPark Zuko wrapper layout")
wrapper_path.write_text(wrapper.replace(old_exec, new_exec))

metainfo = metainfo_path.read_text()
release = f'    <release version="{version}" date="{release_date}" />\n'
if release not in metainfo:
    marker = "  <releases>\n"
    if metainfo.count(marker) != 1:
        raise SystemExit("unsupported FlatPark Zuko release metadata layout")
    metainfo_path.write_text(metainfo.replace(marker, marker + release))
PY

mkdir -p .tmp/flatpak-builder-state
podman run --rm --privileged \
  --security-opt label=disable \
  --volume "$root:/workspace" \
  --volume zuko-flatpak-builder:/root/.local/share/flatpak \
  --workdir /workspace/$source_dir \
  "$IMAGE" \
  bash -lc "
    set -euo pipefail
    flatpak remote-add --user --if-not-exists flathub '$RUNTIME_REPO'
    flatpak-builder --force-clean --disable-rofiles-fuse \\
      --install-deps-from=flathub --user \\
      --state-dir=/workspace/.tmp/flatpak-builder-state \\
      --repo=/workspace/$work/repo --default-branch='$branch' \\
      /workspace/$work/app /workspace/$source_dir/$APP_ID.yml
    flatpak build-bundle --runtime-repo='$RUNTIME_REPO' \\
      /workspace/$work/repo /workspace/$output '$APP_ID' '$branch'
    ostree --repo=/workspace/$work/repo checkout \\
      'app/$APP_ID/x86_64/$branch' /workspace/$work/verify
  "

python3 - "$work/verify/metadata" <<'PY'
from __future__ import annotations

import configparser
import pathlib
import sys

metadata = configparser.ConfigParser(interpolation=None)
metadata.read(sys.argv[1])
context = metadata["Context"]


def values(name: str) -> set[str]:
    return {value for value in context.get(name, "").split(";") if value}

expected = {
    "shared": {"ipc", "network"},
    "sockets": {"wayland"},
    "devices": {"dri"},
}
for name, wanted in expected.items():
    actual = values(name)
    if actual != wanted:
        raise SystemExit(f"unexpected FlatPark {name}: {sorted(actual)}")
if metadata["Session Bus Policy"].get("org.freedesktop.secrets") != "talk":
    raise SystemExit("FlatPark test bundle lacks Secret Service access")

payload = pathlib.Path(sys.argv[1]).parent / "files/lib/zuko/bundle"
for path in (payload / "zuko", payload / "data", payload / "lib"):
    if not path.exists():
        raise SystemExit(f"FlatPark test bundle is missing {path}")
PY

for symbol in 'KeyringLocked' 'Libsecret error' 'secret_service_get_sync'; do
  strings "$work/verify/files/lib/zuko/bundle/lib/libflutter_secure_storage_linux_plugin.so" \
    | grep -F "$symbol" >/dev/null || {
      echo "FlatPark test bundle: secure-storage plugin lacks $symbol" >&2
      exit 1
    }
done
(
  cd "$output_dir"
  sha256sum "$(basename "$output")" > "$(basename "$output").sha256"
  sha256sum --check "$(basename "$output").sha256"
)

echo "FlatPark test bundle: $output"
echo "FlatPark test bundle: $output.sha256"
echo "Install: flatpak --user install '$output'"
echo "Run: flatpak run '$APP_ID//$branch'"
