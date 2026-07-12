# Appetize mobile previews

Tagged releases update two existing Appetize apps:

- Android receives a signed Flutter APK rebuilt from the immutable release tag
  with the same upload key as the GitHub Release APK.
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
5. Under Team settings > Code signing identities, upload the existing Android
   keystore with reference name `zuko-android`, its alias, and both passwords.

The `mobile-appetize-release` workflow imports that variable group and signing
identity only for immutable tag builds. Pull requests and ordinary branch
builds cannot upload to Appetize.

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

Implementation: `scripts/upload-appetize.sh` and `codemagic.yaml`.
