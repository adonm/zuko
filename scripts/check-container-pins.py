#!/usr/bin/env python3
"""Pin container and CI build inputs to their single sources.

The Android SDK package list lives only in
containers/android-sdk-packages.txt; the Containerfile and the CI workflow
must reference that file instead of inlining copies. Java majors must agree
between the container image and CI. Fails loudly on drift so version bumps
happen in exactly one place.
"""

from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
PACKAGES_FILE = ROOT / "containers/android-sdk-packages.txt"
CONTAINERFILE = ROOT / "containers/flutter-ci.Containerfile"
BUILD_WORKFLOW = ROOT / ".github/workflows/build.yml"

EXPECTED_ANDROID_PACKAGES = (
    "platforms;android-34",
    "platforms;android-35",
    "platforms;android-36",
    "build-tools;36.0.0",
    "cmake;3.22.1",
    "ndk;29.0.14206865",
)


def read(path: pathlib.Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except OSError as error:
        raise SystemExit(f"container pins: cannot read {path}: {error}")


def android_packages() -> tuple[str, ...]:
    """Parse the canonical list, ignoring comments and blank lines."""
    packages = []
    for line in read(PACKAGES_FILE).splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        packages.append(stripped)
    return tuple(packages)


def main() -> None:
    packages = android_packages()
    if packages != EXPECTED_ANDROID_PACKAGES:
        raise SystemExit(
            "container pins: containers/android-sdk-packages.txt must hold "
            f"exactly {list(EXPECTED_ANDROID_PACKAGES)!r}; bump versions here "
            "and in this script together"
        )

    containerfile = read(CONTAINERFILE)
    if "android-sdk-packages.txt" not in containerfile:
        raise SystemExit(
            "container pins: flutter-ci.Containerfile must read the SDK "
            "packages from containers/android-sdk-packages.txt"
        )
    if "platforms;android-" in containerfile:
        raise SystemExit(
            "container pins: flutter-ci.Containerfile must not inline "
            "Android SDK packages; use containers/android-sdk-packages.txt"
        )

    workflow = read(BUILD_WORKFLOW)
    if "containers/android-sdk-packages.txt" not in workflow:
        raise SystemExit(
            "container pins: build.yml must read the SDK packages from "
            "containers/android-sdk-packages.txt"
        )
    if re.search(r"^ +platforms;android-", workflow, re.MULTILINE):
        raise SystemExit(
            "container pins: build.yml must not inline Android SDK packages; "
            "use containers/android-sdk-packages.txt"
        )

    container_java = re.search(r"openjdk-(\d+)-jdk-headless", containerfile)
    workflow_java = re.search(r"java-version:\s*'(\d+)'", workflow)
    if container_java is None or workflow_java is None:
        raise SystemExit(
            "container pins: cannot find both JDK majors "
            "(Containerfile openjdk-X, build.yml java-version)"
        )
    if container_java.group(1) != workflow_java.group(1):
        raise SystemExit(
            "container pins: JDK major mismatch: container "
            f"openjdk-{container_java.group(1)} versus workflow "
            f"java-version '{workflow_java.group(1)}'"
        )

    print("container pins: Android list single-sourced; JDK majors agree")


if __name__ == "__main__":
    sys.exit(main())
