# Releasing

Tags matching `vX.Y.Z` trigger the coordinated CLI and Flutter release graph:

- Rust CLI/host tarballs for Linux and macOS, x86_64 and aarch64;
- signed Flutter Android APK and AAB;
- Flutter Linux x86_64 archive consumed by FlatPark;
- Flutter Windows x86_64 bundle;

Codemagic builds the Android, Linux, Windows, and Apple clients from each
release commit. GitHub triggers the non-Apple release workflows through the
Codemagic API, verifies the retained artifacts against the exact tag and
commit, and attaches them beside the CLI assets. Codemagic revalidates and
uploads the exact signed Flutter iOS artifact. Mac App Store packaging is not
currently automated. Flutter web is deployed by the Pages workflow after
changes reach `main`.

Published assets follow these names (`TAG` includes the leading `v`):

| Surface | Asset |
|---------|-------|
| CLI/host | `zuko-<rust-target>.tar.gz` |
| Android | `zuko-android-TAG-signed.apk` and `.aab` |
| Linux client | `zuko-linux-TAG-x86_64.tar.gz` |
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
validates the committed package versions, and requires `CODEMAGIC_API_TOKEN`.
It reuses or triggers the Apple, Linux/Android/web, and Windows compile gates
for the exact `HEAD`, waits for every action to succeed, then creates the
annotated `vX.Y.Z` tag and pushes only that tag. A failed candidate creates no
tag, so fix the source or rerun `just release` after a transient provider
failure. The script never stages files, creates a commit, pushes a branch, or
moves an existing tag. Tag-triggered workflows verify that the tag resolves to
their exact checkout before building anything.

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

Retain the existing Android signing key and application ID `dev.adonm.zuko` so
package upgrades remain valid. Codemagic's `flutter-linux-android-release`
workflow builds unsigned APK and AAB inputs. GitHub retrieves those exact
artifacts, signs them with repository-scoped secrets, verifies their signing
certificate and metadata, and writes SHA-256 sidecars before publication.
After GitHub publishes the coordinated release, it starts Codemagic's
`mobile-appetize-release` workflow for the same immutable tag and waits for
both previews. Appetize receives the checksummed GitHub Release APK and an ARM
iOS Simulator package built from that tag. This keeps Appetize aligned with the
release and TestFlight without copying the Android signing key into Codemagic.
Appetize setup is documented in [mobile previews](appetize.md).

Pull-request CI builds a debug APK in Codemagic. Debug or unsigned outputs are
never attached to a GitHub Release. Google Play draft/release publication is
documented in [Android store publishing](android-publishing.md).

## Linux and Windows

Flutter Linux ships as a deterministic x86_64 `bundle/` archive built and
linkage-checked against the pinned Freedesktop SDK on Codemagic. The published
FlatPark package downloads that official archive by immutable release URL and
pins its checksum and size; FlatPark owns Flatpak wrapping, signing, repository
hosting, and updates. Windows is built on Codemagic's Windows runner and ships
as a versioned x86_64 ZIP while Microsoft Store packaging is validated. Both
have SHA-256 sidecars.
The protected Store workflow is documented in
[Microsoft Store publishing](windows-publishing.md).
The FlatPark registry package is maintained separately from this source tree;
see [Linux delivery through FlatPark](flatpark.md).

## Flutter Apple distribution

Codemagic's `flutter-apple-ci` workflow is the ordinary iOS Simulator and
macOS compile gate. It retains development ZIP artifacts while store signing
and upload remain isolated:

- GitHub explicitly triggers Codemagic's `ios-signing-validation` workflow for
  every exact `vX.Y.Z` commit, then triggers `ios-testflight-release` to retain
  and upload that validated `Zuko-Flutter.ipa` for internal TestFlight
  processing;
- `ios-signing-validation` also remains manually runnable against a selected
  branch without uploading it or claiming a release identity;
- GitHub stores only the Codemagic API token; Apple signing and App Store
  Connect credentials remain isolated in Codemagic;
- macOS remains a Codemagic development compile artifact, not an automated Mac
  App Store package.

The Apple client uses bundle ID `dev.adonm.zuko` and the same deterministic
semantic build number as Android. Codemagic's hosted Apple Silicon environment
owns iOS signing and App Store Connect upload; repository scripts continue to
own release identity and package validation. Portal records, credentials,
certificate types, sandbox requirements, and final submission steps are
documented in [Apple store publishing](apple-publishing.md).

## CI/CD provider responsibilities

Codemagic owns Flutter tests and platform builds on its target runners:

- shared Dart analysis/tests and the web compile gate;
- Android debug and unsigned release builds; GitHub owns release signing;
- x86_64 Linux bundle and release archive builds;
- x86_64 Windows bundle and ZIP release builds;
- iOS Simulator and macOS compile gates for Flutter changes;
- signed iOS validation and immutable-tag TestFlight uploads;
- release-orchestrated Android and ARM iOS Simulator Appetize previews.

GitHub remains the source-of-truth verifier and publisher: it owns Rust checks
and binaries, documentation and web deployment, triggers exact Codemagic tag
workflows, verifies their commit/tag/artifact/checksum handoff, and is the only
GitHub Release writer. Approval-gated crates.io, Google Play, and Microsoft
Store operations remain in GitHub environments. Platform signing credentials
remain scoped to the provider workflows that need them.

## Linux `zuko app` support

The x86_64 Linux CLI tarball continues to include `cage/` and required wlroots
libraries for host-side `zuko app`. This is independent of the Flutter Linux
client. aarch64 users still need `cage` on `PATH`.
