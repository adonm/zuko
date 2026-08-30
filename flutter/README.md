# Zuko Flutter client

One shared client targets Android, iOS, macOS, web, Linux, and Windows. The Core
host and CLI remain in `../src/`.

The terminal widget is the upstream-hosted
[`flterm`](https://pub.dev/packages/flterm) 0.0.5 on
[`libghostty`](https://pub.dev/packages/libghostty) 0.0.12. libghostty's hook
downloads its SHA256-pinned prebuilt release binaries, so normal builds and CI
need no Zig or native compilation. The one exception is the Codemagic App
Store build: App Store Connect rejects Zig-produced iOS dylibs, so
`scripts/prepare-libghostty-ios-static.py` compiles Ghostty there and relinks
it with Apple clang. Terminal content semantics and layout-aware keyboard
handling land with the next upstream release (elias8/libghostty PRs #102 and
#104); until then the app supplies the terminal's accessibility label itself.

Fresh-clone prerequisites, platform commands, and output paths are documented
in [`../docs/building-clients.md`](../docs/building-clients.md). In particular,
native Windows builds use the documented PowerShell sequence because the
repository Justfile requires Bash. Apple builds require macOS/Xcode and use
`just build-flutter-ios` or `just build-flutter-macos`.

On x86_64 Linux, use the version-pinned Ubuntu 24.04 Distrobox documented in
[`../docs/building-clients.md`](../docs/building-clients.md) for normal Dart,
Flutter, and native Linux iteration. Continue to use `just container-ci` for
the complete web, Android, and Linux compile gate, or the focused
`container-web`, `container-android`, and `container-linux-build` recipes,
when you need their pinned build-only inputs. The builder supplies CMake, GTK,
JDK 17, the Android SDK/NDK, and Wasm tooling.

A distrobox is not required. On a Linux host, `mise bootstrap` installs the
system packages and `mise install` the toolchain; the curl installer activates
mise in your shell, so run recipes directly:

    just flutter-integration

It drives the real app against real local PTYs under Xvfb — pairing, accessory
keys, settings toggles, disconnect, and a btop TUI through flterm — swapping
only the network transport for `integration_test/local_host_transport.dart`.
The tests live in the standalone `flutter/integration` package so ptyx and
`integration_test` stay out of the app's dependency graph (ptyx's
native-asset hook breaks iOS builds and the integration_test plugin breaks the
Android release registrant). CI runs the same recipe in the Linux candidate
job.

Architecture:

- `lib/src/`: shared state, pairing, framing, reconnect, UI, and terminal glue
- `rust/web_transport/`: relay-only browser Iroh bridge
- `integration/`: standalone desktop UI integration test package
- `android/`, `ios/`, `macos/`, `linux/`, `windows/`, `web/`: thin Flutter runners

Linux and Windows builds run `scripts/patch-flutter-plugins.py` after dependency
resolution. It works around the published `iroh_flutter` 1.0.1 CMake FFI
bundle path and Linux keyring handling in `flutter_secure_storage_linux` 3.0.1.
The script fails closed when either package version changes.

The pinned Flutter stable SDK (3.47.1) uses explicit Impeller enablement on
Android, Linux, macOS, Windows, and web. Touch platforms drop the top bar:
a translucent floating pad (arrows, PgUp/PgDn, Home/End, hold-drag scroll,
logo that opens the sidebar) floats over the terminal, and the wide layout
collapses the sidebar to a rail so the terminal fills the window.

CI analyzes and tests the shared Dart code, builds web plus all five native
target families, and publishes only the channels documented in
[`../docs/building-clients.md`](../docs/building-clients.md). In particular,
an iOS release tag uploads to internal TestFlight; macOS store packaging remains
manual, and neither Apple store package is a GitHub Release asset.

Dependencies and promotion gates are documented in
[`../docs/building-clients.md`](../docs/building-clients.md) and
[`../docs/roadmap.md`](../docs/roadmap.md).
