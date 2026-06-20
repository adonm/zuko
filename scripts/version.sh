#!/bin/sh
# Print the zuko version (X.Y.Z) from Cargo.toml — the single source of truth
# for both the CLI binary and the iOS app's MARKETING_VERSION. Used by:
#
#   - fastlane/Fastfile (xcargs MARKETING_VERSION) for signed CI builds
#   - .github/workflows/build-ios.yml (xcargs) for the simulator build
#   - scripts/release.sh already reads the same field its own way for the
#     pre-tag sanity check; this is the canonical reader for build tooling.
#
# Keeps `MARKETING_VERSION` in project.yml and the .ipa's
# CFBundleShortVersionString in lockstep with `cargo run -- --version`,
# without a second hand-maintained version string drifting.
#
# macOS sh + Linux sh + busybox ash all understand the sed/regex below.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# First `version = "…"` at column 0 in [package] is the crate version. The
# match is anchored so we don't pick up a dependency's `version = "…"`
# further down Cargo.toml.
sed -n 's|^version = "\([^"]*\)"|\1|p' "$ROOT/Cargo.toml" | head -n 1
