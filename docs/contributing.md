# Contributing

Use `mise`; CI uses the same tasks.

```sh
mise install
mise run check       # fmt --check + clippy + tests + swiftlint
mise run test        # Rust clippy + unit tests
mise run test-e2e    # live Iroh network + PTY
mise run preflight   # CI-ish, includes iOS build
mise run build
```

iOS:

```sh
mise run setup-ios
mise run build-ios
swift test --package-path ios/ZukoWire
```

Before PR:

- `mise run check` is green.
- If iOS Swift/build config changed, run `mise run preflight` where possible.
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
