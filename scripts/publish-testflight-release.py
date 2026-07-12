#!/usr/bin/env python3
"""Validate, then publish one exact Codemagic iOS release to TestFlight."""

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
VALIDATION_WORKFLOW = "ios-signing-validation"
RELEASE_WORKFLOW = "ios-testflight-release"
FAILURES = {"canceled", "cancelled", "failed", "skipped"}


def request(
    token: str,
    method: str,
    path: str,
    payload: dict[str, object] | None = None,
) -> dict[str, object]:
    data = json.dumps(payload).encode() if payload is not None else None
    call = urllib.request.Request(
        f"{API}{path}",
        data=data,
        method=method,
        headers={"Content-Type": "application/json", "x-auth-token": token},
    )
    try:
        with urllib.request.urlopen(call, timeout=60) as response:
            result = json.load(response)
    except urllib.error.HTTPError as error:
        detail = error.read().decode(errors="replace")
        raise SystemExit(
            f"Codemagic API {method} {path} failed: {error.code} {detail}"
        ) from error
    if not isinstance(result, dict):
        raise SystemExit(f"Codemagic API {method} {path} returned invalid JSON")
    return result


def trigger(token: str, workflow: str, tag: str) -> str:
    result = request(
        token,
        "POST",
        "/builds",
        {"appId": APP_ID, "workflowId": workflow, "tag": tag},
    )
    build_id = result.get("buildId")
    if not isinstance(build_id, str) or not re.fullmatch(r"[0-9a-f]{24}", build_id):
        raise SystemExit(f"Codemagic returned an invalid build ID for {workflow}")
    print(f"Codemagic {workflow}: {build_id}", flush=True)
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


def matching_builds(
    token: str, workflow: str, tag: str, sha: str
) -> list[dict[str, Any]]:
    result = request(token, "GET", f"/builds?appId={APP_ID}")
    builds = result.get("builds")
    if not isinstance(builds, list):
        raise SystemExit("Codemagic build list returned invalid metadata")
    matches = [
        build
        for build in builds
        if isinstance(build, dict)
        and build.get("fileWorkflowId") == workflow
        and build.get("tag") == tag
        and isinstance(build.get("commit"), dict)
        and build["commit"].get("hash") == sha
    ]
    return sorted(
        matches,
        key=lambda build: build.get("finishedAt")
        or build.get("startedAt")
        or build.get("createdAt")
        or "",
        reverse=True,
    )


def reusable_build(
    token: str, workflow: str, tag: str, sha: str
) -> tuple[str, bool] | None:
    builds = matching_builds(token, workflow, tag, sha)
    completed = next(
        (
            build
            for build in builds
            if build.get("status") == "finished" and actions_succeeded(build)
        ),
        None,
    )
    candidate = completed or next(
        (
            build
            for build in builds
            if build.get("status") != "finished"
            and build.get("status") not in FAILURES
        ),
        None,
    )
    if candidate is None:
        return None
    build_id = candidate.get("_id")
    if not isinstance(build_id, str) or not re.fullmatch(r"[0-9a-f]{24}", build_id):
        raise SystemExit(f"Codemagic returned an invalid build ID for {workflow}")
    return build_id, candidate is completed


def wait_for_build(
    token: str,
    build_id: str,
    workflow: str,
    tag: str,
    sha: str,
    timeout_minutes: int,
) -> None:
    deadline = time.monotonic() + timeout_minutes * 60
    while time.monotonic() < deadline:
        result = request(token, "GET", f"/builds/{build_id}")
        build = result.get("build", result)
        if not isinstance(build, dict):
            raise SystemExit(f"Codemagic build {build_id} returned invalid metadata")
        status = build.get("status")
        if status == "finished":
            break
        if status in FAILURES:
            raise SystemExit(
                f"Codemagic {workflow} build {build_id} ended as {status}: "
                f"{build.get('message') or 'no failure message'}"
            )
        time.sleep(20)
    else:
        raise SystemExit(f"Codemagic {workflow} build {build_id} timed out")

    commit = build.get("commit")
    if (
        build.get("fileWorkflowId") != workflow
        or build.get("tag") != tag
        or not isinstance(commit, dict)
        or commit.get("hash") != sha
    ):
        raise SystemExit(f"Codemagic build {build_id} did not build {workflow} {tag} at {sha}")
    actions = build.get("buildActions")
    if not isinstance(actions, list) or not actions:
        raise SystemExit(f"Codemagic build {build_id} has no action results")
    failed_actions = [
        action.get("name", "unnamed") if isinstance(action, dict) else "invalid"
        for action in actions
        if not isinstance(action, dict) or action.get("status") != "success"
    ]
    if failed_actions:
        raise SystemExit(
            f"Codemagic build {build_id} has unsuccessful actions: {failed_actions}"
        )
    print(f"Codemagic {workflow} accepted {tag}: {build_id}", flush=True)


def main() -> None:
    if len(sys.argv) not in {3, 4}:
        raise SystemExit(
            "usage: publish-testflight-release.py <vX.Y.Z> <git-sha> "
            "[validation-build-id]"
        )
    tag, sha = sys.argv[1:3]
    if not re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", tag):
        raise SystemExit(f"invalid release tag: {tag}")
    if not re.fullmatch(r"[0-9a-f]{40}", sha):
        raise SystemExit(f"invalid release commit: {sha}")
    token = os.environ.get("CODEMAGIC_API_TOKEN")
    if not token:
        raise SystemExit("CODEMAGIC_API_TOKEN is required")

    release = reusable_build(token, RELEASE_WORKFLOW, tag, sha)
    if release is not None:
        release_id, completed = release
        if completed:
            print(
                f"TestFlight upload already accepted for {tag}: {release_id}",
                flush=True,
            )
            return
        print(f"Codemagic {RELEASE_WORKFLOW}: {release_id} (resuming)", flush=True)
        wait_for_build(token, release_id, RELEASE_WORKFLOW, tag, sha, 30)
        print(f"TestFlight upload accepted for {tag}: {release_id}", flush=True)
        return

    if len(sys.argv) == 4:
        validation_id = sys.argv[3]
        if not re.fullmatch(r"[0-9a-f]{24}", validation_id):
            raise SystemExit("invalid Codemagic validation build ID")
        print(f"Codemagic {VALIDATION_WORKFLOW}: {validation_id}", flush=True)
    else:
        validation = reusable_build(token, VALIDATION_WORKFLOW, tag, sha)
        if validation is None:
            validation_id = trigger(token, VALIDATION_WORKFLOW, tag)
        else:
            validation_id, completed = validation
            state = "reusing" if completed else "resuming"
            print(
                f"Codemagic {VALIDATION_WORKFLOW}: {validation_id} ({state})",
                flush=True,
            )
    wait_for_build(token, validation_id, VALIDATION_WORKFLOW, tag, sha, 120)

    release = reusable_build(token, RELEASE_WORKFLOW, tag, sha)
    if release is None:
        release_id = trigger(token, RELEASE_WORKFLOW, tag)
    else:
        release_id, completed = release
        state = "reusing" if completed else "resuming"
        print(
            f"Codemagic {RELEASE_WORKFLOW}: {release_id} ({state})", flush=True
        )
    wait_for_build(token, release_id, RELEASE_WORKFLOW, tag, sha, 30)
    print(f"TestFlight upload accepted for {tag}: {release_id}", flush=True)


if __name__ == "__main__":
    main()
