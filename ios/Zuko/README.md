# Zuko iOS/iPadOS

Swift client for the same `zuko host` daemon as the CLI.

## Build

```sh
mise install
mise run setup-ios
mise run build-ios
```

Linux build uses xtool and auto-installs the cached Darwin Swift SDK if needed.
On macOS, run `xtool setup` once.

Xcode project:

```sh
cd ios
xtool dev generate-xcode-project
open xtool/Zuko.xcworkspace
```

Wire package tests:

```sh
swift test --package-path ios/ZukoWire
```

## Runtime

- Deployment target: iOS/iPadOS 26.5.
- Networking: `IrohLib`.
- Terminal: `GhosttyTerminal` host-managed I/O backend.
- Wire framing: local `ZukoWire` Swift package.
- Handoff key derivation: Rust FFI (`ZukoFFI.deriveHandoffKey`).

## Layout

```text
Zuko/Zuko/
  Models/      saved connections, Keychain/UserDefaults stores
  Net/         claim, identity, Iroh session, pumps, input bridge
  Views/       connection list, onboarding, terminal, theme picker
ios/ZukoWire/  dependency-free wire framing + tests
ios/ZukoFFI/   generated uniffi wrapper over Rust staticlib
```

## Terminal controls

- Command-circle: shortcut row (`Esc`, `Tab`, arrows, modifiers, paste).
- Hand-tap: cursor/tap mode; taps become terminal mouse clicks, swipes become
  wheel events.
- Refresh: send same-size resize to force remote repaint.
- Overflow: logs, font size, theme picker.

Reconnects use a Keychain-backed per-install identity and host-scoped token.
Detached output is discarded; use `tmux`/`zellij`/`screen` for durable work.

## CI/release

- PR build: `.github/workflows/build-ios.yml` (`mise run build-ios`).
- Signed/TestFlight: [`../DISTRIBUTION.md`](../DISTRIBUTION.md).
