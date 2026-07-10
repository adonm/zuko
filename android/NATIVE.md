# Android native dependencies

The Android client builds native code from immutable upstream revisions rather
than committing generated binaries:

| Component | Revision | License |
| --- | --- | --- |
| `iroh-ffi` 1.0.0 | `afcb46d9f583eca81a592eddeae531efe91f3bd1` | MIT OR Apache-2.0 |
| `libghostty-vt` 0.1.0-dev | `a23d90c89afa00fd5563a3db89d8a1cfab3e7573` | MIT |

`scripts/build-android-native.sh` verifies the checked-out commit before it
builds. It emits `arm64-v8a` and `x86_64` by default, targets Android API 29,
and configures 16 KiB ELF page alignment for the JNI bridge. Generated files
under `android/native/` and `android/app/src/main/jniLibs/` are ignored.

Run through mise so Zig 0.15.2 and cargo-ndk 3.5.4 are pinned:

```sh
export ANDROID_NDK_HOME="$ANDROID_HOME/ndk/29.0.14206865"
mise run build-android-native
```

The Android UI renderer is intentionally app-owned. `libghostty-vt` parses VT
data, maintains screen/scrollback state, and encodes terminal keys. A small C
JNI bridge snapshots visible text for the Compose renderer. It does not use the
unrelated historical Ghostty GUI embedding library.
