# Zuko (iOS / iPadOS)

The **iOS/iPadOS client** for [zuko](../../) — remote terminals over Iroh. It
speaks the same [wire protocol](../../docs/PROTOCOL.md) as the CLI client and
dials the same `zuko host` daemon. Local and PR builds are driven by
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

- [libghostty-spm](https://github.com/Lakr233/libghostty-spm) `~> 1.0` (products `GhosttyTerminal`, `GhosttyKit`, `GhosttyTheme`) — the terminal emulator, low-level mouse bridge, and a 485-theme catalog. Wraps the libghostty static library; the app uses its host-managed I/O backend (`InMemoryTerminalSession`) so it stays sandbox-safe (no PTY spawn — all bytes flow through `IrohSession`).
- [iroh-ffi](https://github.com/n0-computer/iroh-ffi) `~> 1.0` (product `IrohLib`) — networking.

iOS/iPadOS deployment target is **26.5** (matches iroh-ffi's binary floor).
The app is universal (`UIDeviceFamily` iPhone + iPad) and supports portrait and
landscape on iPad.

## Layout

```
Zuko/
  ZukoApp.swift             @main entry
  Models/
    Connection.swift        saved host (label + ticket)
    ConnectionStore.swift   persisted list (Keychain-backed, observable)
    ConnectionKeychain.swift  Keychain wrapper for the bearer-token tickets
    ThemeStore.swift        persisted terminal prefs: color theme, font size
                            (UserDefaults-backed)
  Net/
    ClientIdentity.swift    Keychain-backed stable reattach token derivation
    IrohSession.swift       Iroh connect + framed read loop + serial write pump;
                            owns the InMemoryTerminalSession fed to GhosttyTerminal
    IrohSessionPumps.swift  write/control-read pumps + connection-phase timeout
    TerminalInputFix.swift  software-keyboard byte delivery swizzle
  Views/
    RootView.swift
    ConnectionListView.swift     list + empty-state onboarding
    OnboardingView.swift         host setup commands + app tips (zoom/theme)
    AddConnectionView.swift      add a connection
    TerminalScreen.swift         the live terminal (GhosttyTerminal surface)
    TouchMouseInput.swift        tap/cursor-mode mouse click + scroll bridge
    ThemeBrowserView.swift       searchable list of all 485 catalog themes
  ```

The length-prefixed wire framing lives in a separate dependency-free package,
`ios/ZukoWire` (`Wire.swift` + `WireTests.swift`), so it can be unit-tested on
Linux/CI (`cd ios/ZukoWire && swift test`) exactly like the Rust `src/wire.rs`.
The app target depends on its `ZukoWire` product.

## Terminal controls

- Default input is the plain iOS software keyboard. The shortcut-key accessory
  row starts hidden.
- Toolbar command-circle toggles the accessory row (`Esc`, `Tab`, arrows,
  `Ctrl`/`Alt`/`Cmd`, symbols, paste).
- Toolbar hand-tap toggles cursor/tap mode. Cursor mode resigns first responder
  so the keyboard stays hidden; taps are delivered as mouse clicks to apps that
  enabled terminal mouse capture, and one-finger swipes send precision wheel
  scroll events for scrollback panes in apps like opencode, zellij, vim, and
  btop.
- The refresh icon sends a same-size resize to the host PTY, asking shells/TUIs
  to repaint without clearing zellij/tmux panes.
- Transient Iroh/link failures auto-redial with bounded exponential backoff.
  The app keeps a Keychain-backed per-install identity and derives a stable
  host-scoped session token, so fresh launches and short drops reattach the same
  live PTY while the host's 5-minute lease is alive. Output while detached is
  discarded; use tmux/zellij/screen inside the session for persistent processes
  across long disconnects or host restarts.
- The app tries protocol `zuko/2` first and uses its optional control stream for
  resize/ping traffic, falling back to `zuko/1` for older hosts.

## CI

`.github/workflows/build-ios.yml` runs the same `mise run build-ios` xtool path
and uploads `ios/xtool/Zuko.app`. Signed TestFlight builds still use the legacy
Fastlane/XcodeGen archive path — see [`../DISTRIBUTION.md`](../DISTRIBUTION.md).

## Notes

- IrohLib's own Package.swift links the Apple frameworks it needs
  (`SystemConfiguration` + `Network` on iOS, plus `CoreWLAN` on macOS) via
  `.linkedFramework`. SwiftPM propagates those transitively when you depend
  on `IrohLib`, so we don't list `SystemConfiguration` ourselves. Our
  `Package.swift` and `project.yml` *do* re-link `Network.framework`
  explicitly as belt-and-suspenders (and because the legacy XcodeGen path
  doesn't see SwiftPM linkerSettings). The README mention of CoreWLAN
  applies only to macOS — iOS correctly omits it.
- IrohLib needs `Network.framework` linked on iOS; `Package.swift` links it.
- Targets **iOS/iPadOS 26.5** / **Swift 6.2** with `strict-concurrency` enabled.
  Owns its observable models with the Swift 5.9+ `@Observable` macro
  (`ThemeStore`, `ConnectionStore`, `ClaimSession`); `IrohSession` stays on
  `ObservableObject` + `@Published` because most of its state is internal
  and `@Published`'s opt-in tracking beats `@ObservationIgnored`'s opt-out
  there. Third-party `TerminalViewState` (libghostty-spm) is also still
  `ObservableObject`.
- The Rust crate (host + CLI + FFI) is on edition 2024 (matches iroh-ffi
  1.0.0's edition) and `cargo clippy`-clean under `-W clippy::pedantic
  -W clippy::nursery -W clippy::cargo` (with the doc/noisy lints allowed).
- The default font size is `ThemeStore.defaultFontSize` (5pt — 50% of
  libghostty-spm's iOS default). Adjustable from the toolbar overflow menu or
  by pinching the terminal surface (live). Persisted to UserDefaults.
- The color theme picker also lives in `TerminalScreen`'s toolbar overflow menu:
  Popular menu for quick switching + "Browse all…" for a searchable sheet over
  all 485 catalog themes. The selection persists in UserDefaults and applies
  live via `TerminalController.setTheme`. The app follows the system color
  scheme (no longer force-dark); the default theme is Afterglow (dark) /
  Alabaster (light).
