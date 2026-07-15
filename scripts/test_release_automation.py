from __future__ import annotations

import importlib.util
import pathlib
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


candidate = load_script(
    "check_codemagic_release_candidate",
    "check-codemagic-release-candidate.py",
)
collector = load_script("collect_codemagic_release", "collect-codemagic-release.py")


class ReleaseCandidateTests(unittest.TestCase):
    def test_reuses_successful_exact_build(self) -> None:
        builds = [
            {"_id": "a" * 24, "status": "building", "buildActions": []},
            {
                "_id": "b" * 24,
                "status": "finished",
                "buildActions": [{"status": "success"}],
            },
        ]
        with mock.patch.object(candidate, "matching_builds", return_value=builds):
            self.assertEqual(
                candidate.reusable_build("token", "flutter-windows-ci", "c" * 40),
                ("b" * 24, True),
            )

    def test_retriggers_after_failed_build(self) -> None:
        builds = [
            {
                "_id": "a" * 24,
                "status": "failed",
                "buildActions": [{"status": "failed"}],
            }
        ]
        with mock.patch.object(candidate, "matching_builds", return_value=builds):
            self.assertIsNone(
                candidate.reusable_build("token", "flutter-windows-ci", "c" * 40)
            )

    def test_trigger_targets_main(self) -> None:
        with mock.patch.object(
            candidate, "request", return_value={"buildId": "a" * 24}
        ) as request:
            candidate.trigger("token", "flutter-windows-ci")
        self.assertEqual(
            request.call_args.args[3],
            {
                "appId": candidate.APP_ID,
                "workflowId": "flutter-windows-ci",
                "branch": "main",
            },
        )


class ArtifactCollectorTests(unittest.TestCase):
    def test_reuses_successful_exact_release_build(self) -> None:
        builds = [
            {
                "_id": "a" * 24,
                "status": "finished",
                "buildActions": [{"status": "success"}],
            }
        ]
        with mock.patch.object(collector, "matching_builds", return_value=builds):
            self.assertEqual(
                collector.reusable_build(
                    "token", "flutter-windows-release", "v1.2.3", "c" * 40
                ),
                ("a" * 24, True),
            )

    def test_does_not_reuse_unsuccessful_actions(self) -> None:
        builds = [
            {
                "_id": "a" * 24,
                "status": "finished",
                "buildActions": [{"status": "failed"}],
            }
        ]
        with mock.patch.object(collector, "matching_builds", return_value=builds):
            self.assertIsNone(
                collector.reusable_build(
                    "token", "flutter-windows-release", "v1.2.3", "c" * 40
                )
            )


if __name__ == "__main__":
    unittest.main()
