#!/bin/sh
# Cut a zuko release by tagging `v<version>` and pushing it.
#
# The tag push triggers .github/workflows/release.yml, which cross-compiles
# the CLI for Linux/macOS and the Flutter client for Android/Linux/Windows.
# CLI tarballs are what `mise use --global github:adonm/zuko` consumes. The end
# user then runs `zuko install` to set up the host daemon as a user service.
#
# Usage:
#   just release v0.1.0
#   sh scripts/release.sh v0.1.0
#
# What this does, in order:
#   1. Normalise the argument to `vX.Y.Z`.
#   2. Check it matches the version in Cargo.toml (so we never tag a
#      version the binary doesn't report).
#   3. Refuse if the tag already exists locally or on the remote.
#   4. Warn (but proceed) if the working tree is dirty or the branch isn't
#      `main` — both are usually mistakes, but legitimate in a pinch.
#   5. Create an annotated tag and push it to origin.
#   6. Print the Actions run URL so you can watch the build.
set -eu

# Locate the repo root (this script lives in scripts/).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

if [ "$#" -ne 1 ]; then
    echo "usage: $0 <version>   (e.g. v0.1.0)" >&2
    exit 2
fi

# Normalise to a leading `v`.
ARG="$1"
case "$ARG" in
    v*) TAG="$ARG" ;;
    *)  TAG="v$ARG" ;;
esac
VERSION="${TAG#v}"  # strip the leading v for the Cargo.toml comparison

# Verify the tag matches the version cargo would report. Catches the classic
# "tagged v0.1.0 but forgot to bump Cargo.toml from 0.0.9" mistake.
CARGO_VERSION="$(sed -n 's/^version = "\(.*\)"$/\1/p' "$ROOT/Cargo.toml" | head -1)"
if [ "$VERSION" != "$CARGO_VERSION" ]; then
    echo "error: requested tag $TAG but Cargo.toml has version \"$CARGO_VERSION\"" >&2
    echo "       bump Cargo.toml to version = \"$VERSION\" before tagging, or pass" >&2
    echo "       v$CARGO_VERSION to tag the current version." >&2
    exit 1
fi

# Refuse to clobber an existing tag (local or remote).
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    echo "error: tag $TAG already exists locally" >&2
    git tag -n9 "$TAG" | sed 's/^/       existing: /' >&2
    exit 1
fi
if git ls-remote --tags origin "refs/tags/$TAG" | grep -q "$TAG"; then
    echo "error: tag $TAG already exists on origin" >&2
    exit 1
fi

# Soft warning for off-main — usually an accident, but legitimate in a pinch.
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [ "$BRANCH" != "main" ]; then
    echo "warning: on branch '$BRANCH', not 'main' — continuing in 2s..." >&2
    sleep 2
fi

# Commit-and-push everything pending before tagging. The tag references a
# commit, and the release workflow checks the tag out on a fresh runner — so
# the commit must be on the remote before `git push origin $TAG`. Staging
# everything also catches the classic "tagged but forgot to commit the
# Cargo.toml bump" mistake structurally (not just via the version check above).
if [ -n "$(git status --porcelain)" ]; then
    echo "==> working tree has uncommitted changes; staging + committing as 'release $TAG'"
    git add -A
    git commit -m "release $TAG

Bundle pending work for the $TAG release. Cut by scripts/release.sh;
the tag push triggers .github/workflows/release.yml, which publishes
CLI binaries plus Flutter Android/Linux/Windows clients to the GitHub Release
attached to $TAG."
fi

# Make sure the branch (and any commit we just made) is on the remote before
# the tag references it from there.
echo "==> pushing $BRANCH to origin"
git push origin "$BRANCH"

# HEAD short sha for the annotation (may have just moved).
SHA="$(git rev-parse --short HEAD)"

echo "==> creating annotated tag $TAG at $SHA (Cargo.toml version $CARGO_VERSION)"
git tag -a "$TAG" -m "zuko $TAG

Cut from $SHA. The tag push triggers .github/workflows/release.yml, which
publishes CLI binaries plus Flutter Android/Linux/Windows clients to the GitHub
Release attached to this tag."

echo "==> pushing $TAG to origin"
git push origin "$TAG"

echo
echo "done. watch the build at:"
echo "  https://github.com/adonm/zuko/actions/workflows/release.yml"
echo
echo "once it finishes, the release lives at:"
echo "  https://github.com/adonm/zuko/releases/tag/$TAG"
echo
echo "and \`mise use --global github:adonm/zuko\` will start working."
