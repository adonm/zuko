#!/usr/bin/env python3
"""Install the pinned Flutter SDK and its CI-built GTK4 release engine."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import shutil
import subprocess
import tempfile

FLUTTER_REPOSITORY = "https://github.com/adonm/flutter.git"
FLUTTER_SDK_REVISION = "00fee9824a795ee9b5794e0a0e2bc5975e54dba8"
FLUTTER_VERSION_BASE_TAG = "3.47.0-0.1.pre"
FLUTTER_FRAMEWORK_VERSION = "3.47.0-1.0.pre-158"
FLUTTER_ENGINE_REVISION = "fc1ad955f16467c959e3cd8079b760d5af0984aa"
ENGINE_BUILD_CONTENT_HASH = "62b1a2404558a3078914891adf75668cffd8436b"
PRECACHE_ENGINE_CONTENT_HASH = "469f2b34de41cab5f677ba84d6e9099c0e682d1e"
DART_REVISION = "d402ff7c9c8442d64aa8148609480aa0e04a24fd"
RELEASE_TAG = f"flutter-engine-gtk4-{FLUTTER_SDK_REVISION}"
LIBRARY_SHA256 = "bd80913e83fa9fac66bca3c90a020bc624827c610f3fcff7971455b4f858f701"
BASE_URL = (
    "https://github.com/adonm/flutter-dev/releases/download/"
    f"{RELEASE_TAG}"
)


def run(
    *args: str,
    capture: bool = False,
    environment: dict[str, str] | None = None,
) -> str:
    result = subprocess.run(
        args,
        check=True,
        env=environment,
        text=True,
        stdout=subprocess.PIPE if capture else None,
    )
    return result.stdout.strip() if capture else ""


def require_tools() -> None:
    missing = [tool for tool in ("curl", "git", "readelf") if shutil.which(tool) is None]
    if missing:
        raise SystemExit(f"missing required tools: {', '.join(missing)}")


def checkout_sdk(destination: pathlib.Path) -> None:
    if destination.exists():
        if not (destination / ".git").exists():
            raise SystemExit(f"Flutter destination is not a Git checkout: {destination}")
    else:
        destination.mkdir(parents=True)
        run("git", "-C", str(destination), "init")
        run(
            "git",
            "-C",
            str(destination),
            "remote",
            "add",
            "origin",
            FLUTTER_REPOSITORY,
        )
        run(
            "git",
            "-C",
            str(destination),
            "fetch",
            "--no-tags",
            "origin",
            FLUTTER_SDK_REVISION,
        )
        run(
            "git",
            "-C",
            str(destination),
            "checkout",
            "--detach",
            FLUTTER_SDK_REVISION,
        )

    shallow = run(
        "git",
        "-C",
        str(destination),
        "rev-parse",
        "--is-shallow-repository",
        capture=True,
    )
    if shallow == "true":
        run(
            "git",
            "-C",
            str(destination),
            "fetch",
            "--unshallow",
            "--no-tags",
            "origin",
            FLUTTER_SDK_REVISION,
        )
    tag = subprocess.run(
        [
            "git",
            "-C",
            str(destination),
            "rev-parse",
            "--quiet",
            "--verify",
            f"refs/tags/{FLUTTER_VERSION_BASE_TAG}",
        ],
        check=False,
        stdout=subprocess.DEVNULL,
    )
    if tag.returncode != 0:
        run(
            "git",
            "-C",
            str(destination),
            "fetch",
            "--no-tags",
            "origin",
            f"refs/tags/{FLUTTER_VERSION_BASE_TAG}:refs/tags/{FLUTTER_VERSION_BASE_TAG}",
        )

    revision = run("git", "-C", str(destination), "rev-parse", "HEAD", capture=True)
    if revision != FLUTTER_SDK_REVISION:
        raise SystemExit(
            f"Flutter SDK revision mismatch: expected {FLUTTER_SDK_REVISION}, got {revision}"
        )
    if subprocess.run(
        ["git", "-C", str(destination), "diff", "--quiet", "HEAD", "--"], check=False
    ).returncode != 0:
        raise SystemExit(f"Flutter SDK has tracked changes: {destination}")


def prepare_sdk(destination: pathlib.Path) -> None:
    flutter = destination / "bin/flutter"
    environment = os.environ.copy()
    environment["FLUTTER_PREBUILT_ENGINE_VERSION"] = PRECACHE_ENGINE_CONTENT_HASH
    run(
        str(flutter),
        "--suppress-analytics",
        "config",
        "--enable-linux-desktop",
        environment=environment,
    )
    run(
        str(flutter),
        "--suppress-analytics",
        "precache",
        "--linux",
        environment=environment,
    )
    version = json.loads(
        run(
            str(flutter),
            "--version",
            "--machine",
            capture=True,
            environment=environment,
        )
    )
    expected = {
        "frameworkVersion": FLUTTER_FRAMEWORK_VERSION,
        "frameworkRevision": FLUTTER_SDK_REVISION,
        "engineRevision": FLUTTER_ENGINE_REVISION,
    }
    actual = {key: version.get(key) for key in expected}
    if actual != expected:
        raise SystemExit(f"Flutter version mismatch: expected {expected}, got {actual}")

    stamp = (destination / "bin/cache/engine.stamp").read_text().strip()
    if stamp != PRECACHE_ENGINE_CONTENT_HASH:
        raise SystemExit(
            "Flutter engine cache mismatch: "
            f"expected {PRECACHE_ENGINE_CONTENT_HASH}, got {stamp}"
        )


def download(directory: pathlib.Path, name: str) -> pathlib.Path:
    output = directory / name
    run(
        "curl",
        "--fail",
        "--location",
        "--retry",
        "3",
        "--proto",
        "=https",
        "--tlsv1.2",
        f"{BASE_URL}/{name}",
        "--output",
        str(output),
    )
    return output


def validate_download(directory: pathlib.Path) -> pathlib.Path:
    library = download(directory, "libflutter_linux_gtk4.so")
    checksum = download(directory, "libflutter_linux_gtk4.so.sha256")
    metadata_path = download(directory, "engine-metadata.json")

    digest = hashlib.sha256(library.read_bytes()).hexdigest()
    if digest != LIBRARY_SHA256:
        raise SystemExit(
            f"GTK4 engine SHA-256 mismatch: expected {LIBRARY_SHA256}, got {digest}"
        )
    sidecar = checksum.read_text().split()
    if sidecar != [LIBRARY_SHA256, library.name]:
        raise SystemExit(f"invalid GTK4 engine checksum sidecar: {sidecar}")

    metadata = json.loads(metadata_path.read_text())
    expected_metadata = {
        "schema": 1,
        "platform": "linux-x64-release",
        "library": library.name,
        "library_sha256": LIBRARY_SHA256,
        "library_size": library.stat().st_size,
        "flutter_sdk_revision": FLUTTER_SDK_REVISION,
        "engine_content_hash": ENGINE_BUILD_CONTENT_HASH,
        "dart_revision": DART_REVISION,
        "runtime_mode": "release",
        "tests": 620,
    }
    actual_metadata = {key: metadata.get(key) for key in expected_metadata}
    if actual_metadata != expected_metadata:
        raise SystemExit(
            f"GTK4 engine metadata mismatch: expected {expected_metadata}, got {actual_metadata}"
        )

    dynamic = run("readelf", "--dynamic", "--wide", str(library), capture=True)
    if "Shared library: [libgtk-4.so.1]" not in dynamic:
        raise SystemExit("GTK4 engine does not directly link libgtk-4.so.1")
    if "Shared library: [libgtk-3.so.0]" in dynamic:
        raise SystemExit("GTK4 engine directly links libgtk-3.so.0")
    sections = run("readelf", "--sections", "--wide", str(library), capture=True)
    if ".debug_info" in sections or ".debug_line" in sections:
        raise SystemExit("GTK4 engine contains debug sections")
    return library


def install_library(sdk: pathlib.Path, library: pathlib.Path) -> pathlib.Path:
    cache = sdk / "bin/cache/artifacts/engine/linux-x64-release"
    if not (cache / "gen_snapshot").is_file():
        raise SystemExit(f"Flutter Linux release cache is incomplete: {cache}")
    destination = cache / library.name
    temporary = destination.with_suffix(destination.suffix + ".tmp")
    shutil.copyfile(library, temporary)
    temporary.chmod(0o644)
    os.replace(temporary, destination)
    digest = hashlib.sha256(destination.read_bytes()).hexdigest()
    if digest != LIBRARY_SHA256:
        raise SystemExit("installed GTK4 engine failed its SHA-256 check")
    return destination


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("destination", type=pathlib.Path)
    args = parser.parse_args()

    require_tools()
    destination = args.destination.resolve()
    checkout_sdk(destination)
    prepare_sdk(destination)
    with tempfile.TemporaryDirectory(prefix="flutter-gtk4-engine-") as temporary:
        library = validate_download(pathlib.Path(temporary))
        installed = install_library(destination, library)
    github_environment = os.environ.get("GITHUB_ENV")
    if github_environment:
        with pathlib.Path(github_environment).open("a") as output:
            output.write(
                "FLUTTER_PREBUILT_ENGINE_VERSION="
                f"{PRECACHE_ENGINE_CONTENT_HASH}\n"
            )
    print(f"Flutter GTK4 SDK: {destination}")
    print(f"Flutter GTK4 engine: {installed}")
    print(f"Flutter GTK4 engine SHA-256: {LIBRARY_SHA256}")
    print(
        "export FLUTTER_PREBUILT_ENGINE_VERSION="
        f"{PRECACHE_ENGINE_CONTENT_HASH}"
    )


if __name__ == "__main__":
    main()
