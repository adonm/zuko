#!/usr/bin/env python3
"""Small fail-closed Codemagic API client for release channels."""

from __future__ import annotations

import json
import re
import time
import urllib.error
import urllib.request
from typing import Any, Callable


API = "https://api.codemagic.io"
APP_ID = "6a52dc14add8531e99f88b8a"
FAILURES = {"canceled", "cancelled", "failed", "skipped", "timed_out", "timeout"}
Build = dict[str, Any]


def request(
    token: str,
    method: str,
    path: str,
    payload: dict[str, object] | None = None,
    *,
    retry_not_found_seconds: int = 0,
) -> dict[str, object]:
    data = json.dumps(payload).encode() if payload is not None else None
    deadline = time.monotonic() + retry_not_found_seconds
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
            if error.code == 404 and time.monotonic() < deadline:
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


def trigger(
    token: str,
    workflow: str,
    *,
    tag: str | None = None,
    branch: str | None = None,
    variables: dict[str, str] | None = None,
) -> str:
    if (tag is None) == (branch is None):
        raise ValueError("exactly one Codemagic source is required")
    payload: dict[str, object] = {
        "appId": APP_ID,
        "workflowId": workflow,
        "tag" if tag is not None else "branch": tag or branch,
    }
    if variables:
        payload["environment"] = {"variables": variables}
    result = request(token, "POST", "/builds", payload)
    build_id = result.get("buildId")
    if not isinstance(build_id, str) or not re.fullmatch(r"[0-9a-f]{24}", build_id):
        raise SystemExit(f"Codemagic returned an invalid build ID for {workflow}")
    print(f"Codemagic {workflow}: {build_id}", flush=True)
    return build_id


def actions_succeeded(build: Build) -> bool:
    actions = build.get("buildActions")
    return (
        isinstance(actions, list)
        and bool(actions)
        and all(
            isinstance(action, dict) and action.get("status") == "success"
            for action in actions
        )
    )


def wait(token: str, build_id: str, workflow: str, timeout_minutes: int) -> Build:
    deadline = time.monotonic() + timeout_minutes * 60
    while time.monotonic() < deadline:
        result = request(
            token,
            "GET",
            f"/builds/{build_id}",
            retry_not_found_seconds=60,
        )
        build = result.get("build", result)
        if not isinstance(build, dict):
            raise SystemExit(f"Codemagic build {build_id} returned invalid metadata")
        status = build.get("status")
        if status == "finished":
            if not actions_succeeded(build):
                raise SystemExit(f"Codemagic {workflow} build {build_id} has failed actions")
            return build
        if status in FAILURES:
            raise SystemExit(
                f"Codemagic {workflow} build {build_id} ended as {status}: "
                f"{build.get('message') or 'no failure message'}"
            )
        time.sleep(20)
    raise SystemExit(f"Codemagic {workflow} build {build_id} timed out")


def builds(token: str, app_id: str) -> list[Build]:
    path: str | None = f"/builds?appId={app_id}"
    result_builds: list[Build] = []
    seen: set[str] = set()
    while path is not None:
        if path in seen:
            raise SystemExit("Codemagic build list pagination repeated a page")
        seen.add(path)
        result = request(token, "GET", path)
        page = result.get("builds")
        if not isinstance(page, list):
            raise SystemExit("Codemagic build list returned invalid metadata")
        result_builds.extend(build for build in page if isinstance(build, dict))
        next_page = result.get("nextPageUrl")
        if next_page is None:
            path = None
        elif (
            isinstance(next_page, str)
            and next_page.startswith(f"/builds?appId={app_id}&skip=")
            and next_page.removeprefix(f"/builds?appId={app_id}&skip=").isdigit()
        ):
            path = next_page
        else:
            raise SystemExit("Codemagic build list returned an invalid next page")
    return result_builds


def reusable_build(
    token: str,
    matches: Callable[[Build], bool],
) -> str | None:
    candidates = sorted(
        (build for build in builds(token, APP_ID) if matches(build)),
        key=lambda build: build.get("finishedAt")
        or build.get("startedAt")
        or build.get("createdAt")
        or "",
        reverse=True,
    )
    reusable = next(
        (
            build
            for build in candidates
            if (build.get("status") == "finished" and actions_succeeded(build))
            or (build.get("status") != "finished" and build.get("status") not in FAILURES)
        ),
        None,
    )
    if reusable is None:
        return None
    build_id = reusable.get("_id")
    if not isinstance(build_id, str) or not re.fullmatch(r"[0-9a-f]{24}", build_id):
        raise SystemExit("Codemagic returned an invalid reusable build ID")
    print(f"Codemagic reusable build: {build_id}", flush=True)
    return build_id
