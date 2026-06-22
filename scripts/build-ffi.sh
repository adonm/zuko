#!/bin/sh
# Build ZukoRust.xcframework + regenerate the Swift bindings for the iOS app.
# Cross-platform: runs on macOS (uses xcodebuild when available) and on
# Linux (manual XCFramework assembly; simulator slices require llvm-lipo).
# `scripts/build-ios-xtool.sh` sets ZUKO_FFI_DEVICE_ONLY=1 for xtool's default
# device build, keeping local/Linux smoke builds small and avoiding llvm-lipo.
#
# Run locally before opening Xcode, or in CI (build-ios.yml runs this before
# `xtool dev build`). Produces:
#   ios/ZukoFFI/ZukoRust.xcframework        — the binary framework (gitignored)
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

# iOS deployment target — must match the ZukoFFI/ios Package.swift platforms
# and iroh-ffi's binary floor (26.5: iroh-ffi 1.0 was built against the iOS
# 26.5 SDK; building our staticlib against a lower target makes ld64.lld warn
# that our object files have an older version than the app's minimum).
export IPHONEOS_DEPLOYMENT_TARGET="26.5"

DEVICE_ONLY="${ZUKO_FFI_DEVICE_ONLY:-0}"

# Ensure the iOS targets are installed (no-op if already present).
rustup target add aarch64-apple-ios 2>/dev/null || true
if [ "$DEVICE_ONLY" != "1" ]; then
    rustup target add x86_64-apple-ios aarch64-apple-ios-sim 2>/dev/null || true
fi

# 1. Build staticlibs for each iOS slice. `--lib` skips the binary target
#    (main.rs would fail to cross-compile — it imports desktop-only deps).
#    Target-cfg in Cargo.toml keeps portable-pty/crossterm/clap/etc. out of
#    the iOS build, so only `code.rs` + `ffi.rs` + their deps compile.
#
# Symbol localization (the real fix for the iroh-ffi link conflict):
# iroh-ffi ships Iroh.framework as a static archive that includes Rust's
# std library object files (containing `_rust_eh_personality`, `_rust_alloc`,
# etc.). Our libzuko.a ALSO pulls in std for `code::derive_key`. When both
# archives are linked into the iOS app, Apple's linker sees duplicate
# definitions and errors out:
#     duplicate symbol '_rust_eh_personality' in:
#         ZukoRust.framework/ZukoRust[...](std-...rcgu.o)
#         Iroh.framework/Iroh[...](iroh_ffi...-cgu.12.rcgu.o)
#
# panic=abort on our side doesn't help — std itself is compiled with
# unwind regardless of our crate's panic strategy. llvm-objcopy's
# --wildcard-localize-symbol='_rust_*' is the principled fix: it marks
# every Rust-internal std symbol in OUR archive as local (non-exported),
# so the linker resolves them all from iroh-ffi's archive. Safe because
# ZukoRust's FFI surface (code::derive_key) only exchanges byte arrays
# — no complex Rust types cross the boundary, so allocator/object-file
# representation mismatches between two std copies can't bite.
#
# Our own `zuko_*` exports (the uniffi-generated FFI surface in ffi.rs)
# don't match the `_rust_*` glob, so they stay externally visible.
echo "==> cargo build --lib --release for iOS targets + localize std symbols"
OBJCOPY="$(rustup which --toolchain "$(rustup show active-toolchain | cut -d' ' -f1)" llvm-objcopy 2>/dev/null || true)"
if [ -z "$OBJCOPY" ]; then
    rustup component add llvm-tools-preview >/dev/null
    OBJCOPY="$(find "$(rustup show home)/toolchains" -name llvm-objcopy -type f | head -1)"
fi
echo "    using: $OBJCOPY"

