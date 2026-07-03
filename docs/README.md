# zuko docs

Remote PTYs over Iroh. Operator/developer reference.

zuko is for hosts you own and prefer to keep off public network surfaces and
VPN/bastion plumbing. Iroh handles dial-by-key reachability, relay fallback, NAT
traversal, and transport encryption. zuko stays narrow: a host PTY, explicit
pairing, an authorised-client list, and a small framed protocol.

## Fast path

```sh
curl https://mise.run | sh
mise use --global github:adonm/zuko
zuko install
zuko share        # on host
zuko <code>       # on client
```

Useful commands:

```sh
zuko ls
zuko rm <name>
zuko reset
zuko upgrade --check
zuko app --doctor
```

## Read next

- [Host & CLI](host.md)
- [`zuko app`](app.md)
- [Wire protocol](protocol.md)
- [Client notes](clients.md)
- [Releasing](releasing.md)
- [Security](security.md)

Source: [github.com/adonm/zuko](https://github.com/adonm/zuko).
