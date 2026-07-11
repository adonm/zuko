<p align="center">
  <img src="zuko-logo.svg" width="128" height="128" alt="Zuko logo">
</p>

<h1 align="center">Zuko</h1>

<p align="center">
  Private remote shells for machines you own—without inbound ports or a VPN.
</p>

zuko's supported core is a Linux/macOS host and Rust CLI. Iroh handles
dial-by-key reachability, relay fallback, NAT traversal, and encrypted
transport; zuko handles a real PTY, one-time-code pairing, client authorization,
and short reconnects.

## Start here

- [Install and connect](getting-started.md) on Linux or macOS.
- [Run the Linux host under WSL2](windows-wsl2.md) on Windows, with the
  documented lifecycle limits.
- [Download a client](clients.md) or [build one from a fresh clone](building-clients.md).

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

- [Host operations](host.md)
- [`zuko app` (Labs)](app.md)
- [Wire protocol for client authors](protocol.md)
- [Direction and roadmap](roadmap.md)
- [Releasing](releasing.md)
- [Security](security.md)

The shared Flutter client is the sole graphical client implementation.
The shared Flutter client for Android, iOS, macOS,
[web](https://zuko.adonm.dev/web/), Linux, and Windows is Labs, as is
`zuko app`. See the [roadmap](roadmap.md) before depending on them.

Source: [github.com/adonm/zuko](https://github.com/adonm/zuko).