build_and_localize() {
    target="$1"
    cargo build --lib --release --target "$target"
    lib="target/$target/release/lib${LIB_NAME}.a"
    # llvm-objcopy uses `--wildcard` as a separate flag to enable glob
    # matching in the other arguments (NOT a `--wildcard-` prefix on
    # each flag, which the tool rejects as unknown). Wildcards need LLVM
    # 10+; Rust 1.96 ships LLVM 19, so plenty of headroom.
    #
    # NOTE: this is a real localizing pass on Darwin (where llvm-objcopy
    # handles Mach-O), but a SILENT NO-OP on Linux — llvm-objcopy's
    # --localize-symbol path only mutates ELF, not Mach-O. The sanity
    # check below detects both cases and reacts per-host:
    #   Darwin  → classic ld64 errors on duplicate `_rust_*` definitions
    #             between our archive and Iroh.framework; localization
    #             must take effect, so an unlocalized symbol is fatal.
    #   Linux   → SwiftPM/xtool links via ld64.lld, which tolerates
    #             duplicate globals from static archives (first def
    #             wins). The no-op is safe; we log and continue.
    "$OBJCOPY" --wildcard \
        --localize-symbol='_rust_*' \
        --localize-symbol='__rust_*' \
        "$lib" 2>/dev/null || true
    # Sanity check: count object files where _rust_eh_personality is
    # still global (uppercase 'T'). After localization, it should be
    # either lowercase 't' (localized) or 'U' (undefined — referenced
    # from our other object files, resolved from Iroh.framework at link
    # time). awk handles nm's column layout robustly regardless of
    # whether the address column is present; previous grep+sort pipeline
    # produced newline-joined 'T\nU' that the case statement couldn't
    # match against its space-separated literals.
    globals=$(nm "$lib" 2>/dev/null \
        | awk '$0 ~ /^[0-9a-f]+ T _rust_eh_personality$/ { n++ } END { print n+0 }')
    if [ "$globals" -eq 0 ]; then
        echo "    $target: _rust_eh_personality localized"
    else
        case "$(uname -s)" in
            Darwin)
                echo "    $target: ERROR — _rust_eh_personality still global in $globals object file(s);" >&2
                echo "             llvm-objcopy failed to localize; classic ld64 will reject the duplicate" >&2
                echo "             vs. Iroh.framework. Update Xcode's llvm-tools or use nmedit." >&2
                exit 1
                ;;
            *)
                echo "    $target: _rust_eh_personality still global in $globals object file(s) —"
                echo "             llvm-objcopy can't localize Mach-O on $(uname -s); ld64.lld"
                echo "             (SwiftPM/xtool) tolerates the duplicate vs. Iroh.framework, continuing"
                ;;
        esac
    fi
}

build_and_localize aarch64-apple-ios
if [ "$DEVICE_ONLY" != "1" ]; then
    build_and_localize aarch64-apple-ios-sim
    build_and_localize x86_64-apple-ios
else
    echo "==> ZUKO_FFI_DEVICE_ONLY=1: skipping simulator Rust slices"
fi

# 2. Build a host staticlib so uniffi-bindgen can read the crate metadata.
#    (--library mode works against a staticlib; no cdylib needed.)
#    No panic=abort here — the host build is for bindgen metadata only,
#    never linked into the iOS app, so the duplicate-symbol concern
#    doesn't apply and matching Cargo.toml's release profile keeps the
#    two builds (iOS and host) bit-compatible for metadata reads.
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

if [ "$DEVICE_ONLY" != "1" ]; then
    # 4. Build a fat sim lib (arm64-sim + x86_64-sim) via lipo.
    #    `lipo` is Apple-only; Linux CI uses `llvm-lipo` from LLVM. Must be a
    #    recent LLVM that can read Rust's object files (LLVM 22 for Rust 1.96);
    #    old distro llvm-lipo (e.g. Ubuntu 22.04's LLVM 14) fails with opaque
    #    pointer errors. The Linux smoke build sets ZUKO_FFI_DEVICE_ONLY=1 and
    #    avoids simulator slices entirely, so this full-fat path is macOS/release.
    echo "==> creating fat simulator library"
    LIPO="$(command -v lipo || command -v llvm-lipo || true)"
    if [ -z "$LIPO" ]; then
        echo "build-ffi: neither 'lipo' nor 'llvm-lipo' found on PATH" >&2
        echo "           macOS ships lipo; Linux full XCFramework needs Homebrew llvm's llvm-lipo." >&2
        exit 1
    fi
    echo "    using: $LIPO"
    SIM_UNIVERSAL="$TARGET_DIR/sim-universal-${LIB_NAME}.a"
    "$LIPO" -create \
        "$TARGET_DIR/aarch64-apple-ios-sim/release/lib${LIB_NAME}.a" \
        "$TARGET_DIR/x86_64-apple-ios/release/lib${LIB_NAME}.a" \
        -output "$SIM_UNIVERSAL"
else
    echo "==> ZUKO_FFI_DEVICE_ONLY=1: skipping fat simulator library"
fi

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

