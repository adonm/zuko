# Building clients

This page starts from a fresh clone and names each build's output. The shared
Flutter client targets Android, iOS, macOS, web, Linux, and Windows. Run commands
from the repository root unless noted.

## Preferred Linux container setup

On x86_64 Linux, use the repository's rootless Podman recipes for every build
that does not require Apple or Windows host APIs. Install Podman and
[mise](https://mise.jdx.dev/getting-started.html) on the host first; an
activated mise shell supplies `just`, or use the explicit
`mise exec -- just ...` form. The image contains the pinned Flutter and Rust
toolchains, JDK 17, Android platforms/build-tools/NDK/CMake, the Freedesktop
Linux SDK, LLVM, and the web Wasm tools. The source checkout is mounted
read-only and copied into an ephemeral `/workspace`; only artifact and cache
directories are mounted back into their normal host paths.

```sh
git submodule update --init --recursive
mise install just
mise exec -- just container-ci  # Codemagic: Dart + web + Android + Linux
mise exec -- just container-all # preflight + quality + all Linux builds
```

Focused recipes avoid rebuilding unrelated targets:

```sh
just container-preflight       # Rust + full Flutter/flterm tests
just container-web
just container-android         # ARM64 debug APK compile gate
just container-android-release # unsigned release APK and AAB
just container-linux-build
just container-linux-bundle
just container-quality         # actionlint + mdBook
just container-links           # network link check; honors GITHUB_TOKEN
just container-e2e             # live relay/PTY test; requires network access
```

The image is checksum/digest pinned in `containers/flutter-ci.Containerfile`.
Podman layer caching plus named Cargo, Dart, Pub, and Gradle volumes make
subsequent runs incremental without leaking container-generated platform files
or package paths into the host checkout. Normal checks/builds do not use a
privileged container;
Flatpak assembly remains the explicit exception because `flatpak-builder` needs
additional sandbox privileges.

Linux containers cannot faithfully build Windows, iOS, or macOS runners.
Those targets remain native Windows/macOS builds in Codemagic and the protected
release workflows.

## Host toolchain setup

Install [mise](https://mise.jdx.dev/getting-started.html), then bootstrap the
repository-managed tools, Linux OS packages, and shell activation:

```sh
git submodule update --init --recursive
mise bootstrap
just flutter-check
```

Use this path for native Apple/Windows work or quick host-side iteration. On
Linux, a missing CMake or Android SDK is a signal to use the container recipes,
not a reason to skip the corresponding compile gate.

The shared client pins the focused `adonm/flterm` fork as a Git submodule.
Clone with `--recurse-submodules` or run the update command above before any
Flutter build.

Flutter is installed by mise from the official checksum-pinned
`3.47.0-0.1.pre` beta archives at revision
`bd1e75d918605c91b411e8789fb911e6c9a84534`, so the Impeller APIs cannot drift.

## Android

Requirements:

- Android SDK platforms 34–36, build-tools 36.0.0, and platform-tools 37.0.0;
- Android NDK 29.0.14206865 and CMake 3.22.1;
- JDK 17 and accepted Android licenses;
- Android 15/API 35 or newer to run the app.

Preferred Linux container build:

```sh
just container-android
adb install -r flutter/build/app/outputs/flutter-apk/app-debug.apk # ARM64 device
```

The focused container compile gate intentionally emits ARM64 native libraries.
Use an ARM64 physical device/emulator for that APK. For an x86_64 emulator,
use the host-native unrestricted debug build below.

For host-native Android development, after installing the requirements above:

```sh
mise exec -C flutter -- flutter build apk --debug
adb install -r flutter/build/app/outputs/flutter-apk/app-debug.apk
```

Unsigned release outputs can also be compiled in the container:

```sh
just container-android-release
```

```text
flutter/build/app/outputs/flutter-apk/app-release.apk
flutter/build/app/outputs/bundle/release/app-release.aab
```

The container deliberately does not forward signing credentials. Host-native
release files are signed only when `ANDROID_KEYSTORE_PATH`,
`ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, and `ANDROID_KEY_PASSWORD` are
all set. The AAB is a store upload, not a directly installable package. Tagged
release CI requires all signing secrets and verifies both signatures.

## Web

Preferred Linux build:

```sh
just container-web
```

For host-native iteration, Linux needs `clang`; the script installs the Wasm
Rust target and the exact `wasm-bindgen-cli` version used by the bridge:

```sh
sudo apt-get install clang # Debian/Ubuntu
just flutter-check
just build-web
```

Output: `target/book/web/`. The build uses base path `/web/` for deployment at
[zuko.adonm.dev/web/](https://zuko.adonm.dev/web/); it is not a root-path static
bundle without changing `scripts/build-web.sh`. Browser transport is relay-only,
while terminal payloads remain end-to-end encrypted. Production web builds
currently retain JavaScript/Wasm source maps and Wasm symbol names so browser
failures can be symbolized during the active null-exception investigation.

## Linux desktop

The pinned Freedesktop container is the release-compatible default:

```sh
just container-linux-build
```

For host-native iteration, `mise bootstrap` installs the configured
dependencies on Debian/Ubuntu, Fedora, and Arch. The equivalent Debian/Ubuntu
command is:

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
and an active Secret Service provider such as GNOME Keyring. Tagged releases
package this directory for [FlatPark](flatpark.md). See the [Linux runtime
notes](../flutter/linux/README.md).

To build an unsigned, self-contained Flatpak for local testing, including the
current Linux payload under FlatPark's production app ID and permissions:

```sh
mise exec -- just build-flatpark-test-bundle
flatpak --user install dist/flatpak/zuko-linux-vX.Y.Z-x86_64-test.flatpak
flatpak run dev.adonm.zuko//test-vX.Y.Z
```

The test branch can coexist with FlatPark's `stable` branch. The recipe consumes
an immutable, inspected revision of FlatPark's registry packaging and embeds the
local release archive so installation does not depend on an already-published
GitHub Release. It is for local validation only and is not signed by FlatPark.

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
python scripts/patch-flutter-plugins.py flutter
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
Release assets. For every annotated release tag, GitHub explicitly triggers an
exact-commit `ios-signing-validation` build and then the artifact-only
`ios-testflight-release` upload. Maintainers can also run signing validation
against a branch without publishing. Apple builds use bundle ID
`dev.adonm.zuko` and all signing credentials remain in Codemagic.

## Matching CI

The source of truth for build environments is:

- `codemagic.yaml` for Flutter tests and platform builds on Linux, Windows,
  Android, and Apple runners;
- `.github/workflows/release.yml` for exact-tag Codemagic orchestration,
  artifact verification, and the coordinated GitHub Release;
- `Justfile` for supported local recipes.

`just container-ci` invokes the same `flutter-linux-ci` recipe as Codemagic's
Linux compile gate. It covers every target that can be built faithfully on a
Linux host: shared Dart, web, Android, and Linux desktop. `just container-all`
adds the exhaustive local preflight, workflow lint, and documentation build
without rerunning the lean app tests. Network-dependent link and end-to-end
tests remain explicit focused recipes. Native Windows and Apple compilation
cannot be replaced by a Linux container and remains hosted on those operating
systems.

Current automation coverage is:

| Target | Pull request / `main` build | Release-tag delivery |
|--------|-----------------------------|----------------------|
| Shared Dart + web | Codemagic analyze, unit/widget tests, relay-only web build | Pages deploys after `main`; no release asset |
| Android | Codemagic ARM64 debug APK | Codemagic unsigned APK/AAB signed, verified, and published by GitHub; the signed APK is then sent to Appetize |
| Linux | Codemagic x86_64 release bundle | Checksummed x86_64 bundle archive published by GitHub and consumed by FlatPark |
| Windows | Codemagic x86_64 release bundle | Codemagic x86_64 ZIP verified and published by GitHub |
| iOS/iPadOS | debug ARM64 Simulator app | signed IPA to internal TestFlight; matching-tag Simulator build to Appetize |
| macOS | release application bundle | no automatic release asset; protected store package workflow is manual |

Compilation in this matrix does not imply store publication or the
physical-device/browser coverage listed in [Flutter platform support](platform-support.md)
and the [roadmap](roadmap.md).
