#!/usr/bin/env python3
"""Validate the pinned official Flutter SDK and build-once release policy."""

from __future__ import annotations

import pathlib
import plistlib
import re
import tomllib
import xml.etree.ElementTree as ET

ROOT = pathlib.Path(__file__).resolve().parent.parent
FRAMEWORK_REVISION = "6655482ec06e547f90abf8ae7590466f4415978d"
FRAMEWORK_VERSION = "3.47.1"
SDK_BASE = "https://storage.googleapis.com/flutter_infra_release/releases/stable"
SDK_PLATFORMS = {
    "linux-x64": {
        "archive": "linux/flutter_linux_3.47.1-stable.tar.xz",
        "digest": "a1d8166c0309267cb7dc99f1424eecf08b86946ad3b50723c6f59945964aea45",
    },
    "macos-arm64": {
        "archive": "macos/flutter_macos_3.47.1-stable.zip",
        "digest": "21e06435c50be9a43ffea8abb549bd7640cd38197e7741dd780f0680afbb64ba",
    },
    "windows-x64": {
        "archive": "windows/flutter_windows_3.47.1-stable.zip",
        "digest": "4cbf94fde1f5f8d6b9fc50b2483b57cf2077f61712282c2f4cf92560168f442b",
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
    app = content("flutter/pubspec.yaml")
    # flterm and libghostty come from the fork because upstream has not
    # released the reorganized API yet (hosted 0.0.12 predates it) or the few
    # flterm patches still in review. Both must share one fork ref so they
    # cannot drift.
    fork_ref = "2a1e3e2b12882ee8a0e4c6dd39656378a0062012"
    app_refs = re.findall(r'^      ref: "?([0-9a-f]{40})"?[ \t]*$', app, re.MULTILINE)
    if app_refs != [fork_ref] * 2:
        raise SystemExit("Flutter config: flterm and libghostty refs drifted")
    if app.count("url: https://github.com/adonm/libghostty.git") != 2:
        raise SystemExit("Flutter config: flterm and libghostty must use the monorepo fork")
    for package in ["packages/flterm", "packages/libghostty"]:
        if f"path: {package}" not in app:
            raise SystemExit(f"Flutter config: missing package path {package}")
    # integration_test and ptyx must NOT live in the app pubspec: ptyx's
    # native-asset hook fails iOS builds and integration_test breaks the
    # Android release registrant. They belong to the standalone integration
    # package instead.
    if re.search(r"^  (integration_test|ptyx):", app, re.MULTILINE):
        raise SystemExit("Flutter config: integration_test and ptyx must stay in flutter/integration")

    integration = content("flutter/integration/pubspec.yaml")
    integration_refs = re.findall(
        r'^      ref: "?([0-9a-f]{40})"?[ \t]*$', integration, re.MULTILINE
    )
    ptyx_ref = "d6dd31017ff9975faa126c0c515ad540b5d3925d"
    if integration_refs != [fork_ref, fork_ref, ptyx_ref]:
        raise SystemExit("Flutter config: integration package refs drifted")
    if integration.count("url: https://github.com/adonm/libghostty.git") != 2:
        raise SystemExit("Flutter config: integration flterm and libghostty must use the monorepo fork")
    if integration.count("url: https://github.com/elias8/libghostty.git") != 1:
        raise SystemExit("Flutter config: ptyx must use upstream elias8/libghostty")
    if "integration_test:\n    sdk: flutter" not in integration:
        raise SystemExit("Flutter config: integration package must depend on integration_test")

    app_lock = content("flutter/pubspec.lock")
    app_resolved = re.findall(
        r'^      resolved-ref: "?([0-9a-f]{40})"?[ \t]*\n'
        r'      url: "?https://github\.com/adonm/libghostty\.git"?[ \t]*$',
        app_lock,
        re.MULTILINE,
    )
    if app_resolved != [fork_ref] * 2:
        raise SystemExit("Flutter config: terminal lock refs differ from pubspec")
    integration_lock = content("flutter/integration/pubspec.lock")
    integration_resolved = re.findall(
        r'^      resolved-ref: "?([0-9a-f]{40})"?[ \t]*\n'
        r'      url: "?https://github\.com/(?:adonm|elias8)/libghostty\.git"?[ \t]*$',
        integration_lock,
        re.MULTILINE,
    )
    if integration_resolved != [fork_ref, fork_ref, ptyx_ref]:
        raise SystemExit("Flutter config: integration lock refs differ from its pubspec")


def validate_sdk() -> None:
    with (ROOT / "mise.toml").open("rb") as source:
        mise = tomllib.load(source)
    flutter = mise["tools"].get("http:flutter")
    if not isinstance(flutter, dict) or flutter.get("version") != FRAMEWORK_VERSION:
        raise SystemExit("Flutter config: Mise must install the official SDK")
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
    require_text("scripts/prepare-libghostty-ios-static.py", 'version != "3.47.1"')
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
    print(f"Flutter config: official SDK {FRAMEWORK_VERSION} at {FRAMEWORK_REVISION}")


if __name__ == "__main__":
    main()