# 6. Bundle into an XCFramework. Two paths:
#    - macOS: `xcodebuild -create-xcframework` does the canonical layout
#      (and validates it).
#    - Linux: no xcodebuild available. We assemble the same layout by hand:
#      an Info.plist with the AvailableLibraries array + per-slice
#      subdirectories named after LibraryIdentifier, each containing the
#      .framework bundle. Bit-identical to what xcodebuild produces —
#      SwiftPM's binaryTarget doesn't care which tool created it.
#
#    xcodebuild is preferred when available because it surfaces slice
#    mismatch errors loudly; the manual path is the fallback for Linux CI.
echo "==> assembling XCFramework"
XCFW="$OUT_DIR/$FRAMEWORK_NAME.xcframework"
rm -rf "$XCFW"

# Stage the framework slices in a temp dir, NOT inside $XCFW —
# both xcodebuild -create-xcframework and the manual Linux path copy their
# inputs into the output, so pre-creating them inside the output path
# collides on the second run.
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

echo "==> assembling framework slices"
create_framework \
    "$STAGE/ios-arm64/$FRAMEWORK_NAME.framework" \
    "$TARGET_DIR/aarch64-apple-ios/release/lib${LIB_NAME}.a"
if [ "$DEVICE_ONLY" != "1" ]; then
    create_framework \
        "$STAGE/ios-arm64_x86_64-simulator/$FRAMEWORK_NAME.framework" \
        "$SIM_UNIVERSAL"
fi

mkdir -p "$XCFW"

if command -v xcodebuild >/dev/null 2>&1; then
    if [ "$DEVICE_ONLY" = "1" ]; then
        xcodebuild -create-xcframework \
            -framework "$STAGE/ios-arm64/$FRAMEWORK_NAME.framework" \
            -output "$XCFW" \
            >/dev/null
    else
        xcodebuild -create-xcframework \
            -framework "$STAGE/ios-arm64/$FRAMEWORK_NAME.framework" \
            -framework "$STAGE/ios-arm64_x86_64-simulator/$FRAMEWORK_NAME.framework" \
            -output "$XCFW" \
            >/dev/null
    fi
else
    # Manual assembly — mirrors xcodebuild's output structure byte-for-byte
    # (verified by diffing a macOS-built XCFramework with this layout on
    # Linux). SwiftPM and Xcode both consume it without complaint.
    mkdir -p "$XCFW/ios-arm64"
    cp -R "$STAGE/ios-arm64/$FRAMEWORK_NAME.framework" \
          "$XCFW/ios-arm64/$FRAMEWORK_NAME.framework"
    if [ "$DEVICE_ONLY" != "1" ]; then
        mkdir -p "$XCFW/ios-arm64_x86_64-simulator"
        cp -R "$STAGE/ios-arm64_x86_64-simulator/$FRAMEWORK_NAME.framework" \
              "$XCFW/ios-arm64_x86_64-simulator/$FRAMEWORK_NAME.framework"
    fi
    cat > "$XCFW/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>AvailableLibraries</key>
	<array>
		<dict>
			<key>BinaryPath</key>
			<string>$FRAMEWORK_NAME</string>
			<key>LibraryIdentifier</key>
			<string>ios-arm64</string>
			<key>LibraryPath</key>
			<string>$FRAMEWORK_NAME.framework</string>
			<key>SupportedArchitectures</key>
			<array>
				<string>arm64</string>
			</array>
			<key>SupportedPlatform</key>
			<string>ios</string>
		</dict>
EOF
    if [ "$DEVICE_ONLY" != "1" ]; then
        cat >> "$XCFW/Info.plist" <<EOF
		<dict>
			<key>BinaryPath</key>
			<string>$FRAMEWORK_NAME</string>
			<key>LibraryIdentifier</key>
			<string>ios-arm64_x86_64-simulator</string>
			<key>LibraryPath</key>
			<string>$FRAMEWORK_NAME.framework</string>
			<key>SupportedArchitectures</key>
			<array>
				<string>arm64</string>
				<string>x86_64</string>
			</array>
			<key>SupportedPlatform</key>
			<string>ios</string>
			<key>SupportedPlatformVariant</key>
			<string>simulator</string>
		</dict>
EOF
    fi
    cat >> "$XCFW/Info.plist" <<EOF
	</array>
	<key>CFBundlePackageType</key>
	<string>XFWK</string>
</dict>
</plist>
EOF
fi

echo
echo "done."
echo "  XCFramework:  $XCFW"
echo "  Swift source: $OUT_DIR/Sources/ZukoFFI/ZukoFFI.swift"
echo
echo "The XCFramework is gitignored (rebuilt on demand). The Swift bindings"
echo "are committed (deterministic output). Next: run 'mise run build-ios'."
