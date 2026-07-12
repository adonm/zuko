#!/usr/bin/env python3
"""Build and collect release artifacts from exact Codemagic tag workflows."""

from __future__ import annotations

import hashlib
import json
import os
import pathlib
import re
import shutil
import stat
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile

APP_ID = "6a52dc14add8531e99f88b8a"
API = "https://api.codemagic.io"
TERMINAL_FAILURES = {"canceled", "cancelled", "failed", "skipped"}
MAX_ARTIFACT_SIZE = 1_000_000_000
POLL_SECONDS = 20
WORKFLOWS = {
    "flutter-linux-android-release": "zuko-flutter-linux-android-{tag}.zip",
    "flutter-windows-release": "zuko-flutter-windows-{tag}-artifacts.zip",
}


def request_json(
    token: str,
    method: str,
    path: str,
    payload: dict[str, object] | None = None,
) -> dict[str, object]:
    data = json.dumps(payload).encode() if payload is not None else None
    request = urllib.request.Request(
        f"{API}{path}",
        data=data,
        method=method,
        headers={"Content-Type": "application/json", "x-auth-token": token},
    )
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            value = json.load(response)
    except urllib.error.HTTPError as error:
        detail = error.read().decode(errors="replace")
        raise SystemExit(f"Codemagic API {method} {path} failed: {error.code} {detail}")
    if not isinstance(value, dict):
        raise SystemExit(f"Codemagic API {method} {path} returned invalid JSON")
    return value


def trigger(token: str, workflow: str, tag: str) -> str:
    response = request_json(
        token,
        "POST",
        "/builds",
        {"appId": APP_ID, "workflowId": workflow, "tag": tag},
    )
    build_id = response.get("buildId")
    if not isinstance(build_id, str) or not re.fullmatch(r"[0-9a-f]{24}", build_id):
        raise SystemExit(f"Codemagic returned an invalid build ID for {workflow}")
    print(f"Codemagic {workflow}: {build_id}", flush=True)
    return build_id


def wait_for_build(
    token: str,
    workflow: str,
    build_id: str,
    tag: str,
    sha: str,
    deadline: float,
) -> dict[str, object]:
    while time.monotonic() < deadline:
        response = request_json(token, "GET", f"/builds/{build_id}")
        build = response.get("build", response)
        if not isinstance(build, dict):
            raise SystemExit(f"Codemagic build {build_id} returned invalid metadata")
        status = build.get("status")
        if status == "finished":
            break
        if status in TERMINAL_FAILURES:
            raise SystemExit(
                f"Codemagic {workflow} build {build_id} ended as {status}: "
                f"{build.get('message') or 'no failure message'}"
            )
        time.sleep(POLL_SECONDS)
    else:
        raise SystemExit(f"Codemagic {workflow} build {build_id} timed out")

    if build.get("fileWorkflowId") != workflow or build.get("tag") != tag:
        raise SystemExit(f"Codemagic build {build_id} identity does not match {workflow} {tag}")
    commit = build.get("commit")
    if not isinstance(commit, dict) or commit.get("hash") != sha:
        raise SystemExit(f"Codemagic build {build_id} did not build commit {sha}")
    print(f"Codemagic {workflow}: success", flush=True)
    return build


def download(
    token: str,
    url: str,
    destination: pathlib.Path,
    expected_size: int,
) -> None:
    parsed = urllib.parse.urlparse(url)
    if (
        parsed.scheme != "https"
        or parsed.netloc != "api.codemagic.io"
        or not parsed.path.startswith("/artifacts/")
    ):
        raise SystemExit(f"refusing unexpected Codemagic artifact URL: {url}")
    request = urllib.request.Request(url, headers={"x-auth-token": token})
    total = 0
    with urllib.request.urlopen(request, timeout=120) as response, destination.open("wb") as output:
        length = response.headers.get("Content-Length")
        if length is not None and int(length) > MAX_ARTIFACT_SIZE:
            raise SystemExit(f"Codemagic artifact exceeds size limit: {length}")
        while chunk := response.read(1024 * 1024):
            total += len(chunk)
            if total > MAX_ARTIFACT_SIZE:
                raise SystemExit("Codemagic artifact exceeds size limit")
            output.write(chunk)
    if total != expected_size:
        raise SystemExit(
            f"Codemagic artifact size is {total}, expected {expected_size}"
        )


