#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
FORK_REV=cc3e2009082bb6b4dec31a42f1b11ff0e2a004a6
FORK_PACKAGE=crossterm-zuko
FORK_VERSION=0.29.0-zuko.1
VERSION=$(
  cd "$ROOT"
  scripts/version.sh
)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

echo "Checking the development graph (including the crossterm runtime patch)..."
cargo check --manifest-path "$ROOT/Cargo.toml" --locked --all-targets

if ! python3 - "$FORK_PACKAGE" "$FORK_VERSION" <<'PY' >/dev/null 2>&1
import json
import sys
import urllib.request

name, version = sys.argv[1:]
request = urllib.request.Request(
    f"https://crates.io/api/v1/crates/{name}/{version}",
    headers={"User-Agent": "zuko-publication-check"},
)
with urllib.request.urlopen(request, timeout=30) as response:
    payload = json.load(response)
if payload.get("version", {}).get("num") != version:
    raise SystemExit(1)
PY
then
  echo "crate package: publication BLOCKED: publish $FORK_PACKAGE $FORK_VERSION first" >&2
  echo "crate package: source: https://github.com/adonm/crossterm/tree/crossterm-zuko-v$FORK_VERSION" >&2
  exit 1
fi

echo "Building the crates.io package..."
cargo package \
  --manifest-path "$ROOT/Cargo.toml" \
  --allow-dirty \
  --locked \
  --no-verify \
  --target-dir "$WORK/target"

ARCHIVE="$WORK/target/package/zuko-$VERSION.crate"
PACKAGE="$WORK/package/zuko-$VERSION"
test -f "$ARCHIVE"
mkdir -p "$WORK/package"
tar -xzf "$ARCHIVE" -C "$WORK/package"
test -f "$PACKAGE/Cargo.toml"
if find "$PACKAGE" -type f \( \
  -path '*/.tmp/*' -o \
  -path '*/.github/*' -o \
  -path '*/docs/*' -o \
  -path '*/flutter/*' -o \
  -path '*/scripts/*' \
\) | grep -q .; then
  echo "crate package: non-crate workspace files leaked into the archive" >&2
  exit 1
fi

echo "Checking the unpacked package with its crates.io-only lockfile..."
cargo check \
  --manifest-path "$PACKAGE/Cargo.toml" \
  --locked \
  --all-targets \
  --target-dir "$ROOT/target/crate-package-check"

cargo metadata \
  --manifest-path "$ROOT/Cargo.toml" \
  --locked \
  --format-version 1 > "$WORK/development-metadata.json"
cargo metadata \
  --manifest-path "$PACKAGE/Cargo.toml" \
  --locked \
  --format-version 1 > "$WORK/package-metadata.json"

python3 - \
  "$WORK/development-metadata.json" \
  "$WORK/package-metadata.json" \
  "$PACKAGE/Cargo.toml" \
  "$FORK_REV" \
  "$FORK_PACKAGE" \
  "$FORK_VERSION" <<'PY'
import json
import pathlib
import sys


development_path, package_path, manifest_path, fork_rev, fork_package, fork_version = sys.argv[1:]


def fail(message: str) -> None:
    print(f"crate package: {message}", file=sys.stderr)
    raise SystemExit(1)


def direct_dependency(metadata: dict, name: str) -> tuple[dict, dict]:
    root_id = metadata["resolve"]["root"]
    nodes = {node["id"]: node for node in metadata["resolve"]["nodes"]}
    packages = {package["id"]: package for package in metadata["packages"]}
    matches = [dependency for dependency in nodes[root_id]["deps"] if dependency["name"] == name]
    if len(matches) != 1:
        fail(f"expected exactly one direct {name} dependency, found {len(matches)}")
    dependency_id = matches[0]["pkg"]
    declared = [
        dependency
        for dependency in packages[root_id]["dependencies"]
        if dependency.get("rename") == name
        or (dependency.get("rename") is None and dependency["name"] == name)
    ]
    if len(declared) != 1:
        fail(f"expected exactly one declared {name} dependency, found {len(declared)}")
    return packages[dependency_id], declared[0]


