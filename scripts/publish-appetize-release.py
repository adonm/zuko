#!/usr/bin/env python3
"""Trigger and verify the Codemagic Appetize workflow for one release."""

from __future__ import annotations

import json
import os
import re
import sys
import time
import urllib.error
import urllib.request

APP_ID = "6a52dc14add8531e99f88b8a"
API = "https://api.codemagic.io"
WORKFLOW = "mobile-appetize-release"
FAILURES = {"canceled", "cancelled", "failed", "skipped"}
NOT_FOUND_RETRY_SECONDS = 60


def request(
    token: str,
    method: str,
    path: str,
    payload: object | None = None,
    *,
    retry_not_found: bool = False,
) -> dict:
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


def main() -> None:
    usage = "publish-appetize-release.py <vX.Y.Z> <git-sha>"
    if len(sys.argv) != 3:
        raise SystemExit(f"usage: {usage}")
    tag, sha = sys.argv[1:3]
    if not re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", tag):
        raise SystemExit(f"invalid release tag: {tag}")
    if not re.fullmatch(r"[0-9a-f]{40}", sha):
        raise SystemExit(f"invalid release commit: {sha}")
    token = os.environ.get("CODEMAGIC_API_TOKEN")
    if not token:
        raise SystemExit("CODEMAGIC_API_TOKEN is required")

    payload: dict[str, object] = {
        "appId": APP_ID,
        "workflowId": WORKFLOW,
        "tag": tag,
    }
    result = request(token, "POST", "/builds", payload)
    build_id = result.get("buildId")
    if not isinstance(build_id, str) or not re.fullmatch(r"[0-9a-f]{24}", build_id):
        raise SystemExit("Codemagic returned an invalid Appetize build ID")
    print(f"Codemagic Appetize build: {build_id}", flush=True)

    deadline = time.monotonic() + 120 * 60
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
                f"Codemagic Appetize build {build_id} ended as {status}: "
                f"{build.get('message') or 'no failure message'}"
            )
        time.sleep(20)
    else:
        raise SystemExit(f"Codemagic Appetize build {build_id} timed out")

    if build.get("fileWorkflowId") != WORKFLOW:
        raise SystemExit(f"Codemagic build {build_id} used the wrong workflow")
    commit = build.get("commit")
    if not isinstance(commit, dict):
        raise SystemExit(f"Codemagic build {build_id} has no commit identity")
    if build.get("tag") != tag or commit.get("hash") != sha:
        raise SystemExit(f"Codemagic build {build_id} did not use {tag} at {sha}")
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
    print(f"Appetize previews accepted for {tag}: {build_id}", flush=True)


if __name__ == "__main__":
    main()
