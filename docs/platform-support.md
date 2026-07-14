# Flutter platform support

Zuko's pre-1.0 support statement distinguishes an enforced package floor from
runtime validation. A successful cross-platform compile is not a claim that
every operating-system or browser generation has completed physical testing.

Current build floors and validation:

| Target | Enforced package/build floor | Automated validation |
|--------|------------------------------|----------------------|
| Android | API 35 minimum; SDK/build-tools 36; platform-tools 37.0; NDK 29.0 | shared tests plus ARM64 debug and signed release builds |
| iOS/iPadOS | 18.0 deployment target | ARM64 Simulator build, Appetize preview, and signed device IPA validation |
| macOS | 15.0 deployment target | release app build and protected Mac App Store package validation |
| Windows | Windows 10 package target, x86_64 build | release bundle build; protected MSIX/MSIXBundle validation is manual |
| Linux | x86_64 Wayland FlatPark package, Freedesktop 25.08 | release archive reproducibility and linkage checks; FlatPark package build/install/launch checks |
| Web | `/web/` deployment on current browsers | shared tests and a release WASM build; no automated browser matrix yet |

Android 15+, iOS/iPadOS 18+, macOS 15+, Windows 10/11, the packaged Linux
runtime, and current Chrome/Firefox/Edge/Safari are the intended test range.
Only the floors and CI jobs above are mechanically enforced today.

Temporary `zuko tunnel` forwarding is supported by the native Android, iOS,
macOS, Windows, and Linux Flutter clients. Flutter Web cannot bind a local TCP
listener and ignores tunnel offers.

The apparent Apple version gap reflects Apple's 2025 platform-version naming
change. There was no public iOS/iPadOS 19 or macOS 16 release.

Floors are reviewed with each Flutter toolchain update. Raising a floor requires
release notes and package metadata changes; broadening a support claim requires
CI or recorded physical-device/browser coverage rather than only a successful
compile.
