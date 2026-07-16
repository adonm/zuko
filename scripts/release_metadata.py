#!/usr/bin/env python3
"""Validate and expose Zuko's release identity and artifact contract."""

from __future__ import annotations

import argparse
import dataclasses
import json
import pathlib
import re
import tomllib


ROOT = pathlib.Path(__file__).resolve().parent.parent
PACKAGE_ID = "dev.adonm.zuko"
BUILD_NUMBER_BASE = 1_800_000_000
BUILD_NUMBER_MAX = 2_100_000_000
CLI_TARGETS = (
    "aarch64-apple-darwin",
    "aarch64-unknown-linux-gnu",
    "x86_64-apple-darwin",
    "x86_64-unknown-linux-gnu",
)


@dataclasses.dataclass(frozen=True)
class ReleaseMetadata:
    version: str
    tag: str
    build_number: int
    package: str = PACKAGE_ID


def for_version(version: str) -> ReleaseMetadata:
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        raise ValueError(f"invalid release version: {version}")
    major, minor, patch = (int(part) for part in version.split("."))
    if minor >= 1_000 or patch >= 1_000:
        raise ValueError("release minor and patch components must be below 1000")
    build_number = BUILD_NUMBER_BASE + major * 1_000_000 + minor * 1_000 + patch
    if build_number > BUILD_NUMBER_MAX:
        raise ValueError("release version no longer fits the Google Play build-number range")
    return ReleaseMetadata(version, f"v{version}", build_number)


def load(root: pathlib.Path = ROOT) -> ReleaseMetadata:
    cargo = tomllib.loads((root / "Cargo.toml").read_text())
    version = cargo["workspace"]["package"]["version"]
    if cargo["package"].get("version") != {"workspace": True}:
        raise ValueError("the root crate must inherit workspace.package.version")
    metadata = for_version(version)

    pubspec = (root / "flutter/pubspec.yaml").read_text()
    match = re.search(
        r"^version:\s*([0-9]+\.[0-9]+\.[0-9]+)\+([0-9]+)\s*$",
        pubspec,
        re.MULTILINE,
    )
    if match is None or match.group(1) != metadata.version:
        raise ValueError(f"Flutter version must be {metadata.version}+<build number>")
    if int(match.group(2)) != metadata.build_number:
        raise ValueError(
            f"Flutter build number must be {metadata.build_number} "
            "for store upgrade continuity"
        )
    return metadata


def candidate_asset_names(metadata: ReleaseMetadata) -> set[str]:
    names = {
        f"zuko-linux-{metadata.tag}-x86_64.tar.gz",
        f"zuko-linux-{metadata.tag}-x86_64.tar.gz.sha256",
        f"zuko-android-{metadata.tag}-unsigned.apk",
        f"zuko-android-{metadata.tag}-unsigned.aab",
        f"zuko-windows-{metadata.tag}-x86_64.zip",
        f"zuko-windows-{metadata.tag}-x86_64.zip.sha256",
        "Zuko-Flutter-ios-simulator.zip",
        "Zuko-Flutter-ios-simulator.zip.sha256",
        "Zuko-Flutter-macOS.zip",
        "Zuko-Flutter-macOS.zip.sha256",
    }
    for target in CLI_TARGETS:
        names.add(f"zuko-{target}.tar.gz")
        names.add(f"zuko-{target}.tar.gz.sha256")
    return names


def release_asset_names(metadata: ReleaseMetadata) -> set[str]:
    names = candidate_asset_names(metadata)
    names.remove(f"zuko-android-{metadata.tag}-unsigned.apk")
    names.remove(f"zuko-android-{metadata.tag}-unsigned.aab")
    names.update(
        {
            "release-candidate.json",
            f"zuko-android-{metadata.tag}-signed.apk",
            f"zuko-android-{metadata.tag}-signed.apk.sha256",
            f"zuko-android-{metadata.tag}-signed.aab",
            f"zuko-android-{metadata.tag}-signed.aab.sha256",
        }
    )
    return names


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "command",
        choices=("check", "json", "build-number", "candidate-assets", "release-assets"),
    )
    args = parser.parse_args()
    try:
        metadata = load()
    except (KeyError, OSError, TypeError, ValueError, tomllib.TOMLDecodeError) as error:
        raise SystemExit(f"release metadata: {error}") from error

    if args.command == "check":
        print(f"release metadata: all package versions are {metadata.version}")
    elif args.command == "json":
        print(json.dumps(dataclasses.asdict(metadata), sort_keys=True))
    elif args.command == "build-number":
        print(metadata.build_number)
    else:
        names = (
            candidate_asset_names(metadata)
            if args.command == "candidate-assets"
            else release_asset_names(metadata)
        )
        print("\n".join(sorted(names)))


if __name__ == "__main__":
    main()
