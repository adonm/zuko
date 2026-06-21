# Zuko (iOS)

The **iOS client** for [zuko](../../) — remote terminals over Iroh. It speaks
the same [wire protocol](../../docs/PROTOCOL.md) as the CLI client and dials the
same `zuko host` daemon. Local and PR builds are driven by
[xtool](https://github.com/xtool-org/xtool) from [`../Package.swift`](../Package.swift)
and [`../xtool.yml`](../xtool.yml).

## Build

With [mise](https://mise.jdx.dev) installed:

```sh
mise install             # rust
mise run setup-ios       # install xtool + Swift pieces
mise run build-ios       # build ios/xtool/Zuko.app via xtool
```

On Linux, `mise run build-ios` auto-installs the cached Darwin Swift SDK bundle
from the repo's `xtoolsdk-v*` release if xtool does not see one yet. On macOS,
run `xtool setup` once after installing xtool so the SDK is registered.

To open in Xcode on macOS:

```sh
cd ios
xtool dev generate-xcode-project
open xtool/Zuko.xcworkspace
```

Dependencies are resolved as Swift Packages:

- [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) `~> 1.12` — the terminal emulator.
- [iroh-ffi](https://github.com/n0-computer/iroh-ffi) `~> 1.0` (product `IrohLib`) — networking.

iOS deployment target is **26.0**.

## Layout

```
Zuko/
  ZukoApp.swift             @main entry
  Models/
    Connection.swift        saved host (label + ticket)
    ConnectionStore.swift   persisted list (Keychain-backed, observable)
    ConnectionKeychain.swift  Keychain wrapper for the bearer-token tickets
  Net/
    Wire.swift              length-prefixed framing (shared with host)
    IrohSession.swift       Iroh connect + framed read loop + serial write pump
  Terminal/
    TerminalRepresentable.swift  SwiftTerm UIViewRepresentable + delegate
  Views/
    RootView.swift
    ConnectionListView.swift     list + empty-state onboarding
    OnboardingView.swift         host setup commands
    AddConnectionView.swift      add a connection
    TerminalScreen.swift         the live terminal
```

## CI

`.github/workflows/build-ios.yml` runs the same `mise run build-ios` xtool path
and uploads `ios/xtool/Zuko.app`. Signed TestFlight builds still use the legacy
Fastlane/XcodeGen archive path — see [`../DISTRIBUTION.md`](../DISTRIBUTION.md).

## Notes

- IrohLib needs `Network.framework` linked on iOS; `Package.swift` links it.
