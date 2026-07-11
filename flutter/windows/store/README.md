# Microsoft Store publishing for Flutter Windows

The manual `publish-flutter-windows` workflow packages the source identified by
an immutable `vX.Y.Z` release tag. It records the source commit, creates signed
MSIX and MSIXBundle artifacts, and uploads the bundle to a Partner Center draft.
The `submit` lane requires a second protected environment before it commits that
draft for certification.

## Package mapping

`store-config.json` fixes the logical application ID to `dev.adonm.zuko` and the
architecture to `x64`. Partner Center assigns the package identity, publisher,
package family name, display name, and product ID; none of those values are
guessed or committed here. `Package.ps1`, `Test-Package.ps1`, and
`Test-PartnerCenter.ps1` fail if the protected values, generated manifest,
signed artifacts, release metadata, and live Partner Center record disagree.

Microsoft Store reserves the fourth package-version component and requires a
nonzero first component. The monotonic mapping is therefore:

```text
vX.Y.Z -> (X + 1).Y.Z.0
```

The workflow still validates Flutter's canonical `X.Y.Z+build`, where `build`
is the repository's deterministic store build number. The Windows executable is
built as `X.Y.Z.0`, because each Windows file-version component is 16-bit and
cannot contain that build number. All Store package-version components must fit
the 0-65535 range.

## Protected environments

Create these GitHub environments and configure required reviewers. Do not put
these values in the workflow or repository-level variables.

| Environment | Purpose |
|-------------|---------|
| `microsoft-store-package` | Approves access to package identity and signing material. |
| `microsoft-store-draft` | Approves authentication and draft upload with `--noCommit`. |
| `microsoft-store-submit` | Separately approves `msstore submission publish`, which commits the draft. |

Set these environment variables wherever the workflow requests them. Values
must exactly match **Product management > Product identity** and the live app
record in Partner Center; comparisons are case-sensitive.

- `MSSTORE_PRODUCT_ID`
- `MSSTORE_PACKAGE_IDENTITY_NAME`
- `MSSTORE_PACKAGE_PUBLISHER`
- `MSSTORE_PACKAGE_FAMILY_NAME`
- `MSSTORE_PACKAGE_DISPLAY_NAME`
- `MSSTORE_PUBLISHER_DISPLAY_NAME`
- `MSSTORE_TENANT_ID` (draft and submit)
- `MSSTORE_SELLER_ID` (draft and submit)
- `MSSTORE_CLIENT_ID` (draft and submit)

Set these environment secrets:

- `MSSTORE_SIGNING_PFX_BASE64` and `MSSTORE_SIGNING_PFX_PASSWORD` in
  `microsoft-store-package`;
- `MSSTORE_CLIENT_SECRET` in `microsoft-store-draft` and
  `microsoft-store-submit`.

The PFX must contain a currently valid code-signing certificate whose subject
exactly equals `MSSTORE_PACKAGE_PUBLISHER` and whose chain passes SignTool's
default Authenticode policy. The script imports it only into the ephemeral
runner's current-user certificate store, signs and timestamps both outputs,
verifies them, and removes the certificate and temporary PFX. GitHub secrets
are passed through the process environment and are never intentionally printed.

Use least-privilege Partner Center credentials for a Microsoft Entra application
associated with the Store account. Microsoft currently documents automated app
updates for free products, and the app must already exist with a submission;
the CLI does not create the first loose-MSIX submission.

## Run

1. Run `publish-flutter-windows` from `main` with the immutable release tag and
   `lane=draft`.
2. Download and retain the signed workflow artifact, then review the draft and
   certification inputs in Partner Center.
3. Run the workflow for the same release tag with `lane=submit`. Approve
   `microsoft-store-submit` only after reviewing the newly uploaded draft.

The second run rebuilds and reuploads the same tagged source before approval;
it never commits a draft from an unrelated run. Concurrency prevents two Store
publishing runs from changing the app draft at the same time.
Once Partner Center accepts the package version, cut a new Zuko version rather
than trying to replace the published package.

Before enabling submission, run the generated package through the Windows App
Certification Kit and confirm launch/install behavior on supported Windows 10
and Windows 11 systems. CI verifies package structure and signatures, but WACK
and Partner Center certification remain release gates.

The workflow pins `microsoft/microsoft-store-apppublisher` to immutable commit
`b76227f539d68e6465f79bbbc82ed92f61081aa4` (release `v1.3`) and asks that action
for MSStore Developer CLI `v0.3.9`. Review both upstream releases before moving
either pin.
