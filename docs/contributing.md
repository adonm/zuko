# Contributing

Use `mise` for pinned tools, environment, and bootstrap dependencies. Use
`just` for every human-facing and CI operation. CI installs `mise.toml` directly
and invokes the same Justfile recipes through `mise exec -- just <recipe>`.

On Linux, contribute from an x86_64 Ubuntu 24.04 Distrobox created from
`quay.io/toolbx/ubuntu-toolbox:24.04`. This is the local baseline used to match
the repository's explicit Ubuntu 24.04 Linux jobs. Enter the box and activate
Mise before running checks; Ubuntu 26.04 and Fedora are
optional compatibility environments, not replacements for this gate. See
[Building clients](building-clients.md) for creation and package setup.

```sh
mise trust
mise bootstrap          # OS packages and pinned tools, including Flutter
eval "$(mise activate bash)"
hk install --mise       # local format and full pre-push gates
just                     # grouped recipe list
just check           # Rust + Flutter + release metadata
just test            # Rust clippy + unit tests
just test-e2e        # live Iroh network + PTY
just preflight       # full source, analysis, and test preflight
just container-ci    # web + Android + Linux compile gate on x86_64 Linux
just container-all   # preflight + quality + Linux-hostable Flutter builds
just build
```

The Ubuntu 24.04 Distrobox is the normal Rust, Dart, Flutter-test, and direct
Linux iteration environment. The `container-*` recipes remain the full Flutter
compile gate because they pin the Android SDK/NDK and other build-only inputs.
They prevent silently skipping Android or Linux because CMake, GTK, Java, or
the Android SDK is absent. Use focused `container-web`, `container-android`, and
`container-linux-build` recipes during iteration; use `container-all` before
requesting review when Flutter or its build configuration changed. See
[Building clients](building-clients.md) for the exact coverage and the
Apple/Windows boundary.

Flutter terminal and Dart binding changes live in the `adonm/libghostty`
monorepo. Submit reusable changes upstream, then update both immutable Git
package refs in `flutter/pubspec.yaml` to the same tested commit; do not vendor
package source or generated binary test fixtures into Zuko.

`Justfile` contains commands and dependencies between recipes. `mise.toml`
contains only tool versions, OS packages, and environment. Put multi-step
platform logic in `scripts/` rather than inline workflow YAML. Workflows retain
only GitHub orchestration: runners, permissions, protected environments,
secrets, caches, matrices, approvals, and artifact transfer.

Each CI job lets `jdx/mise-action` install the repository configuration as-is;
do not duplicate tool lists in workflow YAML. Mise's cache covers pinned tool
downloads. Keep additional caching narrow and use the official `actions/cache`
only for expensive immutable inputs such as the Flutter package cache or fixed
test fixtures. Cargo target directories are intentionally rebuilt rather than
restored through a third-party cache action.

Apple targets (macOS/Xcode):

```sh
just build-flutter-ios
just build-flutter-macos
```

Platform prerequisites, output paths, and the native Windows PowerShell build
are in [Building clients](building-clients.md). The Justfile uses the Git Bash
already present on supported Windows development and CI environments; Windows
packaging details remain in focused PowerShell scripts called by recipes.

Before PR:

- `just check` is green.
- If Flutter changed, keep shared logic in `flutter/lib/src/` and run
  `just flutter-check`; on x86_64 Linux also run `just container-ci` so web,
  Android, and Linux compile. Do not create a target-specific second
  implementation.
- For Flutter UI or input changes, follow the
  [human-centered design guide](flutter-design.md) and test the relevant narrow,
  wide, keyboard, touch, and accessibility paths.
- Keep commits terse and imperative.
- Update `docs/protocol.md` for wire changes.
- Update `docs/host.md` for CLI/state changes.
- Update `docs/roadmap.md` when a support tier, priority, or product boundary
  changes.
- Run `zuko doctor` after service/ticket changes; it must remain read-only and
  avoid printing keys, tickets, or client tokens.

## Scope new work

Read the [roadmap](roadmap.md) and [design principles](design.md) first. Core
reliability, recovery, diagnostics, and trust management take priority over new
clients and streaming modes.

For a new platform, protocol, or background service, describe:

- the Core user problem it solves;
- its intended product tier;
- its trust and resource boundaries;
- how failure and recovery work;
- the tests and ongoing maintenance it requires.

Client authors: start with [`clients.md`](clients.md), then read the
[Flutter human-centered design guide](flutter-design.md) for graphical-client
work and [`protocol.md`](protocol.md) for transport work.

Security reports: use GitHub Security Advisories.

## Local hooks and CI scope

The committed `hk.pkl` keeps deterministic checks close to development:

- pre-commit checks Rust and Dart formatting plus staged whitespace;
- pre-push runs `just preflight` when code, Flutter, build, or tool
  configuration changed, including Rust tests, Flutter application tests, and
  the complete vendored `flterm` analysis and test suite. Documentation-only
  and GitHub Actions-only changes use their smaller dedicated checks.

Install the repository hooks with `hk install --mise`; `HK=0` is the explicit
one-command escape hatch when a broken local environment must be bypassed.
Hosted Flutter CI intentionally runs `just flutter-ci-check`, which retains
configuration checks, formatting, application analysis, and application tests
but does not repeat all vendored `flterm` tests. Cross-platform client builds
still compile the pinned package. Release readiness continues to require the
full local preflight rather than treating the lean hosted check as sufficient.
The local container's `ci` mode and GitHub both call `just flutter-linux-ci`
for the Linux-hostable compile matrix.
