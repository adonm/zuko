#!/usr/bin/env python3
"""Resolve one successful exact-commit GitHub release-candidate artifact."""

from __future__ import annotations

import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

API = "https://api.github.com"
WORKFLOW = "build.yml"
WORKFLOW_PATH = ".github/workflows/build.yml"


def request_json(token: str, path: str) -> dict[str, object]:
    request = urllib.request.Request(
        f"{API}{path}",
        headers={
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {token}",
            "X-GitHub-Api-Version": "2022-11-28",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            value = json.load(response)
    except urllib.error.HTTPError as error:
        detail = error.read().decode(errors="replace")
        raise SystemExit(f"GitHub API {path} failed: {error.code} {detail}") from error
    if not isinstance(value, dict):
        raise SystemExit(f"GitHub API {path} returned invalid JSON")
    return value


def resolve(token: str, repository: str, sha: str) -> tuple[int, int, str]:
    query = urllib.parse.urlencode(
        {
            "branch": "main",
            "event": "push",
            "status": "success",
            "head_sha": sha,
            "per_page": 20,
        }
    )
    result = request_json(
        token,
        f"/repos/{repository}/actions/workflows/{WORKFLOW}/runs?{query}",
    )
    runs = result.get("workflow_runs")
    if not isinstance(runs, list):
        raise SystemExit("GitHub candidate run list is invalid")
    matches = []
    for run in runs:
        if not isinstance(run, dict):
            continue
        actual = {
            "conclusion": run.get("conclusion"),
            "event": run.get("event"),
            "head_branch": run.get("head_branch"),
            "head_repository": (run.get("head_repository") or {}).get("full_name"),
            "head_sha": run.get("head_sha"),
            "path": run.get("path"),
            "status": run.get("status"),
        }
        expected = {
            "conclusion": "success",
            "event": "push",
            "head_branch": "main",
            "head_repository": repository,
            "head_sha": sha,
            "path": WORKFLOW_PATH,
            "status": "completed",
        }
        if actual == expected and isinstance(run.get("id"), int):
            matches.append(run)
    name = f"zuko-release-candidate-{sha}"
    for run in matches:
        run_id = run["id"]
        artifacts = request_json(
            token, f"/repos/{repository}/actions/runs/{run_id}/artifacts?per_page=100"
        ).get("artifacts")
        if not isinstance(artifacts, list):
            raise SystemExit("GitHub candidate artifact list is invalid")
        candidates = [
            artifact
            for artifact in artifacts
            if isinstance(artifact, dict)
            and artifact.get("name") == name
            and artifact.get("expired") is False
            and isinstance(artifact.get("id"), int)
            and isinstance(artifact.get("digest"), str)
            and re.fullmatch(r"sha256:[0-9a-f]{64}", artifact["digest"])
        ]
        if len(candidates) == 1:
            return run_id, candidates[0]["id"], name
    raise SystemExit("no successful exact-commit run has one valid candidate artifact")


def main() -> None:
    if len(sys.argv) != 2 or not re.fullmatch(r"[0-9a-f]{40}", sys.argv[1]):
        raise SystemExit("usage: find_github_candidate.py <40-character-git-sha>")
    token = os.environ.get("GITHUB_TOKEN")
    repository = os.environ.get("GITHUB_REPOSITORY", "adonm/zuko")
    if not token:
        raise SystemExit("GITHUB_TOKEN is required")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        raise SystemExit(f"invalid GitHub repository: {repository}")
    run_id, artifact_id, name = resolve(token, repository, sys.argv[1])
    output = os.environ.get("GITHUB_OUTPUT")
    if output:
        with open(output, "a") as stream:
            stream.write(f"run_id={run_id}\nartifact_id={artifact_id}\nartifact_name={name}\n")
    print(f"GitHub release candidate: run {run_id}, artifact {artifact_id} ({name})")


if __name__ == "__main__":
    main()
