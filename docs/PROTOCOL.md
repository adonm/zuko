# zuko wire protocol

zuko connects a **client** to a remote shell on a **host** over a single
Iroh bidirectional stream. This document is the spec for client authors — the
CLI (`src/`) and the iOS app (`ios/Zuko/`) are reference implementations.

zuko is **not** an RPC or a terminal emulator protocol. It is deliberately
tiny: one stream, two frame types, raw bytes. The host runs a real PTY; the
client renders it. Everything that works in a local terminal (`vim`, `htop`,
resize, signals) works because the bytes are passed through verbatim.

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
| `0x02` | `HELLO` | client → host | `[flags:u8][cols:u16 BE][rows:u16 BE][sid_len:u8][sid]` |
| `0x03` | `WELCOME` | host → client | `[flags:u8][sid_len:u8][sid]` |
| `0x04` | `PING` | both | `[nonce: u64 BE]` (may be empty) |
| `0x05` | `PONG` | both | `[nonce: u64 BE]` (may be empty) |

- **`DATA`** — client→host carries keystrokes; host→client carries PTY output.
  Bytes are forwarded verbatim. There is no encoding, escaping, or
  interpretation — a Ctrl-C is the byte `0x03`, a resize keystroke is whatever
  the terminal emulator sends.
- **`RESIZE`** — tells the host to resize the PTY. May be sent any time the
  client's window changes. Unknown frame types **must be ignored** (forward
  compatibility — future types can be added without breaking old clients).
- **`HELLO`** — the **first frame** a v0.4+ client sends after `open_bi`. It
  carries the client's capability `flags`, its current terminal size (so the
  host spawns/resizes the PTY correctly), and an optional session id to resume
  (empty `sid_len` = start a fresh session). Subsumes the v0.3 leading `RESIZE`.
- **`WELCOME`** — the host's **first frame** in reply. Carries the host's
  capability `flags`, the session id it'll use (newly minted for a fresh
  session, or the resumed id), and the `RESUMED` flag if this was a resume
  (meaning a ring-buffer replay follows as `DATA` frames). A v0.3 host doesn't
  speak `HELLO`/`WELCOME`; a v0.4 client falls back to a fresh session and its
  first layout-pass `RESIZE` corrects the size.
