# Host & CLI

`zuko` is one binary: host daemon, CLI client, pairing helper, service installer,
upgrader, and Linux `zuko app` launcher.

## Commands

```sh
zuko host              # foreground host
zuko install           # install/start user service
zuko uninstall         # remove service; keep user state
zuko upgrade           # mise-managed binary upgrade

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
| `~/.config/zuko/key` | host identity |
| `~/.config/zuko/current_ticket` | live dial ticket, refreshed by host |
| `~/.config/zuko/authorized_clients` | host allow-list |
| `~/.config/zuko/hosts` | client-side saved hosts |
| `~/.config/zuko/client_key` | CLI client token seed |

All secret state is user-local and written `0600` where Unix permissions apply.

## Install service

```sh
curl https://mise.run | sh
mise use --global github:adonm/zuko
zuko install
```

Linux:

```sh
journalctl --user -u zuko-host -f
sudo loginctl enable-linger "$USER"   # servers that must run without login
```

macOS:

```sh
tail -f ~/.config/zuko/zuko-host.out.log
```

Install flags:

| Flag | Default |
|------|---------|
| `--prefix` | `~/.local` |
| `--key` | `~/.config/zuko/key` |
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
- CLI reconnects while the process is alive; iOS redials while screen is active.
- Use `tmux`, `zellij`, or `screen` for durable work.

Force-exit a stuck CLI: Ctrl-C three times within ~1s with no remote output.

## Pairing internals

`share` derives a throwaway Iroh key from the code, serves
`<label>\n<ticket>` over ALPN `zuko/handoff/1`, then receives the client's
`AUTHORIZE` frame. `claim` retries the handoff dial for `--timeout` seconds
(default 60). `share` reads `current_ticket`; stale/missing files fail.

`zuko share` flags:

| Flag | Default | Notes |
|------|---------|-------|
| `--ticket` | `current_ticket` | override ticket source |
| `--label` | hostname | default save name on client |
| `--count` | `1` | accepted claims before exit |
| `--timeout` | `300` | seconds; `0` waits forever |

## Upgrade

```sh
zuko upgrade --check
zuko upgrade
zuko upgrade --version 0.8.0
zuko upgrade --no-restart
```

Only works for mise-managed installs. Restarting the service kills in-memory PTYs.

## Debug

```sh
RUST_LOG=iroh=info zuko home
RUST_LOG=iroh=debug zuko home
```

Host logs are stderr in foreground, systemd journal on Linux, and
`~/.config/zuko/zuko-host.out.log` on macOS.

## Build/test

```sh
cargo build --release
cargo test
cargo test --release --test e2e -- --ignored --nocapture
```

The ignored e2e test uses a real PTY and the live Iroh network.
