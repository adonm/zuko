# zuko wire protocol

zuko connects a **client** to a remote shell on a **host** over a single
Iroh bidirectional stream. This document is the spec for client authors — the
CLI (`src/`) and the iOS app (`ios/Zuko/`) are reference implementations.

zuko is **not** an RPC or a terminal emulator protocol. It is deliberately
tiny: one stream, two frame types that matter, raw bytes. The host runs a real
PTY; the client renders it. Everything that works in a local terminal (`vim`,
`htop`, resize, signals) works because the bytes are passed through verbatim.

## Transport

- **Backend:** [Iroh](https://www.iroh.computer/) — QUIC, dial-by-key,
  end-to-end encrypted, NAT traversal via public relays. No open ports.
- **ALPN:** `zuko/1`.
- **Stream:** the client opens exactly **one bidirectional stream**
  (`open_bi`) after connecting. The session runs on that stream until either
  side closes it.

The host accepts any connection advertising ALPN `zuko/1` and calls
`accept_bi` to get the session stream.

## Framing

Every message on the stream is length-prefixed, so the frame types share an
ordering and resize never interleaves with data on the wire:

```
[type: u8][len: u16 big-endian][payload: len bytes]
```

`len` is the payload length only (max 65535). Frames may be coalesced or split
across QUIC packets; receivers must accumulate bytes and parse greedily (see
[`try_parse_frame` in `wire.rs`](../src/wire.rs)).

## Frame types

| type | name | direction | payload |
|------|------|-----------|---------|
| `0x00` | `DATA` | both | raw terminal bytes |
| `0x01` | `RESIZE` | client → host | `[cols: u16 BE][rows: u16 BE]` |
| `0x04` | `PING` | both | `[nonce: u64 BE]` (legacy, ignored by v0.6+) |
| `0x05` | `PONG` | both | `[nonce: u64 BE]` (legacy, ignored by v0.6+) |

- **`DATA`** — client→host carries keystrokes; host→client carries PTY output.
  Bytes are forwarded verbatim. There is no encoding, escaping, or
  interpretation — a Ctrl-C is the byte `0x03`, a resize keystroke is whatever
  the terminal emulator sends.
- **`RESIZE`** — tells the host to resize the PTY. May be sent any time the
  client's window changes. **The first frame** the client sends after
  `open_bi` must be a `RESIZE` carrying the initial size — that doubles as the
  entire handshake (see [Connection lifecycle](#connection-lifecycle)).
- **`PING`/`PONG`** — legacy heartbeat from v0.4–v0.5, kept reserved so old
  peers don't confuse a v0.6 host. v0.6 clients and hosts ignore them (iroh's
  QUIC keepalive handles transport-level liveness).
- **Unknown types** — must be ignored (forward compatibility — future types
  can be added without breaking old clients). Frame types `0x02` (`HELLO`)
  and `0x03` (`WELCOME`) were used by v0.4–v0.5 for the session-resume
  handshake; v0.6 dropped both, leaving the gap reserved.

## Connection lifecycle

1. **Client dials** the host's ticket (see [Ticket](#ticket)) on ALPN `zuko/1`.
2. **Client opens** the bidi stream and sends a single `RESIZE` with its
   current terminal size. That's the entire handshake. (The opener must write
   first for the host's `accept_bi` to resolve.)
3. **Host spawns** a fresh shell (`$SHELL`) on a PTY at the requested size,
   with `TERM=xterm-256color`, in the directory chosen by `zuko host --cwd`
   (default `$HOME`).
4. **Pump:** client keystrokes → `DATA` → host writes to PTY; PTY output →
   `DATA` → client renders. The client sends `RESIZE` whenever its window
   changes (e.g. on `SIGWINCH`).
5. **End:** the connection runs until either the shell exits (host sees PTY
   EOF → closes the stream → client sees recv EOF) or the network drops
   (either side sees a stream error). Either way **the host kills the PTY** —
   there's no session persistence, no auto-reconnect, nothing to resume.

For long-lived work that survives a disconnect, run `tmux`/`zellij`/`screen`
*inside* the zuko session. That's the proper layer for resumability.

## Ticket

The host's **ticket** is an [Iroh `EndpointTicket`](https://docs.rs/iroh/)
string starting with `endpointa`. It encodes:

- the host's **node id** — the ed25519 public key derived from the host's
  persistent secret key (`~/.config/zuko/key`), and
- its **current addresses** — relay URL(s) and any direct addresses.

Because the secret key is persistent, the node id is stable across restarts and
IP changes; Iroh's discovery resolves the current address on dial, so a saved
ticket keeps working. The host writes the ticket to
`~/.config/zuko/current_ticket` for `zuko share` to read; clients receive it
exclusively through the [handoff](#ticket-handoff) flow.

## Ticket handoff

The **handoff** lets a client fetch a host's ticket using a short, memorable
code (the [croc](https://github.com/schollz/croc) model). `zuko share` and
`zuko claim` implement it.

- The host operator runs `zuko share`, which derives a **throwaway** Iroh
  `SecretKey` from the code via memory-hard Argon2id
  (`Argon2id(normalized_code, salt="zuko-share-handoff-v1") → 32-byte seed`),
  binds a *second*, ephemeral endpoint with that key, and serves the real
  ticket on a separate ALPN.
- **Handoff ALPN:** `zuko/handoff/1`.
- The code is a **one-time symmetric secret** for the handoff only — ~28 bits
  (e.g. `iridescent-hilton`), plenty for the minutes-long window before
  `share` exits after the first claim. The real host key is not derivable from
  it.
- **Wire:** the host opens a unidirectional stream (`open_uni`) and writes a
  UTF-8 payload, then closes the send side:
  ```
  <label>\n<ticket>
  ```
  `<label>` has no newlines (sanitised); tickets never contain whitespace, so
  splitting on the first `\n` is unambiguous.

The throwaway endpoint is reached by node id through Iroh's N0 DNS address
lookup, which can lag a couple of seconds behind `share` coming online, so a
claimer retries the dial for a short window.

## Implementing a client

A minimal client, in any language with Iroh bindings (Rust `iroh`, Swift
`IrohLib`, …):

1. Get the host's ticket by implementing the [handoff](#ticket-handoff):
   accept a short code from the user, derive the throwaway key, dial it, and
   read the real ticket off the uni stream.
2. Parse the ticket → `EndpointAddr`.
3. `Endpoint::builder(presets::N0).bind()`; `connect(addr, b"zuko/1")`.
4. `open_bi()` → `(send, recv)`. Send an initial `RESIZE`.
5. Put the local terminal into raw mode. Pump:
   - keystrokes → `DATA` frames on `send`;
   - `DATA` frames from `recv` → render to the terminal;
   - window-size changes → `RESIZE` frames.
6. End when `recv` closes or the connection drops; restore the terminal.

Reference code:

- **Rust:** [`src/wire.rs`](../src/wire.rs) (framing),
  [`src/client.rs`](../src/client.rs) (the connect loop),
  [`src/handoff.rs`](../src/handoff.rs) (the claim side of pairing).
- **Swift:** [`ios/Zuko/Zuko/Net/Wire.swift`](../ios/Zuko/Zuko/Net/Wire.swift),
  [`ios/Zuko/Zuko/Net/IrohSession.swift`](../ios/Zuko/Zuko/Net/IrohSession.swift).

If your client needs a terminal emulator, [GhosttyTerminal](https://github.com/Lakr233/libghostty-spm)
is used on iOS (host-managed I/O backend — no PTY spawn); on Linux,
[alacritty_terminal](https://crates.io/crates/alacritty_terminal) or
[vte](https://crates.io/crates/vte) are good choices. The host sends bytes
compatible with `TERM=xterm-256color`.

## Design notes

A few architectural choices worth recording, since they shape what client
authors can rely on:

### No head-of-line blocking between input and output

QUIC streams have independent send/recv halves, and each endpoint's congestion
controller governs only its *outgoing* direction — so a saturated host→client
download (a `cat hugefile`) does **not** consume the client→host keystroke
budget. The host runs its input and output pumps as separate tasks on a
multi-threaded runtime, and the iOS app runs its write pump on a background
task, so output rendering never starves keystroke delivery.

### Backpressure is end-to-end and bounded

Every hop between the shell and the network has a bounded buffer, so a flood
can't grow memory without limit — it back-pressures all the way back to the
shell:

- Host output path: PTYreader → bounded channel (128) → iroh send stream. When
  full, the reader thread blocks → the kernel TTY buffer fills → the shell's
  own `write(2)` blocks. A verbose command simply *pauses* until the client
  catches up; it isn't buffered infinitely anywhere.
- Host input path: iroh recv → bounded channel (128) → PTY writer. Saturation
  stops the recv read → QUIC flow control chokes the peer.
- Client output path: same — the receiver accumulates at most one partial
  frame (~64 KiB, the `u16` wire max) and renders synchronously.

The iOS outbound queue is capped (`bufferingOldest`, 256) so a user typing or
pasting during a brownout can't grow memory; it drops the impatient tail
rather than block the UI.

### Why no session resume

v0.4–v0.5 had mosh-style session persistence: ring buffer, session registry,
reaper, control socket. v0.6 dropped all of it. Each connection mints a fresh
PTY, killed when the connection ends. The trade-off:

- **Loss:** a network blip kills your shell state. Running `vim` and the
  connection drops? `vim` dies with it.
- **Gain:** no class of "stale session" / "two connections to one PTY" /
  "garbled replay on resume" bugs. No heap growth from abandoned sessions.
  No `zuko reap` operator burden. The host is ~60% smaller.

Users who actually want resumability run `tmux`/`zellij`/`screen` *inside*
the zuko session. Those tools are designed for it, handle redraw cleanly, and
don't leak PTYs across host restarts. Pushing resume into zuko was a false
economy.

## Security

- The ticket is the secret. Anyone holding it can open a shell; store and
  transmit it accordingly. Clients learn it only through the
  [handoff](#ticket-handoff).
- Connections are end-to-end encrypted by Iroh. The relays see only encrypted
  traffic.
- Rotate the host identity by deleting `~/.config/zuko/key` and restarting;
  every previously-issued ticket stops working.
