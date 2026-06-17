# zuko host

The host-side daemon. Binds an Iroh endpoint with a **persistent secret key**,
prints a copy-pasteable ticket, and for each incoming connection spawns your
shell on a PTY and bridges it over a single bidirectional Iroh stream.

## Install (recommended)

```sh
curl -fsSL https://raw.githubusercontent.com/adonm/zuko/main/host/scripts/install.sh | sh
```

This builds `zuko-host`, writes `~/.config/zuko/key` (stable node id), installs
a `zuko-host-run` wrapper, and starts a persistent service:

- **Linux:** systemd user unit `~/.config/systemd/user/zuko-host.service`
  - logs: `journalctl --user -u zuko-host -f`
  - ticket: `journalctl --user -u zuko-host --no-pager | grep endpointa | tail -1`
- **macOS:** launchd agent `~/Library/LaunchAgents/dev.adonm.zuko.host.plist`
  - logs: `tail -f ~/.config/zuko/zuko-host.out.log`
  - ticket: `grep endpointa ~/.config/zuko/zuko-host.out.log | tail -1`

Environment overrides for the installer: `ZUKO_REPO`, `ZUKO_BRANCH`,
`ZUKO_PREFIX` (default `~/.local`), `ZUKO_KEY` (default `~/.config/zuko/key`),
`ZUKO_SHELL`.

## Build manually

```sh
cargo build --release
./target/release/zuko-host --key ~/.config/zuko/key
```

## Run in the foreground

```sh
./scripts/zuko-host.sh
```

Useful for one-off sessions or debugging; prints the ticket to stdout.

## Options

```sh
zuko-host --help
```

| Flag | Default | Notes |
|------|---------|-------|
| `--key` | `~/.config/zuko/key` | Stable secret key. Keep this file; it's your host identity. |
| `--shell` | `$SHELL` | Program launched per connection. |
| `--shell-args` | _(none)_ | Extra args for the shell. |
| `--cwd` | `$HOME` | Working directory. |

## Multiple devices

Each connection gets its own independent PTY + shell, so several phones (or the
same phone multiple times) can connect at once. They all share the host's single
stable identity.

## Rotate the identity

```sh
rm ~/.config/zuko/key
# restart the service; the node id changes and all old tickets stop working.
```

## Wire protocol

See the root [`README.md`](../README.md#wire-protocol). ALPN is `zuko/1`.

## License

Apache-2.0.
