#!/usr/bin/env python3
"""Validate the pinned official Flutter beta SDK and build-once release policy."""

from __future__ import annotations

import pathlib
import plistlib
import re
import tomllib
import xml.etree.ElementTree as ET

ROOT = pathlib.Path(__file__).resolve().parent.parent
FRAMEWORK_REVISION = "ceb9a865625239789d86b31be0a8d04e4c5a5084"
FRAMEWORK_VERSION = "3.48.0-0.1.pre"
SDK_BASE = "https://storage.googleapis.com/flutter_infra_release/releases/beta"
SDK_PLATFORMS = {
    "linux-x64": {
        "archive": "linux/flutter_linux_3.48.0-0.1.pre-beta.tar.xz",
        "digest": "9a21104985070dbddf09112b82d2e54991b28020fea91dd255ef14e8c717082e",
    },
    "macos-arm64": {
        "archive": "macos/flutter_macos_3.48.0-0.1.pre-beta.zip",
        "digest": "5cbedc2adcc06b3e6d9f674b68b0735cca369c9e4ca4dbb982a6d244d958da67",
    },
    "windows-x64": {
        "archive": "windows/flutter_windows_3.48.0-0.1.pre-beta.zip",
        "digest": "ddbf615571184c007d0754b02982e4e5e12d708125dd3810c40821fdd2296692",
    },
}


