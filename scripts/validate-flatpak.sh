#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"

for command in python3 desktop-file-validate appstreamcli; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "flatpak validation: required command not found: $command" >&2
    exit 1
  }
done

python3 - <<'PY'
import configparser
import json
import pathlib
import re
import struct
import tomllib
import xml.etree.ElementTree as ET

root = pathlib.Path.cwd()
app_id = "dev.adonm.zuko"
manifest = json.loads((root / f"flatpak/{app_id}.json").read_text())

assert manifest["app-id"] == app_id
assert manifest["runtime"] == "org.freedesktop.Platform"
assert manifest["sdk"] == "org.freedesktop.Sdk"
assert manifest["runtime-version"] == "25.08"
assert manifest["command"] == "zuko"
required_permissions = {
    "--share=ipc",
    "--share=network",
    "--socket=wayland",
    "--device=dri",
    "--talk-name=org.freedesktop.secrets",
}
assert set(manifest["finish-args"]) == required_permissions
assert len(manifest["modules"]) == 1
sources = manifest["modules"][0]["sources"]
assert sources[0] == {
    "type": "dir",
    "path": "../build/flatpak/staging/bundle",
    "dest": "bundle",
}
assert all(source["type"] in {"dir", "file"} for source in sources)

cargo = tomllib.loads((root / "Cargo.toml").read_text())
version = cargo["workspace"]["package"]["version"]
pubspec = (root / "flutter/pubspec.yaml").read_text()
match = re.search(r"^version:\s*([0-9]+\.[0-9]+\.[0-9]+)\+", pubspec, re.MULTILINE)
assert match and match.group(1) == version

metainfo = ET.parse(root / f"flatpak/{app_id}.metainfo.xml").getroot()
assert metainfo.findtext("id") == app_id
assert metainfo.find("launchable").text == f"{app_id}.desktop"
releases = metainfo.find("releases")
assert releases is not None and releases[0].attrib["version"] == version

desktop = configparser.ConfigParser(interpolation=None, strict=True)
desktop.optionxform = str
desktop.read(root / f"flatpak/{app_id}.desktop")
entry = desktop["Desktop Entry"]
assert entry["Exec"] == "zuko"
assert entry["Icon"] == app_id

icon = ET.parse(root / "zuko-logo.svg").getroot()
assert icon.tag.endswith("svg")
with (root / "flutter/assets/zuko-logo.png").open("rb") as png:
    assert png.read(8) == b"\x89PNG\r\n\x1a\n"
    length, chunk = struct.unpack(">I4s", png.read(8))
    assert length == 13 and chunk == b"IHDR"
    width, height = struct.unpack(">II", png.read(8))
    assert (width, height) == (256, 256)
print(f"flatpak validation: {app_id} metadata matches release {version}")
PY

desktop-file-validate "flatpak/dev.adonm.zuko.desktop"
appstreamcli validate --strict --no-net "flatpak/dev.adonm.zuko.metainfo.xml"
