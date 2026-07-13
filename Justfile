# Human-facing build, test, package, and release recipes.
# Tool versions and bootstrap dependencies live in mise.toml.
# Run through an activated Mise shell or `mise exec -- just <recipe>`.
set shell := ["bash", "-euo", "pipefail", "-c"]

default:
    @just --list --list-heading $'Zuko recipes:\n'

[group('core')]
build:
    cargo build --release

[group('core')]
test:
    cargo clippy --all-targets -- -D warnings
    cargo test

[group('core')]
test-e2e:
    cargo test --release --test e2e -- --ignored --nocapture

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
check-release-metadata:
    python3 scripts/check-release-metadata.py

[group('quality')]
check: fmt-check test flutter-check check-release-metadata test-installer

[group('quality')]
preflight: check

[group('quality')]
hook-format-check:
    git diff --cached --check
    cargo fmt --check
    python3 scripts/check-dart-format.py flutter/lib flutter/test
    python3 scripts/check-dart-format.py --cwd flutter/packages/flterm lib test

[group('flutter')]
flutter-get:
    cd flutter && flutter pub get --enforce-lockfile

[group('flutter')]
flutter-vendor-get:
    cd flutter/packages/flterm && flutter pub get

[group('flutter')]
flutter-vendor-check: flutter-vendor-get
    sh flutter/packages/flterm/tool/fetch-test-assets.sh
    python3 scripts/check-dart-format.py --cwd flutter/packages/flterm lib test
    cd flutter/packages/flterm && flutter analyze --no-pub
    cd flutter/packages/flterm && flutter test --no-pub

[group('flutter')]
flutter-app-check: flutter-get
    python3 scripts/check-flutter-config.py
    python3 scripts/check-dart-format.py flutter/lib flutter/test
    cd flutter && flutter analyze --no-pub
    cd flutter && flutter test --no-pub

[group('flutter')]
flutter-check: flutter-vendor-check flutter-app-check

# Hosted CI keeps application analysis/tests and relies on target builds to
# compile the pinned flterm integration. The exhaustive vendored package suite
# remains in flutter-check and the hk pre-push gate.
[group('flutter')]
flutter-ci-check: flutter-app-check

[group('flutter')]
patch-flutter-plugins: flutter-get
    {{ env_var_or_default('PYTHON', 'python3') }} scripts/patch-flutter-plugins.py flutter

[group('flutter')]
build-flutter-android: flutter-get
    cd flutter && flutter build apk --release --no-pub
    cd flutter && flutter build appbundle --release --no-pub

[group('flutter')]
build-flutter-android-debug: flutter-get
    cd flutter && flutter build apk --debug --no-pub --target-platform android-arm64

[group('flutter')]
build-flutter-android-store tag version build_number:
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
package-apple-development:
    scripts/package-apple-development.sh

[group('flutter')]
package-ios-preview version:
    scripts/package-ios-preview.sh "{{ version }}"

[group('flutter')]
package-linux-release tag sha:
    bash scripts/package-linux-release.sh "{{ tag }}" "{{ sha }}"

[group('flutter')]
install-freedesktop-llvm destination='/opt/llvm':
    bash scripts/install-freedesktop-llvm.sh "{{ destination }}"

[group('flutter')]
container-linux mode='check':
    bash scripts/container-linux.sh "{{ mode }}"

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
build-web:
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
package-codemagic-android-unsigned tag:
    scripts/package-codemagic-android-unsigned.sh "{{ tag }}"

[group('release')]
prepare-android-store-aab tag asset package version build_number:
    scripts/prepare-android-store-aab.sh "{{ tag }}" "{{ asset }}" "{{ package }}" "{{ version }}" "{{ build_number }}"

[group('release')]
publish-android-store file sha package track mode label:
    scripts/android-upload-google-play.sh "{{ file }}" "{{ sha }}" "{{ package }}" "{{ track }}" "{{ mode }}" "{{ label }}"

[group('release')]
prepare-ios-ghostty:
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
