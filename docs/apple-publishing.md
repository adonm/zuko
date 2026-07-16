# Apple publishing with Codemagic

GitHub Actions builds unsigned iOS Simulator and macOS candidates. Codemagic is
used only where Apple trust material is required; GitHub stores no Apple
certificate, provisioning profile, or App Store Connect key.

`codemagic.yaml` defines:

- `ios-signing-validation`: builds and retains one signed IPA from an exact
  temporary release-candidate branch before the tag exists;
- `ios-testflight-release`: downloads that retained IPA, revalidates it against
  the annotated tag, and uploads it without rebuilding.

Both workflows use M2 runners, Xcode 26.3, CocoaPods 1.16.2, and the same
checksum-pinned Mise Flutter SDK used by GitHub. Codemagic CLI Tools 0.68.0 come
from the hash-locked `scripts/codemagic-requirements.txt` closure.

## One-time setup

1. Add `adonm/zuko` with `codemagic.yaml` at the repository root.
2. Add App Store Connect App Manager integration `zuko-app-store`.
3. Add an Apple Distribution certificate and matching App Store profile for
   `dev.adonm.zuko`, team `R8PN382RC4`.
4. Store a Codemagic API token as GitHub secret `CODEMAGIC_API_TOKEN` and in the
   Codemagic `codemagic_api` group used by artifact recovery.

## Release behavior

`prepare-release.yml` verifies an exact successful GitHub candidate, pushes a
temporary branch named `release-candidate/vX.Y.Z-<sha>`, and triggers
`ios-signing-validation` with that branch, tag, and full commit. Codemagic
requires its checkout and built-in commit identity to equal the requested
commit before reading signing material.

After the signed candidate succeeds, GitHub rechecks `origin/main`, pushes the
annotated tag, and deletes the temporary branch. The tag workflow locates the
successful candidate by workflow, branch, and commit, then asks
`ios-testflight-release` to:

1. download the exact retained IPA by build ID;
2. verify bundle ID, version, build, team, signature, profile, ARM64
   architecture, Ghostty framework, and iOS 18 deployment floor;
3. retain a SHA-256 sidecar; and
4. upload through `zuko-app-store` for TestFlight processing.

Rerunning the GitHub release resumes successful Codemagic builds and uploads;
it does not rebuild an accepted IPA. A corrected App Store build requires a new
source version or an explicitly reviewed `IOS_BUILD_NUMBER_OVERRIDE` candidate.

TestFlight upload does not submit for review. Tester groups, screenshots,
privacy declarations, export compliance, pricing, and review remain App Store
Connect operations. Mac App Store packaging is not automated.
