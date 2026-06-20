#!/bin/sh
# Build Zuko.xcframework + regenerate the Swift bindings for the iOS app.
# macOS only (needs Xcode for `xcodebuild -create-xcframework` + the iOS
# targets for cross-compilation).
#
# Run locally before opening Xcode, or in CI (build-ios.yml runs this before
# xcodegen). Produces:
#   ios/ZukoFFI/Zuko.xcframework        — the binary framework (gitignored)
#   ios/ZukoFFI/Sources/ZukoFFI/ZukoFFI.swift — regenerated bindings
#
# Mirrors iroh-ffi's make_swift.sh: framework bundles (not bare .a), so the
# `import zukoFFI` sub-module resolves through the framework modulemap.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

FRAMEWORK_NAME="ZukoRust"  # not "Zuko" — the iOS app target is also `Zuko`,
                           # so a framework of the same name creates a module
                           # dependency cycle. Distinct name, same pattern as
                           # iroh-ffi (framework `Iroh` ≠ consumer app name).
LIB_NAME="zuko"
OUT_DIR="$ROOT/ios/ZukoFFI"
TARGET_DIR=$(cargo metadata --format-version 1 --no-deps | python3 -c 'import json,sys;print(json.load(sys.stdin)["target_directory"])')

# iOS deployment target — must match the ZukoFFI Package.swift platforms and
# iroh-ffi's (17.5). The N0 relay stack (nw_path_is_ultra_constrained) needs it.
export IPHONEOS_DEPLOYMENT_TARGET="17.5"

# Ensure the iOS targets are installed (no-op if already present).
for target in aarch64-apple-ios x86_64-apple-ios aarch64-apple-ios-sim; do
    rustup target add "$target" 2>/dev/null || true
done

# 1. Build staticlibs for each iOS slice. `--lib` skips the binary target
#    (main.rs would fail to cross-compile — it imports desktop-only deps).
#    Target-cfg in Cargo.toml keeps portable-pty/crossterm/clap/etc. out of
#    the iOS build, so only `code.rs` + `ffi.rs` + their deps compile.
echo "==> cargo build --lib --release for iOS targets"
cargo build --lib --release --target aarch64-apple-ios
cargo build --lib --release --target aarch64-apple-ios-sim
cargo build --lib --release --target x86_64-apple-ios

# 2. Build a host staticlib so uniffi-bindgen can read the crate metadata.
#    (--library mode works against a staticlib; no cdylib needed.)
echo "==> cargo build --lib --release (host, for bindgen metadata)"
cargo build --lib --release

# 3. Regenerate Swift bindings + C header + modulemap.
echo "==> generating Swift bindings via uniffi-bindgen"
BINDGEN_OUT="$OUT_DIR/Generated"
rm -rf "$BINDGEN_OUT"
mkdir -p "$BINDGEN_OUT"
cargo run --bin uniffi-bindgen -- generate \
    --language swift \
    --out-dir "$BINDGEN_OUT" \
    --library "$TARGET_DIR/release/lib${LIB_NAME}.a" \
    --config uniffi.toml

# Copy the generated Swift into the package source target (committed; matches
# the iroh-ffi pattern — deterministic output, regenerated when the FFI changes).
# Rewrite the C module name (`zukoFFI`) to the framework name (`Zuko`) so
# `#if canImport(Zuko)` / `import Zuko` resolve against the framework's
# modulemap — mirrors iroh-ffi's `make_swift.sh` line 106. Without this, the
# generated `canImport(zukoFFI)` check fails (there's no top-level `zukoFFI`
# module — it's a sub-module of the `Zuko` framework), and RustBuffer /
# RustCallStatus / the FFI functions all go "not found in scope".
sed "s/${LIB_NAME}FFI/$FRAMEWORK_NAME/g" "$BINDGEN_OUT/${LIB_NAME}.swift" \
    > "$OUT_DIR/Sources/ZukoFFI/ZukoFFI.swift"

