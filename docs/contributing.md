# Contributing to zuko

Thanks for digging in. zuko is a small wire protocol + host daemon; the
reference clients are the CLI and the iOS/iPadOS app. These docs are also
published as a browsable site (built by mdBook — see `mise run build-docs`);
this page is the source of truth either way.

## Dev setup

[Tools, system deps, and tasks are defined in `mise.toml`](https://github.com/adonm/zuko/blob/main/mise.toml) —
local and CI use the same tasks via [`jdx/mise-Action`](https://github.com/jdx/mise-Action),
so they stay in lockstep.

```sh
mise install                 # rust (+ system deps via mise bootstrap)
mise run check               # fast pre-push: fmt --check + clippy + tests + swiftlint (~10-30s)
mise run test                # clippy + unit tests (no network)
mise run test-e2e            # host<->connect + share<->claim over the live Iroh network (needs network)
mise run preflight           # full CI mirror incl. the xtool iOS build (~3 min; touch iOS code first)
mise run build               # release binary
```

iOS work is opt-in — run `mise run setup-ios` once to install xtool + Swift,
then `mise run build-ios`. The wire-framing package has its own Linux-runnable
tests: `swift test --package-path ios/ZukoWire`.

## Before opening a PR

- `mise run check` is green (it's what CI's build job runs).
- If you touched iOS Swift or build config, also run `mise run preflight`.
- If you touched iOS UX shown in onboarding/screenshots, skim
  [`ios/Zuko/README.md`](https://github.com/adonm/zuko/blob/main/ios/Zuko/README.md) and
  [Releasing](releasing.md#ios-app) so TestFlight copy doesn't
  drift from the toolbar controls.
- Commits should match repo style — terse, imperative subject line.

## Writing a client

zuko is Iroh streams + a handful of frame types; anyone can write a client.
Read [the wire protocol](protocol.md) first, then
[clients](clients.md) for the gotchas the existing clients hit
(opener-must-write-first, clamp zero dims, answer PING, serialise writes,
bound your outbound queue). The reference implementations:

- **Rust:** [`src/wire.rs`](https://github.com/adonm/zuko/blob/main/src/wire.rs) + [`src/client.rs`](https://github.com/adonm/zuko/blob/main/src/client.rs).
- **Swift:** [`ios/ZukoWire/Sources/ZukoWire/Wire.swift`](https://github.com/adonm/zuko/blob/main/ios/ZukoWire/Sources/ZukoWire/Wire.swift)
  + [`ios/Zuko/Zuko/Net/IrohSession.swift`](https://github.com/adonm/zuko/blob/main/ios/Zuko/Zuko/Net/IrohSession.swift).

Mobile clients: don't reimplement the Argon2id key derivation — the crate
ships a [uniffi](https://mozilla.github.io/uniffi-rs/) FFI surface
([`src/ffi.rs`](https://github.com/adonm/zuko/blob/main/src/ffi.rs)) exposing `derive_handoff_key(code)`, so the
derivation is bit-exact with the CLI by construction. See
[clients](clients.md#writing-a-client).

If you ship one, open a PR adding a row to the clients table in
[clients](clients.md#status).

## Security reports

See [security](security.md). Don't open public issues for vulnerabilities.

## License

Apache-2.0. By contributing you agree your contributions are licensed under
the same terms as the project.
