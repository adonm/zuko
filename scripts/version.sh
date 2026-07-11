#!/bin/sh
# Print the zuko version (X.Y.Z) from Cargo.toml — the single source of truth
# for the CLI binary and Flutter release builds. scripts/release.sh also checks
# this value before tagging; this is the canonical reader for build tooling.
#
# macOS sh + Linux sh + busybox ash all understand the sed/regex below.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# The workspace package version is the first column-zero `version = "…"`.
# The root crate inherits it through `version.workspace = true`; release checks
# require the Flutter package version to match.
# The match is anchored so dependency versions are ignored.
sed -n 's|^version = "\([^"]*\)"|\1|p' "$ROOT/Cargo.toml" | head -n 1
