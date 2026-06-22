# zuko — host + CLI client + service installer

The `zuko` binary is the **host daemon** (the machine you shell into), the
**reference CLI client**, and the **service installer** — in a single binary.
zuko is remote terminals over Iroh; the [wire protocol](PROTOCOL.md)
and the other clients (iOS, future Android/relm4) are documented in
[`./`](.) (this `docs/` folder).

```
zuko host              serve this machine (writes a key + current_ticket)
zuko install           install the host as a systemd/launchd user service
zuko uninstall         stop + remove the service (keeps the key + saved hosts)
zuko share             mint a one-time code that lets a new device pair
zuko <code>            pair: fetch the host's ticket, save it, connect
zuko claim <code>      the same, with flags (--as, --no-connect, --timeout)
zuko connect <name>    attach a terminal to a saved host
zuko <name>            shorthand for `zuko connect <name>`
zuko                   ask which saved host to connect to (TTY only)
zuko ls                list saved hosts (by name)
zuko rm <name>         remove a saved host
```

Saved hosts live at `~/.config/zuko/hosts`; the host's persistent identity lives
at `~/.config/zuko/key`. `zuko host` also writes its current, dialable ticket to
`~/.config/zuko/current_ticket` (read by `zuko share`).

## Install

Prerequisite: [mise](https://mise.jdx.dev) — install it with `curl https://mise.run | sh`.

```sh
mise use --global github:adonm/zuko   # put `zuko` on PATH
```

mise auto-selects the right asset for your OS/arch and exposes a `zuko` shim on
PATH. To set up host mode as a persistent background service, run on the
machine you want to reach:

```sh
zuko install
```

`zuko install` writes `~/.config/zuko/key` (on the first `zuko host` run),
installs a `zuko-host-run` wrapper at `~/.local/bin/` that execs the resolved
`zuko` binary in host mode, and starts a persistent service:

- **Linux:** systemd user unit `~/.config/systemd/user/zuko-host.service`
  - logs: `journalctl --user -u zuko-host -f`
  - for servers: `sudo loginctl enable-linger "$USER"` so the user manager
    runs without an active login session.
- **macOS:** launchd agent `~/Library/LaunchAgents/dev.adonm.zuko.host.plist`
  - logs: `tail -f ~/.config/zuko/zuko-host.out.log`

Flags for `zuko install`: `--prefix` (default `~/.local`), `--key` (default
`~/.config/zuko/key`), `--shell` (default `$SHELL`), `--no-start` (write +
enable the unit without starting it). `zuko uninstall` stops and removes the
service but leaves the key + saved hosts in place.

## Connect from a terminal

```sh
# once (on the host, foreground):
zuko share
#   iridescent-hilton

# on this machine, once:
zuko iridescent-hilton   # = zuko claim iridescent-hilton
#   fetches the real ticket, saves it, connects

# from then on:
zuko ls                    # list saved hosts
zuko home                  # = zuko connect home (shorthand)
```

The session is a real PTY — `vim`, `htop`, resize, and Ctrl-C all behave like a
local shell. Exiting the remote shell (`exit` or Ctrl-D) ends the session. A
network/client drop detaches the PTY for a 5-minute in-memory lease; mobile
clients can auto-redial and reattach with their token. Output while detached is
discarded, and the CLI still exits on drop. For long-lived work that survives
long disconnects or host restarts, run `tmux`/`zellij`/`screen` *inside* zuko.

## Pairing: how `share` / `claim` work

The pairing code is a *one-time symmetric secret* (the
[croc](https://github.com/schollz/croc) model): `zuko share` derives a
throwaway Iroh key from it, binds an ephemeral endpoint, and uses it solely to
deliver the real ticket over an E2E-encrypted connection. The host key is
unrelated and stays strong. `share` exits after the first claim; `claim`
retries the dial for ~60 s (`--timeout`, a hard overall wall-clock cap) while
the throwaway endpoint's address propagates through Iroh's DNS lookup.

Full mechanics (entropy, Argon2id derivation, the `zuko/handoff/1` wire) are in
[`PROTOCOL.md#ticket-handoff`](PROTOCOL.md#ticket-handoff). `zuko share` reads
`~/.config/zuko/current_ticket` (which `zuko host` writes and refreshes every
30 s); stale files are rejected so a stopped host doesn't hand out a dead
ticket. Override with `--ticket "<ticket>"` to hand off a ticket captured
elsewhere.

## Build from source

```sh
cargo build --release
./target/release/zuko host --key ~/.config/zuko/key
```

The same `cargo build` also produces `target/release/libzuko.a` — the Rust
staticlib wrapped into the `Zuko.xcframework` the iOS app uses for code
derivation (see [`CLIENTS.md`](CLIENTS.md)). You don't need it for host-only
use; it's just a side-effect of the crate being a library + binary + staticlib.

## Run the host in the foreground

```sh
./scripts/zuko-host.sh
```

Useful for one-off sessions or debugging; prints the node id + pairing
instructions to stderr.

## Options

```sh
zuko host --help
```

| Flag | Default | Notes |
|------|---------|-------|
| `--key` | `~/.config/zuko/key` | Stable secret key. Keep this file; it's your host identity. |
| `--shell` | `$SHELL` | Program launched per connection. |
| `--shell-args` | _(none)_ | Extra args for the shell. |
| `--cwd` | `$HOME` | Working directory. |

## Force-quitting the CLI

The CLI runs the terminal in raw mode so Ctrl-C is forwarded to the remote
shell (it has to be — that's how you interrupt a remote command). The
downside: a truly wedged connection swallows keystrokes, and plain Ctrl-C
can't get you out. The escape hatch is **Ctrl-C 3× within ~1 s, with no
remote output between presses** — that force-exits the client (code 130).
The "no output" gate means interrupting a silent-but-healthy remote command
(e.g. `find /`) doesn't false-trigger; only a session that's stopped
responding altogether does.

## Debugging a connection stall

If a connection hangs on "connecting to host" (relay propagation, NAT
traversal, or the host being unreachable), watch iroh's dial:

```sh
RUST_LOG=iroh=info zuko home     # info shows relay/direct path + handshake
RUST_LOG=iroh=debug zuko home    # debug adds QUIC packet-level detail (noisy)
```

Logs go to stderr. The default (`zuko=info,iroh=warn`, same as `zuko host`)
stays quiet so it doesn't corrupt the raw-mode terminal mid-session — opt in
with `RUST_LOG` only when chasing a stall (verbose lines then land on the raw
terminal by design). The host daemon's own logs are on
`journalctl --user -u zuko-host -f` (Linux) or
`~/.config/zuko/zuko-host.out.log` (macOS).

The iOS app captures iroh at `info` level on-device: during a stall, open the
**⋯ → Logs…** menu (under Font size / Color theme) to watch the dial live and
copy or share the evidence. No Xcode or Console.app needed.

## Multiple devices

Each connection is its own independent PTY + shell. Several phones, terminals
(or the same one multiple times) can connect at once under the host's single
stable identity — and because pairing happens through one-time codes, you can
mint a fresh code per device without rotating anything.

## Rotate the identity

```sh
rm ~/.config/zuko/key
# restart the service; the node id changes and all old tickets stop working.
```

## Wire protocol

The full spec is in [`PROTOCOL.md`](PROTOCOL.md) — ALPN `zuko/1` for sessions,
`zuko/handoff/1` for the ticket handoff. Reference code:
[`../src/wire.rs`](../src/wire.rs) (framing),
[`../src/handoff.rs`](../src/handoff.rs) (handoff),
[`../src/service.rs`](../src/service.rs) (service install/uninstall).

## Testing

```sh
mise run test        # clippy + unit tests
mise run test-e2e    # end-to-end: host<->connect + share<->claim over the real Iroh net
```

The end-to-end harness ([`../tests/e2e.rs`](../tests/e2e.rs)) is a
`#[ignore]`'d Rust integration test (so `cargo test` stays fast and offline).
It spawns `zuko host`, seeds the saved-hosts file under a temp
`XDG_CONFIG_HOME`, drives `zuko connect <name>` under a PTY via `portable-pty`
(the client's raw-mode path needs a controlling terminal), and exercises the
full `share`→`claim` handoff — asserting the claimed ticket matches and that
`share` exits on its own after the claim. All state is isolated; requires
network (Iroh's public relays). Run it with
`cargo test --release --test e2e -- --ignored --nocapture`.

## License

Apache-2.0.
