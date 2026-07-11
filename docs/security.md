# Security

## Model

- Host identity: `${XDG_CONFIG_HOME:-$HOME/.config}/zuko/key`.
- Host ticket: `endpointa…`, sensitive dial information containing the host
  public key and current addresses.
- Client allow-list: `${XDG_CONFIG_HOME:-$HOME/.config}/zuko/authorized_clients`.
- Client identity: a private local key used to derive a host-scoped token.
- Saved connection state: `${XDG_CONFIG_HOME:-$HOME/.config}/zuko/hosts`, iOS Keychain, or the Flutter
  target's protected storage.

Connections are Iroh QUIC and end-to-end encrypted. Public relays see encrypted
payloads but can observe connection metadata and traffic volume.

Current shell access requires both:

1. enough ticket information to dial the host; and
2. a client token present in the host's allow-list.

The ticket alone does not authorize a shell. Keep it private anyway: it exposes
reachability metadata, and storing all connection material defensively limits
the effect of future protocol changes.

## Trust boundaries

- `zuko share` is the enrollment boundary. Anyone who obtains its short code
  while it is active can receive connection information and register a token.
- The pairing code is memorable rather than high-entropy. Argon2id slows
  guessing, and the short timeout/count bound exposure; do not use
  `--timeout 0` unattended.
- The host's config directory controls identity and authorization. Local access
  to those files is outside zuko's remote threat boundary.
- Losing a paired client exposes that client's access until it is removed from
  the host allow-list.
- Browser state is available to scripts on the same origin. The Labs web client
  should not be treated as a hardened client until it has a dedicated origin.

## Rules

- Protect saved connection state and client identity together.
- Host tickets are handed out through `zuko share`/`claim` only.
- `zuko host` never prints the raw ticket.
- `zuko share` rejects stale `current_ticket`.
- `zuko host` admits only tokens in `authorized_clients`.
- Remove a lost client with `zuko rm <name>`; use `zuko reset` if trust cannot be
  narrowed safely.

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

Scope: `src/`, the shared Flutter client and platform runners, wire protocol,
handoff, service installer, and release packaging.
