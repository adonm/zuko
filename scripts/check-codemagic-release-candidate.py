#!/usr/bin/env python3
"""Require successful exact-commit Codemagic compile gates before tagging."""

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
BRANCH = "main"
WORKFLOWS = (
    "flutter-apple-ci",
    "flutter-linux-ci",
    "flutter-windows-ci",
)
FAILURES = {"canceled", "cancelled", "failed", "skipped", "timed_out", "timeout"}
NOT_FOUND_RETRY_SECONDS = 60
TIMEOUT_MINUTES = 180


def request(
    token: str,
    method: str,
    path: str,
    payload: dict[str, object] | None = None,
    *,
    retry_not_found: bool = False,
) -> dict[str, object]:
    data = json.dumps(payload).encode() if payload is not None else None
    deadline = time.monotonic() + NOT_FOUND_RETRY_SECONDS
    while True:
        call = urllib.request.Request(
            f"{API}{path}",
            data=data,
            method=method,
            headers={"Content-Type": "application/json", "x-auth-token": token},
        )
        try:
            with urllib.request.urlopen(call, timeout=60) as response:
                result = json.load(response)
            break
        except urllib.error.HTTPError as error:
            if error.code == 404 and retry_not_found and time.monotonic() < deadline:
                error.close()
                time.sleep(2)
                continue
            detail = error.read().decode(errors="replace")
            raise SystemExit(
                f"Codemagic API {method} {path} failed: {error.code} {detail}"
            ) from error
    if not isinstance(result, dict):
        raise SystemExit(f"Codemagic API {method} {path} returned invalid JSON")
    return result


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


def matching_builds(token: str, workflow: str, sha: str) -> list[dict[str, Any]]:
    path: str | None = f"/builds?appId={APP_ID}"
    builds: list[object] = []
    seen: set[str] = set()
    while path is not None:
        if path in seen:
            raise SystemExit("Codemagic build list pagination repeated a page")
        seen.add(path)
        result = request(token, "GET", path)
        page = result.get("builds")
        if not isinstance(page, list):
            raise SystemExit("Codemagic build list returned invalid metadata")
        builds.extend(page)
        next_page = result.get("nextPageUrl")
        if next_page is None:
            path = None
        elif (
            isinstance(next_page, str)
            and next_page.startswith(f"/builds?appId={APP_ID}&skip=")
            and next_page.removeprefix(f"/builds?appId={APP_ID}&skip=").isdigit()
        ):
            path = next_page
        else:
            raise SystemExit("Codemagic build list returned an invalid next page")

    matches = [
        build
        for build in builds
        if isinstance(build, dict)
        and build.get("fileWorkflowId") == workflow
        and build.get("branch") == BRANCH
        and build.get("tag") is None
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


def reusable_build(token: str, workflow: str, sha: str) -> tuple[str, bool] | None:
    builds = matching_builds(token, workflow, sha)
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


def trigger(token: str, workflow: str) -> str:
    result = request(
        token,
        "POST",
        "/builds",
        {"appId": APP_ID, "workflowId": workflow, "branch": BRANCH},
    )
    build_id = result.get("buildId")
    if not isinstance(build_id, str) or not re.fullmatch(r"[0-9a-f]{24}", build_id):
        raise SystemExit(f"Codemagic returned an invalid build ID for {workflow}")
    print(f"Codemagic {workflow}: {build_id} (triggered)", flush=True)
    return build_id


def wait_for_build(
    token: str,
    workflow: str,
    build_id: str,
    sha: str,
    deadline: float,
) -> None:
    while time.monotonic() < deadline:
        result = request(
            token, "GET", f"/builds/{build_id}", retry_not_found=True
        )
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
        or build.get("branch") != BRANCH
        or build.get("tag") is not None
        or not isinstance(commit, dict)
        or commit.get("hash") != sha
    ):
        raise SystemExit(
            f"Codemagic build {build_id} did not build {workflow} at {sha}"
        )
    if not actions_succeeded(build):
        raise SystemExit(f"Codemagic build {build_id} has unsuccessful actions")
    print(f"Codemagic {workflow}: success ({build_id})", flush=True)


def main() -> None:
    if len(sys.argv) != 2 or not re.fullmatch(r"[0-9a-f]{40}", sys.argv[1]):
        raise SystemExit(
            "usage: check-codemagic-release-candidate.py <40-character-git-sha>"
        )
    sha = sys.argv[1]
    token = os.environ.get("CODEMAGIC_API_TOKEN")
    if not token:
        raise SystemExit("CODEMAGIC_API_TOKEN is required to verify release candidates")

    builds: dict[str, str] = {}
    for workflow in WORKFLOWS:
        reusable = reusable_build(token, workflow, sha)
        if reusable is None:
            builds[workflow] = trigger(token, workflow)
            continue
        build_id, completed = reusable
        state = "reusing" if completed else "resuming"
        print(f"Codemagic {workflow}: {build_id} ({state})", flush=True)
        builds[workflow] = build_id

    deadline = time.monotonic() + TIMEOUT_MINUTES * 60
    for workflow, build_id in builds.items():
        wait_for_build(token, workflow, build_id, sha, deadline)
    print(f"Codemagic release candidate passed at {sha}", flush=True)


if __name__ == "__main__":
    main()
