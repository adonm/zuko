# Releasing zuko

Maintainer-facing notes. Users don't need this — `mise use --global
github:adonm/zuko` pulls prebuilt binaries automatically.

## `zuko` binary

Tagging `v*` (or running the `release` workflow) cross-compiles `zuko` for
`linux/{x86_64,aarch64}` and `macos/{x86_64,aarch64}` and attaches tarballs
to a GitHub Release, which `mise use --global github:adonm/zuko` consumes.
The release binary is ~9.5 MB — built with boring dependencies and standard
size-conscious cargo flags (`opt-level="z"`, fat LTO, stripped symbols); no
bespoke trimming, on purpose.

**Cutting a release** is one command — it commits any pending work, pushes
the branch, creates an annotated `v*` tag, and pushes the tag (which fires
[`release.yml`](../.github/workflows/release.yml)):

```sh
mise run release v0.4.2   # = sh scripts/release.sh v0.4.2
```

The script refuses to tag a version that doesn't match `Cargo.toml`'s
`version`, and refuses to clobber an existing tag.

## iOS app

See [`ios/DISTRIBUTION.md`](../ios/DISTRIBUTION.md) for signed builds +
TestFlight, entirely from GitHub Actions (no Mac required).
