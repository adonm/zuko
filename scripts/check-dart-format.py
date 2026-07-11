#!/usr/bin/env python3
"""Format Dart sources and fail only when their bytes actually change."""

from __future__ import annotations

import argparse
import hashlib
import pathlib
import subprocess


ROOT = pathlib.Path(__file__).resolve().parent.parent


def digest(path: pathlib.Path) -> bytes:
    return hashlib.sha256(path.read_bytes()).digest()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--cwd", type=pathlib.Path, default=ROOT)
    parser.add_argument("paths", nargs="+")
    options = parser.parse_args()
    cwd = options.cwd.resolve()

    files: list[pathlib.Path] = []
    for value in options.paths:
        path = (cwd / value).resolve()
        if path.is_dir():
            files.extend(sorted(path.rglob("*.dart")))
        elif path.suffix == ".dart":
            files.append(path)
    before = {path: digest(path) for path in files}

    command = [
        "mise",
        "exec",
        "-C",
        str(cwd),
        "--",
        "dart",
        "format",
        "--output=none",
        *options.paths,
    ]
    subprocess.run(command, check=True)

    changed = [path for path, old_digest in before.items() if digest(path) != old_digest]
    if changed:
        for path in changed:
            print(f"Dart formatting changed {path.relative_to(ROOT)}", file=sys.stderr)
        raise SystemExit(1)


if __name__ == "__main__":
    main()
