# zuko

[![build](https://github.com/adonm/zuko/actions/workflows/build.yml/badge.svg)](https://github.com/adonm/zuko/actions/workflows/build.yml)
[![ios](https://github.com/adonm/zuko/actions/workflows/build-ios.yml/badge.svg)](https://github.com/adonm/zuko/actions/workflows/build-ios.yml)
[![android](https://github.com/adonm/zuko/actions/workflows/build-android.yml/badge.svg)](https://github.com/adonm/zuko/actions/workflows/build-android.yml)
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

Install the zuko binary on the host and client:

```sh
curl https://mise.run | sh
mise use --global github:adonm/zuko
```

On the host, install and start the user service:

```sh
zuko install
```

Linux service logs:

```sh
journalctl --user -u zuko-host -f
```

Or run the host in the foreground:

```sh
zuko host
```

Pair one client:

```sh
# host: prints a one-time two-word code
zuko share
# iridescent-hilton

# client: claims, saves, and connects
zuko iridescent-hilton

# future connections
zuko ls
zuko home
```

Pairing needs a running host; interactively, `zuko share` offers to install and
start one if needed. Pairing registers that client in the host allow-list; the
saved name is used for later connections. See
[`docs/host.md`](docs/host.md) for service setup, macOS logs, trust management,
and troubleshooting.

## Product scope

| Tier | Surface | Commitment |
|------|---------|------------|
| **Core** | Linux/macOS host and Rust CLI | Primary supported workflow |
| **Beta** | iOS/iPadOS client | Built and tested; distribution and OS support are still limited |
| **Labs** | Android/browser clients and Linux `zuko app` | Useful experiments; expect gaps and change |

The current priority is to make pairing, connecting, reconnecting, diagnostics,
and trust management boringly reliable. New platforms and richer streaming do
not take priority over the core shell path. See the [roadmap](docs/roadmap.md)
for promotion criteria and explicitly deferred work.

zuko is not a durable session manager, full remote desktop, or centralized
fleet-access system. Use `tmux`, `zellij`, or `screen` for work that must survive
disconnects and host restarts.

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
zuko doctor              # check service, ticket, state, and network
zuko upgrade --check     # mise-managed upgrade plan
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

## Clients

| Client | Status | Source |
|--------|--------|--------|
| Rust CLI | Core | Linux/macOS release binaries; `src/client.rs` |
| iOS/iPadOS | Beta | iOS/iPadOS 26.5; source and TestFlight pipeline in `ios/` |
| Android | Labs | API 29+ APK/AAB; native Compose, Iroh 1.0, and libghostty-vt in `android/` |
| Web | Labs | [Open web client](https://zuko.adonm.dev/web/); relay-only |

Protocol: [`docs/protocol.md`](docs/protocol.md). Client notes:
[`docs/clients.md`](docs/clients.md).

The web client is a static Pages app using Iroh WASM (relay-only, still E2E
encrypted) and a Ghostty-derived terminal core via wterm. It does not yet
reconnect and stores sensitive connection state (host ticket and client key) in
browser IndexedDB, so treat that browser profile and origin as sensitive.

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

Android (JDK/SDK/NDK are opt-in; see [`android/NATIVE.md`](android/NATIVE.md)):

```sh
mise run test-android-core
export ANDROID_NDK_HOME="$ANDROID_HOME/ndk/29.0.14206865"
mise run android-ci
```

## Repo map

| Path | Contents |
|------|----------|
| `src/` | Rust crate: host, CLI client, handoff, service, app streaming, FFI |
| `ios/Zuko/` | iOS/iPadOS app |
| `ios/ZukoWire/` | Swift wire-framing package |
| `android/` | Android app, pure Kotlin protocol core, and libghostty JNI bridge |
| `docs/` | mdBook docs |
| `tests/e2e.rs` | ignored live-network integration test |
| `.github/workflows/` | build, release, iOS, docs CI |

## Security

Shell access requires both host connection information and an authorized client
token. `zuko share` transfers the former and registers the latter over an
end-to-end-encrypted handoff. Keep both private and revoke lost clients with
`zuko rm <name>`.

Report vulnerabilities via GitHub Security Advisory. Details:
[`docs/security.md`](docs/security.md).

## License

Apache-2.0. See [`LICENSE`](LICENSE).
