# Building clients

This page starts from a fresh clone and names each build's output. The shared
Flutter client targets Android, iOS, macOS, web, Linux, and Windows. Run commands
from the repository root unless noted.

## Common setup

Install [mise](https://mise.jdx.dev/getting-started.html), then bootstrap the
repository-managed tools, Linux OS packages, and shell activation:

```sh
git submodule update --init --recursive
mise bootstrap
just flutter-check
```

The shared client pins the focused `adonm/flterm` fork as a Git submodule.
Clone with `--recurse-submodules` or run the update command above before any
Flutter build.

Flutter is installed by mise from the official checksum-pinned
`3.46.0-0.3.pre` beta archives at revision
`677d472756f83c14371dd8cc624387065f3d32a7`, so the Impeller APIs cannot drift.

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

`mise bootstrap` installs the configured dependencies on Debian/Ubuntu,
Fedora, and Arch. The equivalent Debian/Ubuntu command is:

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

Keep the complete `bundle/` directory together. The supported packaged target
is Wayland with Impeller/OpenGL; runtime machines also need GTK 3, libsecret,
and an active Secret Service provider such as GNOME Keyring. See the [packaged
Linux notes](../flutter/linux/README.md).

## Windows desktop

Build on Windows with Python 3 and Visual Studio 2022's **Desktop development
with C++** workload. Confirm `flutter doctor -v` passes. The repository Justfile
uses Bash, so native Windows CI uses this PowerShell sequence instead:

```powershell
mise install rust http:flutter
mise exec -- flutter --version
$rustBin = Join-Path (mise where rust) "bin"
$env:Path = "$rustBin;$env:Path"

Push-Location flutter
mise exec -- flutter pub get
Pop-Location
python scripts/patch-iroh-flutter.py flutter
Push-Location flutter
mise exec -- flutter build windows --release
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
mise bootstrap
mise exec -- flutter --version
just build-flutter-ios
just build-flutter-macos
```

Outputs:

```text
flutter/build/ios/iphonesimulator/Runner.app
flutter/build/macos/Build/Products/Release/Zuko.app
```

Codemagic's `flutter-apple-ci` compiles and packages both targets for relevant
pull requests and `main` changes. Those development artifacts are not GitHub
Release assets. Every annotated release tag separately runs
`ios-testflight-release`, producing a signed IPA and uploading it for internal
TestFlight processing. Maintainers can run `ios-signing-validation` against a
branch without publishing. Apple builds use bundle ID `dev.adonm.zuko` and all
signing credentials remain in Codemagic.

## Matching CI

The source of truth for build environments is:

- `codemagic.yaml` for Flutter tests and platform builds on Linux, Windows,
  Android, and Apple runners;
- `.github/workflows/release.yml` for exact-tag Codemagic orchestration,
  artifact verification, and the coordinated GitHub Release;
- `Justfile` for supported local recipes.

Current automation coverage is:

| Target | Pull request / `main` build | Release-tag delivery |
|--------|-----------------------------|----------------------|
| Shared Dart + web | Codemagic analyze, unit/widget tests, relay-only web build | Pages deploys after `main`; no release asset |
| Android | Codemagic ARM64 debug APK | Codemagic signed APK/AAB verified and published by GitHub; manual Appetize update |
| Linux | Codemagic x86_64 release bundle | Codemagic x86_64 Wayland Flatpak verified and published by GitHub |
| Windows | Codemagic x86_64 release bundle | Codemagic x86_64 ZIP verified and published by GitHub |
| iOS/iPadOS | debug ARM64 Simulator app | signed IPA to internal TestFlight; manual Appetize Simulator update |
| macOS | release application bundle | no automatic release asset; protected store package workflow is manual |

Compilation in this matrix does not imply store publication or the
physical-device/browser coverage listed in [Flutter platform support](platform-support.md)
and the [roadmap](roadmap.md).
