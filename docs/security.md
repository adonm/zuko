# Security

## Model

- Host identity: `~/.config/zuko/key`.
- Host ticket: `endpointa…`, a bearer secret containing host public key + current
  addresses.
- Client allow-list: `~/.config/zuko/authorized_clients`.
- Saved client tickets: `~/.config/zuko/hosts` or iOS Keychain.

Connections are Iroh QUIC and end-to-end encrypted. Public relays see encrypted
traffic.

## Rules

- Treat host tickets like SSH private keys.
- Tickets are handed out through `zuko share`/`claim` only.
- `zuko host` never prints the raw ticket.
- `zuko share` rejects stale `current_ticket`.
- `zuko host` admits only tokens in `authorized_clients`.

Manage trust:

```sh
zuko ls
zuko rm <name>
zuko reset          # remove key/current_ticket, clear authorised clients
zuko reset --yes
```

After `reset`, restart host and re-pair clients.

## Report vulnerabilities

Use GitHub Security Advisories:
[adonm/zuko/security/advisories/new](https://github.com/adonm/zuko/security/advisories/new).

Use private advisories for vulnerabilities.

Scope: `src/`, wire protocol, handoff, service installer, iOS app.
