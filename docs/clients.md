# Clients

| Client | Status | Get it |
|--------|--------|--------|
| Rust CLI | Core | [curl installer](getting-started.md) or Linux/macOS release tarball |
| Android | Beta | Signed APK attached to tagged GitHub Releases |
| iOS/iPadOS | Beta | Signed TestFlight workflow |
| macOS | Beta | CI-built application bundle |
| Web | Labs | [zuko.adonm.dev/web/](https://zuko.adonm.dev/web/) |
| Linux desktop | Beta | Flatpak attached to GitHub Releases |
| Windows desktop | Labs | Versioned x86_64 ZIP on GitHub Releases |

Release downloads are at
[github.com/adonm/zuko/releases/latest](https://github.com/adonm/zuko/releases/latest).
Every downloadable package has a `.sha256` sidecar.

- Android: install the signed APK; the AAB is for store upload.
- Linux: install the Flatpak bundle; credentials use the host Secret Service.
- Windows: extract the complete ZIP and run `zuko.exe`; do not move the EXE
  away from its DLL and data files.

The Windows bundle is not yet an installer and does not provide automatic updates.
For toolchains, fresh-clone commands, signing behavior, and exact output paths,
see [Building clients](building-clients.md).

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
target. TestFlight and desktop store publication remain protected release jobs.

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
