#!/usr/bin/env python3
"""Validate the pinned Flutter beta and cross-platform rendering policy."""

from __future__ import annotations

import pathlib
import plistlib
import re
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


def validate_terminal_dependency_pin() -> None:
    pubspec = (ROOT / "flutter/pubspec.yaml").read_text(encoding="utf-8")
    refs = re.findall(
        r'^      ref: "?([0-9a-f]{40})"?[ \t]*$', pubspec, re.MULTILINE
    )
    if len(refs) != 2 or len(set(refs)) != 1:
        raise SystemExit(
            "Flutter config: flterm and libghostty must share one immutable Git ref"
        )
    if pubspec.count("url: https://github.com/adonm/libghostty.git") != 2:
        raise SystemExit(
            "Flutter config: flterm and libghostty must use the monorepo fork"
        )
    for package in ["packages/flterm", "packages/libghostty"]:
        if f"path: {package}" not in pubspec:
            raise SystemExit(f"Flutter config: missing monorepo package path {package}")

    lock = (ROOT / "flutter/pubspec.lock").read_text(encoding="utf-8")
    resolved = re.findall(
        r'^      resolved-ref: "?([0-9a-f]{40})"?[ \t]*\n'
        r'      url: "?https://github\.com/adonm/libghostty\.git"?[ \t]*$',
        lock,
        re.MULTILINE,
    )
    if resolved != refs:
        raise SystemExit(
            "Flutter config: terminal dependency lock refs must match pubspec refs"
        )


