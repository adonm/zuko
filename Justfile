# Human-facing build, test, package, and release recipes.
# Tool versions and bootstrap dependencies live in mise.toml.
# Run through an activated Mise shell or `mise exec -- just <recipe>`.
# On x86_64 Linux, prefer the `container-*` Flutter recipes: they include the
# pinned JDK, Android SDK/NDK, GTK4 dependencies, Flutter, Rust, and web toolchain.
set shell := ["bash", "-euo", "pipefail", "-c"]

default:
    @just --list --list-heading $'Zuko recipes:\n'

[group('core')]
build:
    cargo build --locked --release

[group('core')]
test:
    cargo clippy --locked --all-targets -- -D warnings
    cargo test --locked

[group('core')]
test-e2e:
    cargo test --locked --release --test e2e -- --ignored --nocapture

[group('core')]
fmt:
    cargo fmt

[group('core')]
fmt-check:
    cargo fmt --check

[group('quality')]
lint-ci:
    actionlint .github/workflows/*.yml

[group('quality')]
lint-md:
    mapfile -d '' files < <(git ls-files -z --cached --others --exclude-standard -- '*.md'); lychee --config .lychee.toml --root-dir . "${files[@]}"

[group('quality')]
test-installer:
    sh scripts/test-installer.sh

[group('quality')]
test-release-automation:
    python3 -m unittest scripts/test_release_automation.py

[group('quality')]
check-release-metadata:
    python3 scripts/check-release-metadata.py

[group('quality')]
check: fmt-check test flutter-check check-release-metadata test-installer test-release-automation

[group('quality')]
preflight: check

[group('quality')]
hook-format-check:
    git diff --cached --check
    cargo fmt --check
    python3 scripts/check-dart-format.py flutter/lib flutter/test

[group('flutter')]
setup-flutter:
    mise install http:flutter
    mise exec -- flutter --version

[group('flutter')]
flutter-get:
    cd flutter && flutter pub get --enforce-lockfile

[group('flutter')]
flutter-app-check: flutter-get
    python3 scripts/check-flutter-config.py
    python3 scripts/check-dart-format.py flutter/lib flutter/test
    cd flutter && flutter analyze --no-pub
    cd flutter && flutter test --no-pub

[group('flutter')]
flutter-check: flutter-app-check

# Lean hosted application tests; the flterm suite runs in the libghostty repo.
[group('flutter')]
flutter-ci-check: flutter-app-check

# Shared web + Android + Linux gate; prefer container-ci on x86_64 Linux.
[group('flutter')]
flutter-linux-ci: flutter-ci-check flutter-linux-builds

# Compile every Flutter target faithfully buildable on a Linux host.
[group('flutter')]
flutter-linux-builds:
    rm -rf target/book/web flutter/build/app flutter/build/linux-gtk4
    just build-web
    just build-flutter-android-debug
    just build-flutter-linux

[group('flutter')]
patch-flutter-plugins: flutter-get
    {{ env_var_or_default('PYTHON', 'python3') }} scripts/patch-flutter-plugins.py flutter

[group('flutter')]
build-flutter-android: patch-flutter-plugins
    cd flutter && flutter build apk --release --no-pub
    cd flutter && flutter build appbundle --release --no-pub

[group('flutter')]
build-flutter-android-debug: patch-flutter-plugins
    cd flutter && flutter build apk --debug --no-pub --target-platform android-arm64

[group('flutter')]
build-flutter-android-store tag version build_number: patch-flutter-plugins
    scripts/build-android-store-bundle.sh "{{ tag }}" "{{ version }}" "{{ build_number }}"

[group('flutter')]
build-flutter-linux: patch-flutter-plugins
    cd flutter && flutter build linux --release --no-pub

[group('flutter')]
build-flutter-linux-release sha: flutter-get
    export SOURCE_DATE_EPOCH="$(git show -s --format=%ct '{{ sha }}')" TZ=UTC LC_ALL=C.UTF-8; python3 scripts/patch-flutter-plugins.py flutter; cd flutter && flutter build linux --release --no-pub

[group('flutter')]
build-flutter-windows: patch-flutter-plugins
    cd flutter && flutter build windows --release --no-pub

[group('flutter')]
build-flutter-windows-release tag: build-flutter-windows
    pwsh -NoProfile -File scripts/package-windows-release.ps1 "{{ tag }}"

[group('flutter')]
build-flutter-windows-store version: patch-flutter-plugins
    cd flutter && flutter build windows --release --no-pub --build-name "{{ version }}" --build-number 0

[group('flutter')]
build-flutter-ios: flutter-get
    cd flutter && flutter build ios --simulator --debug --no-pub

[group('flutter')]
build-flutter-macos: flutter-get
    cd flutter && flutter build macos --release --no-pub

[group('flutter')]
build-apple-development: flutter-get
    cd flutter && flutter build ios --simulator --debug --no-pub
    cd flutter && flutter build macos --release --no-pub

[group('flutter')]
package-ios-simulator-development:
    scripts/package-apple-development.sh ios-simulator

[group('flutter')]
package-macos-development:
    scripts/package-apple-development.sh macos

[group('flutter')]
package-ios-preview version: flutter-get
    scripts/package-ios-preview.sh "{{ version }}"

[group('flutter')]
package-linux-release tag sha:
    bash scripts/package-linux-release.sh "{{ tag }}" "{{ sha }}"

# Run any supported mode in the pinned Flutter CI image.
[group('containers')]
container-flutter mode='ci':
    bash scripts/container-flutter.sh "{{ mode }}"

# Mirror GitHub's Linux-hosted Dart, web, Android, and Linux gate.
[group('containers')]
container-ci:
    bash scripts/container-flutter.sh ci

# Run preflight, workflow/docs checks, and Linux-hostable Flutter builds.
[group('containers')]
container-all:
    bash scripts/container-flutter.sh all

# Run Rust and exhaustive Flutter application checks without platform builds.
[group('containers')]
container-preflight:
    bash scripts/container-flutter.sh preflight

# Run the exhaustive Flutter application checks.
[group('containers')]
container-flutter-check:
    bash scripts/container-flutter.sh check

# Validate GitHub Actions and build the documentation book.
[group('containers')]
container-quality:
    bash scripts/container-flutter.sh quality

# Check documentation links; pass GITHUB_TOKEN to avoid API rate limits.
[group('containers')]
container-links:
    bash scripts/container-flutter.sh links

# Run the live relay, pairing, revocation, and PTY integration test.
[group('containers')]
container-e2e:
    bash scripts/container-flutter.sh e2e

# Build the release web client with the pinned Wasm toolchain.
[group('containers')]
container-web:
    bash scripts/container-flutter.sh web

# Build the ARM64 Android debug compile gate.
[group('containers')]
container-android:
    bash scripts/container-flutter.sh android

# Build unsigned Android release APK and AAB artifacts.
[group('containers')]
container-android-release:
    bash scripts/container-flutter.sh android-release

# Compatibility entry point; defaults to the historical Flutter check mode.
[group('containers')]
container-linux mode='check':
    bash scripts/container-linux.sh "{{ mode }}"

# Build the Linux desktop client in the pinned Ubuntu/GTK4 image.
[group('containers')]
container-linux-build:
    bash scripts/container-flutter.sh linux

# Build and package the checksummed Linux release archive.
[group('containers')]
container-linux-bundle:
    bash scripts/container-flutter.sh linux-bundle

[group('flutter')]
build-flatpark-test-bundle:
    bash scripts/build-flatpark-test-bundle.sh

[group('docs')]
build-docs:
    mdbook build

[group('docs')]
serve-docs:
    mdbook serve --open

[group('flutter')]
build-web: setup-flutter
    scripts/build-web.sh

[group('flutter')]
test-web: flutter-check build-web

[group('flutter')]
serve-web: build-web
    cd flutter && flutter run -d web-server --web-port 3001

[group('release')]
build-context:
    scripts/release-context.sh

[group('release')]
release-context tag:
    scripts/release-context.sh "{{ tag }}"

[group('release')]
build-cli-release target:
    rustup target add "{{ target }}"
    cargo build --locked --release --target "{{ target }}"

[group('release')]
bundle-cage:
    scripts/bundle-cage.sh

[group('release')]
package-cli-release target:
    scripts/package-cli-release.sh "{{ target }}"

[group('release')]
configure-android-signing:
    scripts/configure-android-signing.sh

[group('release')]
package-android-release tag signing_mode:
    scripts/package-android-release.sh "{{ tag }}" "{{ signing_mode }}"

[group('release')]
package-android-unsigned tag:
    scripts/package-android-unsigned.sh "{{ tag }}"

[group('release')]
publish-android-store file sha package track mode label:
    scripts/android-upload-google-play.sh "{{ file }}" "{{ sha }}" "{{ package }}" "{{ track }}" "{{ mode }}" "{{ label }}"

[group('release')]
prepare-ios-ghostty: flutter-get
    python3 scripts/prepare-libghostty-ios-static.py

[group('release')]
build-ios-store:
    cd flutter && flutter build ipa --release --no-pub --build-name "$ZUKO_VERSION" --build-number "$ZUKO_BUILD_NUMBER" --export-options-plist "$APPLE_EXPORT_OPTIONS"

[group('release')]
package-ios-store:
    scripts/package-ios-store.sh

[group('release')]
package-windows-store tag sha:
    pwsh -NoProfile -File flutter/windows/store/Package.ps1 -Tag "{{ tag }}" -ExpectedSha "{{ sha }}" -BuildDirectory flutter/build/windows/x64/runner/Release -OutputDirectory dist/windows-store

[group('release')]
validate-windows-store tag sha:
    pwsh -NoProfile -File flutter/windows/store/Test-ReleaseSource.ps1 -Tag "{{ tag }}" -ExpectedSha "{{ sha }}"
    pwsh -NoProfile -File flutter/windows/store/Test-Package.ps1 -Tag "{{ tag }}" -ExpectedSha "{{ sha }}" -InputDirectory dist/windows-store

[group('release')]
validate-partner-center:
    pwsh -NoProfile -File flutter/windows/store/Test-PartnerCenter.ps1

[group('release')]
upload-windows-store-draft:
    pwsh -NoProfile -Command '$bundles = @(Get-ChildItem dist/windows-store -Filter *.msixbundle); if ($bundles.Count -ne 1) { throw "Expected exactly one MSIXBundle" }; msstore publish $bundles[0].FullName --appId $env:MSSTORE_PRODUCT_ID --noCommit'

[group('release')]
capture-windows-store-draft:
    pwsh -NoProfile -File flutter/windows/store/Test-PartnerCenterDraft.ps1 -Mode Capture -InputDirectory dist/windows-store -SnapshotPath dist/windows-store/submission-identity.json

[group('release')]
verify-windows-store-draft:
    pwsh -NoProfile -File flutter/windows/store/Test-PartnerCenterDraft.ps1 -Mode Verify -InputDirectory dist/windows-store -SnapshotPath dist/windows-store/submission-identity.json

[group('release')]
submit-windows-store:
    msstore submission publish "$MSSTORE_PRODUCT_ID"

[group('release')]
check-crate-package:
    scripts/check-crate-package.sh

[group('release')]
crate-publish-status:
    scripts/crate-publish-status.sh

[group('release')]
publish-crate:
    cargo publish --locked

[group('release')]
publish-github-release tag:
    scripts/publish-github-release.sh "{{ tag }}"

[group('operations')]
select-xcode:
    scripts/select-xcode.sh

[group('operations')]
run-host:
    sh scripts/zuko-host.sh

[group('operations')]
generate-icons:
    sh scripts/generate-icons.sh

[group('operations')]
upload-appetize platform file public_key note='manual upload':
    sh scripts/upload-appetize.sh "{{ platform }}" "{{ file }}" "{{ public_key }}" "{{ note }}"

[group('release')]
release: check-release-metadata
    sh scripts/release.sh
