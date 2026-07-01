# zuko — host + CLI client + service installer

The `zuko` binary is the **host daemon** (the machine you shell into), the
**reference CLI client**, and the **service installer** — in a single binary.
zuko is remote terminals over Iroh; the [wire protocol](protocol.md)
and the other clients (iOS, future Android/relm4) are documented in
[`./`](.) (this `docs/` folder).

```
zuko host              serve this machine (writes a key + current_ticket)
zuko install           install the host as a systemd/launchd user service
zuko uninstall         stop + remove the service (keeps the key + saved hosts)
zuko upgrade           pull the latest zuko via mise + bounce the host service
zuko share             mint a one-time code that lets a new device pair
zuko <code>            pair: fetch the host's ticket, save it, connect
zuko claim <code>      the same, with flags (--as, --no-connect, --timeout)
zuko connect <name>    attach a terminal to a saved host
zuko <name>            shorthand for `zuko connect <name>`
zuko app <command>     run one Wayland GUI app through Kitty graphics (Linux)
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

## Bare `zuko`

With no arguments, `zuko` adapts to state and context:

- **No saved hosts** → a first-run hint (the `zuko share` / `zuko install`
  paths).
- **Saved hosts, TTY** → an interactive type-to-filter picker. It always
  prompts (even for one host) so bare `zuko` never surprises you by dropping
  into raw terminal mode.
- **Saved hosts, non-TTY** (piped/scripted) → lists names and exits, so a
  script never blocks on a picker. Tickets are never echoed (long-lived
  secret).
- A successful connect **promotes** that host to the front of the saved list,
  so the hosts you actually use surface first next time.

The fast path is still `zuko <name>`; bare `zuko` is the "ask first" variant.

## Pairing: how `share` / `claim` work

The pairing code is a *one-time symmetric secret* (the
[croc](https://github.com/schollz/croc) model): `zuko share` derives a
throwaway Iroh key from it, binds an ephemeral endpoint, and uses it solely to
deliver the real ticket over an E2E-encrypted connection. The host key is
unrelated and stays strong. `share` exits after the first claim; `claim`
retries the dial for ~60 s (`--timeout`, a hard overall wall-clock cap) while
the throwaway endpoint's address propagates through Iroh's DNS lookup.

Full mechanics (entropy, Argon2id derivation, the `zuko/handoff/1` wire) are in
[`protocol.md#ticket-handoff`](protocol.md#ticket-handoff). `zuko share` reads
`~/.config/zuko/current_ticket` (which `zuko host` writes and refreshes every
30 s); stale files are rejected so a stopped host doesn't hand out a dead
ticket.

`zuko share` flags:

| Flag | Default | Notes |
|------|---------|-------|
| `--ticket` | _(reads `current_ticket`)_ | Hand off a ticket captured elsewhere, without the daemon running. |
| `--label` | system hostname | Save name shown to the claimer (their default `--as`). |
| `--count` | `1` | Number of claims to serve before exiting. |
| `--timeout` | `300` | Overall wall-clock seconds. `0` = no timeout. |

## Build from source

```sh
cargo build --release
./target/release/zuko host --key ~/.config/zuko/key
```

The same `cargo build` also produces `target/release/libzuko.a` — the Rust
staticlib wrapped into the `Zuko.xcframework` the iOS app uses for code
derivation (see [`clients.md`](clients.md)). You don't need it for host-only
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

## Upgrading

```sh
zuko upgrade              # mise pulls latest + restarts the host service
zuko upgrade --check      # preview: current version, mise command, service action
zuko upgrade --version 0.7.0   # pin to a specific release
zuko upgrade --no-restart       # upgrade the binary; restart the service later
```

`zuko upgrade` drives `mise upgrade github:adonm/zuko` (mise-managed installs
only — it refuses to run against a cargo/distro install so it never clobbers
your chosen install method). The `zuko install` wrapper routes through mise's
`latest` symlink, so repointing lands on the new build without a re-`install`;
only the already-running process lags. A restart execs the wrapper again.

Restarting the host kills its in-memory PTYs — there is no live handoff yet.
Clients auto-reconnect (the iOS app redials; the CLI is restarted by the
user), but land in **fresh** shells, not the ones they had. For work that
must survive a host upgrade, run `tmux`/`zellij`/`screen` inside the session.

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

The full spec is in [`protocol.md`](protocol.md) — ALPN `zuko/2` with `zuko/1`
fallback for sessions, `zuko/handoff/1` for the ticket handoff. Architecture
rationale is in [`design.md`](design.md). `zuko app` (Linux GUI-app streaming)
is documented in [`app.md`](app.md). Reference code:
[`../src/wire.rs`](https://github.com/adonm/zuko/blob/main/src/wire.rs) (framing),
[`../src/handoff.rs`](https://github.com/adonm/zuko/blob/main/src/handoff.rs) (handoff),
[`../src/service.rs`](https://github.com/adonm/zuko/blob/main/src/service.rs) (service install/uninstall/upgrade).

## Testing

```sh
mise run test        # clippy + unit tests
mise run test-e2e    # end-to-end: host<->connect + share<->claim over the real Iroh net
```

The end-to-end harness ([`../tests/e2e.rs`](https://github.com/adonm/zuko/blob/main/tests/e2e.rs)) is a
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