def main() -> None:
    validate_terminal_dependency_pin()
    with (ROOT / "mise.toml").open("rb") as source:
        mise = tomllib.load(source)
    flutter = mise["tools"]["http:flutter"]
    if flutter["version"] != "3.47.0-0.1.pre":
        raise SystemExit("Flutter config: mise must pin Flutter 3.47.0-0.1.pre")
    expected_archives = {
        "linux-x64": (
            "beta/linux/flutter_linux_3.47.0-0.1.pre-beta.tar.xz",
            "sha256:2cf72c1bc8571f406dfb7a0b3d8128abd4f43d2c335d2ed76249fe492c0d7c34",
        ),
        "macos-x64": (
            "beta/macos/flutter_macos_3.47.0-0.1.pre-beta.zip",
            "sha256:60b11ec8b5540de339c2aeaf19814d86f1232017bf82d3dc06f9cdad68092c97",
        ),
        "macos-arm64": (
            "beta/macos/flutter_macos_arm64_3.47.0-0.1.pre-beta.zip",
            "sha256:688988016fa2f316963e12d993b5006541c2cdadfad3b9d9723da6ffaba16cd3",
        ),
        "windows-x64": (
            "beta/windows/flutter_windows_3.47.0-0.1.pre-beta.zip",
            "sha256:ec2d657406924e87bc84af2f3f38b45efba3a27669e59aa269096deb29e53fef",
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
    if revision != "bd1e75d918605c91b411e8789fb911e6c9a84534":
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
    require_text(
        "flutter/windows/runner/main.cpp",
        "project.set_impeller_switch(flutter::ImpellerSwitch::Enabled);",
    )
    require_text("flutter/web/flutter_bootstrap.js", "renderer: 'skwasm'")
    forbid_text("flutter/web/flutter_bootstrap.js", "enableWimp")
    forbid_text("flutter/lib/main.dart", "mobile_scanner")
    require_text("flutter/pubspec.yaml", "mobile_scanner: 7.2.0")
    forbid_text("flutter/web/index.html", "unpkg.com")
    require_text("scripts/build-web.sh", "prepare-web-plugins.py")
    require_text("scripts/prepare-web-plugins.py", '"mobile_scanner"')
    require_text("scripts/prepare-web-plugins.py", '"--restore"')
    if (ROOT / "flutter/web/vendor/zxing").exists():
        raise SystemExit("Flutter config: obsolete vendored ZXing runtime remains")

    containerfile = "containers/flutter-ci.Containerfile"
    for value in [
        "eclipse-temurin@sha256:89dc1a6e09920ea26b2ede6fddfcac1a7508b50159a6d04c918a46132953aab6",
        "flatpak-github-actions@sha256:bc5938197c339664f893828925061b08486e7f355c3e91eefcaae7293d3cfd6b",
        "ANDROID_COMMAND_LINE_TOOLS_VERSION=14742923",
        "ANDROID_COMMAND_LINE_TOOLS_SHA256=04453066b540409d975c676d781da1477479dde3761310f1a7eb92a1dfb15af7",
        "'platforms;android-34'",
        "'platforms;android-35'",
        "'platforms;android-36'",
        "'build-tools;36.0.0'",
        "'cmake;3.22.1'",
        "'ndk;29.0.14206865'",
        "flutter precache --android --linux --web",
    ]:
        require_text(containerfile, value)
    require_text("Justfile", "flutter-linux-ci: flutter-ci-check flutter-linux-builds")
    require_text("Justfile", "flutter-app-check: flutter-get")
    require_text("scripts/container-flutter.sh", "mise exec -- just flutter-linux-ci")
    require_text("scripts/container-flutter.sh", "localhost/zuko-flutter-ci:2026.07")
    require_text("scripts/container-flutter.sh", "zuko-flutter-dart-tool")
    require_text("scripts/container-flutter.sh", '"$root:/source:ro"')
    forbid_text("scripts/container-flutter.sh", '"$root:/workspace"')
    forbid_text(containerfile, "'platform-tools'")
    require_text("scripts/container-flutter.sh", "mode == links")
    require_text(containerfile, "install-android-platform-tools")
    require_text("scripts/install-android-platform-tools.sh", "VERSION=37.0.0")
    require_text(
        "scripts/install-android-platform-tools.sh",
        "198ae156ab285fa555987219af237b31102fefe8b9d2bc274708a8d4f2865a07",
    )
    require_text("flutter/android/app/build.gradle.kts", 'ndkVersion = "29.0.14206865"')
    require_text("scripts/patch-flutter-plugins.py", 'ndkVersion "29.0.14206865"')
    require_text(
        "scripts/patch-flutter-plugins.py",
        "Zuko does not use desktop JNI",
    )
    require_text("Justfile", "build-flutter-android: patch-flutter-plugins")
    require_text("Justfile", "cargo test --locked")
    require_text(
        "scripts/build-flatpark-test-bundle.sh",
        "localhost/zuko-flutter-ci:2026.07",
    )
    require_text("codemagic.yaml", "mise exec -- just flutter-ci-check")
    require_text("codemagic.yaml", "mise exec -- just build-web")
    require_text("codemagic.yaml", "mise exec -- just build-flutter-android-debug")
    require_text("codemagic.yaml", "with_flutter_gtk4_sdk.sh")
    require_text("codemagic.yaml", "scripts/prepare-web-plugins.py")
    require_text(".github/workflows/docs.yml", '"scripts/prepare-web-plugins.py"')
    require_text(".github/workflows/build.yml", "Flutter Linux GTK4 release")
    require_text(
        ".github/workflows/build.yml", "scripts/install_flutter_gtk4_sdk.py"
    )
    require_text(
        "scripts/install_flutter_gtk4_sdk.py",
        "328b829d35a3a5d7a00e0c2f0e97eb8cc0d97188",
    )
    require_text(
        "scripts/install_flutter_gtk4_sdk.py",
        "libflutter_linux_gtk4.so",
    )
    require_text(
        "scripts/install_flutter_gtk4_sdk.py",
        "github.com/adonm/flutter-dev/releases/download",
    )
    require_text(
        "scripts/install_flutter_gtk4_sdk.py",
        "61cafba174d24e2c4f73e416cb98c0b33a0ca751b99bf0d9c42cf2c4f1f44add",
    )
    require_text(
        "scripts/with_flutter_gtk4_sdk.sh",
        "469f2b34de41cab5f677ba84d6e9099c0e682d1e",
    )
    forbid_text("scripts/install_flutter_gtk4_sdk.py", "__CI_LIBRARY_SHA256__")
    require_text("scripts/package-linux-release.sh", "debug sections remain")
    require_text(
        "scripts/package-linux-release.sh",
        "GTK4 engine does not match its immutable release",
    )
    require_text(
        "scripts/package-linux-release.sh", "release bundle contains a JIT artifact"
    )
    forbid_text("scripts/container-flutter.sh", "--privileged")
    for obsolete in [
        "containers/flutter-linux.Containerfile",
        "containers/flutter-linux.ignore",
    ]:
        if (ROOT / obsolete).exists():
            raise SystemExit(f"Flutter config: obsolete container definition remains: {obsolete}")

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

    print(f"Flutter config: rendering policy uses beta revision {revision}")


if __name__ == "__main__":
    main()
