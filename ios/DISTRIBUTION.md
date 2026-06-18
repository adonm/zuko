# Distributing Zuko (signed builds + TestFlight, no Mac needed)

This describes how to produce a **signed** `.ipa` and push it to **TestFlight**
entirely from GitHub Actions — you never need to open Xcode on a Mac. It uses
[fastlane](https://fastlane.tools) [`match`](https://docs.fastlane.tools/actions/match/)
for signing and `gym`/`pilot` for build/upload.

The workflow is [`.github/workflows/release-ios.yml`](../.github/workflows/release-ios.yml)
(manual: *Actions → release-ios → Run workflow*).

## How it works (no Mac, no Keychain Access)

The traditional pain is creating the distribution **certificate**, which
normally needs Keychain Access on macOS to generate a CSR. `match` sidesteps
this: with an **App Store Connect API key** it talks to Apple's Developer Portal
API directly and creates the cert + provisioning profile on the CI runner, then
stores them (encrypted) in a private git repo. Every later run just reads them
back. No CSR, no `.p12` wrangling, no Mac.

## One-time prerequisites

1. **Apple Developer Program** membership ($99/yr) — <https://developer.apple.com/programs/>.
2. **App ID** for bundle id `dev.adonm.zuko`: App Store Connect → *Users and
   Access → Certificates, IDs & Profiles* → create an App ID (no special
   capabilities needed for Zuko).
3. **App Store Connect API key** (Admin role): App Store Connect →
   *Users and Access → Keys → Generate API Key*. Give it *Admin* (needed so
   `match` can create certs/profiles). Download the `.p8` and note the **Key ID**
   and **Issuer ID**.
4. **A private git repo to store certs** (e.g. `adonm/zuko-certs`). Add a
   **deploy key** (Settings → SSH keys) with write access and keep the private
   key — this is how CI pushes the cert it creates on the first run.

## GitHub secrets to set (repo → Settings → Secrets and variables → Actions)

| Secret | Value |
|--------|-------|
| `ASC_KEY_ID`            | App Store Connect API **Key ID** |
| `ASC_ISSUER_ID`         | App Store Connect **Issuer ID** |
| `ASC_KEY_CONTENT`       | The full contents of the downloaded `.p8` (PEM body, including newlines) |
| `TEAM_ID`               | Your Apple **Team ID** (Membership tab at developer.apple.com) |
| `MATCH_GIT_URL`         | SSH url of the certs repo, e.g. `git@github.com:adonm/zuko-certs.git` |
| `MATCH_PASSWORD`        | A strong passphrase — used to encrypt the cert repo |
| `MATCH_GIT_PRIVATE_KEY` | The private deploy key for the certs repo (so CI can push the first cert) |

## Running it

1. **First run** (bootstraps signing): *Actions → release-ios → Run workflow*,
   choose `lane: signonly`, and ensure the repo variable `MATCH_READONLY` is
   `false` (the default). This creates the cert + profile and commits them to
   the certs repo.
2. **Set `MATCH_READONLY=true`** for normal runs (repo → *Variables*). Faster
   and prevents accidental cert changes.
3. **Beta**: choose `lane: beta` — signs, builds a signed `.ipa`, uploads to
   TestFlight. The build appears in TestFlight within a few minutes.
4. **Build only**: choose `lane: build` — same but skips the TestFlight upload;
   the `.ipa` is published as a workflow artifact.

The iOS tools (xcodegen + fastlane, both Homebrew formulae) are installed by
`mise run setup-ios`, so this workflow uses the same toolchain as local dev and
the unsigned simulator build.

## Going further (full App Store release)

- `beta` gets you into TestFlight, which is enough to install on your own
  devices and beta testers.
- For a public App Store release you'll additionally want store metadata
  (description, screenshots, privacy answers). Add a `release` lane using
  fastlane [`deliver`](https://docs.fastlane.tools/actions/deliver/) and a
  screenshots directory — out of scope for this starter, but the lane is the
  natural place to add it.
- App Store Connect now requires a **privacy policy URL** and the *data
  collection* questionnaire for new submissions; have those ready.

## Troubleshooting

- **`match` permission errors**: the API key must be *Admin*, not just
  App Manager.
- **profile expired**: set `MATCH_READONLY=false` once and run `signonly` to
  regenerate.
- **`DEVELOPMENT_TEAM` blank**: ensure the `TEAM_ID` secret is set; the Fastfile
  injects it as a build setting for automatic signing.
- **different bundle id**: change `app_identifier` in
  [`fastlane/Appfile`](fastlane/Appfile) and `PRODUCT_BUNDLE_IDENTIFIER` in
  [`Zuko/project.yml`](Zuko/project.yml) together.
