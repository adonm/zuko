# Appetize mobile previews

Tagged releases update two existing Appetize apps:

- Android receives the exact signed Flutter APK attached to GitHub Releases.
- iOS receives an unsigned ARM Flutter Simulator `.app` zip built from the same
  immutable tag. Appetize cannot run the signed device IPA.

Appetize is a preview channel, not a source of release artifacts or credentials.

## One-time setup

1. In [Appetize API Tokens](https://appetize.io/organization/api-tokens), create
   a least-privilege Developer token named `zuko-github-actions`.
2. At [Appetize Upload](https://appetize.io/upload), create separate apps from a
   signed Android APK and an ARM iOS Simulator `.app` zip.
3. Copy each app's `publicKey` from its share URL or settings.
4. Add these GitHub Actions secrets:

   | Secret | Value |
   |--------|-------|
   | `APPETIZE_API_TOKEN` | Organization API token |
   | `APPETIZE_ANDROID_PUBLIC_KEY` | Android app public key |
   | `APPETIZE_IOS_PUBLIC_KEY` | iOS Simulator app public key |

The GitHub CLI prompts without placing values in shell history:

```sh
gh secret set APPETIZE_API_TOKEN
gh secret set APPETIZE_ANDROID_PUBLIC_KEY
gh secret set APPETIZE_IOS_PUBLIC_KEY
```

Repository secrets are unavailable to untrusted pull requests, and ordinary PR
builds never upload to Appetize.

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

Confirm both dashboard entries report the expected version and launch. The APK
must match the GitHub Release checksum; the iOS entry must report an ARM
`iPhoneSimulator` build.

## Rotation

- Rotate the organization token in Appetize, then replace
  `APPETIZE_API_TOKEN` in GitHub.
- If an app is recreated, replace its platform public-key secret.
- Keep preview access authenticated unless a public demo is intentional.
- Revoke temporary Appetize client authorization on the host after testing.

Implementation: `scripts/upload-appetize.sh` and
`.github/workflows/release.yml`.
