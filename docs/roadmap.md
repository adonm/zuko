# Direction and roadmap

## North star

Zuko provides private remote shells for machines you own without opening an
inbound port or operating a VPN:

1. install a per-user host service;
2. pair once with a short code;
3. reconnect by name;
4. survive ordinary network and application lifecycle changes;
5. inspect or revoke access locally.

Iroh owns encrypted reachability. Zuko owns authorization, PTY behavior, the
terminal experience, recovery, packaging, and clear operator feedback.

## Supported products

| Tier | Product | Surfaces |
|------|---------|----------|
| **Core** | Host and reference client | Linux/macOS host and Rust CLI |
| **Beta** | Packaged shared Flutter client | Android, iOS/iPadOS, macOS, and Linux |
| **Labs** | Early delivery channels and application streaming | Flutter web/Windows and Linux `zuko app` |

The former Compose Android client, TypeScript web client, and Relm4 Flatpak
client and native Swift client were removed. They will not receive parallel
feature work.

## Current priority: ship one credible Flutter client

All Android, iOS, macOS, web, Linux, and Windows client work now lands in
`flutter/`.
Flutter shares navigation, saved-host behavior, pairing, framing, reconnect,
terminal integration, and tests. Platform code is limited to transport,
credential storage, deep links, lifecycle, and packaging where the operating
system genuinely differs.

Chosen foundations:

- **Terminal:** pinned `flterm` and `libghostty`; do not build another renderer.
- **Native transport:** pinned `iroh_flutter` on Android, iOS, macOS, Linux, and
  Windows.
- **Web transport:** Zuko's relay-only Rust/Iroh WASM bridge behind Dart JS
  interop until `iroh_flutter` has a production browser backend.
- **Storage:** `flutter_secure_storage`, backed by Android Keystore, Apple
  Keychain, Linux Secret Service, Windows protected storage, and browser-origin
  storage.
- **Versioning:** Cargo remains canonical; Flutter uses the same semantic
  version and the existing monotonic Android version-code formula.

The old Labs clients do not have an in-place state migration guarantee. The
Flutter Android package retains `dev.adonm.zuko` and the signing identity, but
users should expect to pair again after this cutover. The web app remains at
`/web/`, but old IndexedDB records are not imported automatically.
The Flutter iOS replacement likewise retains `dev.adonm.zuko` but intentionally
starts with new Keychain state and session-token derivation; pre-1.0 testers
must pair again and revoke the old native client authorization when finished.

## Delivery plan

### 1. Make the shared session trustworthy

Required before any Flutter target is promoted:

- validate endpoint tickets and host identity before dialing;
- keep the Argon2 handoff KDF and host-scoped token fixtures identical to Rust
  across Rust and Dart fixtures;
- require `ATTACHED` before accepting terminal data or user input;
- serialize writes and split data at the 65,535-byte frame limit;
- reconnect transient failures with bounded 1/2/4/8/15-second backoff;
- stop on authorization errors, protocol errors, clean shell exit, explicit
  disconnect, or host switch;
- bound terminal output and outbound work so a slow renderer cannot consume
  unbounded memory;
- add integration coverage for pairing, reconnect, revocation, malformed
  frames, and persisted identity on native and browser transports.

The shared Dart framing, pairing parser, KDF fixture, native transport, browser
bridge, and reconnect loops now exist. Integration and long-session coverage
remain release gates.

### 2. Reach terminal and lifecycle parity

The Flutter client must provide:

- correct styles, cursor, alternate screen, selection, clipboard, scrollback,
  resize, keyboard/IME, mouse reporting, and supported Kitty graphics;
- usable phone, tablet, desktop, and narrow-browser layouts;
- QR pairing plus handled `zuko://pair` links;
- explicit connecting, attached, retrying, rejected, ended, and disconnected
  states;
- foreground/background and network-change recovery on mobile targets;
- screen-reader semantics and keyboard-only operation;
- visible destructive reset behavior that rotates the client identity and
  explains host-side revocation.

`flterm` supplies the shared terminal surface. Typed recovery states, foreground
redial, mobile shortcut controls, host management, themes, and font sizing now
exist. Accessibility semantics, QR input, URI delivery, lifecycle tests, and
representative physical-device coverage remain open.

### 3. Ship each target through its normal channel

| Target | Release gate |
|--------|--------------|
| **Android** | Signed APK/AAB, Appetize preview, upgrade test, physical phone/tablet tests, Play-ready metadata |
| **Web** | Chrome/Firefox/Safari tests, strict CSP, origin review, deployed `/web/` smoke test |
| **Linux** | Reproducible Wayland-only Flatpak, Impeller rendering, Secret Service behavior, install/uninstall documentation |
| **Windows** | Promote the protected MSIX/MSIXBundle path, verify protected-storage behavior, URI registration, and upgrade/uninstall tests |
| **iOS/iPadOS** | Signed TestFlight build, physical-device Iroh/terminal/lifecycle tests, replacement migration decision |
| **macOS** | Mac App Store package/upload validation, Keychain behavior, keyboard/accessibility and upgrade tests |

CI now analyzes and tests the shared client and builds all six target families.
Tagged releases produce Android, Linux, and Windows GitHub assets, Android/iOS
Appetize previews, and an internal TestFlight upload. Web remains part of the
Pages deployment; macOS store packaging/upload and Windows Store publication
remain protected manual workflows. Promotion waits for package-level smoke
tests and target-specific gates, not merely a successful compile.

## Core and shared-client policy

Flutter work must not regress host authorization, revocation, PTY correctness,
protocol compatibility, service recovery, or secret handling. Before 1.0, keep
one maintained cross-platform client rather than parallel implementations.

Host and CLI reach a 1.0 stability promise when install, upgrade, reset,
uninstall, compatibility, authorization/reconnect, security review, and state
migration are release-gated. There is no calendar promise for 1.0.

## Explicitly out of scope

- restoring the removed Compose, TypeScript, or Relm4 clients;
- another terminal renderer or a local-PTY terminal dependency;
- durable PTY output replay; use `tmux`, `zellij`, or `screen`;
- full desktop streaming, centralized accounts, RBAC, or fleet management;
- broad plugin or protocol frameworks without a concrete client need.

## Decision order

When work competes, choose in this order:

1. prevent unauthorized shell access, identity loss, or weaker secret storage;
2. preserve framing, terminal correctness, reconnect, and recovery;
3. close shared Flutter terminal, accessibility, and lifecycle gaps;
4. make signed packages, upgrades, and releases repeatable;
5. add new features or platforms.
