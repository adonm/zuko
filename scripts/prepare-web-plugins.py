#!/usr/bin/env python3
"""Temporarily hide native-only web plugin declarations from Flutter."""

from __future__ import annotations

import json
import pathlib
import shutil
import sys
import urllib.parse
import urllib.request


NATIVE_ONLY = {"device_info_plus", "mobile_scanner"}
WEB_PLUGIN_BLOCKS = {
    "mobile_scanner": """      web:
        pluginClass: MobileScannerWeb
        fileName: src/web/mobile_scanner_web.dart
""",
}
ROOT = pathlib.Path(__file__).resolve().parent.parent
OVERLAY_ROOT = ROOT / "target/web-plugin-overlays"


def restore(state_path: pathlib.Path) -> None:
    if not state_path.is_file() or state_path.stat().st_size == 0:
        return
    state = json.loads(state_path.read_text())
    client = pathlib.Path(state["client"])
    if not client.is_relative_to(ROOT):
        raise SystemExit(f"invalid Flutter client in web plugin state: {client}")
    (client / ".flutter-plugins-dependencies").write_text(state["plugin_metadata"])
    (client / ".dart_tool/package_config.json").write_text(state["package_config"])
    shutil.rmtree(OVERLAY_ROOT, ignore_errors=True)
    state_path.unlink(missing_ok=True)


def package_root(entry: dict[str, object], config_path: pathlib.Path) -> pathlib.Path:
    root_uri = entry.get("rootUri")
    if not isinstance(root_uri, str):
        raise SystemExit(f"invalid package root in {config_path}")
    parsed = urllib.parse.urlparse(root_uri)
    if parsed.scheme == "file":
        return pathlib.Path(urllib.request.url2pathname(parsed.path))
    if parsed.scheme:
        raise SystemExit(f"unsupported package root URI in {config_path}: {root_uri}")
    return (config_path.parent / urllib.request.url2pathname(root_uri)).resolve()


def create_overlay(name: str, source: pathlib.Path) -> pathlib.Path:
    block = WEB_PLUGIN_BLOCKS.get(name)
    if block is None:
        raise SystemExit(f"missing web plugin override for {name}")
    pubspec = (source / "pubspec.yaml").read_text()
    if block not in pubspec:
        raise SystemExit(f"unsupported {name} web plugin declaration: {source}")

    destination = OVERLAY_ROOT / name
    destination.mkdir(parents=True)
    for child in source.iterdir():
        target = destination / child.name
        if child.name == "pubspec.yaml":
            target.write_text(pubspec.replace(block, "", 1))
        else:
            target.symlink_to(child, target_is_directory=child.is_dir())
    return destination


def main() -> None:
    if len(sys.argv) == 3 and sys.argv[1] == "--restore":
        restore(pathlib.Path(sys.argv[2]))
        return
    if len(sys.argv) != 3:
        raise SystemExit(
            "usage: prepare-web-plugins.py FLUTTER_CLIENT STATE_FILE\n"
            "       prepare-web-plugins.py --restore STATE_FILE"
        )

    client = pathlib.Path(sys.argv[1]).resolve()
    state_path = pathlib.Path(sys.argv[2])
    if not client.is_relative_to(ROOT):
        raise SystemExit(f"Flutter client must be inside {ROOT}")
    metadata_path = client / ".flutter-plugins-dependencies"
    config_path = client / ".dart_tool/package_config.json"
    metadata_text = metadata_path.read_text()
    config_text = config_path.read_text()
    data = json.loads(metadata_text)
    plugins = data.get("plugins")
    if not isinstance(plugins, dict) or not isinstance(plugins.get("web"), list):
        raise SystemExit(f"invalid Flutter plugin metadata: {metadata_path}")
    removed = {
        plugin.get("name")
        for plugin in plugins["web"]
        if plugin.get("name") in NATIVE_ONLY
    }
    plugins["web"] = [
        plugin
        for plugin in plugins["web"]
        if plugin.get("name") not in NATIVE_ONLY
    ]
    remaining = {plugin.get("name") for plugin in plugins["web"]}
    unexpected = remaining & NATIVE_ONLY
    if unexpected:
        raise SystemExit(f"native-only plugins remain registered for web: {unexpected}")

    package_config = json.loads(config_text)
    packages = package_config.get("packages")
    if not isinstance(packages, list):
        raise SystemExit(f"invalid Flutter package config: {config_path}")
    entries = {
        entry.get("name"): entry
        for entry in packages
        if isinstance(entry, dict) and isinstance(entry.get("name"), str)
    }
    missing = removed - entries.keys()
    if missing:
        raise SystemExit(f"native-only packages are missing from {config_path}: {missing}")

    shutil.rmtree(OVERLAY_ROOT, ignore_errors=True)
    state_path.write_text(
        json.dumps(
            {
                "client": str(client),
                "plugin_metadata": metadata_text,
                "package_config": config_text,
            }
        )
    )
    try:
        for name in sorted(removed):
            entry = entries[name]
            overlay = create_overlay(name, package_root(entry, config_path))
            entry["rootUri"] = overlay.as_uri()
        metadata_path.write_text(json.dumps(data, separators=(",", ":")))
        config_path.write_text(json.dumps(package_config, separators=(",", ":")))
    except BaseException:
        restore(state_path)
        raise


if __name__ == "__main__":
    main()
