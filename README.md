<p align="center">
  <img src="zuko-logo.svg" width="128" height="128" alt="Zuko logo">
</p>

<h1 align="center">zuko</h1>

[![build](https://github.com/adonm/zuko/actions/workflows/build.yml/badge.svg)](https://github.com/adonm/zuko/actions/workflows/build.yml)
[![flutter](https://github.com/adonm/zuko/actions/workflows/build-flutter.yml/badge.svg)](https://github.com/adonm/zuko/actions/workflows/build-flutter.yml)
[![docs](https://github.com/adonm/zuko/actions/workflows/docs.yml/badge.svg)](https://zuko.adonm.dev/)
[![release](https://github.com/adonm/zuko/actions/workflows/release.yml/badge.svg)](https://github.com/adonm/zuko/releases/latest)
[![license](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)

**Private remote shells for machines you own—without opening inbound ports or
operating a VPN.** Pair once with a short code, then reconnect by name from a
terminal.

zuko runs a real PTY over [Iroh](https://www.iroh.computer/), which provides
dial-by-key reachability, NAT traversal, relay fallback, and end-to-end
encryption. The supported core is deliberately small: a Linux/macOS host, the
Rust CLI, explicit device authorization, and short reconnects.

## Quick start

Install the CLI on a Linux or macOS host:

```sh
curl --proto '=https' --tlsv1.2 -LsSf https://zuko.adonm.dev/install.sh | sh
# Relaunch your shell here if the installer asks.
zuko install
```

Pair from another machine with the CLI installed:

```sh
# host: prints a one-time two-word code
zuko share

# client: claims, saves, and connects
zuko iridescent-hilton

# later
zuko home
```

The installer bootstraps and activates mise when needed, then installs Zuko as a
mise-managed global tool. Relaunch your shell first if it asks. See
[Getting started](docs/getting-started.md) for mise, version selection, service
logs, and first connection. Windows hosts can use the documented
[WSL2 setup](docs/windows-wsl2.md), with lifecycle limitations.

## Product scope

| Tier | Surface | Commitment |
|------|---------|------------|
| **Core** | Linux/macOS host and Rust CLI | Primary supported workflow |
| **Beta** | Shared Flutter client (Android/iOS/macOS/web/Linux/Windows) | One cross-platform graphical client in active validation |
| **Labs** | Linux `zuko app` | Optional GUI-over-terminal experiment |

See [Clients](docs/clients.md) for downloads and the
[client build guide](docs/building-clients.md) for fresh Android, Apple, web,
Linux, and Windows builds.

zuko is not a durable session manager, full remote desktop, or centralized
fleet-access system. Use `tmux`, `zellij`, or `screen` for work that must survive
disconnects and host restarts.

## Use

```sh
zuko <name>              # connect
zuko                     # TTY picker / non-TTY list
zuko share               # authorise a new client
zuko claim <code> --as x # explicit claim form
zuko doctor              # check service, ticket, state, and network
```

Session notes:

- Real host PTY; bytes are forwarded verbatim.
- Detached PTY lease: 5 minutes. No replay buffer.
- Use `tmux`, `zellij`, or `screen` for durable work.
- CLI force-exit: Ctrl-C three times within ~1s with no remote output.

## Labs: `zuko app` (Linux)

Run a GUI app inside an existing zuko shell. Output is Kitty graphics over the
same PTY/Iroh connection. This is an optional Labs feature, not a remote-desktop
goal.

```sh
zuko app --list
zuko app firefox
zuko app --doctor
```

See [`docs/app.md`](docs/app.md).

## Build/test

```sh
mise install
just check
just test-e2e      # live Iroh network + PTY
cargo build --release
```

Platform prerequisites, Windows PowerShell commands, signing behavior, and
artifact paths are in [Building clients](docs/building-clients.md).

## Repo map

| Path | Contents |
|------|----------|
| `src/` | Rust crate: host, CLI client, handoff, service, and app streaming |
| `flutter/` | Shared Android, iOS, macOS, web, Linux, and Windows client |
| `Justfile` | Human-facing build, test, package, and release recipes |
| `mise.toml` | Managed tools, system dependencies, and compatibility task aliases |
| `docs/` | mdBook docs |
| `tests/e2e.rs` | ignored live-network integration test |
| `.github/workflows/` | Rust, Flutter, release, TestFlight, and docs CI |

## Security

Shell access requires both host connection information and an authorized client
token. `zuko share` transfers the former and registers the latter over an
end-to-end-encrypted handoff. Keep both private and revoke lost clients with
`zuko rm <name>`.

Report vulnerabilities via GitHub Security Advisory. Details:
[`docs/security.md`](docs/security.md).

## License

Apache-2.0. See [`LICENSE`](LICENSE).
