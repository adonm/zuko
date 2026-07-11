# Building clients

This page starts from a fresh clone and names each build's output. The shared
Flutter client targets Android, iOS, macOS, web, Linux, and Windows. Run commands
from the repository root unless noted.

## Common setup

Install [mise](https://mise.jdx.dev/getting-started.html), then install the
repository-managed Rust and Flutter toolchains:

```sh
git submodule update --init --recursive
mise install
just flutter-check
```

The shared client pins the focused `adonm/flterm` fork as a Git submodule.
Clone with `--recurse-submodules` or run the update command above before any
Flutter build.

Flutter is pinned to 3.44.6. Rust and several contributor tools track their
configured mise channels, so `mise install` is the supported entry point rather
than a claim that every tool is version-locked.

## Android

Requirements:

- Android SDK platform 36 and build-tools 36.0.0;
- Android NDK 28.2.13676358;
- JDK 17 and accepted Android licenses;
- Android 15/API 35 or newer to run the app.

For a locally installable development APK:

```sh
mise exec -C flutter -- flutter build apk --debug
adb install -r flutter/build/app/outputs/flutter-apk/app-debug.apk
```

Release outputs:

```sh
just build-flutter-android
```

```text
flutter/build/app/outputs/flutter-apk/app-release.apk
flutter/build/app/outputs/bundle/release/app-release.aab
```

Local release files are signed only when `ANDROID_KEYSTORE_PATH`,
`ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, and `ANDROID_KEY_PASSWORD` are
all set. The AAB is a store upload, not a directly installable package. Tagged
release CI requires all signing secrets and verifies both signatures.

## Web

Linux needs `clang`; the script installs the WASM Rust target and the exact
`wasm-bindgen-cli` version used by the bridge:

```sh
sudo apt-get install clang # Debian/Ubuntu
just flutter-check
just build-web
```

Output: `target/book/web/`. The build uses base path `/web/` for deployment at
[zuko.adonm.dev/web/](https://zuko.adonm.dev/web/); it is not a root-path static
bundle without changing `scripts/build-web.sh`. Browser transport is relay-only,
while terminal payloads remain end-to-end encrypted.

## Linux desktop

Install the build dependencies on Debian/Ubuntu:

```sh
sudo apt-get update
sudo apt-get install -y \
  clang cmake libgtk-3-dev libsecret-1-dev ninja-build pkg-config
just build-flutter-linux
```

Output and run command:

```sh
flutter/build/linux/x64/release/bundle/zuko
```

Keep the complete `bundle/` directory together. Runtime machines need GTK 3,
libsecret, and an active Secret Service provider such as GNOME Keyring; see the
[packaged Linux notes](../flutter/linux/README.md).

## Windows desktop

Build on Windows with Python 3 and Visual Studio 2022's **Desktop development
with C++** workload. Confirm `flutter doctor -v` passes. The repository Justfile
uses Bash, so native Windows CI uses this PowerShell sequence instead:

```powershell
mise install flutter rust
$flutter = Join-Path (mise where flutter) "bin\flutter.bat"
$rustBin = Join-Path (mise where rust) "bin"
$env:Path = "$rustBin;$env:Path"

Push-Location flutter
& $flutter pub get
Pop-Location
python scripts/patch-iroh-flutter.py flutter
Push-Location flutter
& $flutter build windows --release
Pop-Location
```

Output: `flutter/build/windows/x64/runner/Release/`. Run `zuko.exe` from that
directory and keep its DLLs and data beside it. Tagged releases zip this whole
directory; there is not yet a signed Windows installer.

## Flutter iOS/iPadOS and macOS

Apple builds require macOS, Xcode, CocoaPods, Flutter, and Rust. The CocoaPods
build compiles `iroh_flutter`'s Rust library and packages `libghostty` for the
selected Apple platform. The generated runners target iOS 18 and macOS 15.

```sh
mise install flutter rust
just build-flutter-ios
just build-flutter-macos
```

Outputs:

```text
flutter/build/ios/iphonesimulator/Runner.app
flutter/build/macos/Build/Products/Release/Zuko.app
```

Flutter Apple CI builds and uploads both bundles on pull requests and `main`.
Maintainers can run `release-flutter-ios` with
`lane=build` for a signed IPA artifact or `lane=beta` for an internal TestFlight
upload. It uses bundle ID `dev.adonm.zuko` and the repository's protected Apple
signing environment.

## Matching CI

The source of truth for build environments is:

- `.github/workflows/build-flutter.yml` for development artifacts;
- `.github/workflows/release.yml` for signed/versioned Flutter packages;
- `.github/workflows/release-flutter-ios.yml` for signed Flutter IPA/TestFlight;
- `Justfile` for supported local recipes.
