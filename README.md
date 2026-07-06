# zuko

[![build](https://github.com/adonm/zuko/actions/workflows/build.yml/badge.svg)](https://github.com/adonm/zuko/actions/workflows/build.yml)
[![ios](https://github.com/adonm/zuko/actions/workflows/build-ios.yml/badge.svg)](https://github.com/adonm/zuko/actions/workflows/build-ios.yml)
[![docs](https://github.com/adonm/zuko/actions/workflows/docs.yml/badge.svg)](https://adonm.github.io/zuko/)
[![release](https://github.com/adonm/zuko/actions/workflows/release.yml/badge.svg)](https://github.com/adonm/zuko/releases/latest)
[![license](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)

Remote PTYs over [Iroh](https://www.iroh.computer/). No open ports. Linux/macOS
host daemon, Rust CLI client, and iOS/iPadOS client.

zuko targets machines you own and prefer to keep off public SSH/VPN/bastion/DNS
plumbing. Iroh gives dial-by-key reachability, relay fallback, NAT traversal,
and end-to-end encryption; zuko keeps the payload simple: a real host PTY plus a
small framed protocol. It is terminal-first, with GUI app streaming as an
extension of the same shell session.

## Install a host

```sh
curl https://mise.run | sh
mise use --global github:adonm/zuko
zuko install
```

Linux service logs:

```sh
journalctl --user -u zuko-host -f
```

Manual foreground host:

```sh
zuko host
```

## Pair and connect

```sh
# host
zuko share
# iridescent-hilton

# client
zuko iridescent-hilton

# later
zuko ls
zuko home
```

State:

| Path | Meaning |
|------|---------|
| `~/.config/zuko/key` | host identity |
| `~/.config/zuko/current_ticket` | host's current dial ticket, read by `zuko share` |
| `~/.config/zuko/authorized_clients` | host allow-list |
| `~/.config/zuko/hosts` | client-side saved hosts |
| `~/.config/zuko/client_key` | CLI client's stable token seed |

Manage host trust:

```sh
zuko ls          # saved hosts + authorised clients
zuko rm ipad     # remove saved host and/or authorised client named ipad
zuko reset       # rotate host key, clear authorised clients; restart host after
```

## Use

```sh
zuko <name>              # connect
zuko                     # TTY picker / non-TTY list
zuko share               # authorise a new client
zuko claim <code> --as x # explicit claim form
zuko upgrade --check     # mise-managed upgrade plan
```

Session notes:

- Real host PTY; bytes are forwarded verbatim.
- Detached PTY lease: 5 minutes. No replay buffer.
- Use `tmux`, `zellij`, or `screen` for durable work.
- CLI force-exit: Ctrl-C three times within ~1s with no remote output.

## `zuko app` (Linux)

Run a GUI app inside an existing zuko shell. Output is Kitty graphics over the
same PTY/Iroh connection.

```sh
zuko app --list
zuko app firefox
zuko app --doctor
```

See [`docs/app.md`](docs/app.md).

## Clients

| Client | Status | Source |
|--------|--------|--------|
| CLI | shipped | `src/client.rs` |
| iOS/iPadOS | shipped | `ios/Zuko/` |
| Web | experimental | [`adonm.github.io/zuko/web/`](https://adonm.github.io/zuko/web/) / `web/` |
| Android | planned | — |

Protocol: [`docs/protocol.md`](docs/protocol.md). Client notes:
[`docs/clients.md`](docs/clients.md).

The web client is a static Pages app using Iroh WASM (relay-only, still E2E
encrypted) and a Ghostty-derived terminal core via wterm. It stores claimed host
tickets in browser IndexedDB, so treat that browser profile/origin as sensitive.

## Build/test

```sh
mise install
mise run test
mise run test-e2e      # live Iroh network + PTY
cargo build --release
```

iOS:

```sh
mise run setup-ios
mise run build-ios
swift test --package-path ios/ZukoWire
```

## Repo map

| Path | Contents |
|------|----------|
| `src/` | Rust crate: host, CLI client, handoff, service, app streaming, FFI |
| `ios/Zuko/` | iOS/iPadOS app |
| `ios/ZukoWire/` | Swift wire-framing package |
| `docs/` | mdBook docs |
| `tests/e2e.rs` | ignored live-network integration test |
| `.github/workflows/` | build, release, iOS, docs CI |

## Security

The host ticket (`endpointa…`) is a bearer secret. It is handed out only via
`zuko share`/`claim`; clients must also be listed in `authorized_clients`.

Report vulnerabilities via GitHub Security Advisory. Details:
[`docs/security.md`](docs/security.md).

## License

Apache-2.0. See [`LICENSE`](LICENSE).
