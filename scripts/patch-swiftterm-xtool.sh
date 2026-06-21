#!/bin/sh
# Patch SwiftTerm's Package.swift for xtool Linux→iOS cross-compilation.
#
# Upstream SwiftTerm (1.13.0) decides which source directories to exclude based
# on the *manifest host*:
#
#   #if os(Linux) || os(Windows)
#   let platformExcludes = ["Apple", "Mac", "iOS"]
#
# That is correct for native Linux builds, but wrong for xtool: the manifest is
# evaluated on Linux while the target triple is arm64-apple-ios. SwiftTerm then
# drops Sources/SwiftTerm/iOS/iOSTerminalView.swift (which defines
# TerminalView), while TerminalViewSearch.swift still compiles under `#if os(iOS)`
# and fails with "cannot find type 'TerminalView' in scope".
#
# This patch is intentionally tiny and local to the checked-out dependency. It
# keeps Windows behavior unchanged and simply treats Linux hosts like macOS for
# manifest source exclusion in this xtool-only build path.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PKG="$ROOT/ios/.build/checkouts/SwiftTerm/Package.swift"

if [ ! -f "$PKG" ]; then
    echo "patch-swiftterm-xtool: $PKG not found — run 'swift package resolve' from ios/ first" >&2
    exit 1
fi

if grep -q '#if os(Windows)' "$PKG"; then
    echo "patch-swiftterm-xtool: already patched"
    exit 0
fi

if ! grep -q '#if os(Linux) || os(Windows)' "$PKG"; then
    echo "patch-swiftterm-xtool: expected platformExcludes conditional not found" >&2
    exit 1
fi

sed -i.bak 's/#if os(Linux) || os(Windows)/#if os(Windows)/' "$PKG"
rm -f "$PKG.bak"
echo "patch-swiftterm-xtool: patched SwiftTerm Package.swift for xtool Linux→iOS cross-compile"
