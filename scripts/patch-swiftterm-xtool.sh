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
# This patch is intentionally tiny and local to the checked-out dependency:
#   1. Treat Linux hosts like macOS for manifest source exclusion.
#   2. Disable SwiftUI `#Preview` blocks when the Linux SDK bundle lacks
#      Apple's PreviewsMacros plugin.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PKG="$ROOT/ios/.build/checkouts/SwiftTerm/Package.swift"

if [ ! -f "$PKG" ]; then
    echo "patch-swiftterm-xtool: $PKG not found — run 'swift package resolve' from ios/ first" >&2
    exit 1
fi

changed=0

if grep -q '#if os(Linux) || os(Windows)' "$PKG"; then
    sed -i.bak 's/#if os(Linux) || os(Windows)/#if os(Windows)/' "$PKG"
    rm -f "$PKG.bak"
    changed=1
elif grep -q '#if os(Windows)' "$PKG"; then
    :
elif grep -q 'let platformExcludes = \["Apple", "Mac", "iOS"\]' "$PKG"; then
    # The Linux host conditional should have been the only reason for this
    # exclude list in xtool's iOS cross-build. If the exact conditional is gone
    # but the exclude list remains, fail loudly instead of silently compiling a
    # broken SwiftTerm checkout.
    echo "patch-swiftterm-xtool: platformExcludes still excludes Apple/iOS, but expected conditional was not found" >&2
    exit 1
fi

for swift_file in \
    "$ROOT/ios/.build/checkouts/SwiftTerm/Sources/SwiftTerm/Apple/AppleTerminalView.swift" \
    "$ROOT/ios/.build/checkouts/SwiftTerm/Sources/SwiftTerm/iOS/iOSTerminalView.swift"; do
    [ -f "$swift_file" ] || continue
    if grep -q '#if canImport(UIKit) && DEBUG$' "$swift_file"; then
        sed -i.bak 's/#if canImport(UIKit) && DEBUG$/#if canImport(UIKit) \&\& DEBUG \&\& canImport(PreviewsMacros)/' "$swift_file"
        rm -f "$swift_file.bak"
        changed=1
    fi
done

if [ "$changed" -eq 0 ]; then
    echo "patch-swiftterm-xtool: already patched"
else
    echo "patch-swiftterm-xtool: patched SwiftTerm for xtool Linux→iOS cross-compile"
fi
