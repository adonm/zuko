// swift-tools-version: 6.2
//
// Top-level SwiftPM manifest for the Zuko iOS app. Replaces the old
// `Zuko/project.yml` (xcodegen + xcodebuild) for local dev + CI builds.
//
// xtool (`xtool dev build --ipa`) drives this manifest directly — no
// `.xcodeproj` is generated for the build path. The Swift sources stay at
// `Zuko/Zuko/` (legacy path; cheap to keep) and the local `ZukoFFI` package
// (Rust staticlib via uniffi) is referenced by relative path. xtool's PackLib
// handles the binary `ZukoRust.xcframework` inside ZukoFFI the same way xcodebuild
// did (see `PackLib/Planner.swift`'s `BinaryTarget` resource handling).
//
// On Linux/CI: `xtool dev build --ipa` (unsigned) for smoke testing. The
// signed TestFlight path stays on macOS via the upload-split workflow.
//
// On macOS: `xtool dev generate-xcode-project` if you want an `.xcodeproj`
// to open in Xcode. The old `Zuko/project.yml` is kept for now as a fallback
// (older fastlane path); once the migration is stable we delete it.

import PackageDescription

let package = Package(
    name: "Zuko",
    platforms: [
        // Must match iroh-ffi's floor + the N0 relay stack
        // (nw_path_is_ultra_constrained). Kept in sync with `project.yml`'s
        // `deploymentTarget` until the legacy xcodegen path is removed.
        .iOS(.v26),
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
        // Versions mirror the legacy `project.yml` so a side-by-side build
        // produces a bit-identical app.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.12.0"),
        .package(url: "https://github.com/n0-computer/iroh-ffi.git", from: "1.0.0"),
        // Local wrapper around the Rust staticlib. Built by
        // `scripts/build-ffi.sh` (cargo build --lib --release for each iOS
        // slice) and consumed via its binary target `ZukoRust.xcframework`.
        .package(path: "ZukoFFI"),
    ],
    targets: [
        .target(
            name: "Zuko",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "IrohLib", package: "iroh-ffi"),
                .product(name: "ZukoFFI", package: "ZukoFFI"),
            ],
            // Legacy path — keeps the diff to one new file rather than
            // moving all of Zuko/Zuko/*.swift to Sources/Zuko/.
            path: "Zuko/Zuko",
            // The xcassets bundle ships alongside the app's executable.
            // Declared via SwiftPM's resources so xtool's Planner picks it
            // up (Planner.swift's `target.resources` path).
            resources: [
                .copy("Assets.xcassets"),
            ],
            linkerSettings: [
                // iroh's deps need Network.framework on iOS
                // (nw_interface_get_index). Mirrors the `OTHER_LDFLAGS:
                // -framework Network` in project.yml's base settings.
                .linkedFramework("Network"),
            ]
        ),
    ]
)
