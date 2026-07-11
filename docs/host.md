# Host operations

`zuko` is one binary: host daemon, CLI client, pairing helper, service installer,
upgrader, and Linux `zuko app` launcher.

For binary installation, first service setup, and pairing, start with
[Install and connect](getting-started.md).

## Commands

```sh
zuko host              # foreground host
zuko install           # install/start user service
zuko uninstall         # remove service; keep user state
zuko upgrade           # mise-managed binary upgrade
zuko doctor            # service, ticket, state, network diagnostics

zuko share             # authorise a client with a one-time code
zuko <code>            # claim, save, connect
zuko claim <code>      # flags: --as, --no-connect, --timeout

zuko <name>            # connect to saved host
zuko connect <name>
zuko                   # TTY picker / non-TTY list
zuko ls                # saved hosts + authorised clients
zuko rm <name>         # remove saved host and/or authorised client
zuko reset             # rotate host key; clear authorised clients

zuko app <command>     # Linux GUI app over Kitty graphics
```

## State

| Path | Role |
|------|------|
| `$ZUKO_CONFIG/key` | host identity |
| `$ZUKO_CONFIG/current_ticket` | live dial ticket, refreshed by host |
| `$ZUKO_CONFIG/authorized_clients` | host allow-list |
| `$ZUKO_CONFIG/hosts` | client-side saved hosts |
| `$ZUKO_CONFIG/client_key` | CLI client token seed |

Here `$ZUKO_CONFIG` means `${XDG_CONFIG_HOME:-$HOME/.config}/zuko`. All secret
state is user-local and written `0600` where Unix permissions apply.

## Service control

`zuko install` writes `~/.local/bin/zuko-host-run`, installs the platform user
service, and enables and starts it. Rerunning it updates that configuration.

Linux:

```sh
systemctl --user status zuko-host
systemctl --user restart zuko-host
journalctl --user -u zuko-host -f
sudo loginctl enable-linger "$USER"   # servers that must run without login
```

macOS:

```sh
tail -f "${XDG_CONFIG_HOME:-$HOME/.config}/zuko/zuko-host.err.log"
```

Install flags:

| Flag | Default |
|------|---------|
| `--prefix` | `~/.local` |
| `--key` | `$ZUKO_CONFIG/key` |
| `--shell` | `$SHELL` |
| `--no-start` | disabled |

Foreground host:

```sh
zuko host --shell /bin/bash --cwd "$HOME"
```

## Pair and connect

```sh
# host
zuko share

# client
zuko <code>
```

`claim` saves the ticket under the host label unless `--as <name>` is set.
On an interactive terminal, `share` also renders a QR containing only the
one-time code for the iOS scanner. The long-lived ticket is never in the QR,
and stdout remains the plain code so scripts can continue to pipe it.
After pairing:

```sh
zuko ls
zuko <name>
```

The host admits only tokens in `authorized_clients`. Pairing writes that list.

## Trust management

```sh
zuko ls
zuko rm ipad
zuko reset
zuko reset --yes
```

`reset` removes `key`, removes `current_ticket`, and writes an empty
`authorized_clients`. Restart the host, then re-pair each client.

## Session behavior

- Host runs a real PTY with `TERM=xterm-256color`.
- Shell exit ends the session and kills the PTY.
- Network/client drop detaches the PTY for 5 minutes.
- Detached output is discarded.
- CLI reconnects while the process is alive; Flutter redials while its screen
  is active; Flutter clients use bounded reconnect while their session is open.
- Use `tmux`, `zellij`, or `screen` for durable work.

Force-exit a stuck CLI: Ctrl-C three times within ~1s with no remote output.

## Pairing internals

`share` derives a throwaway Iroh key from the code, serves
`<label>\n<ticket>` over ALPN `zuko/handoff/1`, then receives the client's
`AUTHORIZE` frame. `claim` retries the handoff dial for `--timeout` seconds
(default 60). `share` reads `current_ticket`; interactively it offers to start
the service when that file is unavailable, while non-interactive use fails.

`zuko share` flags:

| Flag | Default | Notes |
|------|---------|-------|
| `--ticket` | `current_ticket` | advanced override; argv may expose the ticket, so prefer the file |
| `--label` | hostname | default save name on client |
| `--count` | `1` | accepted claims before exit |
| `--timeout` | `300` | seconds; `0` waits forever |

## Upgrade

Mise-managed install:

```sh
zuko upgrade --check
zuko upgrade
zuko upgrade --version 0.9.11
zuko upgrade --no-restart
```

The curl installer creates this mise-managed installation, so the same upgrade
commands apply. Restarting the service kills in-memory PTYs.

## Debug

```sh
RUST_LOG=iroh=info zuko home
RUST_LOG=iroh=debug zuko home
```

Host logs are stderr in foreground, systemd journal on Linux, and
`$ZUKO_CONFIG/zuko-host.err.log` on macOS.

## Troubleshooting

Start with the read-only diagnostic report:

```sh
zuko doctor
```

It checks whether the platform user service is installed and active, validates
the host key and fresh ticket without printing either, summarizes saved hosts
and authorized clients, and performs a 10-second Iroh relay-registration probe.
Warnings include the next command to run; a client-only installation may
legitimately warn that no local host is installed. Pass `--key <path>` if the
host service was installed with a non-default key path.

### `zuko share` reports a missing or stale ticket

The host service must be running and refreshing `current_ticket`. Check its log,
then restart it with the platform service manager or run `zuko host` in the
foreground. Do not copy a raw ticket around as a workaround.

### The host rejects authorization

The client's token is no longer in `authorized_clients`, usually after
`zuko rm` or `zuko reset`. Run `zuko share` on the host and claim the new code
from that client. Repeated dialing cannot repair an authorization failure.

### A reconnect opens a fresh shell

The detached lease lasts 5 minutes and exists only in the host process. Expired
leases, host restarts, and upgrades create a fresh PTY. Use a terminal
multiplexer for durable work.

### A connected full-screen app looks stale

Resize the local terminal to trigger a repaint. On iOS, use the Refresh action.
If the link is wedged, use the CLI force-exit sequence and reconnect.

## Build/test

```sh
mise bootstrap
just test
just test-e2e
```

The e2e test uses a real PTY and the live Iroh network. See
[Contributing](contributing.md) for the full check graph.
