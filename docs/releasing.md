# Releasing

Tags matching `vX.Y.Z` trigger the coordinated CLI and Flutter release graph:

- Rust CLI/host tarballs for Linux and macOS, x86_64 and aarch64;
- signed Flutter Android APK and AAB;
- Flutter Linux x86_64 and aarch64 Flatpaks;
- Flutter Windows x86_64 bundle;

Codemagic revalidates and uploads the exact signed Flutter iOS artifact built
from each release commit. Mac App Store packaging is not currently automated.
Flutter web is deployed by the Pages workflow after changes reach `main`.

Published assets follow these names (`TAG` includes the leading `v`):

| Surface | Asset |
|---------|-------|
| CLI/host | `zuko-<rust-target>.tar.gz` |
| Android | `zuko-android-TAG-signed.apk` and `.aab` |
| Linux client | `zuko-linux-TAG-<x86_64|aarch64>.flatpak` |
| Windows client | `zuko-windows-TAG-x86_64.zip` |

Each payload has a matching `.sha256` sidecar. End-user notes are in
[Clients](clients.md); source build outputs are in
[Building clients](building-clients.md).

Before the first external publication, complete the
[distribution setup checklist](distribution-setup.md). It is the canonical
inventory of portal identities, GitHub environments, variables, and secrets;
the platform guides provide deeper operational detail.

## Cut a release

```sh
mise bootstrap
just check
just test-e2e
just release
```

`scripts/release.sh` requires a clean `main` exactly matching `origin/main`,
validates the committed package versions, creates the annotated `vX.Y.Z` tag,
and pushes only that tag. It never stages files, creates a commit, pushes a
branch, or moves an existing tag. Tag-triggered workflows verify that the tag
resolves to their exact checkout before building anything.

A release tag is the permanent source identity for that release. Re-run a
failed job only for transient runner, network, or approval failures. If source,
packaging, or workflow code changes, increment the patch version, commit and
push it, and cut a new tag. Never rebuild an old version from current `main`.

Cargo `workspace.package.version` is canonical. Flutter must use the same
semantic version plus this Android-compatible build number:

```text
1,800,000,000 + major * 1,000,000 + minor * 1,000 + patch
```

The baseline preserves ordering after the timestamp build numbers used before
`v0.9.12` while remaining below Google Play's limit. Android and Apple use this
same deterministic value. Run `just check-release-metadata` after every version
change.

## crates.io

Crate publication requires the compatibility package
`crossterm-zuko 0.29.0-zuko.1` on crates.io. Development resolves the
immutable Git tag `crossterm-zuko-v0.29.0-zuko.1` at commit
`cc3e2009082bb6b4dec31a42f1b11ff0e2a004a6`; Cargo normalizes the packaged Zuko
manifest to the exact crates.io fallback `=0.29.0-zuko.1`.

Run `scripts/check-crate-package.sh` before attempting publication. It packages
and checks the unpacked archive, confirms that the development graph uses the
expected fork revision, and inspects the crossterm source selected by the
package's registry-only resolution. The tagged compatibility package is
published and protected by crates.io trusted publishing. Do not publish Zuko
unless the check reports that the exact registry package contains the normal,
rxvt, SGR, and cursor-position underflow fixes.

The `publish-crate.yml` workflow validates `vX.Y.Z` against the selected source
before running the same fail-closed package check. Its `crates-io` GitHub
environment allows only `v*` tags and has no required reviewer, so successful
verification proceeds directly to trusted publishing. The publish job is not
reached when verification fails, and crates.io refuses replacement of an
existing version.

The Zuko crate uses a crates.io trusted publisher for repository `adonm/zuko`,
workflow `publish-crate.yml`, and environment `crates-io`. Publications use
GitHub OIDC and store no crates.io token or other publishing secret in the
repository.

## Mobile Appetize previews

GitHub Release Android builds require all four repository secrets and fail
closed if any is missing:

- `ANDROID_KEYSTORE_BASE64`
- `ANDROID_KEYSTORE_PASSWORD`
- `ANDROID_KEY_ALIAS`
- `ANDROID_KEY_PASSWORD`

Retain the existing signing key and application ID `dev.adonm.zuko` so package
upgrades remain valid. The GitHub workflow verifies APK and AAB signatures and
writes SHA-256 sidecars for release assets. Codemagic's manual
`mobile-appetize-release` workflow independently rebuilds a signed Android APK
and unsigned ARM iOS Simulator package from an immutable tag, validates them,
and updates both Appetize apps after its credentials are configured. Appetize
setup is documented in [mobile previews](appetize.md).

Pull-request CI builds a debug APK. Debug or unsigned outputs are never attached
to a GitHub Release. Google Play draft/release publication is documented in
[Android store publishing](android-publishing.md).

## Linux and Windows

Flutter Linux ships as a Flatpak bundle. Windows currently ships as a versioned
ZIP while Microsoft Store packaging is validated. Both have SHA-256 sidecars.
The protected Store workflow is documented in
[Microsoft Store publishing](windows-publishing.md).
The release-attached Flatpak is separate from Flathub submission. Use Flathub's
official `org.flatpak.Builder` for submission-oriented linting and follow the
current policy caveats in [Flatpak packaging](../flatpak/README.md).

## Flutter Apple distribution

Codemagic's `flutter-apple-ci` workflow is the ordinary iOS Simulator and
macOS compile gate. It retains development ZIP artifacts while store signing
and upload remain isolated:

- Codemagic's `ios-testflight-release` workflow handles every `vX.Y.Z` tag and
  creates, validates, retains, and uploads `Zuko-Flutter.ipa` for internal
  TestFlight processing;
- Codemagic's manual `ios-signing-validation` workflow creates and validates a
  signed IPA from the selected branch without uploading it or claiming a
  release identity;
- GitHub stores no Apple signing or App Store Connect credentials and has no
  Apple publishing workflow;
- macOS remains a Codemagic development compile artifact, not an automated Mac
  App Store package.

The Apple client uses bundle ID `dev.adonm.zuko` and the same deterministic
semantic build number as Android. Codemagic's hosted Apple Silicon environment
owns iOS signing and App Store Connect upload; repository scripts continue to
own release identity and package validation. Portal records, credentials,
certificate types, sandbox requirements, and final submission steps are
documented in [Apple store publishing](apple-publishing.md).

## CI/CD provider responsibilities

Codemagic owns the mobile operations that benefit from managed Apple Silicon,
mobile signing identities, and App Store Connect integration:

- iOS Simulator and macOS compile gates for Flutter changes;
- signed iOS validation and immutable-tag TestFlight uploads;
- manually started signed Android and ARM iOS Simulator Appetize previews.

GitHub remains the source-of-truth orchestrator for Rust checks and binaries,
documentation and web deployment, Android/Linux/Windows release assets,
Flatpak container builds, and the coordinated GitHub Release. Approval-gated
crates.io, Google Play, and Microsoft Store operations remain in GitHub
environments. Apple signing and TestFlight credentials exist only in
Codemagic.

## Linux `zuko app` support

The x86_64 Linux CLI tarball continues to include `cage/` and required wlroots
libraries for host-side `zuko app`. This is independent of the Flutter Linux
client. aarch64 users still need `cage` on `PATH`.
