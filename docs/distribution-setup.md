# Distribution setup checklist

This is the single operator checklist for external identities, GitHub
environments, variables, secrets, and first uploads. Platform-specific details
remain in the linked guides. Never commit credentials or pass them as workflow
inputs.

## Common release controls

- [ ] Keep Cargo and Flutter versions aligned (`0.9.18` and
  `0.9.18+1800009018` at the time of writing); run
  `just check-release-metadata`.
- [ ] Use application/package/bundle ID `dev.adonm.zuko` everywhere except the
  Partner Center-assigned Microsoft package identity.
- [ ] Keep `https://adonm.dev` reachable and visibly associated with Zuko so
  the reverse-DNS ID remains supportable and can be verified by stores.
- [ ] Require reviews on every publishing environment and prevent self-review
  where practical.
- [ ] Run `just check`, `just test-e2e`, and the platform package check before
  creating an annotated `vX.Y.Z` tag.

## GitHub configuration matrix

| Scope | Name | Required values |
|-------|------|-----------------|
| Repository secrets | coordinated Flutter release | `CODEMAGIC_API_TOKEN` with access to Codemagic app `6a52dc14add8531e99f88b8a`; `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, and `ANDROID_KEY_PASSWORD` for signing exact Codemagic Android outputs |
| Repository secret | static Flatpak testing repository | `FLATPAK_GPG_PRIVATE_KEY_BASE64`, containing the base64-encoded private export matching `flatpak/zuko-flatpak-repo.gpg` |
| `google-play` environment | Play publication | `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD`, and `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON` |
| `microsoft-store-package` environment | package/sign | variables `MSSTORE_PRODUCT_ID`, `MSSTORE_PACKAGE_IDENTITY_NAME`, `MSSTORE_PACKAGE_PUBLISHER`, `MSSTORE_PACKAGE_FAMILY_NAME`, `MSSTORE_PACKAGE_DISPLAY_NAME`, `MSSTORE_PUBLISHER_DISPLAY_NAME`; secrets `MSSTORE_SIGNING_PFX_BASE64`, `MSSTORE_SIGNING_PFX_PASSWORD` |
| `microsoft-store-draft` environment | draft upload | the six package variables above plus `MSSTORE_TENANT_ID`, `MSSTORE_SELLER_ID`, `MSSTORE_CLIENT_ID`; secret `MSSTORE_CLIENT_SECRET` |
| `microsoft-store-submit` environment | final submission | the same values as `microsoft-store-draft`, with a separate final approval |
| `crates-io` environment | trusted publish | no long-lived secret; allow OIDC and configure the crates.io trusted publisher after the initial publication |

Environment values are not shared between GitHub environments. Repeat the
Microsoft identity variables in every environment that consumes them, and
repeat `MSSTORE_CLIENT_SECRET` in both draft and submit.

## Codemagic configuration matrix

| Scope | Name | Required values |
|-------|------|-----------------|
| Developer Portal integration | `zuko-app-store` | App Store Connect App Manager issuer ID, key ID, and `.p8` key |
| iOS signing identity | `dev.adonm.zuko` | matching Apple Distribution certificate and App Store provisioning profile |
| Android signing identity | `zuko-android` | optional for the manual Appetize workflow; existing release keystore, alias, store password, and key password |
| Variable group | `codemagic_api` | secret `CODEMAGIC_API_TOKEN` used by the existing iOS artifact handoff |
| Variable group | `appetize_credentials` | `APPETIZE_API_TOKEN`, `APPETIZE_ANDROID_PUBLIC_KEY`, `APPETIZE_IOS_PUBLIC_KEY` |

Codemagic's YAML workflows expose signing identities only to the workflows that
need them. Compile gates have no store or Appetize credentials. The coordinated
release passes no GitHub credential into Codemagic: GitHub retrieves unsigned
Android outputs and signs them locally, while Apple signing material remains in
Codemagic.

## First-time portal work

### Google Play

- [ ] Create `dev.adonm.zuko`, complete Play policy/listing declarations, and
  enroll in Play App Signing.
- [ ] Preserve the existing keystore as the upload key.
- [ ] Make the first Console upload if required, then grant a dedicated service
  account least-privilege access to Zuko and test the internal track.
- [ ] Dispatch `publish-flutter-android.yml` with `draft` on the internal track
  before any production release.

Details: [Android store publishing](android-publishing.md).

### Apple

- [ ] Create the explicit App ID and iOS App Store Connect record for
  `dev.adonm.zuko`.
- [ ] Create an Apple Distribution certificate and matching iOS App Store
  profile.
- [ ] Create a dedicated App Store Connect App Manager API key and retain its
  issuer ID, key ID, and one-time `.p8` securely.
- [ ] Run Codemagic's manual `ios-signing-validation` first. An annotated
  release tag uploads iOS to TestFlight automatically; validation never
  uploads. GitHub requires no Apple signing secrets.

Details: [Apple store publishing](apple-publishing.md).

### Microsoft Store

- [ ] Reserve the app and copy every identity value exactly from **Product
  management > Product identity**; do not derive these values from
  `dev.adonm.zuko`.
- [ ] Associate a least-privilege Entra application, create the code-signing
  PFX, and ensure the certificate subject exactly equals the assigned publisher.
- [ ] Complete the initial Partner Center submission, run WACK locally, then
  dispatch `lane=draft`. Approve `lane=submit` only after reviewing the draft.

Details: [Microsoft Store publishing](windows-publishing.md) and the
[package identity reference](../flutter/windows/store/README.md).

### crates.io

- [x] Publish `crossterm-zuko 0.29.0-zuko.1` first from immutable fork tag
  `crossterm-zuko-v0.29.0-zuko.1` using a short-lived crates.io token. The
  tagged source and commit are
  `adonm/crossterm@cc3e2009082bb6b4dec31a42f1b11ff0e2a004a6`.
- [x] Run `scripts/check-crate-package.sh`; it must resolve that exact registry
  package and verify the underflow fix before Zuko is publishable.
- [x] Publish Zuko's first verified crate version with a short-lived token.
- [x] Configure crates.io trusted publishing with environment `crates-io` for
  `adonm/zuko` workflow `publish-crate.yml` and `adonm/crossterm` workflow
  `publish-zuko.yml`, then require trusted publishing for both crates.
- [ ] Revoke the bootstrap token in crates.io account settings. It has been
  removed from local Cargo storage, but its endpoint scope did not permit API
  self-revocation.

### Linux Flatpak and Flathub

- [x] Create the dedicated static-repository signing identity, commit only its
  public key, and store its private export in the repository secret.
- [x] Publish the latest release bundle as a signed archive-z2 repository and
  from-empty static delta under `/flatpak/` on the documentation site.
- [ ] Build and test the release-attached bundle with `just container-flatpak`.
- [ ] Install Flathub's official author tool with `just flatpak-author-setup`,
  then run `just flatpak-author-lint`.
- [ ] Capture and host real application screenshots, add them to AppStream, and
  clear both `metainfo-missing-screenshots` and
  `appstream-screenshots-not-mirrored-in-ostree` in repository lint.
- [ ] Treat `flatpak/dev.adonm.zuko.json` as a release-bundle manifest, not a
  Flathub source-build submission. Read the current
  [submission guide](https://docs.flathub.org/docs/for-app-authors/submission)
  and [requirements](https://docs.flathub.org/docs/for-app-authors/requirements)
  before preparing any separate submission.

Details: [Flatpak packaging](../flatpak/README.md).

## Release order

1. Complete the portal records, Codemagic identities/groups, and protected
   GitHub environments.
2. Publish the `crossterm-zuko` bootstrap dependency and verify Zuko packaging.
3. Cut the tag and let GitHub trigger exact Codemagic release builds, verify
   their checksummed handoff, and publish the coordinated GitHub Release.
4. Confirm the automatic TestFlight build, then publish Google Play internal,
   Mac App Store, and Microsoft draft builds through their protected workflows.
5. Review each portal's retained artifact, metadata, policy answers, and human approval before production submission.

Tags are immutable release source identities. Re-run failed jobs only when the
source and workflow are unchanged. If automation or packaging needs a code
change, increment the patch version and cut a new tag; never publish current
`main` under an older tag.
