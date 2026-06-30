// swift-tools-version: 6.2
//
// Top-level SwiftPM manifest for the Zuko iOS app. This is the local/PR build
// source of truth; `Zuko/project.yml` remains only for the signed Fastlane
// archive path.
//
// xtool (`xtool dev build --ipa`) drives this manifest directly — no
// `.xcodeproj` is generated for the build path. The Swift sources stay at
// `Zuko/Zuko/` (legacy path; cheap to keep) and the local `ZukoFFI` package
// (Rust staticlib via uniffi) is referenced by relative path. xtool's PackLib
// handles the binary `ZukoRust.xcframework` inside ZukoFFI the same way xcodebuild
// did (see `PackLib/Planner.swift`'s `BinaryTarget` resource handling).
//
// The terminal emulator is GhosttyTerminal from libghostty-spm — a Swift
// wrapper around the libghostty static library with native SwiftUI/UIKit
// views and a host-managed I/O backend (no PTY spawn, sandbox-safe). The
// prior SwiftTerm dependency was replaced in the v0.5 redesign; the
// `libghostty` XCFramework is a binary target so no source patching (à la
// `patch-swiftterm-xtool.sh`) is needed for the xtool Linux→iOS cross build.
//
// On Linux/CI: `mise run build-ios` (unsigned) for smoke testing. The signed
// TestFlight path still archives through Fastlane/XcodeGen until xtool supports
// this repo's App Store export flow.
//
// On macOS: `xtool dev generate-xcode-project` if you want an `.xcworkspace`
// to open in Xcode.

import PackageDescription

let package = Package(
    name: "Zuko",
    platforms: [
        // Must match iroh-ffi's floor: iroh-ffi 1.0's binary XCFramework was
        // built against the iOS 26.5 SDK (its object files carry
        // LC_VERSION_MIN_IPHONEOS 26.5), so anything lower trips
        //   ld64.lld: warning: Iroh.framework/Iroh(...o) has version 26.5.0,
        //   which is newer than target minimum of 26.0.0
        // Kept in sync with `project.yml`'s `deploymentTarget` + the
        // IPHONEOS_DEPLOYMENT_TARGET baked into scripts/build-ffi.sh.
        .iOS("26.5"),
    ],
    products: [
        // xtool's PackLib picks the single `.autoLibrary` product as the main
        // app target (see `Planner.selectLibrary`). `.library` defaults to
        // `.autoLibrary` when there's exactly one product, so this resolves.
        .library(
            name: "Zuko",
            targets: ["Zuko"]
        ),
    ],
    dependencies: [
        // libghostty-spm ships GhosttyTerminal (Swift wrapper around the
        // libghostty XCFramework binary target). We use its host-managed I/O
        // backend (`InMemoryTerminalSession`) so the app stays sandbox-safe —
        // no PTY spawn, all bytes flow through `IrohSession`.
        .package(url: "https://github.com/Lakr233/libghostty-spm.git", from: "1.0.1775374806"),
        .package(url: "https://github.com/n0-computer/iroh-ffi.git", from: "1.0.0"),
        // Local wrapper around the Rust staticlib. Built by
        // `scripts/build-ffi.sh` (cargo build --lib --release for each iOS
        // slice) and consumed via its binary target `ZukoRust.xcframework`.
        .package(path: "ZukoFFI"),
        // The wire protocol (framing shared with `zuko host`), isolated into a
        // dependency-free package so it can be unit-tested on Linux/CI exactly
        // like the Rust `src/wire.rs`. See ZukoWire/Package.swift.
        .package(path: "ZukoWire"),
    ],
    targets: [
        .target(
            name: "Zuko",
            dependencies: [
                .product(name: "GhosttyTerminal", package: "libghostty-spm"),
                // Direct dependency on the C wrapper (libghostty) — used by
                // `TouchMouseInput.swift` to call `ghostty_surface_mouse_*`
                // and `ghostty_surface_mouse_captured` via Mirror reflection,
                // because the Swift `TerminalSurface` wrapper keeps those
                // APIs `internal`. GhosttyTerminal transitively links the
                // static lib so we don't pull in a second copy.
                .product(name: "GhosttyKit", package: "libghostty-spm"),
                // 485 iTerm2-Color-Schemes themes (MIT) for the in-app
                // theme picker on TerminalScreen.
                .product(name: "GhosttyTheme", package: "libghostty-spm"),
                .product(name: "IrohLib", package: "iroh-ffi"),
                .product(name: "ZukoFFI", package: "ZukoFFI"),
                .product(name: "ZukoWire", package: "ZukoWire"),
            ],
            // Legacy path — keeps the diff to one new file rather than
            // moving all of Zuko/Zuko/*.swift to Sources/Zuko/.
            path: "Zuko/Zuko",
            exclude: [
                // xtool reads this via ios/xtool.yml's infoPath; SwiftPM should
                // not try to classify it as a source/resource file.
                "Info.plist",
            ],
            // The xcassets bundle ships alongside the app's executable.
            // Declared via SwiftPM's resources so xtool's Planner picks it
            // up (Planner.swift's `target.resources` path).
            resources: [
                .copy("Assets.xcassets"),
            ],
            linkerSettings: [
                // Network.framework is also linked by iroh-ffi's own
                // Package.swift (it ships `.linkedFramework("Network")` +
                // `.linkedFramework("SystemConfiguration")` on every Apple
                // platform, and `.linkedFramework("CoreWLAN", .when(platforms: [.macOS]))`
                // for macOS WiFi enumeration). SwiftPM propagates those
                // transitively, so this explicit link is redundant — kept as
                // belt-and-suspenders so a future iroh-ffi drop can't
                // silently break our link, and to mirror the `-framework
                // Network` in project.yml's base settings (the legacy
                // XcodeGen path doesn't see SwiftPM linkerSettings).
                .linkedFramework("Network"),
            ]
        ),
    ]
)
