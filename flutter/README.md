# Zuko Flutter client

One shared client targets Android, iOS, macOS, web, Linux, and Windows. The Core
host and CLI remain in `../src/`.

The terminal widget and Dart bindings come from the
[`adonm/libghostty`](https://github.com/adonm/libghostty) fork at one shared
commit: libghostty there is exactly upstream `elias8/libghostty` main, and
flterm adds only three commits — accessible terminal semantics, layout-aware
keyboard input, and tap-to-present keyboard — all submitted upstream
(PRs [#102](https://github.com/elias8/libghostty/pull/102) and
[#104](https://github.com/elias8/libghostty/pull/104)). When upstream releases
the reorganized libghostty API plus these flterm patches, the client switches
to the hosted packages and their prebuilt release binaries (no Zig compile);
until then `source: compile` is required because the published 0.0.12
binaries predate the API. ptyx (integration tests only) comes straight from
upstream `elias8/libghostty`.

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

The pinned Flutter beta uses explicit Impeller enablement on Android, Linux,
macOS, Windows, and web.

CI analyzes and tests the shared Dart code, builds web plus all five native
target families, and publishes only the channels documented in
[`../docs/building-clients.md`](../docs/building-clients.md). In particular,
an iOS release tag uploads to internal TestFlight; macOS store packaging remains
manual, and neither Apple store package is a GitHub Release asset.

Dependencies and promotion gates are documented in
[`../docs/building-clients.md`](../docs/building-clients.md) and
[`../docs/roadmap.md`](../docs/roadmap.md).
