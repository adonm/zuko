#!/usr/bin/env python3
"""Select one validated IPA from a successful Codemagic signing build."""

from __future__ import annotations

import json
import pathlib
import sys


def fail(message: str) -> None:
    print(f"Codemagic IPA recovery: {message}", file=sys.stderr)
    raise SystemExit(1)


def main() -> None:
    if len(sys.argv) != 3:
        fail("usage: select-codemagic-ios-artifact.py <build-json> <expected-commit>")

    payload = json.loads(pathlib.Path(sys.argv[1]).read_text())
    build = payload.get("build")
    if not isinstance(build, dict):
        fail("response does not contain a build")
    if build.get("status") != "finished":
        fail("source build is not finished")
    if build.get("fileWorkflowId") != "ios-signing-validation":
        fail("source build is not ios-signing-validation")
    if (build.get("commit") or {}).get("hash") != sys.argv[2]:
        fail("source build commit does not match the release tag")

    failed_actions = [
        action.get("name", "unnamed")
        for action in build.get("buildActions", [])
        if action.get("status") != "success"
    ]
    if failed_actions:
        fail(f"source build has unsuccessful actions: {', '.join(failed_actions)}")

    artifacts = [
        artifact
        for artifact in build.get("artefacts", [])
        if artifact.get("name") == "Zuko-Flutter.ipa"
        and artifact.get("type") == "ipa"
        and artifact.get("url")
    ]
    if len(artifacts) != 1:
        fail(f"expected one validated IPA artifact, found {len(artifacts)}")

    print(artifacts[0]["url"])


if __name__ == "__main__":
    main()
