from __future__ import annotations

import importlib.util
import pathlib
import tempfile
import unittest
from types import ModuleType
from unittest import mock

SCRIPTS = pathlib.Path(__file__).parent


def load_script(name: str, filename: str) -> ModuleType:
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / filename)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {filename}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


release_candidate = load_script("release_candidate", "release_candidate.py")
github_candidate = load_script("find_github_candidate", "find_github_candidate.py")
ios_candidate = load_script("prepare_ios_candidate", "prepare_ios_candidate.py")
testflight = load_script("publish_testflight_release", "publish-testflight-release.py")


class ReleaseCandidateManifestTests(unittest.TestCase):
    def test_manifest_binds_every_expected_artifact(self) -> None:
        version = "1.2.3"
        sha = "a" * 40
        with tempfile.TemporaryDirectory() as temporary:
            directory = pathlib.Path(temporary)
            names = release_candidate.expected_names(version)
            for name in names:
                if not name.endswith(".sha256"):
                    (directory / name).write_bytes(name.encode())
            for name in names:
                if name.endswith(".sha256"):
                    payload = directory / name.removesuffix(".sha256")
                    digest = release_candidate.sha256(payload)
                    (directory / name).write_text(f"{digest}  {payload.name}\n")
            with mock.patch.object(
                release_candidate, "source_version", return_value=version
            ):
                release_candidate.create(directory, directory, sha)
                release_candidate.verify(directory, directory, sha)
            manifest = directory / "release-candidate.json"
            self.assertTrue(manifest.is_file())


class GithubCandidateTests(unittest.TestCase):
    def test_resolves_one_exact_successful_run_and_artifact(self) -> None:
        sha = "a" * 40
        repository = "adonm/zuko"
        run = {
            "id": 123,
            "conclusion": "success",
            "event": "push",
            "head_branch": "main",
            "head_repository": {"full_name": repository},
            "head_sha": sha,
            "path": ".github/workflows/build.yml",
            "status": "completed",
        }
        artifact = {
            "id": 456,
            "name": f"zuko-release-candidate-{sha}",
            "expired": False,
            "digest": "sha256:" + "b" * 64,
        }
        with mock.patch.object(
            github_candidate,
            "request_json",
            side_effect=[{"workflow_runs": [run]}, {"artifacts": [artifact]}],
        ):
            self.assertEqual(
                github_candidate.resolve("token", repository, sha),
                (123, 456, artifact["name"]),
            )


class IosCandidateTests(unittest.TestCase):
    def test_trigger_uses_exact_temporary_branch(self) -> None:
        tag = "v1.2.3"
        sha = "a" * 40
        branch = f"release-candidate/{tag}-{sha[:12]}"
        with mock.patch.object(
            ios_candidate, "request", return_value={"buildId": "b" * 24}
        ) as request:
            self.assertEqual(
                ios_candidate.trigger("token", tag, sha, branch), "b" * 24
            )
        payload = request.call_args.args[3]
        self.assertEqual(payload["branch"], branch)
        self.assertEqual(
            payload["environment"]["variables"]["RELEASE_CANDIDATE_SHA"], sha
        )

    def test_accepts_one_direct_ipa_artifact(self) -> None:
        tag = "v1.2.3"
        sha = "a" * 40
        branch = f"release-candidate/{tag}-{sha[:12]}"
        build = {
            "_id": "b" * 24,
            "fileWorkflowId": ios_candidate.WORKFLOW,
            "branch": branch,
            "tag": None,
            "commit": {"hash": sha},
            "status": "finished",
            "buildActions": [{"status": "success"}],
            "artefacts": [
                {
                    "name": "Zuko-Flutter.ipa",
                    "type": "ipa",
                    "url": "https://example.invalid/Zuko-Flutter.ipa",
                },
                {
                    "name": "zuko_artifacts.zip",
                    "type": "bundle",
                    "url": "https://example.invalid/zuko_artifacts.zip",
                },
            ],
        }
        with mock.patch.object(
            ios_candidate, "request", return_value={"build": build}
        ):
            self.assertEqual(
                ios_candidate.wait_for_build(
                    "token", "b" * 24, tag, sha, branch
                ),
                build,
            )

    def test_testflight_reuses_signed_branch_candidate(self) -> None:
        tag = "v1.2.3"
        sha = "a" * 40
        build = {
            "_id": "b" * 24,
            "fileWorkflowId": testflight.VALIDATION_WORKFLOW,
            "branch": f"release-candidate/{tag}-{sha[:12]}",
            "tag": None,
            "commit": {"hash": sha},
            "status": "finished",
            "buildActions": [{"status": "success"}],
            "finishedAt": "2026-01-01T00:00:00Z",
        }
        with mock.patch.object(
            testflight,
            "request",
            return_value={"builds": [build], "nextPageUrl": None},
        ):
            self.assertEqual(
                testflight.reusable_build(
                    "token", testflight.VALIDATION_WORKFLOW, tag, sha
                ),
                ("b" * 24, True),
            )


if __name__ == "__main__":
    unittest.main()
