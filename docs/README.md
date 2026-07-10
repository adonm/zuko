# zuko docs

Private remote shells for machines you own—without inbound ports or a VPN.

zuko's supported core is a Linux/macOS host and Rust CLI. Iroh handles
dial-by-key reachability, relay fallback, NAT traversal, and encrypted
transport; zuko handles a real PTY, one-time-code pairing, client authorization,
and short reconnects.

## Fast path

```sh
curl https://mise.run | sh
mise use --global github:adonm/zuko
zuko install
zuko share        # on host
zuko <code>       # on client
```

Use `tmux`, `zellij`, or `screen` for durable work. zuko deliberately does not
store detached output or promise that PTYs survive a host restart.

Useful commands:

```sh
zuko ls
zuko rm <name>
zuko reset
zuko doctor
zuko upgrade --check
zuko app --doctor
```

## Read next

- [Direction and roadmap](roadmap.md)
- [Host & CLI](host.md)
- [`zuko app` (Labs)](app.md)
- [Wire protocol](protocol.md)
- [Client notes](clients.md)
- [Browser target notes](targets.md#browser-client)
- [Releasing](releasing.md)
- [Security](security.md)

The iOS/iPadOS client is Beta. The Android client,
[browser client](https://zuko.adonm.dev/web/), and `zuko app` are Labs surfaces
with narrower support; see the
[roadmap](roadmap.md) before depending on them.

Source: [github.com/adonm/zuko](https://github.com/adonm/zuko).
