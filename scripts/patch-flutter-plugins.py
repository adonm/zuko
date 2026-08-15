#!/usr/bin/env python3
"""Patch known desktop issues in pinned Flutter plugins."""

from __future__ import annotations

import json
import pathlib
import sys
import urllib.parse
import urllib.request


def package_root(flutter_root: pathlib.Path, name: str) -> pathlib.Path:
    config_path = flutter_root / ".dart_tool/package_config.json"
    config = json.loads(config_path.read_text())
    package = next(
        (entry for entry in config["packages"] if entry["name"] == name),
        None,
    )
    if package is None:
        raise SystemExit(f"{name} is missing from Flutter package_config.json")

    root_uri = package["rootUri"]
    parsed = urllib.parse.urlparse(root_uri)
    if parsed.scheme == "file":
        return pathlib.Path(urllib.request.url2pathname(parsed.path))
    return (config_path.parent / urllib.request.url2pathname(root_uri)).resolve()


def require_version(root: pathlib.Path, name: str, version: str) -> None:
    if f"version: {version}" not in (root / "pubspec.yaml").read_text():
        raise SystemExit(f"remove the {name} {version} workaround before upgrading")


def patch_file(
    path: pathlib.Path,
    replacements: list[tuple[str, str]],
) -> None:
    contents = path.read_text()
    changed = False
    for old, new in replacements:
        if new in contents:
            continue
        if old not in contents:
            raise SystemExit(f"unsupported pinned plugin layout: {path}")
        contents = contents.replace(old, new, 1)
        changed = True
    if changed:
        path.write_text(contents)
        print(f"patched {path}")


def patch_jni(flutter_root: pathlib.Path) -> None:
    root = package_root(flutter_root, "jni")
    require_version(root, "jni", "1.0.3")
    patch_file(
        root / "android/build.gradle",
        [("ndkVersion flutter.ndkVersion", 'ndkVersion "29.0.14206865"')],
    )
    patch_file(
        root / "src/CMakeLists.txt",
        [
            (
                """    else()
        # Flutter Plugin Build: Try to find JNI, but don't fail if missing
        find_package(JNI COMPONENTS JVM)
        if (JNI_FOUND)
            set(JNI_AVAILABLE TRUE)
        endif()
    endif()
""",
                """    else()
        # Zuko does not use desktop JNI; only build it when explicitly required.
    endif()
""",
            ),
        ],
    )


def main() -> None:
    flutter_root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "flutter").resolve()
    patch_jni(flutter_root)


if __name__ == "__main__":
    main()
