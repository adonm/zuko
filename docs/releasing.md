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

### `zuko app` (Linux only)

`zuko app` is part of the normal Linux build (no feature split). It is not wired
into non-Linux binaries. The **x86_64-linux** tarball additionally bundles
**cage** + a few wlroots `.so`s in a `cage/` dir next to the `zuko` binary.
`mise use` extracts both, so `zuko app` works with no extra setup — it spawns
the bundled cage (`WLR_BACKENDS=headless WLR_RENDERER=pixman`, no GPU) and
acts as a wlr-screencopy + virtual-keyboard/pointer client.

How the bundle is produced (in `release.yml`): a `docker run fedora:latest`
step installs `cage` (which pulls wlroots 0.20) and copies the binary + the
uncommon libs (`libwlroots-0.20.so`, `libliftoff.so.0`, `libseat.so.1`,
`libxcb-errors.so.0`) into `dist/cage/`. zuko finds it exe-relative
(`<exe_dir>/cage/`), falling back to `~/.local/share/zuko/cage` or a `cage`
on `PATH` / `$ZUKO_CAGE`.

Runtime deps not bundled (present on any host that runs GUI apps, but worth
knowing): `libwayland`, `libxkbcommon`, `libdrm`, `libxcb`, `libinput`,
`libudev`, mesa's `libEGL`/`libGLESv2`. On a truly minimal/headless server you
may need to install these. glibc portability tracks Fedora (recent) — if you
need to support older distros, the follow-up is to build a stripped wlroots
(`-Dbackends=headless -Drenderers=pixman -Dxwayland=disabled`) + cage from
source against an older glibc, which shrinks the closure to ~5 libs.

**Not yet bundled for aarch64-linux** (needs QEMU in CI); on aarch64,
`zuko app` requires a `cage` on `PATH` until that's added.

**Cutting a release** is one command — it commits any pending work, pushes
the branch, creates an annotated `v*` tag, and pushes the tag (which fires
[`release.yml`](https://github.com/adonm/zuko/blob/main/.github/workflows/release.yml)):

```sh
mise run release v0.4.2   # = sh scripts/release.sh v0.4.2
```

The script refuses to tag a version that doesn't match `Cargo.toml`'s
`version`, and refuses to clobber an existing tag.

Patch-release checklist before running it:

```sh
mise run test
mise run lint          # if any iOS Swift changed
mise run build-ios     # if any iOS Swift/build config changed
```

For an iOS-facing patch, also skim the first-run tips in
[`OnboardingView.swift`](https://github.com/adonm/zuko/blob/main/ios/Zuko/Zuko/Views/OnboardingView.swift) and the
iOS app notes in [`ios/Zuko/README.md`](https://github.com/adonm/zuko/blob/main/ios/Zuko/README.md) so TestFlight
copy/screenshots don't drift from the toolbar controls.

## iOS app

See [`ios/DISTRIBUTION.md`](https://github.com/adonm/zuko/blob/main/ios/DISTRIBUTION.md) for signed builds +
TestFlight, entirely from GitHub Actions (no Mac required).
