# Releasing

Tags `v*` trigger binary releases for:

- Linux x86_64/aarch64
- macOS x86_64/aarch64
- Android arm64-v8a/x86_64 APK and AAB packages

The release tarballs are consumed by:

```sh
mise use --global github:adonm/zuko
```

## Cut a release

```sh
mise run test
mise run lint          # if Swift changed
mise run build-ios     # if iOS changed
mise run android-ci    # if Android/mobile FFI changed
mise run release v0.8.0
```

`scripts/release.sh` checks `Cargo.toml` version, commits pending work, pushes
branch, creates an annotated tag, and pushes the tag.

Manual equivalent:

```sh
git commit -m "..."
git tag -a v0.8.0 -m "zuko v0.8.0"
git push origin main v0.8.0
```

## Linux `zuko app` bundle

x86_64 Linux release includes `cage/` next to the binary:

- `cage`
- `libwlroots-0.20.so`
- `libliftoff.so.0`
- `libseat.so.1`
- `libxcb-errors.so.0`

Built in `release.yml` from `fedora:latest` packages. aarch64 Linux does not
bundle cage yet; users need `cage` on `PATH`.

## iOS

Signed/TestFlight builds: [`ios/DISTRIBUTION.md`](../ios/DISTRIBUTION.md).

## Android

The final `release.yml` publisher waits for both desktop and Android builds, so
there is only one GitHub Release writer. Android assets include SHA-256
sidecars and are signed before publication.

Release signing requires all four secrets and fails closed if any are missing:

- `ANDROID_KEYSTORE_BASE64`
- `ANDROID_KEYSTORE_PASSWORD`
- `ANDROID_KEY_ALIAS`
- `ANDROID_KEY_PASSWORD`

Use a distribution/upload key, not a Play app-signing private key. Native source
pins and ABI details are documented in [`android/NATIVE.md`](../android/NATIVE.md).
Unsigned APK/AAB outputs remain available from the ordinary Android CI workflow
for build verification, but are never attached to a GitHub Release.
