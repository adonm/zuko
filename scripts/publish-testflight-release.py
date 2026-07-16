#!/usr/bin/env python3
"""Build, validate, and publish one exact tagged iOS release."""

from __future__ import annotations

import os
import re
import sys
from typing import Any

import codemagic_api


WORKFLOW = "ios-testflight-release"


def matches_release(build: dict[str, Any], tag: str, sha: str) -> bool:
    return (
        build.get("fileWorkflowId") == WORKFLOW
        and build.get("tag") == tag
        and isinstance(build.get("commit"), dict)
        and build["commit"].get("hash") == sha
    )


def validate(build: dict[str, Any], tag: str, sha: str) -> None:
    if not matches_release(build, tag, sha):
        raise SystemExit(f"Codemagic {WORKFLOW} did not use {tag} at {sha}")


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: publish-testflight-release.py <vX.Y.Z> <git-sha>")
    tag, sha = sys.argv[1:]
    if not re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", tag):
        raise SystemExit(f"invalid release tag: {tag}")
    if not re.fullmatch(r"[0-9a-f]{40}", sha):
        raise SystemExit(f"invalid release commit: {sha}")
    token = os.environ.get("CODEMAGIC_API_TOKEN")
    if not token:
        raise SystemExit("CODEMAGIC_API_TOKEN is required")

    build_id = codemagic_api.reusable_build(
        token,
        lambda build: matches_release(build, tag, sha),
    )
    if build_id is None:
        build_id = codemagic_api.trigger(token, WORKFLOW, tag=tag)
    build = codemagic_api.wait(token, build_id, WORKFLOW, 90)
    validate(build, tag, sha)
    print(f"TestFlight upload accepted for {tag}: {build_id}", flush=True)


if __name__ == "__main__":
    main()
