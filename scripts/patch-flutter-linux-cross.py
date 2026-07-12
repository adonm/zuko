#!/usr/bin/env python3
"""Enable Flutter's implemented x64-to-arm64 Linux cross-build path."""

from __future__ import annotations

import pathlib
import sys


GUARD = """    // TODO(fujino): https://github.com/flutter/flutter/issues/74929
    if (_operatingSystemUtils.hostPlatform == HostPlatform.linux_x64 &&
        targetPlatform == TargetPlatform.linux_arm64) {
      throwToolExit(
        'Cross-build from Linux x64 host to Linux arm64 target is not currently supported.',
      );
    }
"""
PATCH = "    // Zuko enables the implemented x64-to-arm64 cross-build path.\n"


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: patch-flutter-linux-cross.py <flutter-executable>")
    root = pathlib.Path(sys.argv[1]).resolve().parents[1]
    path = root / "packages/flutter_tools/lib/src/commands/build_linux.dart"
    source = path.read_text()
    if GUARD in source:
        path.write_text(source.replace(GUARD, PATCH, 1))
        print(f"patched {path}")
    elif PATCH not in source:
        raise SystemExit(f"Flutter Linux cross-build guard changed: {path}")
    (root / "bin/cache/flutter_tools.stamp").unlink(missing_ok=True)


if __name__ == "__main__":
    main()
