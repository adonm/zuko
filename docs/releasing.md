# Releasing

Tags matching `vX.Y.Z` trigger the coordinated CLI and Flutter release graph:

- Rust CLI/host tarballs for Linux and macOS, x86_64 and aarch64;
- signed Flutter Android APK and AAB;
- Flutter Linux x86_64 Flatpak;
- Flutter Windows x86_64 bundle;

Flutter iOS and Mac App Store distribution use manual protected workflows.
Flutter web is deployed by the Pages workflow after changes reach `main`.

Published assets follow these names (`TAG` includes the leading `v`):

| Surface | Asset |
|---------|-------|
| CLI/host | `zuko-<rust-target>.tar.gz` |
| Android | `zuko-android-TAG-signed.apk` and `.aab` |
| Linux client | `zuko-linux-TAG-x86_64.flatpak` |
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
mise install
just check
just test-e2e
just release v0.9.9
```

`scripts/release.sh` validates the version, commits requested pending work,
pushes the branch, creates an annotated tag, and pushes it. The tag-triggered
workflow validates that the tag, Cargo version, Flutter version, and checked-out
commit agree before building any artifact.

Cargo `workspace.package.version` is canonical. Flutter must use the same
semantic version plus this Android-compatible build number:

```text
major * 1,000,000 + minor * 1,000 + patch
```

Run `just check-release-metadata` after every version change.

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

The `publish-crate.yml` workflow validates `vX.Y.Z`, the Cargo version, and the
tag commit before running the same fail-closed package check. Its `crates-io`
GitHub environment must be protected with required reviewers and tag-only
deployment rules. The protected publish job is not reached when verification
fails.

The Zuko crate uses a crates.io trusted publisher for repository `adonm/zuko`,
workflow `publish-crate.yml`, and environment `crates-io`. Tag publications use
GitHub OIDC and store no crates.io token or other publishing secret in the
repository.

## Mobile Appetize previews

Release Android builds require all four secrets and fail closed if any is
missing:

- `ANDROID_KEYSTORE_BASE64`
- `ANDROID_KEYSTORE_PASSWORD`
- `ANDROID_KEY_ALIAS`
- `ANDROID_KEY_PASSWORD`

Retain the existing signing key and application ID `dev.adonm.zuko` so package
upgrades remain valid. The workflow verifies APK and AAB signatures, writes
SHA-256 sidecars, and uploads the exact signed APK to Appetize. A separate
tag-gated macOS job uploads an unsigned ARM iOS Simulator build. Appetize setup
is documented in [mobile previews](appetize.md).

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

The Apple job in `build-flutter.yml` remains the ordinary iOS Simulator and
macOS compile gate. Store signing and upload are isolated in manual workflows:

- `lane=build` creates and validates `Zuko-Flutter.ipa` without uploading it;
- iOS `lane=beta` uploads that IPA for internal TestFlight processing;
- macOS `lane=build` creates and validates a signed, sandboxed Mac App Store
  installer package;
- macOS `lane=upload` passes through the protected `apple-store` environment
  before validating and uploading that package.

The Apple client uses bundle ID `dev.adonm.zuko` and a monotonically increasing
build-number stream. Pinned Codemagic CLI Tools own keychain, certificate,
profile, package-validation, and App Store Connect upload operations at this
boundary. Portal records, secrets, certificate types, sandbox requirements, and
final submission steps are documented in [Apple store publishing](apple-publishing.md).

## Linux `zuko app` support

The x86_64 Linux CLI tarball continues to include `cage/` and required wlroots
libraries for host-side `zuko app`. This is independent of the Flutter Linux
client. aarch64 users still need `cage` on `PATH`.
