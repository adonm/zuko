# Clients

| Client | Status | Get it |
|--------|--------|--------|
| Rust CLI | Core | [curl installer](getting-started.md) or Linux/macOS release tarball |
| Android | Beta | Signed APK attached to tagged GitHub Releases |
| iOS/iPadOS | Beta | Internal TestFlight build produced from each release tag |
| macOS | Beta | CI application artifact; protected Mac App Store package workflow |
| Web | Labs | [zuko.adonm.dev/web/](https://zuko.adonm.dev/web/) |
| Linux desktop | Beta | [FlatPark](https://flatpark.org/apps/dev.adonm.zuko/) |
| Windows desktop | Labs | Versioned x86_64 ZIP on GitHub Releases |

GitHub Release downloads are at
[github.com/adonm/zuko/releases/latest](https://github.com/adonm/zuko/releases/latest).
Every package attached there has a `.sha256` sidecar. The web deployment,
TestFlight build, and transient CI artifacts are separate delivery channels.

Fully signed public-store releases for every graphical target are still being
worked on. The checksummed GitHub Release packages are the best source for
testing current builds; they are not a claim that each platform's store
listing, review, installer, upgrade, and signing path is complete. iOS/iPadOS
testing continues through the separate internal TestFlight channel.

- Android: install the signed APK; the AAB is for store upload.
- Linux: install the signed FlatPark package; credentials use the host Secret
  Service.
- Windows: extract the complete ZIP and run `zuko.exe`; do not move the EXE
  away from its DLL and data files.

FlatPark is an independent community Flatpak hub. Add its signed remote and
Flathub's Freedesktop runtime source once, then install Zuko:

```sh
flatpak --user remote-add --if-not-exists flatpark \
  https://dl.flatpark.org/flatpark.flatpakrepo
flatpak --user remote-add --if-not-exists flathub \
  https://dl.flathub.org/repo/flathub.flatpakrepo
flatpak --user install flatpark dev.adonm.zuko
flatpak run dev.adonm.zuko
```

The package downloads Zuko's versioned Linux archive from the official GitHub
Release and pins its SHA-256 and size; FlatPark signs the resulting package
repository. It is not affiliated with Flathub. The release
archive and checksum remain the upstream payload and provenance record;
FlatPark owns the Flatpak wrapper and update channel. See [Linux delivery
through FlatPark](flatpark.md).

The Windows ZIP attached to GitHub Releases is not an installer and does not
provide automatic updates. A separate protected workflow can build and sign
MSIX/MSIXBundle packages for Partner Center, but that path remains manual. For
toolchains, fresh-clone commands, signing behavior, and exact output paths, see
[Building clients](building-clients.md).

## Implemented shared behavior

The current Flutter client provides the same application behavior on all six
targets unless a platform note below says otherwise:

- pair by entering a two-word code or `zuko://pair/...` value;
- preserve a stable client identity and saved hosts in protected platform
  storage, with invalid-state recovery;
- connect only after validating the saved endpoint ticket, host identity, and
  `ATTACHED` token;
- expose connecting, attached, retrying, ended, rejected, and failed states,
  with bounded reconnect for transient failures;
- rename, inspect, and forget saved hosts, including the host-side revocation
  command when its authorized-client label is known;
- render a resizable `flterm`/`libghostty` terminal with scrollback, selection,
  copy, guarded multi-line paste, desktop keyboard/IME input, and mobile
  accessory keys, plus a screen-reader-readable visible viewport and terminal
  focus action;
- persist system/light/dark theme and terminal font-size preferences.

The Linux shell uses Yaru's Adwaita-red theme and an integrated draggable title
bar with native window controls. Other desktop targets retain their platform
window chrome.

This is a remote shell client, not a durable session manager: it has no output
replay, and forgetting a host locally does not revoke that client on the host.
QR capture, operating-system deep-link registration, complete accessibility
coverage, and representative physical-device/browser testing remain promotion
gates rather than advertised capabilities.

The Rust CLI and shared Flutter client are the behavior references. Former
Compose, TypeScript, Relm4, and Swift UI implementations were removed.

The Flutter client shares:

- pairing and saved-host behavior;
- wire framing and bounded reconnect;
- `flterm`/`libghostty` terminal rendering;
- secure-storage model and platform-neutral UI;
- Dart unit and widget tests.

Native targets use `iroh_flutter`. Browser Iroh remains relay-only and uses the
Rust/WASM bridge in `flutter/rust/web_transport/`. Platform-specific code is
reserved for credential storage, URI delivery, lifecycle, and packaging.

Apple builds use the same Flutter implementation as every other graphical
target. A release tag automatically builds and uploads the protected iOS IPA to
internal TestFlight. macOS store packaging and upload remain manual protected
jobs; neither Apple package is attached to the GitHub Release.

## Implementing or reviewing a client

Read [`protocol.md`](protocol.md). A client must:

1. claim through `zuko/handoff/1`, derive the canonical Argon2 key, read the
   endpoint ticket, persist a stable client identity, and send `AUTHORIZE`;
2. dial the saved endpoint ticket with ALPN `zuko/2`;
3. open a bidirectional stream and send `ATTACH` first;
4. reject terminal data until the host echoes the expected token in `ATTACHED`;
5. serialize writes, chunk `DATA` at 65,535 bytes, and send `RESIZE` changes;
6. treat host `ERROR` and clean shell exit as permanent, while reconnecting only
   transient failures with bounded backoff;
7. cancel readers, writers, and pending retries on disconnect or host switch.

Reference implementations and fixtures:

- Rust: `src/wire.rs`, `src/client.rs`, `src/handoff.rs`
- Flutter: `flutter/lib/src/`, `flutter/test/`
- Browser bridge: `flutter/rust/web_transport/`