def content(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def require_text(path: str, value: str) -> None:
    if value not in content(path):
        raise SystemExit(f"Flutter config: {path} must contain {value!r}")


def forbid_text(path: str, value: str) -> None:
    if value in content(path):
        raise SystemExit(f"Flutter config: {path} must not contain {value!r}")


def validate_terminal_dependency_pin() -> None:
    pubspec = content("flutter/pubspec.yaml")
    refs = re.findall(r'^      ref: "?([0-9a-f]{40})"?[ \t]*$', pubspec, re.MULTILINE)
    if len(refs) != 2 or len(set(refs)) != 1:
        raise SystemExit("Flutter config: terminal packages must share one Git ref")
    if pubspec.count("url: https://github.com/adonm/libghostty.git") != 2:
        raise SystemExit("Flutter config: terminal packages must use the monorepo fork")
    for package in ["packages/flterm", "packages/libghostty"]:
        if f"path: {package}" not in pubspec:
            raise SystemExit(f"Flutter config: missing package path {package}")
    lock = content("flutter/pubspec.lock")
    resolved = re.findall(
        r'^      resolved-ref: "?([0-9a-f]{40})"?[ \t]*\n'
        r'      url: "?https://github\.com/adonm/libghostty\.git"?[ \t]*$',
        lock,
        re.MULTILINE,
    )
    if resolved != refs:
        raise SystemExit("Flutter config: terminal lock refs differ from pubspec")


def validate_sdk() -> None:
    with (ROOT / "mise.toml").open("rb") as source:
        mise = tomllib.load(source)
    flutter = mise["tools"].get("http:flutter")
    if not isinstance(flutter, dict) or flutter.get("version") != FRAMEWORK_VERSION:
        raise SystemExit("Flutter config: Mise must install the official beta SDK")
    platforms = flutter.get("platforms")
    if not isinstance(platforms, dict) or set(platforms) != set(SDK_PLATFORMS):
        raise SystemExit("Flutter config: Mise SDK platforms are incomplete")
    for name, entry in SDK_PLATFORMS.items():
        if not re.fullmatch(r"[0-9a-f]{64}", entry["digest"]):
            raise SystemExit(f"Flutter config: unresolved SDK checksum for {name}")
        expected = {
            "url": f"{SDK_BASE}/{entry['archive']}",
            "checksum": f"sha256:{entry['digest']}",
        }
        if platforms.get(name) != expected:
            raise SystemExit(f"Flutter config: invalid Mise SDK pin for {name}")
    environment = mise["env"]
    if "_" in environment:
        raise SystemExit("Flutter config: repository SDK PATH override must be removed")


def validate_rendering() -> None:
    android = ET.parse(ROOT / "flutter/android/app/src/main/AndroidManifest.xml").getroot()
    namespace = "{http://schemas.android.com/apk/res/android}"
    application = android.find("application")
    impeller = next(
        (
            item
            for item in application.findall("meta-data")
            if item.attrib.get(f"{namespace}name")
            == "io.flutter.embedding.android.EnableImpeller"
        ),
        None,
    )
    if impeller is None or impeller.attrib.get(f"{namespace}value") != "true":
        raise SystemExit("Flutter config: Android must enable Impeller")
    with (ROOT / "flutter/macos/Runner/Info.plist").open("rb") as source:
        if plistlib.load(source).get("FLTEnableImpeller") is not True:
            raise SystemExit("Flutter config: macOS must enable Impeller")
    require_text(
        "flutter/linux/runner/my_application.cc",
        "fl_dart_project_set_enable_impeller(project, TRUE);",
    )
    require_text(
        "flutter/windows/runner/main.cpp",
        "project.set_impeller_switch(flutter::ImpellerSwitch::Enabled);",
    )
    require_text("flutter/web/flutter_bootstrap.js", "renderer: 'skwasm'")


def validate_automation() -> None:
    containerfile = "containers/flutter-ci.Containerfile"
    for value in [
        "ubuntu@sha256:52df9b1ee71626e0088f7d400d5c6b5f7bb916f8f0c82b474289a4ece6cf3faf",
        "ANDROID_COMMAND_LINE_TOOLS_VERSION=14742923",
        "ANDROID_COMMAND_LINE_TOOLS_SHA256=04453066b540409d975c676d781da1477479dde3761310f1a7eb92a1dfb15af7",
        "libgtk-3-dev",
        "mise install",
        "mise exec -- flutter --version",
        "'platforms;android-34'",
        "'platforms;android-35'",
        "'platforms;android-36'",
        "'build-tools;36.0.0'",
        "'cmake;3.22.1'",
        "'ndk;29.0.14206865'",
    ]:
        require_text(containerfile, value)
    for forbidden in ["flatpak-github-actions", "GNOME_SDK", "install_flutter_sdk"]:
        forbid_text(containerfile, forbidden)

    require_text("Justfile", "setup-flutter:")
    require_text("Justfile", "mise install http:flutter")
    forbid_text("Justfile", "install-freedesktop-llvm")
    require_text("scripts/install-mise-codemagic.sh", "install rust zig just 'http:flutter'")
    require_text(".github/workflows/build.yml", "Assemble build-once release candidate")
    require_text(".github/workflows/build.yml", 'MISE_AUTO_INSTALL: "0"')
    require_text(".github/workflows/build.yml", "libc6-dev-arm64-cross")
    require_text(".github/workflows/build.yml", "timeout 30s dbus-run-session")
    require_text(".github/workflows/build.yml", "zuko-release-candidate-${{ github.sha }}")
    require_text(".github/workflows/build.yml", "Flutter Windows candidate")
    require_text(".github/workflows/build.yml", "Flutter iOS Simulator candidate")
    require_text(".github/workflows/build.yml", "Flutter macOS candidate")
    require_text(".github/workflows/build.yml", "mise exec -- just flutter-ci-check")
    require_text(".github/workflows/ci.yml", "Compile web client")
    require_text(".github/workflows/release.yml", "environment: release")
    require_text(".github/workflows/release.yml", "release_candidate.py verify")
    require_text(".github/workflows/release.yml", "sign-android-release.sh")
    require_text(".github/workflows/release.yml", "publish-testflight.yml")
    require_text(".github/workflows/release.yml", "publish-appetize.yml")
    require_text(".github/workflows/publish-flutter-android.yml", "Download and validate exact GitHub Release AAB")
    require_text(".github/workflows/publish-flutter-windows.yml", "Verify approved draft is still current")
    require_text("scripts/release.sh", "gh workflow run release.yml")
    require_text("scripts/release-context.sh", "release_metadata.py build-number")
    require_text("flutter/windows/store/Package.ps1", "Join-Path $PSScriptRoot '../../..'")
    require_text("flutter/windows/store/Package.ps1", "$expectedFlutterBuild = 1800000000 +")
    require_text("flutter/windows/store/Test-Package.ps1", "$flutterBuild = 1800000000 +")
    require_text("scripts/package-linux-release.sh", "debug sections remain")
    require_text("scripts/package-linux-release.sh", "release bundle contains a JIT artifact")
    require_text("scripts/package-linux-release.sh", "engine does not link the stock GTK3 embedder")
    require_text("scripts/prepare-libghostty-ios-static.py", 'version != "3.48.0-0.1.pre"')
    require_text("scripts/install-android-platform-tools.sh", "VERSION=37.0.0")
    require_text(
        "scripts/install-android-platform-tools.sh",
        "198ae156ab285fa555987219af237b31102fefe8b9d2bc274708a8d4f2865a07",
    )
    require_text("flutter/android/app/build.gradle.kts", 'ndkVersion = "29.0.14206865"')
    require_text("scripts/patch-flutter-plugins.py", 'ndkVersion "29.0.14206865"')
    require_text("scripts/build-web.sh", "prepare-web-plugins.py")
    require_text("scripts/prepare-web-plugins.py", '"mobile_scanner"')
    require_text("scripts/container-flutter.sh", "zuko-flutter-ci:2026.07-mise-sdk")
    require_text("scripts/build-flatpark-test-bundle.sh", "zuko-flatpak-test:2026.07")
    require_text(
        "containers/flatpak-test.Containerfile",
        "flatpak-github-actions@sha256:bc5938197c339664f893828925061b08486e7f355c3e91eefcaae7293d3cfd6b",
    )
    forbid_text("scripts/container-flutter.sh", "--privileged")

    workflows = set(re.findall(r"^  ([a-z][a-z0-9-]+):$", content("codemagic.yaml"), re.MULTILINE))
    expected = {
        "ios-testflight-release",
        "mobile-appetize-release",
    }
    if workflows != expected:
        raise SystemExit(f"Flutter config: unexpected Codemagic workflows: {workflows}")
    require_text("codemagic.yaml", "instance_type: linux_x2")
    require_text("codemagic.yaml", 'MISE_AUTO_INSTALL: "0"')
    require_text("codemagic.yaml", "Build signed Flutter IPA")
    require_text("codemagic.yaml", "Download exact release previews")
    require_text("codemagic.yaml", "sh scripts/upload-appetize.sh android")
    require_text("codemagic.yaml", "APPETIZE_RELEASE_SHA")
    for obsolete in [
        "flutter-apple-ci:",
        "flutter-linux-ci:",
        "flutter-linux-android-release:",
        "flutter-windows-ci:",
        "flutter-windows-release:",
        "ios-testflight-artifact-recovery:",
    ]:
        forbid_text("codemagic.yaml", obsolete)

    for removed in [
        "scripts/check-codemagic-release-candidate.py",
        "scripts/collect-codemagic-release.py",
        "scripts/install_flutter_sdk.py",
        "scripts/install-freedesktop-llvm.sh",
        "scripts/install-mise-codemagic.ps1",
        "scripts/prepare-android-store-aab.sh",
        "scripts/prepare_ios_candidate.py",
        "scripts/package-codemagic-android-unsigned.sh",
        "scripts/select-codemagic-ios-artifact.py",
        "scripts/sign-codemagic-android-release.sh",
    ]:
        if (ROOT / removed).exists():
            raise SystemExit(f"Flutter config: obsolete automation remains: {removed}")


def main() -> None:
    validate_terminal_dependency_pin()
    validate_sdk()
    validate_rendering()
    validate_automation()
    print(f"Flutter config: official beta SDK {FRAMEWORK_VERSION} at {FRAMEWORK_REVISION}")


if __name__ == "__main__":
    main()
