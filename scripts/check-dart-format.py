#!/usr/bin/env python3
"""Check Dart formatting without modifying the source tree."""

from __future__ import annotations

import argparse
import pathlib
import subprocess


ROOT = pathlib.Path(__file__).resolve().parent.parent


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--cwd", type=pathlib.Path, default=ROOT)
    parser.add_argument("paths", nargs="+")
    options = parser.parse_args()
    cwd = options.cwd.resolve()

    command = [
        "mise",
        "exec",
        "-C",
        str(cwd),
        "--",
        "dart",
        "format",
        "--output=none",
        "--set-exit-if-changed",
        *options.paths,
    ]
    subprocess.run(command, check=True)


if __name__ == "__main__":
    main()
