# Android store publishing

Android compilation remains a native Flutter/Gradle build. The manual
`publish-flutter-android.yml` workflow uses pinned Codemagic CLI Tools only at
the signing, bundle validation, Google Play API validation, and upload boundary.
It must be dispatched from `main` with a `vX.Y.Z` release version.

The workflow checks out the selected `main` commit, runs a normal unsigned
`flutter build appbundle`, and signs that output with Codemagic inside the
protected publishing job. It validates and uploads the exact AAB retained as
the final workflow artifact.

The workflow verifies all of the following before upload:

- the requested version matches the checked-out Cargo and Flutter metadata;
- the Google Play version code is the dispatch timestamp, so a new recovery run
  for the same version receives a higher code;
- the package and namespace are `dev.adonm.zuko`;
- Bundletool accepts the AAB and its manifest reports the expected package,
  version name, and version code;
- the JAR signature is valid and its certificate is the configured Google Play
  upload key;
- the SHA-256 sidecar matches, and the file is unchanged immediately before the
  Codemagic Google Play upload.

## Google Play setup

External setup cannot be created safely by this repository:

1. Register `dev.adonm.zuko` in Google Play Console. Complete the developer
   account, agreements, payments profile, app access, ads, content rating,
   target audience, data safety, privacy policy, store listing, and any required
   testing declarations.
2. Enroll the app in Play App Signing. Preserve the existing keystore as the
   **upload key**; it is not the Google-managed app-signing key. Existing users
   can only upgrade when the package name and signing lineage remain valid.
3. Make the first Play Console upload manually if the application has never had
   an artifact. The Android Publisher API cannot create the app record or
   bootstrap every first-release state.
4. In a dedicated Google Cloud project, enable the Google Play Android Developer
   API and create a dedicated service account with a JSON key.
5. In Play Console, invite or link that service account under **Users and
   permissions**. Restrict it to Zuko and grant only the app/release permissions
   needed to inspect tracks and publish releases. Confirm API access with the
   internal track before allowing production.
6. Create a GitHub Actions environment named `google-play`. Add required
   reviewers, prevent self-review where practical, and restrict deployment to
   `main`. Store the secrets below on that environment, not as plaintext files
   or workflow inputs.

## Protected secrets

| Environment secret | Value |
|--------------------|-------|
| `ANDROID_KEYSTORE_BASE64` | Base64-encoded upload keystore bytes |
| `ANDROID_KEYSTORE_PASSWORD` | Upload keystore password |
| `ANDROID_KEY_ALIAS` | Upload key alias |
| `ANDROID_KEY_PASSWORD` | Upload key password |
| `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON` | Complete service-account JSON key |

Do not enable shell tracing or print these values. The workflow writes decoded
credentials only under the ephemeral runner directory with restrictive
permissions and deletes them after use. Codemagic receives passwords through
`@env:` and the Google credential through `@file:` rather than command-line
plaintext.

## Dispatch and release

Run **publish-flutter-android** manually, select the release version, Play track,
and mode. `draft` uploads a draft release; `release` makes it
available according to the selected track and Google Play review state. Use the
internal track first. A production `release` is a full production release, so
the `google-play` environment approval is the final human control.

Google Play upload does not complete the store listing, policy declarations,
managed publishing choice, country/device availability, staged production
rollout, release review, or final publication. Complete and audit those records
in Play Console.
