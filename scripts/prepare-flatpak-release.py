#!/usr/bin/env python3
"""Set the leading Flatpak release entry from immutable release metadata."""

from __future__ import annotations

import datetime
import pathlib
import subprocess
import sys
import xml.etree.ElementTree as ET


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: prepare-flatpak-release.py <vX.Y.Z> <git-sha>")
    tag, sha = sys.argv[1:]
    epoch = int(
        subprocess.check_output(
            ["git", "show", "-s", "--format=%ct", sha], text=True
        )
    )
    path = pathlib.Path("flatpak/dev.adonm.zuko.metainfo.xml")
    tree = ET.parse(path)
    release = tree.getroot().find("releases/release")
    if release is None:
        raise SystemExit("Flatpak metainfo has no release entry")
    release.set("version", tag.removeprefix("v"))
    release.set(
        "date",
        datetime.datetime.fromtimestamp(epoch, datetime.timezone.utc).date().isoformat(),
    )
    ET.indent(tree, space="  ")
    tree.write(path, encoding="UTF-8", xml_declaration=True)
    print(epoch)


if __name__ == "__main__":
    main()
