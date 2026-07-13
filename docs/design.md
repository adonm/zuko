# Design principles

The product direction lives in the [roadmap](roadmap.md). These principles turn
it into engineering constraints.

The shared graphical client's interaction, accessibility, responsive-layout,
and contributor-testing goals live in the
[Flutter human-centered design guide](flutter-design.md).

## Product boundary

zuko is a terminal-first, per-user remote shell for machines the user owns. The
Core product is the Linux/macOS host and Rust CLI. Mobile, browser, and GUI app
streaming must not make that path harder to install, secure, debug, or maintain.

zuko does not own network reachability, durable terminal sessions, or fleet
identity. Iroh provides reachability and encrypted transport; terminal
multiplexers provide durable work.

## Priorities

When a design trades one property for another, prefer this order:

1. explicit authorization and safe local secret storage;
2. correct PTY behavior and bounded failure modes;
3. actionable operator feedback and recovery;
4. protocol simplicity and compatibility;
5. optional client or streaming features.

## Constraints

- The base experience is a real PTY over Iroh.
- A stock terminal and one binary must remain a useful client.
- Pairing is explicit, short-lived, and separate from ordinary connections.
- Host state remains inspectable under `${XDG_CONFIG_HOME:-$HOME/.config}/zuko`.
- Handshakes, queues, retries, and detached leases are bounded.
- A brief disconnect may reattach; detached output is not replayed.
- Long-running work belongs in `tmux`, `zellij`, or `screen`.
- New background services and trust surfaces require a concrete Core use case.

## Protocol shape

Session ALPN: `zuko/2`.

- data stream: `ATTACH`, `DATA`, `ATTACHED`, `ERROR`;
- control frames: `RESIZE`, `PING`, `PONG` on an optional control stream, with
  data-stream fallback;
- handoff ALPN: `zuko/handoff/1`;
- authorization: `AUTHORIZE` during handoff, enforced on `ATTACH`.

Prefer additive frame types over negotiation layers until a concrete client
needs more. Unknown frame types are ignored; a new incompatible handshake gets
a new ALPN.

## Labs: `zuko app`

The current GUI path runs cage/wlroots on the host, sends Kitty graphics over
the existing PTY, and maps terminal input back into cage. Reusing the shell path
avoids a second listener, client, and pairing surface.

This remains an experiment, not the start of a remote-desktop stack. A native
video protocol should be considered only after a demonstrated use case and an
explicit maintenance/security plan.
