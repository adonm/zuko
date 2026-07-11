# Zuko Flutter client

One shared client targets Android, iOS, macOS, web, Linux, and Windows. The Core
host and CLI remain in `../src/`.

The terminal widget is pinned as the `packages/flterm` Git submodule from
[`adonm/flterm`](https://github.com/adonm/flterm). Initialize submodules before
running Flutter commands.

Fresh-clone prerequisites, platform commands, and output paths are documented
in [`../docs/building-clients.md`](../docs/building-clients.md). In particular,
native Windows builds use the documented PowerShell sequence because the
repository Justfile requires Bash. Apple builds require macOS/Xcode and use
`just build-flutter-ios` or `just build-flutter-macos`.

Architecture:

- `lib/src/`: shared state, pairing, framing, reconnect, UI, and terminal glue
- `rust/web_transport/`: relay-only browser Iroh bridge
- `android/`, `ios/`, `macos/`, `linux/`, `windows/`, `web/`: thin Flutter runners

Linux and Windows builds run `scripts/patch-iroh-flutter.py` after dependency
resolution to work around the published `iroh_flutter` 1.0.1 CMake FFI bundle
path. The script fails closed when that package version changes.

The pinned Flutter beta uses explicit Impeller enablement on Android, Linux,
macOS, and web. Its Windows embedder predates the public
`DartProject::set_impeller_switch` API, so Windows intentionally uses the SDK
default until the Flutter pin and configuration check are advanced together.

CI analyzes and tests the shared Dart code, builds web plus all five native
target families, and publishes only the channels documented in
[`../docs/building-clients.md`](../docs/building-clients.md). In particular,
an iOS release tag uploads to internal TestFlight; macOS store packaging remains
manual, and neither Apple store package is a GitHub Release asset.

Dependencies and promotion gates are documented in
[`../docs/building-clients.md`](../docs/building-clients.md) and
[`../docs/roadmap.md`](../docs/roadmap.md).