# 4. Build a fat sim lib (arm64-sim + x86_64-sim) via lipo.
echo "==> creating fat simulator library"
SIM_UNIVERSAL="$TARGET_DIR/sim-universal-${LIB_NAME}.a"
lipo -create \
    "$TARGET_DIR/aarch64-apple-ios-sim/release/lib${LIB_NAME}.a" \
    "$TARGET_DIR/x86_64-apple-ios/release/lib${LIB_NAME}.a" \
    -output "$SIM_UNIVERSAL"

# 5. Assemble .framework bundles for each slice. The structure mirrors
#    iroh-ffi's: an umbrella Export.h + module.modulemap that turns the FFI
#    header into a sub-module the generated Swift can `import zukoFFI`.
create_framework() {
    fw_dir="$1"
    binary="$2"
    mkdir -p "$fw_dir/Headers" "$fw_dir/Modules"
    # The framework "binary" is the staticlib renamed. XCFramework wraps it
    # as a static framework (the consumer links it at build time).
    cp "$binary" "$fw_dir/$FRAMEWORK_NAME"
    # C header from uniffi-bindgen.
    cp "$BINDGEN_OUT/${LIB_NAME}FFI.h" "$fw_dir/Headers/"
    # Umbrella header so the modulemap can export everything via one entry.
    cat > "$fw_dir/Headers/Export.h" <<EOF
#import "${LIB_NAME}FFI.h"
EOF
    # `framework module Zuko { umbrella header "Export.h"; module * { export * } }`
    # creates a sub-module per header — so `zukoFFI.h` becomes importable as
    # `import zukoFFI`, which is what the generated Swift bindings expect.
    cat > "$fw_dir/Modules/module.modulemap" <<EOF
framework module $FRAMEWORK_NAME {
    umbrella header "Export.h"
    export *
    module * { export * }
}
EOF
    # Minimal Info.plist — xcodebuild -create-xcframework requires one.
    cat > "$fw_dir/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleExecutable</key><string>$FRAMEWORK_NAME</string>
<key>CFBundleIdentifier</key><string>dev.adonm.$FRAMEWORK_NAME</string>
<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
<key>CFBundleName</key><string>$FRAMEWORK_NAME</string>
<key>CFBundlePackageType</key><string>FMWK</string>
<key>CFBundleVersion</key><string>1.0</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
</dict>
</plist>
EOF
}

XCFW="$OUT_DIR/$FRAMEWORK_NAME.xcframework"
rm -rf "$XCFW"

# Stage the framework slices in a temp dir, NOT inside $XCFW —
# `xcodebuild -create-xcframework` copies its inputs into the output, so
# pre-creating them inside the output path collides on the second run.
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

echo "==> assembling framework slices"
create_framework \
    "$STAGE/ios-arm64/$FRAMEWORK_NAME.framework" \
    "$TARGET_DIR/aarch64-apple-ios/release/lib${LIB_NAME}.a"
create_framework \
    "$STAGE/ios-arm64_x86_64-simulator/$FRAMEWORK_NAME.framework" \
    "$SIM_UNIVERSAL"

# 6. Bundle into an XCFramework. xcodebuild copies the framework slices from
#    the staging dir into $XCFW, producing the canonical layout.
echo "==> xcodebuild -create-xcframework"
xcodebuild -create-xcframework \
    -framework "$STAGE/ios-arm64/$FRAMEWORK_NAME.framework" \
    -framework "$STAGE/ios-arm64_x86_64-simulator/$FRAMEWORK_NAME.framework" \
    -output "$XCFW" \
    >/dev/null

echo
echo "done."
echo "  XCFramework:  $XCFW"
echo "  Swift source: $OUT_DIR/Sources/ZukoFFI/ZukoFFI.swift"
echo
echo "The XCFramework is gitignored (rebuilt on demand). The Swift bindings"
echo "are committed (deterministic output). Next: open Xcode / run xcodegen."