def parser_has_underflow_fix(package: dict) -> bool:
    parser = pathlib.Path(package["manifest_path"]).parent / "src/event/sys/unix/parse.rs"
    try:
        source = parser.read_text()
    except OSError as error:
        fail(f"cannot inspect resolved crossterm parser at {parser}: {error}")

    def section(start: str, end: str) -> str:
        try:
            return source.split(start, 1)[1].split(end, 1)[0]
        except IndexError:
            fail(f"resolved crossterm parser does not have the expected {start} section")

    cursor = section("fn parse_csi_cursor_position", "fn parse_csi_keyboard_enhancement_flags")
    rxvt = section("fn parse_csi_rxvt_mouse", "fn parse_csi_normal_mouse")
    normal = section("fn parse_csi_normal_mouse", "fn parse_csi_sgr_mouse")
    sgr = section("fn parse_csi_sgr_mouse", "fn parse_cb")
    parsed_fix = "next_parsed::<u16>(&mut split)?.saturating_sub(1)"
    return (
        cursor.count(parsed_fix) >= 2
        and rxvt.count(parsed_fix) >= 2
        and "buffer[4].saturating_sub(33)" in normal
        and "buffer[5].saturating_sub(33)" in normal
        and sgr.count(parsed_fix) >= 2
    )


development = json.loads(pathlib.Path(development_path).read_text())
package = json.loads(pathlib.Path(package_path).read_text())

development_crossterm, development_declared = direct_dependency(development, "crossterm")
development_source = development_crossterm.get("source") or ""
development_version = development_crossterm["version"]
if development_crossterm["name"] != fork_package:
    fail(f"development graph resolves unexpected package {development_crossterm['name']}")
if development_version != fork_version:
    fail(f"development graph resolves unexpected fork version {development_version}")
if development_source.startswith("git+https://github.com/adonm/crossterm.git?"):
    if not development_source.endswith(f"#{fork_rev}"):
        fail(f"development graph uses unexpected crossterm revision: {development_source}")
    if not parser_has_underflow_fix(development_crossterm):
        fail(f"development crossterm revision {fork_rev} does not contain the required parser fix")
elif development_source.startswith("registry+"):
    if not parser_has_underflow_fix(development_crossterm):
        fail(f"development graph resolves unfixed registry crossterm {development_version}")
    if development_declared["req"] != f"={development_version}":
        fail(f"development crossterm {development_version} is not pinned exactly")
else:
    fail(f"development graph uses unsupported crossterm source: {development_source or 'no source'}")

normalized_manifest = pathlib.Path(manifest_path).read_text()
if "[patch." in normalized_manifest:
    fail("normalized package manifest unexpectedly contains a registry patch")
if "git =" in normalized_manifest:
    fail("normalized package manifest unexpectedly retains a Git dependency")

package_crossterm, declared_crossterm = direct_dependency(package, "crossterm")
resolved_version = package_crossterm["version"]
resolved_source = package_crossterm.get("source") or ""
if package_crossterm["name"] != fork_package:
    fail(f"packaged dependency resolves unexpected package {package_crossterm['name']}")
if resolved_version != fork_version:
    fail(f"packaged dependency resolves unexpected fork version {resolved_version}")
if not resolved_source.startswith("registry+"):
    fail(f"packaged crossterm must resolve from a registry, got {resolved_source or 'no source'}")

expected_requirement = f"={resolved_version}"
if not parser_has_underflow_fix(package_crossterm):
    fail(
        "publication BLOCKED: packaged zuko resolves crossterm "
        f"{resolved_version} from crates.io, and that source does not contain the "
        "pixel-mouse/cursor underflow fix"
    )
if declared_crossterm["req"] != expected_requirement:
    fail(
        "publication BLOCKED: packaged zuko resolves fixed crossterm "
        f"{resolved_version}, but Cargo.toml requires {declared_crossterm['req']!r}; "
        f"pin the verified release exactly as {expected_requirement!r}"
    )

print(
    "crate package: publishable; packaged dependency resolution contains the "
    f"verified fix in exact registry package {fork_package} {resolved_version}"
)
PY
