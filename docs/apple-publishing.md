# Apple store publishing

Development compilation stays in `build-flutter.yml`. Store distribution is a
separate, protected boundary:

- Codemagic's `ios-testflight-release` workflow builds, validates, retains, and
  uploads a signed IPA for internal TestFlight processing on every immutable
  `vX.Y.Z` tag. Its `ios-signing-validation` workflow is a manual,
  non-publishing signing smoke test for the selected branch.
- `release-flutter-ios.yml` is manual-only. It provides an independent GitHub
  signing smoke test and checksum-pinned artifact recovery, but does not react
  to release tags.
- `release-flutter-macos.yml` builds a sandboxed Mac App Store `.pkg`;
  manual runs require an immutable release tag, and `lane=upload` starts a
  second job in the same run before validation and upload.

All Apple workflows use Xcode 26.3, the checksum-pinned Flutter `3.46.0-0.3.pre`
beta archive in `mise.toml`, Rust 1.96.1, Zig 0.15.2, and
bundle ID `dev.adonm.zuko`. The iOS workflow retains
`scripts/prepare-libghostty-ios-static.py` before its device archive build.

## Codemagic hosted iOS boundary

The repository-root `codemagic.yaml` uses an Apple Silicon M2 runner and the
`zuko-app-store` Developer Portal integration. Although Codemagic detects the
mobile project under `flutter/`, its monorepo configuration remains at the
repository root so release scripts and `mise.toml` stay shared across clients.

Complete this one-time setup in Codemagic:

1. Add `adonm/zuko` as a Flutter application, with project path `flutter` and
   branch `main`, then select YAML configuration.
2. Under Team integrations > Developer Portal, add the dedicated App Store
   Connect API key with App Manager access and name it exactly
   `zuko-app-store`.
3. Under Team settings > Code signing identities, generate or upload an Apple
   Distribution certificate and fetch or upload the App Store provisioning
   profile for `dev.adonm.zuko`. Codemagic must show the certificate/profile
   pair as matching.
4. Check `codemagic.yaml` from `main`, then run `ios-signing-validation`. It
   must produce a validated IPA without publishing it. Only the
   `ios-testflight-release` tag workflow publishes.

The Codemagic runner uses Xcode 26.3 explicitly. A checksum-verified mise
2026.7.5 binary installs the exact Flutter, Rust, Zig, and `just` versions from
`mise.toml`; no floating Codemagic Flutter channel is used. Codemagic injects
the selected signing identities into its ephemeral keychain and publishes the
validated IPA through the named integration. IPA, checksum, xcarchive, Xcode
logs, and crash diagnostics are retained as build artifacts.

## GitHub recovery boundary

Codemagic CLI Tools 0.68.0 owns release keychain initialization, certificate
import, provisioning-profile application, package inspection, App Store
Connect validation, and upload. `scripts/codemagic-requirements.txt`
pins its complete Python dependency closure and hashes every accepted artifact;
the installer uses `pip --require-hashes --only-binary=:all:` and checks the
installed version. Update the lock deliberately with:

```sh
uv pip compile --universal --generate-hashes --python-version 3.13 \
  --output-file scripts/codemagic-requirements.txt - \
  <<< 'codemagic-cli-tools==VERSION'
```

The GitHub workflows decode signing material only into an ephemeral runner
directory. Commands pass passwords and API credentials by environment or
protected files; do not add shell tracing or print those values.

## Apple portal setup

These records remain external and must exist before running either workflow:

1. In Certificates, Identifiers & Profiles, retain or create the explicit App
   ID `dev.adonm.zuko`. Enable the capabilities represented by the committed
   entitlements. The macOS release uses App Sandbox, outgoing and incoming
   network access, and Keychain access.
2. For iOS, create an App Store Connect provisioning profile and an Apple
   Distribution certificate for that identifier.
3. For macOS, create a Mac App Store provisioning profile, a Mac App
   Distribution certificate, and a Mac Installer Distribution certificate.
   Export each certificate and private key as a password-protected `.p12`.
4. In App Store Connect, add the macOS platform to the existing app record for
   `dev.adonm.zuko` if it is not already present. This preserves the common
   bundle ID; Apple controls whether the platforms use universal purchase.
5. In Users and Access > Integrations, create a dedicated App Store Connect API
   key with App Manager access. Keep its issuer ID, key ID, and one-time `.p8`
   download in the maintainer secret store.

The workflow fails if a profile is expired, belongs to another team or bundle,
contains devices, or targets the wrong platform. It also requires the expected
Apple Distribution, Mac App Distribution, and Mac Installer Distribution
certificate identities.

## GitHub recovery configuration

Configure these Actions secrets without placing values in shell history:

| Secret | Purpose |
|--------|---------|
| `TEAM_ID` | Apple Developer team identifier |
| `BUILD_CERTIFICATE_BASE64` | iOS Apple Distribution `.p12` |
| `P12_PASSWORD` | Password for the iOS `.p12` |
| `PROVISIONING_PROFILE_BASE64` | iOS App Store `.mobileprovision` |
| `MACOS_APPLICATION_CERTIFICATE_BASE64` | Mac App Distribution `.p12` |
| `MACOS_APPLICATION_CERTIFICATE_PASSWORD` | Application `.p12` password |
| `MACOS_INSTALLER_CERTIFICATE_BASE64` | Mac Installer Distribution `.p12` |
| `MACOS_INSTALLER_CERTIFICATE_PASSWORD` | Installer `.p12` password |
| `MACOS_PROVISIONING_PROFILE_BASE64` | Mac App Store `.provisionprofile` |
| `ASC_KEY_ID` | App Store Connect API key ID |
| `ASC_ISSUER_ID` | App Store Connect issuer ID |
| `ASC_KEY_CONTENT` | Complete App Store Connect `.p8` contents |

Certificate and profile values are unwrapped base64. Protect the `apple-store`
environment with required reviewers and restrict deployment to approved manual
smoke, recovery, and macOS Store runs. Put all listed secrets, including the
three `ASC_*` values used by iOS recovery and macOS, in that environment.

## Validation and release

Before upload, the workflows verify the archive/application bundle identifier,
marketing version, build number, executable architecture, embedded profile,
team, deep code signature, and store package. iOS additionally checks the
App-Store-compatible Ghostty Mach-O. macOS checks sandbox/network entitlements,
the installer signature, payload, and `/Applications` install location.
Codemagic then runs Apple's package validation immediately before uploading the
exact checked artifact.

An upload does not submit an app for review. Complete screenshots, description,
support and privacy URLs, privacy declarations, encryption/export-compliance
answers, age rating, pricing, tax/banking agreements, tester groups, phased
release choice, and final review submission in App Store Connect. Those portal
records are intentionally not stored in this repository.
