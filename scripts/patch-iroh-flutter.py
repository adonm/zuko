#!/usr/bin/env python3
"""Patch iroh_flutter 1.0.1's invalid desktop CMake bundle paths."""

from __future__ import annotations

import json
import pathlib
import sys
import urllib.parse
import urllib.request


def package_root(flutter_root: pathlib.Path) -> pathlib.Path:
    config_path = flutter_root / ".dart_tool/package_config.json"
    config = json.loads(config_path.read_text())
    package = next(
        (entry for entry in config["packages"] if entry["name"] == "iroh_flutter"),
        None,
    )
    if package is None:
        raise SystemExit("iroh_flutter is missing from Flutter package_config.json")

    root_uri = package["rootUri"]
    parsed = urllib.parse.urlparse(root_uri)
    if parsed.scheme == "file":
        return pathlib.Path(urllib.request.url2pathname(parsed.path))
    return (config_path.parent / urllib.request.url2pathname(root_uri)).resolve()


def patch_file(path: pathlib.Path, library_name: str) -> None:
    old = f'"$<TARGET_FILE_DIR:${{PLUGIN_NAME}}>/{library_name}"'
    new = '"${${PLUGIN_NAME}_cargokit_lib}"'
    contents = path.read_text()
    if new in contents:
        return
    if old not in contents:
        raise SystemExit(f"unsupported iroh_flutter CMake layout: {path}")
    path.write_text(contents.replace(old, new))
    print(f"patched {path}")


def main() -> None:
    flutter_root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "flutter").resolve()
    root = package_root(flutter_root)
    if "version: 1.0.1" not in (root / "pubspec.yaml").read_text():
        raise SystemExit("remove the iroh_flutter 1.0.1 workaround before upgrading")
    patch_file(root / "linux/CMakeLists.txt", "libirohdart_ffi.so")
    patch_file(root / "windows/CMakeLists.txt", "irohdart_ffi.dll")


if __name__ == "__main__":
    main()
