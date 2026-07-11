#!/usr/bin/env python3
"""Validate and print immutable Android release identity for a tagged source tree."""

from __future__ import annotations

import argparse
import pathlib
import re
import subprocess
import sys
import tomllib


PACKAGE = "dev.adonm.zuko"
TAG_PATTERN = re.compile(r"v([0-9]+)\.([0-9]+)\.([0-9]+)")
SHA_PATTERN = re.compile(r"[0-9a-f]{40}")


def fail(message: str) -> None:
    print(f"Android release metadata: {message}", file=sys.stderr)
    raise SystemExit(1)


def git(source: pathlib.Path, *args: str) -> str:
    try:
        return subprocess.run(
            ["git", "-C", str(source), *args],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
    except subprocess.CalledProcessError as error:
        fail(error.stderr.strip() or f"git {' '.join(args)} failed")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", required=True, type=pathlib.Path)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--commit")
    parser.add_argument("--tag-object")
    args = parser.parse_args()

    source = args.source.resolve()
    tag_match = TAG_PATTERN.fullmatch(args.tag)
    if tag_match is None:
        fail(f"tag must match vX.Y.Z: {args.tag}")
    if args.commit is not None and SHA_PATTERN.fullmatch(args.commit) is None:
        fail("expected commit is not a full SHA")
    if args.tag_object is not None and SHA_PATTERN.fullmatch(args.tag_object) is None:
        fail("expected tag object is not a full SHA")

    head = git(source, "rev-parse", "HEAD")
    local_object = git(source, "rev-parse", f"refs/tags/{args.tag}")
    if git(source, "cat-file", "-t", local_object) != "tag":
        fail(f"{args.tag} must be an annotated tag")
    local_commit = git(source, "rev-parse", f"refs/tags/{args.tag}^{{commit}}")
    if head != local_commit:
        fail(f"checked-out commit {head} is not {args.tag} ({local_commit})")
    if args.commit is not None and local_commit != args.commit:
        fail(f"tag commit moved from {args.commit} to {local_commit}")
    if args.tag_object is not None and local_object != args.tag_object:
        fail(f"tag object moved from {args.tag_object} to {local_object}")

    remote_output = git(
        source,
        "ls-remote",
        "--tags",
        "origin",
        f"refs/tags/{args.tag}",
        f"refs/tags/{args.tag}^{{}}",
    )
    remote = dict(line.split("\t", 1)[::-1] for line in remote_output.splitlines())
    if remote.get(f"refs/tags/{args.tag}") != local_object:
        fail("remote annotated tag object does not match the checkout")
    if remote.get(f"refs/tags/{args.tag}^{{}}") != local_commit:
        fail("remote tag commit does not match the checkout")

    cargo = tomllib.loads((source / "Cargo.toml").read_text())
    version = cargo["workspace"]["package"]["version"]
    if args.tag != f"v{version}":
        fail(f"tag {args.tag} does not match workspace version {version}")

    pubspec = (source / "flutter/pubspec.yaml").read_text()
    flutter_match = re.search(
        r"^version:\s*([0-9]+\.[0-9]+\.[0-9]+)\+([0-9]+)\s*$",
        pubspec,
        re.MULTILINE,
    )
    if flutter_match is None or flutter_match.group(1) != version:
        fail(f"Flutter version must be {version}+<version code>")
    version_code = int(flutter_match.group(2))
    major, minor, patch = (int(part) for part in version.split("."))
    expected_code = major * 1_000_000 + minor * 1_000 + patch
    if version_code != expected_code:
        fail(f"Flutter version code must be {expected_code}, got {version_code}")

    gradle = (source / "flutter/android/app/build.gradle.kts").read_text()
    namespaces = re.findall(r'^\s*namespace\s*=\s*"([^"]+)"\s*$', gradle, re.MULTILINE)
    application_ids = re.findall(r'^\s*applicationId\s*=\s*"([^"]+)"\s*$', gradle, re.MULTILINE)
    if namespaces != [PACKAGE] or application_ids != [PACKAGE]:
        fail(f"Android namespace and application ID must both be {PACKAGE}")

    print(f"tag={args.tag}")
    print(f"sha={local_commit}")
    print(f"tag_object={local_object}")
    print(f"version={version}")
    print(f"version_code={version_code}")
    print(f"package={PACKAGE}")
    print(f"asset=zuko-android-{args.tag}-signed.aab")


if __name__ == "__main__":
    main()
