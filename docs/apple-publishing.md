# Apple publishing with Codemagic

Codemagic is the only Apple signing and TestFlight provider. GitHub stores no
Apple certificates, provisioning profiles, or App Store Connect credentials.
The repository-root `codemagic.yaml` defines:

- `flutter-apple-ci`: unsigned iOS Simulator and macOS compile gate;
- `ios-signing-validation`: manual signed IPA build without publishing;
- `ios-testflight-release`: signed IPA build and TestFlight upload for every
  annotated `vX.Y.Z` release tag.

The workflows use Apple Silicon M2 runners, Xcode 26.3, CocoaPods 1.16.2, the
checksum-pinned mise bootstrap, and the exact Flutter, Rust, Zig, and `just`
versions in `mise.toml`. Codemagic CLI Tools 0.68.0 are installed from the
hash-locked `scripts/codemagic-requirements.txt` closure.

## One-time Codemagic setup

1. Add `adonm/zuko` as a Flutter application with project path `flutter`; keep
   `codemagic.yaml` at the repository root.
2. Add the App Store Connect App Manager key under **Team integrations >
   Developer Portal** with the exact name `zuko-app-store`.
3. Under **Code signing identities**, add a valid Apple Distribution
   certificate and matching App Store profile for `dev.adonm.zuko`, team
   `R8PN382RC4`.
4. Rescan `main` and run `ios-signing-validation`. The profile must show a
   matching certificate, and the workflow must produce a validated IPA.

The signing validation completed successfully in Codemagic build
`6a52e7354b78f62f917e3ffc`.

## Release behavior

`scripts/release-context.sh` rejects lightweight tags, mismatched versions, and
checkouts that do not equal the tagged commit. For an accepted annotated tag,
Codemagic:

1. validates the immutable release identity before installing the toolchain;
2. analyzes and tests the Flutter client;
3. prepares the App-Store-compatible Ghostty library;
4. imports the matching Codemagic signing identities;
5. builds `Zuko-Flutter.ipa` with the deterministic version and build number;
6. verifies the bundle ID, version, build, team, signature, profile, ARM64
   architecture, Ghostty framework, and iOS 18.0 deployment floor;
7. retains the IPA, SHA-256 sidecar, xcarchive, and diagnostics;
8. uploads the validated IPA through `zuko-app-store` for TestFlight
   processing.

An upload does not submit the app for review. Tester groups, screenshots,
privacy declarations, export compliance, pricing, and final review submission
remain App Store Connect operations.

The automated macOS workflow currently provides development compile artifacts,
not a Mac App Store package. Add a Codemagic-native macOS Store workflow before
attempting Mac App Store publication; do not restore GitHub signing secrets.
