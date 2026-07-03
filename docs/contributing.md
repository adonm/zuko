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

Client authors: start with [`protocol.md`](protocol.md), then
[`clients.md`](clients.md).

Security reports: use GitHub Security Advisories.
