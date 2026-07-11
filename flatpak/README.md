# Flutter Linux Flatpak

The release pipeline creates one x86_64 bundle named
`zuko-linux-vX.Y.Z-x86_64.flatpak` and its SHA-256 sidecar. The application ID
is `dev.adonm.zuko`; both the Freedesktop runtime and SDK use branch `25.08`.

This is a release-bundle manifest, not a Flathub submission manifest. It imports
the already-built Flutter Linux bundle from a local `dir` source. Flathub
requires a top-level manifest that builds entirely from declared sources with
no network during the build; source code and prebuilt artifacts must not be
committed to the submission repository.

## Reproducibility model

This is a validated two-stage build. A fully offline Flatpak source manifest
for Flutter would have to duplicate Flutter's pub, Cargo, and engine artifact
resolvers. Instead:

1. The official checksum-pinned Flutter `3.46.0-0.3.pre` beta archive in
   `mise.toml`, Rust `1.96.1`, LLVM 20.1.8, `pubspec.lock`, and `Cargo.lock`
   produce the Impeller Linux release bundle in the digest-pinned Freedesktop
   25.08 SDK CI image.
2. `scripts/package-flatpak.sh` hashes and normalizes that bundle, checks its
   native linkage, and imports only local files with `flatpak-builder
   --disable-download`. It then installs the result into a temporary user
   installation and checks every packaged ELF dependency.

The CI container digest also pins these runtime inputs:

```text
org.freedesktop.Platform/x86_64/25.08 fdad08cc10905f9175f0224652a7b1c1b4d37fc1a5fa8c97843ccef846c642a0
org.freedesktop.Sdk/x86_64/25.08      30e83c31042c341df56dbca804ec2f1eef204145c513659b83d6c446b2e7b4f5
```

The package script rejects other commits. Update the container digest and both
commit pins together after validating a Freedesktop SDK update.

## Local validation

Metadata validation does not require a Flutter build:

```sh
just flatpak-validate
```

For a host-independent Flutter check, Linux build, or complete Flatpak package,
use the digest-pinned Podman environment:

```sh
just container-flutter
just container-flutter linux
just container-flatpak
```

The container image is built from `containers/flutter-flatpak.Containerfile`
and uses the same Freedesktop image digest and pinned tools as CI. Podman volumes
cache Cargo and pub downloads; generated outputs remain in the working tree's
ignored build directories.

## Official Flathub author tooling

Flathub recommends [`org.flatpak.Builder`](https://github.com/flathub/org.flatpak.Builder)
for submission-oriented local builds and linting. Install it and lint the
release manifest with:

```sh
just flatpak-author-setup
just flatpak-author-lint
```

After `just container-flatpak`, the lint recipe also validates the generated
OSTree repository at `build/flatpak/repo`. The authoritative process is the
[Flathub submission guide](https://docs.flathub.org/docs/for-app-authors/submission),
including its requirements, local `flathub-build`, manifest/repository lint,
and a pull request against the `new-pr` branch rather than `master`.

For a native host build instead of Podman, install the exact inputs from
Flathub before packaging:

```sh
flatpak install --system flathub \
  org.freedesktop.Platform//25.08 org.freedesktop.Sdk//25.08
sudo flatpak update --system \
  --commit=fdad08cc10905f9175f0224652a7b1c1b4d37fc1a5fa8c97843ccef846c642a0 \
  org.freedesktop.Platform//25.08
sudo flatpak update --system \
  --commit=30e83c31042c341df56dbca804ec2f1eef204145c513659b83d6c446b2e7b4f5 \
  org.freedesktop.Sdk//25.08
```

Build and package the current version:

```sh
just flatpak-package
```

The recipe performs a temporary install smoke test. To exercise the GUI and
Secret Service integration against the user's desktop:

```sh
flatpak --user install --reinstall \
  dist/linux/zuko-linux-v0.9.12-x86_64.flatpak
flatpak run dev.adonm.zuko
flatpak info --show-permissions dev.adonm.zuko
(cd dist/linux && \
  sha256sum --check zuko-linux-v0.9.12-x86_64.flatpak.sha256)
```

The sandbox grants network access, native Wayland, DRI, and only the
`org.freedesktop.secrets` session-bus name needed by libsecret. X11 is not a
supported package target. A host Secret Service provider such as GNOME Keyring
or KWallet must be running.
