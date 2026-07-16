from __future__ import annotations

import importlib.util
import pathlib
import sys
import tempfile
import unittest
from types import ModuleType
from unittest import mock

SCRIPTS = pathlib.Path(__file__).parent
sys.path.insert(0, str(SCRIPTS))


def load_script(name: str, filename: str) -> ModuleType:
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / filename)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {filename}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


import codemagic_api as codemagic
import release_metadata

release_candidate = load_script("release_candidate", "release_candidate.py")
github_candidate = load_script("find_github_candidate", "find_github_candidate.py")
testflight = load_script("publish_testflight_release", "publish-testflight-release.py")
appetize = load_script("publish_appetize_release", "publish-appetize-release.py")


class ReleaseMetadataTests(unittest.TestCase):
    def test_loads_one_release_contract(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            (root / "flutter").mkdir()
            (root / "Cargo.toml").write_text(
                '[workspace]\n[workspace.package]\nversion = "1.2.3"\n'
                '[package]\nname = "zuko"\nversion.workspace = true\n'
            )
            (root / "flutter/pubspec.yaml").write_text("version: 1.2.3+1801002003\n")
            metadata = release_metadata.load(root)
        self.assertEqual(metadata.tag, "v1.2.3")
        self.assertEqual(metadata.build_number, 1_801_002_003)
        self.assertEqual(len(release_metadata.candidate_asset_names(metadata)), 18)
        self.assertEqual(len(release_metadata.release_asset_names(metadata)), 21)

    def test_rejects_colliding_semver_components(self) -> None:
        with self.assertRaisesRegex(ValueError, "below 1000"):
            release_metadata.for_version("1.2.1000")


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
            metadata = release_candidate.release_metadata.for_version(version)
            with mock.patch.object(release_candidate, "source_metadata", return_value=metadata):
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
                (123, 456, artifact["name"], artifact["digest"]),
            )


class CodemagicTests(unittest.TestCase):
    def test_trigger_uses_exact_tag(self) -> None:
        tag = "v1.2.3"
        with mock.patch.object(
            codemagic, "request", return_value={"buildId": "b" * 24}
        ) as request:
            self.assertEqual(
                codemagic.trigger("token", "workflow", tag=tag), "b" * 24
            )
        payload = request.call_args.args[3]
        self.assertEqual(payload["tag"], tag)
        self.assertNotIn("branch", payload)

    def test_testflight_accepts_exact_tagged_build(self) -> None:
        tag = "v1.2.3"
        sha = "a" * 40
        build = {
            "_id": "b" * 24,
            "fileWorkflowId": testflight.WORKFLOW,
            "tag": tag,
            "commit": {"hash": sha},
            "status": "finished",
            "buildActions": [{"status": "success"}],
        }
        self.assertTrue(testflight.matches_release(build, tag, sha))
        testflight.validate(build, tag, sha)

    def test_appetize_reuses_only_exact_tagged_build(self) -> None:
        tag = "v1.2.3"
        sha = "a" * 40
        build = {
            "fileWorkflowId": appetize.WORKFLOW,
            "tag": tag,
            "commit": {"hash": sha},
        }
        self.assertTrue(appetize.matches_release(build, tag, sha))
        self.assertFalse(appetize.matches_release(build, tag, "b" * 40))


if __name__ == "__main__":
    unittest.main()
