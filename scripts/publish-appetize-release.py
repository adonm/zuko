#!/usr/bin/env python3
"""Publish immutable GitHub Release previews through Codemagic."""

from __future__ import annotations

import os
import re
import sys

import codemagic_api


WORKFLOW = "mobile-appetize-release"


def matches_release(build: dict[str, object], tag: str, sha: str) -> bool:
    commit = build.get("commit")
    return (
        build.get("fileWorkflowId") == WORKFLOW
        and build.get("tag") == tag
        and isinstance(commit, dict)
        and commit.get("hash") == sha
    )


def main() -> None:
    usage = "publish-appetize-release.py <vX.Y.Z> <git-sha> [config-branch]"
    if len(sys.argv) not in {3, 4}:
        raise SystemExit(f"usage: {usage}")
    tag, sha = sys.argv[1:3]
    branch = sys.argv[3] if len(sys.argv) == 4 else None
    if not re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", tag):
        raise SystemExit(f"invalid release tag: {tag}")
    if not re.fullmatch(r"[0-9a-f]{40}", sha):
        raise SystemExit(f"invalid release commit: {sha}")
    if branch is not None and branch != "main":
        raise SystemExit("the Appetize recovery config branch must be main")
    token = os.environ.get("CODEMAGIC_API_TOKEN")
    if not token:
        raise SystemExit("CODEMAGIC_API_TOKEN is required")

    variables = None
    if branch is not None:
        variables = {"APPETIZE_RELEASE_TAG": tag, "APPETIZE_RELEASE_SHA": sha}
    build_id = None
    if branch is None:
        build_id = codemagic_api.reusable_build(
            token, lambda build: matches_release(build, tag, sha)
        )
    if build_id is None:
        build_id = codemagic_api.trigger(
            token,
            WORKFLOW,
            tag=tag if branch is None else None,
            branch=branch,
            variables=variables,
        )
    build = codemagic_api.wait(token, build_id, WORKFLOW, 30)
    commit = build.get("commit")
    if build.get("fileWorkflowId") != WORKFLOW or not isinstance(commit, dict):
        raise SystemExit(f"Codemagic Appetize build {build_id} identity failed closed")
    if branch is None:
        valid_source = build.get("tag") == tag and commit.get("hash") == sha
    else:
        valid_source = build.get("branch") == branch
    if not valid_source:
        raise SystemExit(f"Codemagic Appetize build {build_id} used the wrong source")
    print(f"Appetize uploads accepted for {tag}: {build_id}", flush=True)


if __name__ == "__main__":
    main()