- **`PING`/`PONG`** — app-level heartbeat. Either side may send a `PING` at any
  time; the recipient echoes the nonce back as `PONG`. Used to surface a
  "stalled" state faster than the QUIC idle timeout (see [Heartbeat](#heartbeat)).

### Capability flags (HELLO/WELCOME `flags`)

| bit | name | meaning |
|-----|------|---------|
| `0x01` | `RESUME` | the peer supports session resume (HELLO: client; WELCOME: host) |
| `0x02` | `HEARTBEAT` | the peer sends/understands PING/PONG |
| `0x04` | `RESUMED` | WELCOME-only: this connection resumed an existing session |

## Connection lifecycle

1. **Client dials** the host's ticket (see [Ticket](#ticket)) on ALPN `zuko/1`.
2. **Client opens** the bidi stream and sends a `HELLO` with its capability
   flags, current size, and an optional session id to resume. (The opener must
   write first for the host's `accept_bi` to resolve, so `HELLO` doubles as the
   stream-opening write — and carries the initial size, subsuming the v0.3
   leading `RESIZE`.) A v0.3 client instead sends a bare `RESIZE`; the host
   treats that as a legacy new-session handshake.
3. **Host resolves the session:** if the `HELLO` carried a session id and that
   session is still live, it **resumes** it (same PTY + shell, same cwd/editor/
   running command); otherwise it **spawns** a fresh shell (`$SHELL`) on a PTY
   at the requested size, with `TERM=xterm-256color`, in `$HOME` (overridable
   via `--shell`, `--shell-args`, `--cwd`).
4. **Host replies `WELCOME`** with its capability flags, the session id, and
   the `RESUMED` bit set if this was a resume. On a resume, it then replays the
   session's recent-output ring buffer as `DATA` frames before live output.
5. **Pump:** client keystrokes → `DATA` → host writes to PTY; PTY output →
   `DATA` → client renders. The client sends `RESIZE` whenever its window
   changes (e.g. on `SIGWINCH`). Either side may send `PING`/`PONG` (see
   [Heartbeat](#heartbeat)).
6. **Detach vs. end:** a connection drop is a **detach** — the host keeps the
   session alive (PTY reader keeps buffering into the ring buffer) so a client
   can reconnect with the session id and resume. The session ends only when the
   shell exits (host sees PTY EOF → closes the stream → client sees recv EOF →
   stops) or an operator runs `zuko reap` on the host (kills idle sessions
   over a threshold — default 1 hour — sparing the session it's run from).
   The host kills the child when the session is reaped.

## Session resume

A **session** is a PTY + shell + a bounded ring buffer of recent output
(~1 MiB) that outlives any single connection. The host mints an 8-byte session
id on first connect and returns it in `WELCOME`; the client sends it back in
`HELLO` on reconnect. The session id is **not a secret** — the ticket already
gates access, so anyone holding it can resume any of the host's sessions (same
trust boundary as mosh's key).

On resume the host replays the ring buffer (starting at the first newline, so
line-oriented output is clean), then live-feeds. The client re-sends its
current size in `HELLO`, which resizes the PTY and delivers `SIGWINCH` to
full-screen apps (`vim`, `htop`) — they redraw, so a resume into a full-screen
app recovers a clean screen despite the raw-byte replay (zuko has no
server-side terminal emulator; this is the pragmatic alternative to mosh's
state-sync).

The iOS app persists the session id on the saved `Connection` (`lastSessionID`)
so a relaunch can resume; the CLI keeps it in-process for the reconnect loop.

## Heartbeat

iroh's QUIC keepalive (5 s) keeps the transport alive across brief idle, but an
app-level heartbeat surfaces a stuck link faster and lets the client show a
"stalled" state. Both sides send `PING` every ~5 s and answer with `PONG`
(echoing the nonce). If a client receives no frame at all for ~10 s it flips to
a `stalled` UI state; the actual reconnect triggers when the QUIC idle timeout
(15–30 s) errors the recv. The host doesn't gate reaping on heartbeat state —
sessions live forever until the shell exits or `zuko reap` is invoked.

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

If your client needs a terminal emulator, [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)
is used on iOS; on Linux, [alacritty_terminal](https://crates.io/crates/alacritty_terminal)
or [vte](https://crates.io/crates/vte) are good choices. The host sends bytes
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

- Host output path: PTY reader → bounded channel (128) → iroh send stream. When
  full, the reader thread blocks → the kernel TTY buffer fills → the shell's
  own `write(2)` blocks. A verbose command simply *pauses* until the client
  catches up; it isn't buffered infinitely anywhere.
- Host input path: iroh recv → bounded channel (128) → PTY writer. Saturation
  stops the recv read → QUIC flow control chokes the peer.
- Client output path: same — the receiver accumulates at most one partial
  frame (~64 KiB, the `u16` wire max) and renders synchronously.

The iOS outbound queue is capped (`bufferingOldest`, 256) so a user typing or
pasting during a brownout can't grow memory; it drops the impatient tail
rather than block the UI. The CLI keeps keystrokes in a bounded channel so
they flush on reconnect.

### Why no server-side terminal emulator

mosh runs the terminal emulator on the server so it can send screen *state* on
resume. zuko replays raw *bytes* from the ring buffer instead — simpler, and
keeps the client's terminal emulator (SwiftTerm, your local terminal) as the
single source of rendering truth. The trade-off: a resume into a full-screen
app may briefly show a mid-redraw screen, fixed by re-sending the size
(→ `SIGWINCH` → redraw). Line-oriented output replays cleanly (the snapshot
starts at the first newline). A future Tier-4 state-sync would remove the
caveat at the cost of a much larger rewrite.

## Security

- The ticket is the secret. Anyone holding it can open a shell; store and
  transmit it accordingly. Clients learn it only through the
  [handoff](#ticket-handoff).
- Connections are end-to-end encrypted by Iroh. The relays see only encrypted
  traffic.
- Rotate the host identity by deleting `~/.config/zuko/key` and restarting;
  every previously-issued ticket stops working.
