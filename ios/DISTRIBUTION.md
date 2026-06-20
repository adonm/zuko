# Distributing Zuko (signed builds + TestFlight, no Mac needed)

Produce a **signed** `.ipa` and push it to **TestFlight** entirely from GitHub
Actions — you never need to open Xcode on a Mac.

All signing material lives in **GitHub secrets on this repo** (no separate
certs repository). The workflow is
[`.github/workflows/release-ios.yml`](../.github/workflows/release-ios.yml):
*Actions → release-ios → Run workflow*.

## How it works

CI imports your **Apple Distribution** certificate (`.p12`) into a temporary
keychain and installs your **provisioning profile** (`.mobileprovision`), then
fastlane `gym` archives and exports an app-store `.ipa`, and `pilot` uploads it
to TestFlight. The App Store Connect **API key** secret authenticates the
TestFlight upload.

## Prerequisites

1. **Apple Developer Program** membership ($99/yr).
2. **App ID** registered for bundle id `dev.adonm.zuko` (no special capabilities
   needed for Zuko).
3. **App Store Connect API key** (at least *App Manager* role) for TestFlight
   uploads: App Store Connect → *Users and Access → Keys → Generate API Key*.
   Download the `.p8`, note **Key ID** and **Issuer ID**.

## Create the signing certificate + profile (one time)

You need an **Apple Distribution** certificate and an **App Store** provisioning
profile for `dev.adonm.zuko`. Both are exportable files you'll store as secrets.

### Without a Mac (openssl + the Developer portal)

Run on any machine with openssl:

```sh
# 1. generate a private key + CSR
openssl req -newkey rsa:2048 -nodes -keyout zuko.key -out zuko.csr -subj "/CN=Zuko Distribution"

# 2. in your browser: developer.apple.com → Certificates, IDs & Profiles →
#    Certificates → + → Apple Distribution → upload zuko.csr → download zuko.cer

# 3. combine the downloaded .cer with your key into a password-protected .p12
export P12_PASSWORD='choose-a-strong-password'
openssl pkcs12 -export -out zuko.p12 -inkey zuko.key -in zuko.cer -password pass:"$P12_PASSWORD"
```

Then create the profile in the portal: *Profiles → + → App Store → select the
Zuko App ID → select the certificate above → download `Zuko_AppStore.mobileprovision`*.

### With a Mac

Keychain Access → *Certificate Assistant → Request a Certificate from a
Certificate Authority* to make the CSR, create the *Apple Distribution* cert in
the portal, install it, then *export* the identity as a `.p12` (right-click the
identity → Export). Create + download the App Store profile as above.

## GitHub secrets to set (repo → Settings → Secrets → Actions)

Create these seven secrets:

| Secret | Value |
|--------|-------|
| `BUILD_CERTIFICATE_BASE64`   | `base64` of your `zuko.p12` (e.g. `base64 -i zuko.p12`) |
| `P12_PASSWORD`               | the password you set on the `.p12` |
| `PROVISIONING_PROFILE_BASE64`| `base64` of your `.mobileprovision` |
| `TEAM_ID`                    | your Apple **Team ID** |
| `ASC_KEY_ID`                 | App Store Connect API **Key ID** |
| `ASC_ISSUER_ID`              | App Store Connect **Issuer ID** |
| `ASC_KEY_CONTENT`            | full contents of the `.p8` (PEM body, newlines included) |

### Shortcut: `mise run setup-ios-signing`

[`scripts/setup-ios-signing.sh`](../scripts/setup-ios-signing.sh) automates the
whole flow: generates the key + CSR, opens the right portal pages, builds the
`.p12` with a random password, and pushes all seven secrets via the `gh` CLI
(no Mac needed, no manual copy-paste into the secrets UI). Prereqs: `openssl`
+ `gh` on PATH, `gh auth login` done, run from inside the repo.

```sh
mise run setup-ios-signing
```

Artifacts (`.key`, `.p12`, `.mobileprovision`, `.p8`, etc.) land under
`~/.config/zuko/ios-signing/` (override with `ZUKO_IOS_SIGNING_DIR`) — outside
the repo so `git clean` can't delete them, and reused on re-runs so rotation
is just "run it again". The manual steps below are the same flow, done by
hand — use them as a reference or if you prefer not to authorise `gh` to set
secrets from your machine.

## Run it

*Actions → release-ios → Run workflow*:

- `beta` — builds the signed `.ipa` and uploads it to TestFlight. The build
  shows up in TestFlight within a few minutes.
- `build` — same, but skips the TestFlight upload; the `.ipa` is published as a
  workflow artifact (useful for verifying signing without spending a TestFlight
  slot).

## Notes

- **Rotating**: generate a new `.p12`/profile and overwrite the three
  `*_BASE64` secrets + `P12_PASSWORD`. CI picks them up on the next run.
- **App Store release**: `beta` gets you into TestFlight (your devices + beta
  testers). A public App Store release additionally needs store metadata
  (description, screenshots, privacy policy URL, data-collection answers). Add
  a fastlane `deliver` lane when ready.
- **automatic signing**: the build uses automatic signing against the imported
  certificate. If your profile/cert setup needs manual signing, drop an
  `ExportOptions.plist` and pass it to `gym` via `export_options:`.
