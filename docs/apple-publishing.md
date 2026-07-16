# Apple publishing with Codemagic

GitHub Actions builds unsigned iOS Simulator and macOS candidates. Codemagic is
used only where Apple trust material is required; GitHub stores no Apple
certificate, provisioning profile, or App Store Connect key.

`codemagic.yaml` defines one `ios-testflight-release` workflow. It checks out an
immutable annotated tag, builds and validates the signed IPA, and uploads it to
TestFlight. It uses an M2 runner, Xcode 26.3, CocoaPods 1.16.2, and the same
checksum-pinned Mise Flutter SDK used by GitHub. Codemagic CLI Tools 0.68.0 come
from the hash-locked `scripts/codemagic-requirements.txt` closure.

## One-time setup

1. Add `adonm/zuko` with `codemagic.yaml` at the repository root.
2. Add App Store Connect App Manager integration `zuko-app-store`.
3. Add an Apple Distribution certificate and matching App Store profile for
   `dev.adonm.zuko`, team `R8PN382RC4`.
4. Store a Codemagic API token as GitHub secret `CODEMAGIC_API_TOKEN`.
5. Protect the GitHub `testflight` environment.

## Release behavior

After the core GitHub Release is published, `publish-testflight.yml` resolves
the annotated tag and asks Codemagic to:

1. require its checkout and built-in tag/commit identity to match;
2. build the signed device IPA with the protected Apple identity;
3. verify bundle ID, version, build, team, signature, profile, ARM64
   architecture, Ghostty framework, and iOS 18 deployment floor;
4. retain a SHA-256 sidecar; and
5. upload through `zuko-app-store` for TestFlight processing.

Rerunning `publish-testflight.yml` reuses a successful exact-tag Codemagic build
and resumes an active one. A corrected App Store binary requires a new source
version; immutable tags and accepted store build numbers are never replaced.

TestFlight upload does not submit for review. Tester groups, screenshots,
privacy declarations, export compliance, pricing, and review remain App Store
Connect operations. Mac App Store packaging is not automated.
