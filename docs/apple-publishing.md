# Apple store publishing

Development compilation stays in `build-flutter.yml`. Store distribution is a
separate, manual boundary:

- `release-flutter-ios.yml` builds a signed IPA; `lane=beta` validates and
  uploads it for internal TestFlight processing.
- `release-flutter-macos.yml` builds a sandboxed Mac App Store `.pkg`;
  `lane=upload` starts a second job protected by the `apple-store` GitHub
  environment before validation and upload.

Both workflows use Xcode 26.3, the checksum-pinned Flutter `3.46.0-0.3.pre`
beta archive in `mise.toml`, Rust 1.96.1, Zig 0.15.2, and
bundle ID `dev.adonm.zuko`. The iOS workflow retains
`scripts/prepare-libghostty-ios-static.py` before its device archive build.

## Codemagic boundary

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

The workflows decode signing material only into an ephemeral runner directory.
Commands pass passwords and API credentials by environment or protected files;
do not add shell tracing or print those values.

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

## GitHub configuration

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

Certificate and profile values are unwrapped base64. Protect the
`apple-store` environment with required reviewers and restrict deployment to
the release refs allowed by repository policy. Put all listed secrets, including
the three `ASC_*` values used by both iOS and macOS, in that environment.

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
