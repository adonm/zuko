#!/usr/bin/env python3
"""Build one exact-commit signed iOS candidate before release tagging."""

from __future__ import annotations

import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
from typing import Any

APP_ID = "6a52dc14add8531e99f88b8a"
API = "https://api.codemagic.io"
WORKFLOW = "ios-signing-validation"
FAILURES = {"canceled", "cancelled", "failed", "skipped", "timed_out", "timeout"}


class InfrastructureFailure(RuntimeError):
    pass


def request(
    token: str,
    method: str,
    path: str,
    payload: dict[str, object] | None = None,
) -> dict[str, object]:
    call = urllib.request.Request(
        f"{API}{path}",
        data=json.dumps(payload).encode() if payload is not None else None,
        method=method,
        headers={"Content-Type": "application/json", "x-auth-token": token},
    )
    try:
        with urllib.request.urlopen(call, timeout=60) as response:
            value = json.load(response)
    except urllib.error.HTTPError as error:
        detail = error.read().decode(errors="replace")
        raise SystemExit(
            f"Codemagic API {method} {path} failed: {error.code} {detail}"
        ) from error
    if not isinstance(value, dict):
        raise SystemExit(f"Codemagic API {method} {path} returned invalid JSON")
    return value


def trigger(token: str, tag: str, sha: str, branch: str) -> str:
    result = request(
        token,
        "POST",
        "/builds",
        {
            "appId": APP_ID,
            "workflowId": WORKFLOW,
            "branch": branch,
            "environment": {
                "variables": {
                    "RELEASE_CANDIDATE_BRANCH": branch,
                    "RELEASE_CANDIDATE_SHA": sha,
                    "RELEASE_CANDIDATE_TAG": tag,
                }
            },
        },
    )
    build_id = result.get("buildId")
    if not isinstance(build_id, str) or not re.fullmatch(r"[0-9a-f]{24}", build_id):
        raise SystemExit("Codemagic returned an invalid iOS candidate build ID")
    print(f"Codemagic iOS candidate: {build_id}", flush=True)
    return build_id


def actions_succeeded(build: dict[str, Any]) -> bool:
    actions = build.get("buildActions")
    return (
        isinstance(actions, list)
        and bool(actions)
        and all(
            isinstance(action, dict) and action.get("status") == "success"
            for action in actions
        )
    )


def wait_for_build(
    token: str, build_id: str, tag: str, sha: str, branch: str
) -> dict[str, Any]:
    deadline = time.monotonic() + 120 * 60
    while time.monotonic() < deadline:
        result = request(token, "GET", f"/builds/{build_id}")
        build = result.get("build", result)
        if not isinstance(build, dict):
            raise SystemExit(f"Codemagic build {build_id} returned invalid metadata")
        status = build.get("status")
        if status == "finished":
            break
        if status in FAILURES:
            if build.get("startedAt") is None and not any(
                isinstance(action, dict) and action.get("status") is not None
                for action in (build.get("buildActions") or [])
            ):
                raise InfrastructureFailure(
                    f"Codemagic could not provision iOS candidate runner {build_id}"
                )
            raise SystemExit(
                f"Codemagic iOS candidate {build_id} ended as {status}: "
                f"{build.get('message') or 'no failure message'}"
            )
        time.sleep(20)
    else:
        raise SystemExit(f"Codemagic iOS candidate {build_id} timed out")
    commit = build.get("commit")
    if (
        build.get("fileWorkflowId") != WORKFLOW
        or build.get("branch") != branch
        or build.get("tag") is not None
        or not isinstance(commit, dict)
        or commit.get("hash") != sha
        or not actions_succeeded(build)
    ):
        raise SystemExit(f"Codemagic iOS candidate {build_id} identity failed closed")
    artifacts = build.get("artefacts")
    ipa_artifacts = [
        artifact
        for artifact in artifacts
        if isinstance(artifact, dict)
        and artifact.get("name") == "Zuko-Flutter.ipa"
        and artifact.get("type") == "ipa"
        and isinstance(artifact.get("url"), str)
        and artifact["url"].startswith("https://")
    ] if isinstance(artifacts, list) else []
    if len(ipa_artifacts) != 1:
        raise SystemExit(
            f"Codemagic iOS candidate has {len(ipa_artifacts)} direct IPA artifacts"
        )
    print(f"Codemagic iOS candidate accepted {tag} at {sha}: {build_id}", flush=True)
    return build


def main() -> None:
    if len(sys.argv) != 4:
        raise SystemExit(
            "usage: prepare_ios_candidate.py <vX.Y.Z> <git-sha> <candidate-branch>"
        )
    tag, sha, branch = sys.argv[1:]
    if not re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", tag):
        raise SystemExit(f"invalid release candidate tag: {tag}")
    if not re.fullmatch(r"[0-9a-f]{40}", sha):
        raise SystemExit(f"invalid release candidate commit: {sha}")
    expected_branch = f"release-candidate/{tag}-{sha[:12]}"
    if branch != expected_branch:
        raise SystemExit(f"invalid release candidate branch: {branch}")
    token = os.environ.get("CODEMAGIC_API_TOKEN")
    if not token:
        raise SystemExit("CODEMAGIC_API_TOKEN is required")
    build_id = ""
    for attempt in range(2):
        build_id = trigger(token, tag, sha, branch)
        try:
            wait_for_build(token, build_id, tag, sha, branch)
            break
        except InfrastructureFailure as error:
            if attempt == 1:
                raise SystemExit(str(error)) from error
            print(f"{error}; retrying once", flush=True)
    output = os.environ.get("GITHUB_OUTPUT")
    if output:
        with open(output, "a") as stream:
            stream.write(f"build_id={build_id}\n")


if __name__ == "__main__":
    main()
