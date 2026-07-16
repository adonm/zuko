# Linux delivery through FlatPark

Zuko's graphical Linux client is available through
[FlatPark](https://flatpark.org/apps/dev.adonm.zuko/), an independent community
repository that is not affiliated with Flathub. FlatPark distributes the
official Zuko Linux release payload as a signed, sandboxed Flatpak.

![Zuko Linux client](zuko-linux.png)

Zuko does not build, sign, or host a Flatpak repository. Each immutable GitHub
Release instead contains the official x86_64 Flutter Linux payload:

```text
zuko-linux-vX.Y.Z-x86_64.tar.gz
zuko-linux-vX.Y.Z-x86_64.tar.gz.sha256
```

The archive contains one top-level `bundle/` directory with the executable,
Flutter data, and adjacent libraries. GitHub builds it on Ubuntu 24.04 with the
immutable Mise Flutter/GTK4 SDK. `scripts/package-linux-release.sh` normalizes the archive,
rejects links, privileged files, and non-relocatable runtime paths, checks
native linkage before and after extraction, and emits its checksum.

The separate FlatPark registry manifest downloads that official release asset
as Flatpak `extra-data`, pins its SHA-256 and byte size, and unpacks it
without modifying the application payload. FlatPark owns the wrapper,
AppStream data, repository signing, hosting, and package-update automation.
Users therefore trust both the official Zuko release bytes and FlatPark's
packaging and signing infrastructure; published registry packages are
reviewable in the
[FlatPark registry](https://github.com/flatpark/flatpark/tree/main/registry).

## Install

Add FlatPark and Flathub at the same user scope, then install Zuko:

```sh
flatpak --user remote-add --if-not-exists flatpark \
  https://dl.flatpark.org/flatpark.flatpakrepo
flatpak --user remote-add --if-not-exists flathub \
  https://dl.flathub.org/repo/flathub.flatpakrepo
flatpak --user install flatpark dev.adonm.zuko
flatpak run dev.adonm.zuko
```

The package grants only the capabilities required by the client:

- network access for Iroh;
- IPC, Wayland, and DRI for Flutter rendering;
- access to `org.freedesktop.secrets` for encrypted client state.

It grants no X11 socket and no host or home-directory filesystem access. A
Secret Service provider such as GNOME Keyring or KWallet must be running. If the
login keyring is locked, Zuko leaves encrypted state unchanged and displays an
unlock-and-retry screen without requesting an unlock itself. If no provider is
available, it reports secure storage as unavailable instead of creating an
unprotected fallback.

## Release and update maintenance

The Zuko release workflow publishes the raw archive and checksum. It does not
publish a `.flatpak`, `.flatpakref`, OSTree repository, or repository signing
key. `scripts/release_candidate.py` binds the archive bytes to the source
commit, and `scripts/publish-github-release.sh` fails closed unless the expected
archive and checksum are present exactly once.

The package's `resolve-update.sh` selects the exact versioned Linux archive from
the latest GitHub Release. FlatPark's update automation computes a new size and
checksum and opens a reviewed registry update. Changes to
the FlatPark wrapper, permissions, or metadata belong in that registry rather
than this repository.

For pre-publication testing, `just build-flatpark-test-bundle` builds the
versioned Linux payload in the pinned Ubuntu container, applies an
immutable revision of the registry's Zuko wrapper and permissions, and emits an
unsigned local test branch under `dist/flatpak/`. It embeds the payload only to
make local install testing self-contained; official FlatPark builds continue to
use reviewed `extra-data` pins and FlatPark's signing infrastructure.
