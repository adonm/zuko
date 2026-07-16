# Releasing

Every pushed `main` commit produces one build-once release candidate in
`.github/workflows/build.yml`. The aggregate candidate binds the source commit,
Flutter/Dart contract, file sizes, and SHA-256 digests for:

- Rust CLI/host tarballs for Linux and macOS, x86_64 and aarch64;
- unsigned Flutter Android APK and AAB;
- Flutter Linux x86_64 archive consumed by FlatPark;
- Flutter Windows x86_64 bundle;
- iOS Simulator and macOS development archives.

GitHub Actions performs all ordinary tests and platform builds. Codemagic is
reserved for a signed iOS candidate, TestFlight upload, and upload-only
Appetize publication. Flutter web remains deployed by the Pages workflow after
changes reach `main`.

Published assets follow these names (`TAG` includes the leading `v`):

| Surface | Asset |
|---------|-------|
| CLI/host | `zuko-<rust-target>.tar.gz` |
| Android | `zuko-android-TAG-signed.apk` and `.aab` |
| Linux client | `zuko-linux-TAG-x86_64.tar.gz` |
| Windows client | `zuko-windows-TAG-x86_64.zip` |
| Apple previews | `Zuko-Flutter-ios-simulator.zip`, `Zuko-Flutter-macOS.zip` |
| Provenance | `release-candidate.json` |

Each installable payload has a matching `.sha256` sidecar. End-user notes are
in [Clients](clients.md); source build outputs are in
[Building clients](building-clients.md).

## Cut a release

```sh
mise bootstrap
mise install
just check
just test-e2e
just release
```

`just release` is intentionally non-blocking. It requires a clean `main`
exactly matching `origin/main`, validates the committed package versions, and
dispatches `prepare-release.yml` for that exact commit. No local polling
process needs to remain running.

The protected workflow then:

1. resolves the one successful exact-commit GitHub candidate and its aggregate
   artifact;
2. creates a temporary branch pinned to that commit;
3. asks Codemagic to build and retain one signed IPA from that exact branch;
4. rechecks that `origin/main` did not move;
5. creates and pushes the annotated `vX.Y.Z` tag; and
6. removes the temporary branch even when a prior step fails.

No tag is created if candidate validation, signing, or source identity fails.
The tag-triggered release downloads the existing aggregate candidate, verifies
`release-candidate.json`, signs Android once, and promotes those same bytes.
The prevalidated IPA is recovered by build ID, revalidated against the tag, and
uploaded to TestFlight without rebuilding it.

A release tag is permanent. Retry only transient runner, network, upload, or
approval failures. If source, packaging, or workflow code changes, increment
the patch version and produce a new candidate. Never rebuild an old version
from current `main`.

Cargo `workspace.package.version` is canonical. Flutter uses the same semantic
version plus:

```text
1,800,000,000 + major * 1,000,000 + minor * 1,000 + patch
```

Run `just check-release-metadata` after every version change.

## crates.io

Crate publication requires `crossterm-zuko 0.29.0-zuko.1` on crates.io.
Development resolves immutable tag `crossterm-zuko-v0.29.0-zuko.1` at
`cc3e2009082bb6b4dec31a42f1b11ff0e2a004a6`; packaging resolves the exact
registry fallback `=0.29.0-zuko.1`.

`publish-crate.yml` verifies the tag and packaged dependency graph, then uses
crates.io trusted publishing through the `crates-io` GitHub environment. No
registry token is stored in the repository.

## Mobile previews and stores

GitHub signs the candidate APK and AAB with repository-scoped secrets and
publishes their checksums. Appetize's Codemagic workflow only downloads the
published signed APK and iOS Simulator ZIP and uploads those exact bytes; it no
longer compiles either client.

The Google Play workflow similarly downloads and validates the already signed
release AAB instead of rebuilding Flutter. Microsoft Store MSIX packaging
remains a separate protected build because it is a different package format.
See [Appetize previews](appetize.md), [Android publishing](android-publishing.md),
and [Windows publishing](windows-publishing.md).

## Linux and Windows

GitHub's Ubuntu 24.04 job builds, normalizes, linkage-checks, reproduces, and
smokes the GTK4 Linux archive. FlatPark consumes that immutable URL and owns
Flatpak wrapping and repository publication. GitHub's Windows runner produces
the portable x86_64 ZIP and checksum. Neither platform is rebuilt after the
release tag.

## Apple distribution

GitHub's macOS job owns the unsigned iOS Simulator and macOS compile gate.
Codemagic retains only Apple-specific trust boundaries:

- `ios-signing-validation` builds one signed candidate before tagging;
- `ios-testflight-release` downloads, revalidates, and uploads that IPA;
- Apple signing and App Store Connect credentials never enter GitHub.

The Apple bundle ID is `dev.adonm.zuko`; Android and Apple share the deterministic
build number above. Mac App Store publication is not currently automated.

## Provider responsibilities

GitHub Actions owns tests, Flutter compile gates, all unsigned/portable release
artifacts, candidate provenance, Android signing, immutable tags and Releases,
crates.io, Google Play, and Microsoft Store orchestration. Codemagic owns only
signed iOS construction, TestFlight upload, and Appetize credentials. This is a
build-once/promote-many boundary: each publisher validates source identity and
artifact hashes rather than recompiling.

## Linux `zuko app` support

The x86_64 Linux CLI tarball includes `cage/` and required wlroots libraries for
host-side `zuko app`. This is independent of the Flutter Linux client. aarch64
users still need `cage` on `PATH`.
