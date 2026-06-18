# zuko

The `zuko` binary: one tool that **serves** a shell over Iroh (`zuko host`) and
**attaches** a terminal to one (`zuko connect`). Built on the same wire protocol
as the [iOS app](../ios/Zuko).

```
zuko host              serve this machine (prints a ticket)
zuko connect <target>  attach a terminal to a host (target = saved name or ticket)
zuko <target>          shorthand for `zuko connect <target>`
zuko add <name> <t>    save a host ticket under a name
zuko ls                list saved hosts
zuko rm <name>         remove a saved host
zuko share             hand this host's ticket to a new device via a short code
zuko claim <code>      fetch the ticket from a `zuko share` code, save it, connect
```

Saved hosts live at `~/.config/zuko/hosts`; the host's persistent identity lives
at `~/.config/zuko/key`. `zuko host` also writes its current, dialable ticket to
`~/.config/zuko/current_ticket` (used by `zuko share`).

## Install (recommended)

Prerequisite: [mise](https://mise.jdx.dev) — install it with `curl https://mise.run | sh`.

```sh
mise use --global github:adonm/zuko
```

mise auto-selects the right asset for your OS/arch and exposes a `zuko` shim on
PATH. To set up the host mode as a persistent background service, run the
installer on the machine you want to reach:

```sh
curl -fsSL https://raw.githubusercontent.com/adonm/zuko/main/zuko/scripts/install.sh | sh
```

This writes `~/.config/zuko/key` (stable node id), installs a `zuko-host-run`
wrapper that runs `zuko host`, and starts a persistent service:

- **Linux:** systemd user unit `~/.config/systemd/user/zuko-host.service`
  - logs: `journalctl --user -u zuko-host -f`
  - ticket: `journalctl --user -u zuko-host --no-pager | grep endpointa | tail -1`
- **macOS:** launchd agent `~/Library/LaunchAgents/dev.adonm.zuko.host.plist`
  - logs: `tail -f ~/.config/zuko/zuko-host.out.log`
  - ticket: `grep endpointa ~/.config/zuko/zuko-host.out.log | tail -1`

Environment overrides for the installer: `ZUKO_VERSION` (default `latest`, e.g.
`v0.1.0`), `ZUKO_KEY` (default `~/.config/zuko/key`), `ZUKO_SHELL`,
`ZUKO_PREFIX` (default `~/.local`).

## Connect from a terminal

```sh
zuko connect "endpointa..."        # one-off: paste the ticket
zuko add home "endpointa..."       # then connect by name forever after:
zuko home                          # shorthand for `zuko connect home`
```

You can also pipe the ticket in: `echo "endpointa..." | zuko`, or
`zuko < ticket.txt`. The session is a real PTY — `vim`, `htop`, resize, and
Ctrl-C all behave like a local shell. Disconnect by exiting the remote shell
(e.g. `exit` or Ctrl-D), which closes the session.

## Hand off a ticket to a new device (croc-style)

Pasting the long `endpointa…` ticket into a brand-new device is the one rough
edge. `zuko share` / `zuko claim` replace it with a short, memorable code:

```sh
# on the host (or any machine with its ticket):
zuko share
#   share this code (serves 1, then exits):
#   wowu-hiva-fiki-rufu
#   on the other machine:
#     zuko claim wowu-hiva-fiki-rufu

# on the new device:
zuko claim wowu-hiva-fiki-rufu   # fetches the real ticket, saves it, connects
```

By default `claim` saves the host (under the host's label, or `--as <name>`) and
drops you straight into the shell — one command and you're in. `--no-connect`
just fetches+saves; `--no-save` prints the ticket to stdout instead.

**How it stays safe.** The code is a *one-time symmetric secret* for the handoff
(the [croc](https://github.com/schollz/croc) model), never the host's identity.
`zuko share` derives a throwaway Iroh key from the code, binds a *second*,
ephemeral endpoint with it, and uses it solely to deliver the real ticket over
an end-to-end encrypted connection. The real host key is unrelated and stays
strong. The code has ~52 bits of entropy (a one-time, minutes-long window — far
beyond reach for online guessing), and `share` exits after the first claim.

The throwaway endpoint is reached by node id through Iroh's N0 DNS lookup, so
`claim` retries the dial for a few seconds (`--timeout`, default 60) while that
address propagates. The handoff runs on its own ALPN (`zuko/handoff/1`).

`zuko share` reads `~/.config/zuko/current_ticket` (which `zuko host` writes);
override with `--ticket "<ticket>"` to hand off a ticket captured elsewhere.

## Build from source

```sh
cargo build --release --manifest-path zuko/Cargo.toml
./zuko/target/release/zuko host --key ~/.config/zuko/key
```

## Run the host in the foreground

```sh
./zuko/scripts/zuko-host.sh
```

Useful for one-off sessions or debugging; prints the ticket to stdout.

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

## Multiple devices

Each connection gets its own independent PTY + shell, so several phones,
terminals (or the same one multiple times) can connect at once. They all share
the host's single stable identity.

## Rotate the identity

```sh
rm ~/.config/zuko/key
# restart the service; the node id changes and all old tickets stop working.
```

## Wire protocol

See the root [`README.md`](../README.md#wire-protocol). ALPN is `zuko/1`. The
framing code is shared by host and client in [`src/wire.rs`](src/wire.rs). The
ticket handoff uses a separate ALPN `zuko/handoff/1` — see [`src/share.rs`](src/share.rs).

## Testing

```sh
mise run test        # clippy + unit tests
mise run test-e2e    # end-to-end: host<->connect + share<->claim over the real Iroh net
```

The end-to-end harness ([`scripts/e2e_test.py`](scripts/e2e_test.py)) spawns
`zuko host`, drives `zuko connect` under a PTY (the client's raw-mode path needs
a controlling terminal), and exercises the full `share`→`claim` handoff,
asserting the claimed ticket matches. All state is isolated under a temp
`XDG_CONFIG_HOME`. Requires network (Iroh's public relays) and `python3`.

## License

Apache-2.0.
