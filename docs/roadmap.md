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

## Current priority: steadily improve one credible Flutter client

All Android, iOS, macOS, web, Linux, and Windows client work now lands in
`flutter/`.
Flutter shares navigation, saved-host behavior, pairing, framing, reconnect,
terminal integration, and tests. Platform code is limited to transport,
credential storage, camera access, lifecycle, and packaging where the operating
system genuinely differs.

The [Flutter human-centered design guide](flutter-design.md) records the shared
interaction goals, current responsive behavior, accessibility expectations, and
evidence required for client-facing changes.

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

## Continuous quality program

Shipping the shared client is not the end state. Quality work should land in
small, measured increments across `flterm`, every Flutter target, and the
host/client boundary.

`flterm` is a long-lived product dependency and will receive substantial
ongoing work rather than only compatibility patches needed by Zuko. Priorities
include:

- expand terminal conformance coverage for escape sequences, Unicode grapheme
  and cell-width behavior, cursor/style state, scrollback, alternate screen,
  selection, clipboard, links, and Kitty graphics;
- make keyboard, IME, mouse, wheel, touch, and DEC input modes consistent on
  phones, tablets, browsers, and desktop systems;
- add deterministic renderer goldens, fuzz/property tests at parser and input
  boundaries, long-session tests, and measured performance/memory baselines;
- improve accessibility semantics, API documentation, diagnostics, examples,
  and release hygiene so downstream Flutter clients can depend on behavior
  rather than implementation details;
- upstream generally useful fixes in `flterm` first and pin Zuko to reviewed,
  tested commits instead of carrying hidden application-only forks.

The first focused terminal-experience increment is clickable links. `flterm`
detects OSC 8 hyperlinks and plain-text URLs, and Zuko wires supported web
links to the existing platform URL launcher while rejecting unsupported
schemes. This small cross-platform improvement exercises an existing reviewed
`flterm` capability.

The accessibility baseline now exposes the visible, non-concealed terminal
viewport and a terminal-focus action through `flterm` semantics. Zuko supplies
the remote-terminal label and hint. Output is deliberately not a live region,
so continuous command output does not create announcement spam. Structured
cursor/selection navigation and representative VoiceOver, TalkBack, and
desktop screen-reader testing remain follow-up work.

Shared Flutter quality work should continuously exercise real small phones,
tablets, desktop windows, narrow browsers, lifecycle transitions, credential
storage, reconnect, upgrade, and uninstall behavior. A successful compile is
not sufficient evidence of client quality.

Host/client user experience is part of the same program: pairing and
revocation should be understandable, connection and retry states actionable,
diagnostics safe to share, errors specific about the next step, and host
install/upgrade/reset behavior predictable from every supported client.

Binary size remains a release constraint. CI should record compressed and
installed sizes per target, compare them with the previous release, and make
large regressions explicit. Prefer shared assets, targeted font subsets,
tree-shaking, symbol stripping, and one native implementation per capability;
do not add parallel frameworks or broad asset bundles when a measured smaller
choice meets the same user need. Size work must preserve terminal correctness,
accessibility, security, and offline fallback behavior.

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
- in-app QR pairing with typed-code fallback;
- explicit connecting, attached, retrying, rejected, ended, and disconnected
  states;
- foreground/background and network-change recovery on mobile targets;
- screen-reader semantics and keyboard-only operation;
- visible destructive reset behavior that rotates the client identity and
  explains host-side revocation.

`flterm` supplies the shared terminal surface. Typed recovery states, foreground
redial, mobile shortcut controls, host management, themes, font sizing, and
baseline terminal viewport semantics now exist. Complete screen-reader
navigation and testing, QR scanner lifecycle tests, and representative
physical-device coverage remain open.

### 3. Ship each target through its normal channel

| Target | Release gate |
|--------|--------------|
| **Android** | Signed APK/AAB, Appetize preview, upgrade test, physical phone/tablet tests, Play-ready metadata |
| **Web** | Chrome/Firefox/Safari tests, strict CSP, origin review, deployed `/web/` smoke test |
| **Linux** | Reproducible Wayland-only release archive and FlatPark package, Impeller rendering, Secret Service behavior, install/uninstall documentation |
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
4. improve pairing, diagnostics, recovery, and host/client operational UX;
5. make signed packages, upgrades, releases, and size reporting repeatable;
6. add new features or platforms.
