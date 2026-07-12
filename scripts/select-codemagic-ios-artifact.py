#!/usr/bin/env python3
"""Select a validated IPA from successful Codemagic signing build data."""

from __future__ import annotations

import json
import pathlib
import sys
from typing import Any


def fail(message: str) -> None:
    print(f"Codemagic IPA selection: {message}", file=sys.stderr)
    raise SystemExit(1)


def validated_artifact(build: dict[str, Any], expected_commit: str) -> dict[str, Any] | None:
    if build.get("status") != "finished":
        return None
    if build.get("fileWorkflowId") != "ios-signing-validation":
        return None
    if (build.get("commit") or {}).get("hash") != expected_commit:
        return None
    if any(action.get("status") != "success" for action in build.get("buildActions", [])):
        return None

    artifacts = [
        artifact
        for artifact in build.get("artefacts", [])
        if artifact.get("name") == "Zuko-Flutter.ipa"
        and artifact.get("type") == "ipa"
        and artifact.get("url")
    ]
    if len(artifacts) != 1:
        return None
    return artifacts[0]


def main() -> None:
    if len(sys.argv) != 3:
        fail("usage: select-codemagic-ios-artifact.py <build-json> <expected-commit>")

    payload = json.loads(pathlib.Path(sys.argv[1]).read_text())
    expected_commit = sys.argv[2]
    if isinstance(payload.get("build"), dict):
        builds = [payload["build"]]
    elif isinstance(payload.get("builds"), list):
        builds = payload["builds"]
    else:
        fail("response does not contain build data")

    candidates = [
        (build, artifact)
        for build in builds
        if isinstance(build, dict)
        if (artifact := validated_artifact(build, expected_commit)) is not None
    ]
    if not candidates:
        fail("no successful signing validation IPA matches the release commit")

    build, artifact = max(candidates, key=lambda candidate: candidate[0].get("finishedAt") or "")
    print(f"source_build_id={build.get('_id', '')}")
    print(f"artifact_url={artifact['url']}")


if __name__ == "__main__":
    main()
