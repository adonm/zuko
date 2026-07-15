#!/bin/sh
# Create an immutable release tag from the clean, already-pushed main branch.
# The tag triggers the coordinated GitHub Release, crate, and TestFlight jobs.
#
# Usage:
#   just release
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

if [ "$#" -ne 0 ]; then
    echo "usage: $0" >&2
    exit 2
fi

if [ -n "$(git status --porcelain)" ]; then
    echo "error: release requires a clean working tree" >&2
    git status --short >&2
    exit 1
fi

BRANCH="$(git branch --show-current)"
if [ "$BRANCH" != main ]; then
    echo "error: release must be cut from main, not '$BRANCH'" >&2
    exit 1
fi

git fetch --quiet origin main --tags
HEAD_SHA="$(git rev-parse HEAD)"
REMOTE_SHA="$(git rev-parse origin/main)"
if [ "$HEAD_SHA" != "$REMOTE_SHA" ]; then
    echo "error: HEAD $HEAD_SHA does not match origin/main $REMOTE_SHA" >&2
    exit 1
fi

python3 scripts/check-release-metadata.py
VERSION="$(scripts/version.sh)"
TAG="v$VERSION"

if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || \
   git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null 2>&1; then
    echo "error: immutable release tag already exists: $TAG" >&2
    exit 1
fi

echo "==> verifying exact-commit Codemagic release candidate"
python3 scripts/check-codemagic-release-candidate.py "$HEAD_SHA"

SHA="$(git rev-parse --short HEAD)"
echo "==> creating annotated tag $TAG at $SHA"
git tag -a "$TAG" -m "zuko $TAG

Cut from $SHA. This immutable tag triggers the coordinated GitHub Release,
crates.io publication, and signed iOS TestFlight build."

echo "==> pushing immutable tag $TAG to origin"
git push origin "$TAG"

echo
echo "done. watch the release at:"
echo "  https://github.com/adonm/zuko/actions/workflows/release.yml"
echo "  https://codemagic.io/app/6a52dc14add8531e99f88b8a"
