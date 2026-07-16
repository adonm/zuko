#!/bin/sh
# Dispatch exact-commit candidate promotion and protected release tagging.
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

command -v gh >/dev/null 2>&1 || {
    echo "error: GitHub CLI is required to dispatch the release" >&2
    exit 1
}
gh auth status >/dev/null

SHORT_SHA="$(git rev-parse --short=12 HEAD)"
echo "==> dispatching protected release for $TAG at $SHORT_SHA"
gh workflow run release.yml \
    --repo adonm/zuko \
    --ref main \
    -f "sha=$HEAD_SHA"

echo
echo "release dispatched. No local process needs to remain running:"
echo "  https://github.com/adonm/zuko/actions/workflows/release.yml"