def expected_files(tag: str) -> dict[str, set[str]]:
    android = {
        f"zuko-android-{tag}-unsigned.apk",
        f"zuko-android-{tag}-unsigned.aab",
    }
    linux = {
        f"zuko-linux-{tag}-x86_64.tar.gz",
        f"zuko-linux-{tag}-x86_64.tar.gz.sha256",
    }
    windows = {
        f"zuko-windows-{tag}-x86_64.zip",
        f"zuko-windows-{tag}-x86_64.zip.sha256",
    }
    return {
        "flutter-linux-android-release": android | linux,
        "flutter-windows-release": windows,
    }


def extract_exact(archive: pathlib.Path, destination: pathlib.Path, expected: set[str]) -> None:
    with zipfile.ZipFile(archive) as source:
        entries = source.infolist()
        names = [entry.filename for entry in entries]
        if set(names) != expected or len(names) != len(expected):
            raise SystemExit(
                f"Codemagic artifact {archive.name} contains {sorted(names)}, "
                f"expected {sorted(expected)}"
            )
        if sum(entry.file_size for entry in entries) > MAX_ARTIFACT_SIZE:
            raise SystemExit(f"Codemagic artifact expands beyond size limit: {archive.name}")
        for entry in entries:
            name = entry.filename
            if pathlib.PurePosixPath(name).name != name:
                raise SystemExit(f"unsafe Codemagic artifact member: {name}")
            mode = entry.external_attr >> 16
            if entry.is_dir() or stat.S_ISLNK(mode) or entry.flag_bits & 1:
                raise SystemExit(f"unsupported Codemagic artifact member: {name}")
            target = destination / name
            if target.exists():
                raise SystemExit(f"duplicate Codemagic release artifact: {name}")
            with source.open(entry) as input_file, target.open("wb") as output:
                shutil.copyfileobj(input_file, output)


def verify_checksums(destination: pathlib.Path) -> None:
    for sidecar in sorted(destination.glob("*.sha256")):
        fields = sidecar.read_text().split()
        if len(fields) != 2 or not re.fullmatch(r"[0-9a-f]{64}", fields[0]):
            raise SystemExit(f"invalid checksum sidecar: {sidecar.name}")
        payload = destination / pathlib.PurePath(fields[1]).name
        if fields[1] != payload.name or not payload.is_file():
            raise SystemExit(f"invalid checksum target in {sidecar.name}")
        digest = hashlib.sha256()
        with payload.open("rb") as source:
            while chunk := source.read(1024 * 1024):
                digest.update(chunk)
        actual = digest.hexdigest()
        if actual != fields[0]:
            raise SystemExit(f"checksum mismatch for {payload.name}")


def main() -> None:
    if len(sys.argv) != 4:
        raise SystemExit("usage: collect-codemagic-release.py <vX.Y.Z> <git-sha> <output-dir>")
    tag, sha, output = sys.argv[1:]
    if not re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", tag):
        raise SystemExit(f"invalid release tag: {tag}")
    if not re.fullmatch(r"[0-9a-f]{40}", sha):
        raise SystemExit(f"invalid release commit: {sha}")
    token = os.environ.get("CODEMAGIC_API_TOKEN")
    if not token:
        raise SystemExit("CODEMAGIC_API_TOKEN is required")
    destination = pathlib.Path(output)
    destination.mkdir(parents=True, exist_ok=True)
    if any(destination.iterdir()):
        raise SystemExit(f"output directory is not empty: {destination}")

    builds = {workflow: trigger(token, workflow, tag) for workflow in WORKFLOWS}
    deadline = time.monotonic() + 150 * 60
    expected = expected_files(tag)
    for workflow, build_id in builds.items():
        build = wait_for_build(token, workflow, build_id, tag, sha, deadline)
        artifact_name = WORKFLOWS[workflow].format(tag=tag)
        artifacts = build.get("artefacts")
        if not isinstance(artifacts, list):
            raise SystemExit(f"Codemagic build {build_id} has no artifacts")
        matches = [item for item in artifacts if isinstance(item, dict) and item.get("name") == artifact_name]
        if (
            len(matches) != 1
            or not isinstance(matches[0].get("url"), str)
            or not isinstance(matches[0].get("size"), int)
            or not 0 < matches[0]["size"] <= MAX_ARTIFACT_SIZE
        ):
            raise SystemExit(f"Codemagic build {build_id} is missing exactly one {artifact_name}")
        archive = destination.parent / artifact_name
        download(token, matches[0]["url"], archive, matches[0]["size"])
        extract_exact(archive, destination, expected[workflow])
        archive.unlink()
    verify_checksums(destination)
    print("Codemagic release artifacts:", flush=True)
    for path in sorted(destination.iterdir()):
        print(path.name, flush=True)


if __name__ == "__main__":
    main()
