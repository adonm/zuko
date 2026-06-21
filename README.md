# zuko

**Remote terminals over [Iroh](https://www.iroh.computer/).** Dial by key,
end-to-end encrypted, no open ports or port forwarding. Run the **host** on any
Linux/macOS box you want to reach, then attach a **client** from anywhere —
`vim`, `htop`, tab completion, resize, Ctrl-C all work, because the host runs a
real PTY.

zuko is a small **wire protocol** and a **host daemon**. The clients are
pluggable: the iOS app and the CLI are the first two, and Android / a Linux GUI
(relm4) / others can speak the same protocol. The spec is in
[`docs/PROTOCOL.md`](docs/PROTOCOL.md); the client list lives in
[`docs/CLIENTS.md`](docs/CLIENTS.md).

```mermaid
flowchart TB
    subgraph clients["any client"]
        direction LR
        iOS["iOS app"]
        CLI["CLI"]
        Android["Android…"]
    end

    Iroh(["Iroh · end-to-end encrypted"])
    Zuko["zuko host"]
    PTY[("PTY + your shell")]

    clients <--> Iroh
    Iroh <--> Zuko
    Zuko --- PTY
```

- **Pair with a code.** Add a new device with `zuko share` on the host (prints
  a short, minutes-long code) and `zuko <code>` on the other machine. The code
  is a one-time pad over an ephemeral Iroh key — the host's persistent key
  stays put.
- **Real PTY.** Bytes flow verbatim between the client and the host's shell, so
  every terminal program behaves exactly as if it were local.
- **Survives network drops.** A session outlives its connection: drop wifi, put
  the laptop to sleep, switch networks — the client reconnects and resumes the
  same shell (cwd, running command, editor intact). The host keeps sessions
  alive **forever** (so resuming days later still works); run `zuko reap` on
  the host to clean up idle ones. See
  [Reconnect & resume](#reconnect--resume).
- **No port forwarding, no relay you run.** Iroh's public relays + NAT
  traversal do the reachability; the connection is end-to-end encrypted by the
  host's key.
- **Service install in the CLI.** `zuko install` writes the systemd/launchd
  user unit and starts the daemon. `zuko uninstall` reverses it.

## Clients

Anyone can write a client — zuko is one bidirectional Iroh stream and a tiny
frame format. See [`docs/CLIENTS.md`](docs/CLIENTS.md) for the full list and
[`docs/PROTOCOL.md`](docs/PROTOCOL.md) for the spec. Reference implementations:

| Client | Status | Stack | Source |
|--------|--------|-------|--------|
| **CLI** | shipped | Rust 2024 edition + crossterm | the `zuko` binary (`zuko connect`) |
| **iOS** | shipped | Swift 6.2 + [GhosttyTerminal](https://github.com/Lakr233/libghostty-spm) + IrohLib | [`ios/Zuko/`](ios/Zuko) |
| Android | planned | — | — |
| Linux GUI (relm4) | planned | — | — |

The CLI ships in the same `zuko` binary as the host — one install gives you
both. The iOS app is built from source (or pushed to TestFlight from CI; see
[`ios/DISTRIBUTION.md`](ios/DISTRIBUTION.md)).

## Quick start

### 1. Set up a host

Prerequisite: [mise](https://mise.jdx.dev) on the host (`curl https://mise.run | sh`).

On the machine you want to shell into:

```sh
mise use --global github:adonm/zuko   # put `zuko` on PATH
zuko install                          # write the systemd/launchd unit + start it
```

`zuko install` writes a persistent secret key to `~/.config/zuko/key` (on the
first host run), installs a `zuko-host-run` wrapper at `~/.local/bin/`, and
starts a background service (systemd user unit on Linux, launchd on macOS).
Logs go to `journalctl --user -u zuko-host -f` (Linux) or
`~/.config/zuko/zuko-host.out.log` (macOS).

> Manual / no service manager? Run `zuko host` in the foreground, or
> [`scripts/zuko-host.sh`](scripts/zuko-host.sh) from a checkout.

### 2. Pair a client

```sh
# on the host (code is read-once, expires in minutes):
zuko share
#   iridescent-hilton

# on the client:
zuko iridescent-hilton   # fetches the ticket, saves it, connects
```

By default `claim` saves the host under the host's label (override with
`--as <name>`) and drops you straight into the shell. From then on, connect
by name:

```sh
zuko ls                            # list saved hosts
zuko home                          # = zuko connect home (shorthand)
```

**iOS** — see [`ios/Zuko/README.md`](ios/Zuko/README.md) for building the app
from source (Simulator or device).

## Reconnect & resume

A zuko **session** (PTY + shell + a buffer of recent output) outlives any single
connection: drop wifi, sleep the laptop, switch networks — the client reconnects
and resumes the same shell (cwd, running command, editor intact). The host
keeps sessions alive **forever** (so resuming days later still works) — the
operator controls cleanup via `zuko reap` (kills sessions idle for over an hour,
run on the host). Print `exit` in the remote shell to end for real; `kill` the
`zuko` process to give up.

If the session wedges hard (keystrokes vanish), **Ctrl-C 3× within ~1 s** with
no remote output between presses force-exits the client — see
[`docs/HOST.md`](docs/HOST.md#force-quitting-the-cli) for the detail.

Full mechanics (ring buffer, SIGWINCH redraw, the wire flags that make
resume work) are in [`docs/PROTOCOL.md`](docs/PROTOCOL.md#session-resume);
the operator-facing cleanup is `zuko reap` (see
[`docs/HOST.md`](docs/HOST.md#sessions--resume)).

## Wire protocol

One bidirectional Iroh stream, ALPN `zuko/1`. The full spec (frame types,
capability flags, the ticket-handoff ALPN) is in
[`docs/PROTOCOL.md`](docs/PROTOCOL.md); reference impls in
[`src/wire.rs`](src/wire.rs) (Rust) and
[`ios/Zuko/Zuko/Net/Wire.swift`](ios/Zuko/Zuko/Net/Wire.swift) (Swift).

## What's in here

| Path | What |
|------|------|
| `src/`, `Cargo.toml` | The `zuko` crate — library + binary + uniffi staticlib. Binary covers host (`zuko host`), CLI client (`zuko connect`/`share`/`claim`), and service installer. `src/ffi.rs` exposes the Argon2id code-derivation for mobile clients. |
| `tests/e2e.rs` | End-to-end PTY harness — spawns host + client, exercises `share`→`claim` over the live Iroh network. |
| `scripts/` | `zuko-host.sh` (foreground dev wrapper), `release.sh` (tag + push). |
| `ios/Zuko/` | The iOS client (xtool + Swift + GhosttyTerminal, networking via IrohLib). |
| `docs/` | [`HOST.md`](docs/HOST.md) (user guide), [`PROTOCOL.md`](docs/PROTOCOL.md) (wire spec), [`CLIENTS.md`](docs/CLIENTS.md) (client registry), [`RELEASING.md`](docs/RELEASING.md) (cutting releases). |
| `.github/workflows/` | CI: build+test `zuko` + iOS app; publish release binaries. |

## Requirements

- Host: any Linux/macOS box with [mise](https://mise.jdx.dev). `mise use
  --global github:adonm/zuko` installs the prebuilt binary; `cargo` is only
  needed to build from source.
- CLI client: same — `mise use --global github:adonm/zuko`.
- iOS client: iOS 26+ (IrohLib requirement), Xcode 26+.

## Security notes

- The host's `endpointa…` ticket is the only long-lived secret. It moves only
  through `zuko share` → `zuko claim`: an E2E-encrypted Iroh stream keyed by a
  one-time code; `share`/`claim` never weaken the host key (see
  [`docs/PROTOCOL.md`](docs/PROTOCOL.md#ticket-handoff)).
- Anyone with the ticket can connect — treat it like an SSH private key.
  Rotate by deleting `~/.config/zuko/key` and restarting; the node id changes
  and all old tickets stop working.

## Development

Tools, system deps, and tasks are defined in [`mise.toml`](mise.toml):

```sh
mise install              # rust (+ system deps via mise bootstrap)
mise run test             # clippy + unit tests
mise run test-e2e         # end-to-end: host<->connect + share<->claim over Iroh
mise run build            # release binary
mise run setup-ios        # install xtool + Swift pieces for local iOS builds
mise run build-ios        # Linux-first xtool iOS build (auto-installs cached SDK)
mise run run-host         # run `zuko host` in the foreground
```

CI uses the same tasks via [`jdx/mise-Action`](https://github.com/jdx/mise-Action),
so local and CI stay in lockstep. Cutting a release is documented in
[`docs/RELEASING.md`](docs/RELEASING.md).

## License

Apache-2.0. See [`LICENSE`](LICENSE).
