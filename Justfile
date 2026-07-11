# Human-facing build, test, package, and release recipes.
# Tool versions live in mise.toml; CI and contributors enter through mise.
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

[group('flutter')]
flutter-get:
    mise exec -C flutter -- flutter pub get --enforce-lockfile

[group('flutter')]
flutter-vendor-get:
    mise exec -C flutter/packages/flterm -- flutter pub get

[group('flutter')]
flutter-vendor-check: flutter-vendor-get
    sh flutter/packages/flterm/tool/fetch-test-assets.sh
    python3 scripts/check-dart-format.py --cwd flutter/packages/flterm lib test
    mise exec -C flutter/packages/flterm -- flutter analyze --no-pub
    mise exec -C flutter/packages/flterm -- flutter test --no-pub

[group('flutter')]
flutter-check: flutter-get flutter-vendor-check
    python3 scripts/check-flutter-config.py
    python3 scripts/check-dart-format.py flutter/lib flutter/test
    mise exec -C flutter -- flutter analyze --no-pub
    mise exec -C flutter -- flutter test --no-pub

[group('flutter')]
patch-iroh-flutter: flutter-get
    python3 scripts/patch-iroh-flutter.py flutter

[group('flutter')]
build-flutter-android: flutter-get
    mise exec -C flutter -- flutter build apk --release --no-pub
    mise exec -C flutter -- flutter build appbundle --release --no-pub

[group('flutter')]
build-flutter-linux: flutter-get patch-iroh-flutter
    mise exec -C flutter -- flutter build linux --release --no-pub

[group('flatpak')]
flatpak-validate:
    bash scripts/validate-flatpak.sh

[group('flatpak')]
flatpak-author-setup:
    flatpak remote-add --if-not-exists --user flathub https://dl.flathub.org/repo/flathub.flatpakrepo
    flatpak install --user --noninteractive -y flathub org.flatpak.Builder

[group('flatpak')]
flatpak-author-lint:
    flatpak run --command=flatpak-builder-lint org.flatpak.Builder manifest flatpak/dev.adonm.zuko.json
    # The repository exists after `just flatpak-package` or `just container-flatpak`.
    if test -d build/flatpak/repo; then flatpak run --command=flatpak-builder-lint org.flatpak.Builder repo build/flatpak/repo; fi

[group('flatpak')]
flatpak-package tag='': build-flutter-linux
    bash scripts/package-flatpak.sh "{{ tag }}"

[group('flutter')]
container-flutter mode='check':
    bash scripts/container-flutter.sh "{{ mode }}"

[group('flatpak')]
container-flatpak:
    bash scripts/container-flutter.sh flatpak

[group('flutter')]
build-flutter-windows: flutter-get patch-iroh-flutter
    mise exec -C flutter -- flutter build windows --release --no-pub

[group('flutter')]
build-flutter-ios: flutter-get
    mise exec -C flutter -- flutter build ios --simulator --debug --no-pub

[group('flutter')]
build-flutter-macos: flutter-get
    mise exec -C flutter -- flutter build macos --release --no-pub

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
    mise exec -C flutter -- flutter run -d web-server --web-port 3001

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
release version: check-release-metadata
    sh scripts/release.sh "{{ version }}"
