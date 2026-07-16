#!/usr/bin/env python3
"""Fail when release-facing package versions drift from the workspace version."""

from __future__ import annotations

import release_metadata


def main() -> None:
    try:
        metadata = release_metadata.load()
    except (KeyError, OSError, TypeError, ValueError) as error:
        raise SystemExit(f"release metadata: {error}") from error
    print(f"release metadata: all package versions are {metadata.version}")


if __name__ == "__main__":
    main()
