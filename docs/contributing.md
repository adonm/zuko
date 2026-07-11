# Contributing

Use `mise` for managed tools and `just` for recipes. CI enters through the same
mise environment and recipe graph. The existing `mise run <name>` aliases are
kept for compatibility, but new commands and documentation should prefer
`just <name>`.

```sh
git submodule update --init --recursive
mise bootstrap          # OS packages + shell activation + pinned tools
just                 # grouped recipe list
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
contains tool versions, OS packages, environment, and thin task aliases. Put
multi-step platform logic in `scripts/` rather than inline workflow YAML.

Apple targets (macOS/Xcode):

```sh
just build-flutter-ios
just build-flutter-macos
```

Platform prerequisites, output paths, and the native Windows PowerShell build
are in [Building clients](building-clients.md). The Justfile requires Bash;
Windows CI therefore invokes Flutter directly from PowerShell.

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
