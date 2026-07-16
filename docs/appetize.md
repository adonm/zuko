# Appetize mobile previews

The coordinated GitHub release workflow updates two existing Appetize apps
from the same immutable annotated release tag used by GitHub Releases and
TestFlight:

- Android receives the checksummed, signed APK already published in the GitHub
  Release.
- iOS receives an unsigned ARM Flutter Simulator `.app` zip built from that
  same tag. Appetize cannot run the signed device IPA.

Appetize is a preview channel, not a source of release artifacts or credentials.

## One-time setup

1. In [Appetize API Tokens](https://appetize.io/organization/api-tokens), create
   a least-privilege Developer token named `zuko-codemagic`.
2. At [Appetize Upload](https://appetize.io/upload), create separate apps from a
   signed Android APK and an ARM iOS Simulator `.app` zip.
3. Copy each app's `publicKey` from its share URL or settings.
4. In Codemagic application settings, create the variable group
   `appetize_credentials` with these values:

   | Variable | Value |
   |----------|-------|
   | `APPETIZE_API_TOKEN` | Organization API token |
   | `APPETIZE_ANDROID_PUBLIC_KEY` | Android app public key |
   | `APPETIZE_IOS_PUBLIC_KEY` | iOS Simulator app public key |

   Mark the API token secret. The public keys are identifiers rather than
   credentials, but may also be marked secret to keep all three values scoped
   to the release workflow.

After GitHub publishes all assets for a tag, its release workflow starts
Codemagic's `mobile-appetize-release` workflow for that exact tag and waits for
both uploads. Codemagic verifies the immutable release identity, downloads the
published APK, checksum, and iOS Simulator ZIP, validates both archives, and
uploads those exact bytes. It installs no Flutter SDK and performs no compile.
The Android signing key remains only in GitHub. Pull requests and ordinary
branch builds cannot upload to Appetize.

## Verify credentials

Download an existing package and run the matching command:

```sh
read -r -s APPETIZE_API_TOKEN
export APPETIZE_API_TOKEN
sh scripts/upload-appetize.sh android ./zuko-android-vX.Y.Z-signed.apk \
  YOUR_ANDROID_PUBLIC_KEY "manual credential check"
sh scripts/upload-appetize.sh ios ./Zuko-Flutter-ios-simulator.zip \
  YOUR_IOS_PUBLIC_KEY "manual credential check"
unset APPETIZE_API_TOKEN
```

Confirm both dashboard entries report the expected version and launch. The
Android package must have the same application ID and signing certificate as
the GitHub Release APK; the iOS entry must report an ARM `iPhoneSimulator`
build.

## Rotation

- Rotate the organization token in Appetize, then replace
  `APPETIZE_API_TOKEN` in Codemagic's `appetize_credentials` group.
- If an app is recreated, replace its platform public-key secret.
- Keep preview access authenticated unless a public demo is intentional.
- Revoke temporary Appetize client authorization on the host after testing.

Implementation: `scripts/upload-appetize.sh`,
`scripts/publish-appetize-release.py`, `codemagic.yaml`, and
`.github/workflows/release.yml`.
