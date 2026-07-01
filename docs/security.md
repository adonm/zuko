# Security policy

## Threat model, in one paragraph

zuko is remote terminals over [Iroh](https://www.iroh.computer/) — QUIC,
dial-by-key, end-to-end encrypted, NAT traversal via public relays. The host's
ticket (an Iroh `EndpointTicket` starting with `endpointa`) is the only
long-lived secret: it encodes the host's ed25519 public key + its current
addresses. Anyone holding the ticket can open a shell on the host — **treat it
like an SSH private key.** Connections are E2E-encrypted by Iroh; the public
relays see only encrypted traffic. The persistent secret key at
`~/.config/zuko/key` never leaves the host.

## Ticket handling

- Clients learn the ticket **only** through the
  [handoff](protocol.md#ticket-handoff) flow (`zuko share` →
  `zuko claim`): a one-time, minutes-long code derived into a throwaway Iroh
  key over an E2E-encrypted stream. `share`/`claim` never weaken the host key.
- The ticket never crosses the CLI argument surface (there is no
  `zuko add <ticket>`) and is never printed by `zuko host`.
- `zuko share` rejects stale ticket files, so pairing fails closed if the host
  service is gone.
- Saved tickets live at `~/.config/zuko/hosts` (CLI) / Keychain (iOS) and are
  bearer tokens — protect them accordingly.

## Rotate the host identity

```sh
rm ~/.config/zuko/key
# restart the service; the node id changes and all old tickets stop working.
```

Existing saved clients must re-pair (`zuko share` on the host, `zuko <code>`
on each client). There is no in-place rotation flow yet.

## Reporting a vulnerability

**Please do not open a public GitHub issue for security vulnerabilities.**

Report privately via GitHub's advisory feature:
**Security → Advisories → New advisory** on
[adonm/zuko](https://github.com/adonm/zuko/security/advisories/new), or email
the maintainer if you have a direct address. Include a reproduction and your
assessment of impact. You'll get an acknowledgement within 72 hours and a
coordinated disclosure timeline once a fix is ready.

## Scope

In scope: the `zuko` crate (`src/`), the wire protocol, the host/claim
handoff, the service installer, and the iOS app (`ios/`). Out of scope:
upstream Iroh/QUIC/crypto bugs (report to
[iroh](https://github.com/n0-computer/iroh)), and bugs in bundled
third-party terminals (GhosttyTerminal, etc.).

More detail on protocol-level guarantees: [protocol §security](protocol.md#security).
