#!/usr/bin/env python3
"""Validate the pinned Flutter beta and cross-platform Impeller policy."""

from __future__ import annotations

import pathlib
import plistlib
import tomllib
import xml.etree.ElementTree as ET


ROOT = pathlib.Path(__file__).resolve().parent.parent


def require_text(path: str, value: str) -> None:
    content = (ROOT / path).read_text(encoding="utf-8")
    if value not in content:
        raise SystemExit(f"Flutter config: {path} must contain {value!r}")


def forbid_text(path: str, value: str) -> None:
    content = (ROOT / path).read_text(encoding="utf-8")
    if value in content:
        raise SystemExit(f"Flutter config: {path} must not contain {value!r}")


def main() -> None:
    with (ROOT / "mise.toml").open("rb") as source:
        mise = tomllib.load(source)
    flutter = mise["tools"]["http:flutter"]
    if flutter["version"] != "3.46.0-0.3.pre":
        raise SystemExit("Flutter config: mise must pin Flutter 3.46.0-0.3.pre")
    expected_archives = {
        "linux-x64": (
            "beta/linux/flutter_linux_3.46.0-0.3.pre-beta.tar.xz",
            "sha256:931c30fde3cc9b4eae2bbae750914c1ec60bfea4d46531e37f25caaa1a47d2da",
        ),
        "macos-x64": (
            "beta/macos/flutter_macos_3.46.0-0.3.pre-beta.zip",
            "sha256:788df8e91c57880b0559ceeb8e09021bbc841bd2e03f3e8d1a149cd127735f86",
        ),
        "macos-arm64": (
            "beta/macos/flutter_macos_arm64_3.46.0-0.3.pre-beta.zip",
            "sha256:5191b391f00a8e3756c873e27326af01b62c40c152d8cfd4b490b9ed8a3530f0",
        ),
        "windows-x64": (
            "beta/windows/flutter_windows_3.46.0-0.3.pre-beta.zip",
            "sha256:11e5b04a443f0a764ddcf36b53dca811f65f859b6074f7e4a3e8591075d572ed",
        ),
    }
    platforms = flutter["platforms"]
    if set(platforms) != set(expected_archives):
        raise SystemExit("Flutter config: Flutter archive platforms must match supported clients")
    for platform, (archive, checksum) in expected_archives.items():
        entry = platforms.get(platform, {})
        if not entry.get("url", "").endswith(archive) or entry.get("checksum") != checksum:
            raise SystemExit(f"Flutter config: invalid {platform} beta archive pin")
    revision = mise["env"].get("ZUKO_FLUTTER_REVISION")
    if revision != "677d472756f83c14371dd8cc624387065f3d32a7":
        raise SystemExit("Flutter config: mise must pin the published beta revision")

    android = ET.parse(ROOT / "flutter/android/app/src/main/AndroidManifest.xml").getroot()
    namespace = "{http://schemas.android.com/apk/res/android}"
    impeller = next(
        (
            item
            for item in android.find("application").findall("meta-data")
            if item.attrib.get(f"{namespace}name")
            == "io.flutter.embedding.android.EnableImpeller"
        ),
        None,
    )
    if impeller is None or impeller.attrib.get(f"{namespace}value") != "true":
        raise SystemExit("Flutter config: Android must explicitly enable Impeller")

    with (ROOT / "flutter/macos/Runner/Info.plist").open("rb") as source:
        if plistlib.load(source).get("FLTEnableImpeller") is not True:
            raise SystemExit("Flutter config: macOS must explicitly enable Impeller")

    require_text(
        "flutter/linux/runner/my_application.cc",
        "fl_dart_project_set_enable_impeller(project, TRUE);",
    )
    # This published beta predates the Windows DartProject Impeller API. Keep
    # the runner compatible with its headers; later SDKs can use the explicit
    # switch after the SDK pin and this check are updated together.
    forbid_text("flutter/windows/runner/main.cpp", "set_impeller_switch")
    require_text("flutter/web/flutter_bootstrap.js", "enableWimp: true")
    require_text("flutter/web/flutter_bootstrap.js", "renderer: 'skwasm'")

    for path, value in [
        ("codemagic.yaml", "flutter-linux-ci:"),
        ("codemagic.yaml", "flutter-linux-android-release:"),
        ("codemagic.yaml", "flutter-windows-ci:"),
        ("codemagic.yaml", "flutter-windows-release:"),
        ("codemagic.yaml", "package-codemagic-android-unsigned"),
        (".github/workflows/release.yml", "collect-codemagic-release.py"),
        (".github/workflows/release.yml", "publish-testflight-release.py"),
        (".github/workflows/release.yml", "sign-codemagic-android-release.sh"),
        ("scripts/collect-codemagic-release.py", "zuko-android-{tag}-unsigned.apk"),
        ("scripts/package-linux-release.sh", "zuko-linux-$TAG-x86_64.tar.gz"),
        ("scripts/collect-codemagic-release.py", "zuko-linux-{tag}-x86_64.tar.gz"),
        ("scripts/publish-github-release.sh", "zuko-linux-$tag-x86_64.tar.gz"),
    ]:
        require_text(path, value)
    forbid_text("scripts/package-linux-release.sh", "aarch64")
    forbid_text("codemagic.yaml", "flutter-linux-aarch64")
    forbid_text(".github/workflows/release.yml", "linux-arm-build")
    for removed in [
        "scripts/build-flutter-linux-release.sh",
        "scripts/build-flatpak-repository.sh",
        "scripts/install-flatpak-sysroot.sh",
        "scripts/package-flatpak.sh",
        "scripts/prepare-flatpak-release.py",
        "scripts/patch-flutter-linux-cross.py",
        "scripts/validate-flatpak.sh",
    ]:
        if (ROOT / removed).exists():
            raise SystemExit(f"Flutter config: obsolete Linux packaging helper still exists: {removed}")

    print(f"Flutter config: Impeller policy uses beta revision {revision}")


if __name__ == "__main__":
    main()
