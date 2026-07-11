# Flutter platform support

Zuko supports the latest two major operating-system generations available to
each Flutter target at release time. The policy is intentionally narrow before
1.0 so terminal, lifecycle, storage, and packaging behavior can be tested on
every supported generation.

Current floors:

| Target | Supported generations | Enforced floor |
|--------|-----------------------|----------------|
| Android | Android 15 and 16 | API 35 |
| iOS/iPadOS | iOS/iPadOS 18 and 26 | 18.0 |
| macOS | macOS 15 and 26 | 15.0 |
| Windows | Windows 10 and 11 | Windows 10 |
| Linux | Distribution-independent Flatpak | Freedesktop 25.08 runtime |
| Web | Latest two stable Chrome, Firefox, Edge, and Safari releases | CI/browser policy |

The apparent Apple version gap reflects Apple's 2025 platform-version naming
change. There was no public iOS/iPadOS 19 or macOS 16 release.

Floors are reviewed with each Flutter stable/toolchain update. Raising a floor
requires release notes and package metadata changes; lowering one requires CI
and physical-device coverage rather than only a successful compile.
