#!/usr/bin/env python3
"""Prepare Flutter and libghostty for an App-Store-compatible iOS build.

libghostty compiles Ghostty's vt core with Zig. On iOS devices Zig emits a
Mach-O dylib without Apple's LC_ENCRYPTION_INFO_64 load command, which App
Store Connect rejects. This patch converts the native-assets hook so the iOS
device build relinks Zig's static `libghostty-vt.a` with Apple clang instead.

Flutter 3.48.0-0.1.pre also hardcodes native-asset framework Info.plists to an
iOS 13.0 minimum even when the binary targets iOS 18.0. Patch the pinned
Flutter generator so its framework metadata matches the linked binary.
"""

from __future__ import annotations

import json
import pathlib
import shutil
import subprocess
import sys
import urllib.parse


ROOT = pathlib.Path(__file__).resolve().parent.parent
PACKAGE_CONFIG = ROOT / "flutter/.dart_tool/package_config.json"
GHOSTTY_COMMIT = "91f66da24527fa02d92b5fd0b41cd020f553a64c"


def fail(message: str) -> None:
    print(f"libghostty iOS Apple-link setup: {message}", file=sys.stderr)
    raise SystemExit(1)


def replace_once(path: pathlib.Path, old: str, new: str) -> bool:
    text = path.read_text()
    if new in text:
        return False
    if text.count(old) != 1:
        fail(f"unexpected upstream source in {path}")
    path.write_text(text.replace(old, new))
    return True


def package_root() -> pathlib.Path:
    if not PACKAGE_CONFIG.is_file():
        fail("run `flutter pub get --enforce-lockfile` first")

    config = json.loads(PACKAGE_CONFIG.read_text())
    package = next(
        (entry for entry in config["packages"] if entry["name"] == "libghostty"),
        None,
    )
    if package is None:
        fail("libghostty is absent from Flutter's package resolution")

    root_uri = urllib.parse.urlparse(package["rootUri"])
    if root_uri.scheme != "file":
        fail(f"expected a hosted file URI, got {package['rootUri']}")
    return pathlib.Path(urllib.parse.unquote(root_uri.path))


def patch_flutter_native_assets() -> None:
    flutter = shutil.which("flutter")
    if flutter is None:
        fail("flutter is absent from PATH")
    flutter_root = pathlib.Path(flutter).resolve().parent.parent
    version_result = subprocess.run(
        [flutter, "--version", "--machine"],
        check=True,
        capture_output=True,
        text=True,
    )
    version = json.loads(version_result.stdout)["frameworkVersion"]
    if version != "3.48.0-0.1.pre":
        fail(f"the patch must be reviewed for Flutter {version}")

    native_assets = (
        flutter_root
        / "packages/flutter_tools/lib/src/isolated/native_assets/ios/native_assets.dart"
    )
    replace_once(
        native_assets,
        "const targetIOSVersion = 13;",
        "const targetIOSVersion = 18;",
    )
    (flutter_root / "bin/cache/flutter_tools.snapshot").unlink(missing_ok=True)
    (flutter_root / "bin/cache/flutter_tools.stamp").unlink(missing_ok=True)


def patch_ios_apple_link() -> None:
    package = package_root()
    pubspec = (package / "pubspec.yaml").read_text()
    if "version: 0.0.11\n" not in pubspec:
        fail("the patch must be reviewed for the resolved libghostty version")
    if (package / "ghostty.version").read_text().strip() != GHOSTTY_COMMIT:
        fail("the patch must be reviewed for the resolved Ghostty commit")

    provider = package / "lib/src/hook/library_provider.dart"
    replace_once(
        provider,
        """    final srcDir = os == .windows ? 'bin' : 'lib';
    final srcFileName = os.dylibFileName('ghostty-vt');
    final srcFile = File('${installDir.toFilePath()}/$srcDir/$srcFileName');
    if (srcFile.existsSync()) srcFile.renameSync(target.path);
""",
        """    final srcDir = os == .windows ? 'bin' : 'lib';
    final appleLinkedIos = os == .iOS && ios != .iPhoneSimulator;
    final srcFileName = appleLinkedIos
        ? 'libghostty-vt.a'
        : os.dylibFileName('ghostty-vt');
    final srcFile = File('${installDir.toFilePath()}/$srcDir/$srcFileName');

    if (appleLinkedIos && srcFile.existsSync()) {
      if (arch != Architecture.arm64) {
        throw UnsupportedError('Unsupported device iOS architecture: $arch');
      }
      target.parent.createSync(recursive: true);
      final linkResult = Process.runSync('xcrun', [
        '--sdk',
        'iphoneos',
        'clang',
        '-arch',
        'arm64',
        '-mios-version-min=18.0',
        '-dynamiclib',
        '-Wl,-force_load,${srcFile.path}',
        '-Wl,-dead_strip',
        '-Wl,-install_name,@rpath/ghostty.framework/ghostty',
        '-o',
        target.path,
      ]);
      if (linkResult.exitCode != 0) {
        throw Exception(
          'Apple clang link failed (exit code ${linkResult.exitCode}):\\n'
          'stdout: ${linkResult.stdout}\\n'
          'stderr: ${linkResult.stderr}',
        );
      }
    } else if (srcFile.existsSync()) {
      srcFile.renameSync(target.path);
    }
""",
    )


def main() -> None:
    patch_flutter_native_assets()
    patch_ios_apple_link()


if __name__ == "__main__":
    main()
