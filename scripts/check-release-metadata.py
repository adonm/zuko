#!/usr/bin/env python3
"""Fail when release-facing package versions drift from the workspace version."""

from __future__ import annotations

import pathlib
import re
import sys
import tomllib


ROOT = pathlib.Path(__file__).resolve().parent.parent


def fail(message: str) -> None:
    print(f"release metadata: {message}", file=sys.stderr)
    raise SystemExit(1)


def main() -> None:
    cargo = tomllib.loads((ROOT / "Cargo.toml").read_text())
    version = cargo["workspace"]["package"]["version"]

    root_package = cargo["package"].get("version", {})
    if root_package != {"workspace": True}:
        fail("the root crate must inherit workspace.package.version")

    pubspec = (ROOT / "flutter/pubspec.yaml").read_text()
    flutter_match = re.search(r"^version:\s*([0-9]+\.[0-9]+\.[0-9]+)\+([0-9]+)\s*$", pubspec, re.MULTILINE)
    if flutter_match is None or flutter_match.group(1) != version:
        fail(f"Flutter version must be {version}+<build number>")

    major, minor, patch = (int(part) for part in version.split("."))
    # The baseline keeps deterministic builds above the timestamp identifiers
    # used before v0.9.12 while remaining below Google Play's 2.1B limit.
    expected_build = 1_800_000_000 + major * 1_000_000 + minor * 1_000 + patch
    if expected_build > 2_100_000_000:
        fail("release version no longer fits the Google Play build-number range")
    if int(flutter_match.group(2)) != expected_build:
        fail(f"Flutter build number must be {expected_build} for store upgrade continuity")

    print(f"release metadata: all package versions are {version}")


if __name__ == "__main__":
    main()
