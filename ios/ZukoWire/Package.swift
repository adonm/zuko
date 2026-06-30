// swift-tools-version: 6.0
//
// ZukoWire — the wire protocol shared with the `zuko` host daemon, isolated
// into its own dependency-free SwiftPM package.
//
// Why a separate local package (like `ZukoFFI`):
//   - It imports only Foundation, so `swift test` builds + runs it on Linux
//     (and in CI) — the rest of the app can't, because it links UIKit /
//     IrohLib / libghostty (Apple-only). This is the one slice of the iOS
//     client we can unit-test exactly like the Rust core tests `src/wire.rs`.
//   - It pins the framing contract in one tested place, mirroring the Rust
//     `wire.rs`, so the two implementations can't drift silently (the
//     byte-layout tests double as the protocol spec — see `docs/PROTOCOL.md`).
//
// The app's `ios/Package.swift` references this by relative path and the
// `Zuko` target depends on the `ZukoWire` product.
import PackageDescription

let package = Package(
    name: "ZukoWire",
    // Match the consuming app's floor (ios/Package.swift). This only constrains
    // Apple platforms; Linux is unlisted, so `swift test` still builds here and
    // in CI (the package is Foundation-only).
    platforms: [
        .iOS("26.5"),
    ],
    products: [
        .library(name: "ZukoWire", targets: ["ZukoWire"]),
    ],
    targets: [
        .target(name: "ZukoWire"),
        .testTarget(name: "ZukoWireTests", dependencies: ["ZukoWire"]),
    ]
)
