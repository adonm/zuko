from __future__ import annotations

import importlib.util
import json
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


candidate = load_script(
    "check_codemagic_release_candidate",
    "check-codemagic-release-candidate.py",
)
collector = load_script("collect_codemagic_release", "collect-codemagic-release.py")
sdk_installer = load_script("install_flutter_sdk", "install_flutter_sdk.py")


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


class FlutterSdkInstallerTests(unittest.TestCase):
    def test_precaches_each_hosts_supported_platforms(self) -> None:
        expected_flags = {
            "linux": ("--android", "--linux", "--web"),
            "macos": ("--ios", "--macos"),
            "windows": ("--windows",),
        }
        version = json.dumps(
            {
                "frameworkVersion": sdk_installer.FLUTTER_FRAMEWORK_VERSION,
                "frameworkRevision": sdk_installer.FLUTTER_SDK_REVISION,
                "engineRevision": sdk_installer.FLUTTER_ENGINE_REVISION,
                "dartSdkVersion": sdk_installer.DART_SDK_VERSION,
            }
        )
        for host, flags in expected_flags.items():
            with self.subTest(host=host), tempfile.TemporaryDirectory() as temporary:
                sdk = pathlib.Path(temporary)
                stamp = sdk / "bin/cache/engine.stamp"
                stamp.parent.mkdir(parents=True)
                stamp.write_text(sdk_installer.PRECACHE_ENGINE_CONTENT_HASH)
                calls: list[tuple[str, ...]] = []

                def fake_run(*args: str, **kwargs: object) -> str:
                    calls.append(args)
                    environment = kwargs.get("environment")
                    self.assertIsInstance(environment, dict)
                    self.assertEqual(
                        environment.get("FLUTTER_PREBUILT_ENGINE_VERSION"),
                        sdk_installer.PRECACHE_ENGINE_CONTENT_HASH,
                    )
                    return version if "--version" in args else ""

                with mock.patch.object(sdk_installer, "run", side_effect=fake_run):
                    sdk_installer.prepare_sdk(sdk, host)

                precache = next(call for call in calls if "precache" in call)
                self.assertEqual(precache[-len(flags) :], flags)


if __name__ == "__main__":
    unittest.main()
