#!/usr/bin/env python3
"""Create and verify one build-once release-candidate manifest."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import re
import release_metadata

FLUTTER_FRAMEWORK_REVISION = "328b829d35a3a5d7a00e0c2f0e97eb8cc0d97188"
FLUTTER_ENGINE_REVISION = "fc1ad955f16467c959e3cd8079b760d5af0984aa"
FLUTTER_ENGINE_CONTENT_HASH = "469f2b34de41cab5f677ba84d6e9099c0e682d1e"
DART_SDK_VERSION = "3.14.0 (build 3.14.0-28.0.dev)"


def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while chunk := source.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def source_metadata(root: pathlib.Path) -> release_metadata.ReleaseMetadata:
    try:
        return release_metadata.load(root)
    except (KeyError, OSError, TypeError, ValueError) as error:
        raise SystemExit(f"invalid source release metadata: {error}") from error


def expected_names(version: str) -> set[str]:
    return release_metadata.candidate_asset_names(release_metadata.for_version(version))


def verify_sidecars(directory: pathlib.Path) -> None:
    for sidecar in directory.glob("*.sha256"):
        fields = sidecar.read_text().split()
        if len(fields) != 2 or not re.fullmatch(r"[0-9a-f]{64}", fields[0]):
            raise SystemExit(f"invalid candidate checksum: {sidecar.name}")
        payload = directory / pathlib.PurePath(fields[1]).name
        if fields[1] != payload.name or not payload.is_file():
            raise SystemExit(f"unsafe candidate checksum target: {sidecar.name}")
        if sha256(payload) != fields[0]:
            raise SystemExit(f"candidate checksum mismatch: {payload.name}")


def artifact_records(directory: pathlib.Path, version: str) -> dict[str, dict[str, object]]:
    expected = expected_names(version)
    actual = {
        path.name
        for path in directory.iterdir()
        if path.is_file() and path.name != "release-candidate.json"
    }
    if actual != expected:
        raise SystemExit(
            f"candidate files differ: missing={sorted(expected - actual)}, "
            f"unexpected={sorted(actual - expected)}"
        )
    verify_sidecars(directory)
    return {
        name: {
            "sha256": sha256(directory / name),
            "size": (directory / name).stat().st_size,
        }
        for name in sorted(expected)
    }


def build_manifest(root: pathlib.Path, directory: pathlib.Path, sha: str) -> dict[str, object]:
    if not re.fullmatch(r"[0-9a-f]{40}", sha):
        raise SystemExit(f"invalid candidate commit: {sha}")
    metadata = source_metadata(root)
    return {
        "schema": 2,
        "version": metadata.version,
        "tag": metadata.tag,
        "build_number": metadata.build_number,
        "package": metadata.package,
        "commit": sha,
        "github_run_id": os.environ.get("GITHUB_RUN_ID"),
        "flutter": {
            "framework_revision": FLUTTER_FRAMEWORK_REVISION,
            "engine_revision": FLUTTER_ENGINE_REVISION,
            "engine_content_hash": FLUTTER_ENGINE_CONTENT_HASH,
            "dart_sdk_version": DART_SDK_VERSION,
        },
        "artifacts": artifact_records(directory, metadata.version),
    }


def create(root: pathlib.Path, directory: pathlib.Path, sha: str) -> None:
    manifest = build_manifest(root, directory, sha)
    output = directory / "release-candidate.json"
    output.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    verify(root, directory, sha)
    print(f"release candidate: {manifest['tag']} at {sha}")


def verify(root: pathlib.Path, directory: pathlib.Path, sha: str) -> None:
    path = directory / "release-candidate.json"
    if not path.is_file():
        raise SystemExit("release candidate manifest is missing")
    actual = json.loads(path.read_text())
    expected_run_id = os.environ.get("GITHUB_CANDIDATE_RUN_ID")
    if expected_run_id is not None and actual.get("github_run_id") != expected_run_id:
        raise SystemExit("release candidate manifest has the wrong GitHub run ID")
    expected = build_manifest(root, directory, sha)
    expected["github_run_id"] = actual.get("github_run_id")
    if actual != expected:
        raise SystemExit("release candidate manifest does not match artifact bytes")
    print(f"release candidate verified: {actual['tag']} at {sha}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=("create", "verify"))
    parser.add_argument("sha")
    parser.add_argument("directory", type=pathlib.Path)
    parser.add_argument("--root", type=pathlib.Path, default=pathlib.Path.cwd())
    args = parser.parse_args()
    root = args.root.resolve()
    directory = args.directory.resolve()
    if args.command == "create":
        create(root, directory, args.sha)
    else:
        verify(root, directory, args.sha)


if __name__ == "__main__":
    main()
