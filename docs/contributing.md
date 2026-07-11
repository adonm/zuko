# Contributing

Use `mise` for pinned tools, environment, and bootstrap dependencies. Use
`just` for every human-facing and CI operation. CI installs `mise.toml` directly
and invokes the same Justfile recipes through `mise exec -- just <recipe>`.

```sh
git submodule update --init --recursive
mise bootstrap          # OS packages + shell activation + pinned tools
just                     # grouped recipe list
just check           # Rust + Flutter + release metadata
just test            # Rust clippy + unit tests
just test-e2e        # live Iroh network + PTY
just preflight       # full local CI mirror
just build
```

Flutter terminal changes live in the pinned `flutter/packages/flterm`
submodule. Commit and push them in `adonm/flterm` first, then update the Zuko
gitlink; do not vendor the package source or generated binary test fixtures.

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
  `just flutter-check`; do not create a target-specific second implementation.
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

Client authors: start with [`protocol.md`](protocol.md), then
[`clients.md`](clients.md).

Security reports: use GitHub Security Advisories.
