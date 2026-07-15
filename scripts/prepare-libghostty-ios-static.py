#!/usr/bin/env python3
"""Prepare Flutter and libghostty for an App-Store-compatible iOS build.

libghostty 0.0.11 bundles a Zig-linked dylib on iOS. App Store Connect rejects
that Mach-O because it lacks Apple's LC_ENCRYPTION_INFO_64 load command. The
upstream Ghostty build also emits a complete static archive. This patch compiles
that archive and relinks it into the bundled dylib with Apple clang.

Flutter 3.47.0-0.1.pre also hardcodes native-asset framework Info.plists to an
iOS 13.0 minimum even when the binary targets iOS 18.0. Patch the pinned Flutter
generator so its framework metadata matches the linked binary.
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


def replace_one_variant(path: pathlib.Path, variants: tuple[str, ...], new: str) -> None:
    text = path.read_text()
    if new in text:
        return
    matches = [variant for variant in variants if text.count(variant) == 1]
    if len(matches) != 1:
        fail(f"unexpected upstream source in {path}")
    path.write_text(text.replace(matches[0], new))


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
    if version != "3.47.0-0.1.pre":
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


def main() -> None:
    patch_flutter_native_assets()
    package = package_root()
    pubspec = (package / "pubspec.yaml").read_text()
    if "version: 0.0.11\n" not in pubspec:
        fail("the patch must be reviewed for the resolved libghostty version")
    if (package / "ghostty.version").read_text().strip() != GHOSTTY_COMMIT:
        fail("the patch must be reviewed for the resolved Ghostty commit")

    hook = package / "hook/build.dart"
    provider = package / "lib/src/hook/library_provider.dart"

    replace_once(
        hook,
        """  final targetOS = input.config.code.targetOS;
  final staticIos = targetOS == OS.iOS;
  final libFileName = staticIos
      ? 'libghostty.a'
      : targetOS.dylibFileName('ghostty');
""",
        """  final targetOS = input.config.code.targetOS;
  final libFileName = targetOS.dylibFileName('ghostty');
""",
    )
    replace_once(
        hook,
        """  if (targetOS == OS.iOS && !staticIos) fixIosPageAlignment(libFile);

  output.assets.code.add(
    CodeAsset(
      package: input.packageName,
      name: 'libghostty.dart',
      linkMode: staticIos ? StaticLinking() : DynamicLoadingBundled(),
      file: libFile.uri,
    ),
  );
""",
        """  if (targetOS == OS.iOS) fixIosPageAlignment(libFile);

  output.assets.code.add(
    CodeAsset(
      package: input.packageName,
      name: 'libghostty.dart',
      linkMode: DynamicLoadingBundled(),
      file: libFile.uri,
    ),
  );
""",
    )
    replace_once(
        provider,
        """    final source = input.userDefines['source'];

    if (source == 'compile') {
""",
        """    final source = input.userDefines['source'];

    if (source == 'compile' || input.config.code.targetOS == OS.iOS) {
""",
    )
    replace_once(
        provider,
        """    final zig = zigTarget(os, arch, iOSSdk: ios);
""",
        """    final baseZigTarget = zigTarget(os, arch, iOSSdk: ios);
    final zig = os == .iOS && ios != .iPhoneSimulator
        ? '$baseZigTarget.18.0'
        : baseZigTarget;
""",
    )
    replace_one_variant(
        provider,
        (
            """    final srcDir = os == .windows ? 'bin' : 'lib';
    final srcFileName = os.dylibFileName('ghostty-vt');
    final srcFile = File('${installDir.toFilePath()}/$srcDir/$srcFileName');
    if (srcFile.existsSync()) srcFile.renameSync(target.path);
""",
            """    final srcDir = os == .windows ? 'bin' : 'lib';
    final staticIos = os == .iOS && target.path.endsWith('.a');
    final srcFileName = staticIos
        ? 'libghostty-vt.a'
        : os.dylibFileName('ghostty-vt');
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
      final result = Process.runSync('xcrun', [
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
      if (result.exitCode != 0) {
        throw Exception(
          'Apple clang link failed (exit code ${result.exitCode}):\\n'
          'stdout: ${result.stdout}\\n'
          'stderr: ${result.stderr}',
        );
      }
    } else if (srcFile.existsSync()) {
      srcFile.renameSync(target.path);
    }
""",
        ),
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

    print(f"libghostty iOS Apple-link setup: patched {package}")


if __name__ == "__main__":
    main()
