# Design notes

This is a terminal-first project.

## Constraints

- Base experience is a PTY over Iroh.
- Stock terminals must remain useful clients.
- Host state should be explicit files under `~/.config/zuko`.
- Failure modes should be bounded: handshakes, queues, detached leases.
- Long-running user work belongs in `tmux`, `zellij`, or `screen`; zuko's
  in-memory lease handles short disconnects.

## `zuko app`

Current GUI path: cage/wlroots on host, Kitty graphics over the existing zuko
PTY, terminal input back into cage.

Keep it as the baseline because it needs no second listener, no separate client,
and no additional pairing surface. It works anywhere the terminal can render
Kitty graphics.

A native GUI/video stream can be added later as an opt-in fast path alongside
the PTY/Kitty path.

## Protocol shape

Session ALPN: `zuko/2`.

- data stream: `ATTACH`, `DATA`, `ATTACHED`;
- optional control stream: `RESIZE`, `PING`, `PONG`;
- handoff ALPN: `zuko/handoff/1`;
- host authorisation: `AUTHORIZE` during handoff, enforced on `ATTACH`.

Prefer additive frame types over negotiation layers until there is a concrete
client that needs more.
