# zuko wire protocol

zuko connects a **client** to a remote shell on a **host** over Iroh QUIC
streams. This document is the spec for client authors — the
CLI (`src/`) and the iOS app (`ios/Zuko/`) are reference implementations.

zuko is **not** an RPC or a terminal emulator protocol. It is deliberately
tiny: raw terminal bytes plus a few control frames. The host runs a real PTY;
the client renders it. Everything that works in a local terminal (`vim`,
`htop`, resize, signals) works because the bytes are passed through verbatim.

## Transport

- **Backend:** [Iroh](https://www.iroh.computer/) — QUIC, dial-by-key,
  end-to-end encrypted, NAT traversal via public relays. No open ports.
- **ALPN:** clients try `zuko/2` first and fall back to `zuko/1`.
- **v1 stream:** the client opens exactly **one bidirectional stream**
  (`open_bi`) after connecting. Data and control frames share it.
- **v2 streams:** the first bidirectional stream is the data stream. The client
  may open a second bidirectional control stream for `RESIZE`/`PING`; terminal
  `DATA` stays on the data stream so control does not queue behind bulk output.

The host advertises both ALPNs. v1 peers keep the original one-stream behavior;
v2 peers get the separate control stream foundation without changing frame
encoding.

## Framing

Every message on each stream is length-prefixed:

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
| `0x01` | `RESIZE` | client → host | `[cols: u16 BE][rows: u16 BE][pixel_width: u16 BE][pixel_height: u16 BE]` |
| `0x04` | `PING` | both | `[nonce: u64 BE]` (optional control/compat) |
| `0x05` | `PONG` | both | `[nonce: u64 BE]` (optional control/compat) |
| `0x06` | `ATTACH` | client → host | `[token: 16 bytes][cols: u16 BE][rows: u16 BE][pixel_width: u16 BE][pixel_height: u16 BE]` |
| `0x07` | `ATTACHED` | host → client | `[token: 16 bytes]` |

- **`DATA`** — client→host carries keystrokes; host→client carries PTY output.
  Bytes are forwarded verbatim. There is no encoding, escaping, or
  interpretation — a Ctrl-C is the byte `0x03`, a resize keystroke is whatever
  the terminal emulator sends.
- **`RESIZE`** — tells the host to resize the PTY. May be sent any time the
  client's window changes. Legacy clients may use `RESIZE` as the first frame;
  current clients use `ATTACH` first so they can resume a leased PTY.
- **`PING`/`PONG`** — optional control frames kept for compatibility. zuko does
  not require application heartbeats (Iroh/QUIC owns transport liveness), but
  peers should answer `PING` with `PONG` carrying the same nonce.
- **`ATTACH`/`ATTACHED`** — optional reconnect lease. New clients send `ATTACH`
  as the first frame. A zero token asks for a fresh PTY; a non-zero token asks
  to reattach a still-leased detached PTY. The host replies with `ATTACHED`
  carrying the token to use next time. If the requested token expired or is
  unknown, the host silently starts a fresh PTY and returns a new token. Legacy
  clients may still send first-frame `RESIZE` and get a fresh PTY.
- **Unknown types** — must be ignored (forward compatibility — future types
  can be added without breaking old clients). Frame types `0x02` (`HELLO`)
  and `0x03` (`WELCOME`) were used by v0.4–v0.5 for the session-resume
  handshake; v0.6 dropped both, leaving the gap reserved.

## Connection lifecycle

1. **Client dials** the host's ticket (see [Ticket](#ticket)) on ALPN `zuko/2`,
   falling back to `zuko/1` if the host is older.
2. **Client opens** the bidi stream and sends `ATTACH` with its last token and
   current terminal size. First connection uses an all-zero token. Legacy
   clients may send `RESIZE` instead, which always creates a fresh PTY. The
   opener must write first for the host's `accept_bi` to resolve. A host should
   bound this handshake with a short timeout, clamp zero dimensions to at least
   `1×1`, and if a non-handshake frame arrives first, spawn at `80×24` but still
   process that frame rather than discard input.
3. **Host spawns** a fresh shell (`$SHELL`) on a PTY at the requested size,
   or reattaches the requested still-leased PTY. Fresh shells use
   `TERM=xterm-256color`, in the directory chosen by `zuko host --cwd` (default
   `$HOME`). The host sends `ATTACHED` with the active token.
4. **Pump:** client keystrokes → `DATA` → host writes to PTY; PTY output →
   `DATA` → client renders. The client sends `RESIZE` whenever its window
   changes (e.g. on `SIGWINCH`).
5. **End:** the connection runs until either the shell exits (host sees PTY
   EOF → closes the stream → client sees recv EOF) or the network drops
   (either side sees a stream error). Shell exit kills the PTY immediately. A
   network/client drop detaches the PTY for a short host lease (currently 5
   minutes); reconnecting with the token reattaches it. Output while detached is
   discarded — there is no replay buffer.

For long-lived work that survives long disconnects or host restarts, run
`tmux`/`zellij`/`screen` *inside* the zuko session. The lease is only a mobile
handover safety net.

## Ticket

The host's **ticket** is an [Iroh `EndpointTicket`](https://docs.rs/iroh/)
string starting with `endpointa`. It encodes:

- the host's **node id** — the ed25519 public key derived from the host's
  persistent secret key (`~/.config/zuko/key`), and
- its **current addresses** — relay URL(s) and any direct addresses.

Because the secret key is persistent, the node id is stable across restarts and
IP changes; Iroh's discovery resolves the current address on dial, so a saved
ticket keeps working. The host writes and refreshes the ticket at
`~/.config/zuko/current_ticket` for `zuko share` to read; `share` rejects stale
files rather than handing out a ticket from a stopped host. Clients receive the
ticket exclusively through the [handoff](#ticket-handoff) flow.

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
claimer retries the dial until its overall timeout expires.

## Implementing a client

A minimal client, in any language with Iroh bindings (Rust `iroh`, Swift
`IrohLib`, …):

1. Get the host's ticket by implementing the [handoff](#ticket-handoff):
   accept a short code from the user, derive the throwaway key, dial it, and
   read the real ticket off the uni stream.
2. Parse the ticket → `EndpointAddr`.
3. `Endpoint::builder(presets::N0).bind()`; connect on `zuko/2`, falling back
   to `zuko/1` for older hosts.
4. `open_bi()` → `(send, recv)`. Send initial `ATTACH` (or legacy `RESIZE`).
5. Put the local terminal into raw mode. Pump:
   - keystrokes → `DATA` frames on `send`;
   - `DATA` frames from `recv` → render to the terminal;
   - window-size changes → `RESIZE` frames.
6. Store the token from `ATTACHED`. End when `recv` closes or the connection
   drops; restore the terminal. If you auto-redial transient drops, reuse the
   token so short disconnects reattach the same PTY.

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
pasting during a brownout can't grow memory; it drops the impatient tail rather
than block the UI. During reconnect backoff there is intentionally no input
buffer — keystrokes typed while no stream exists are discarded instead of being
replayed later into a possibly reattached shell.

### GUI apps use terminal graphics first

`zuko app` deliberately streams GUI frames through the existing terminal session
using the Kitty graphics protocol. That keeps the baseline client "any terminal
that supports the de-facto graphics/input escapes" instead of "a custom zuko GUI
client". It also keeps Ghostty a primary target: the iOS app already embeds
GhosttyTerminal, and desktop Ghostty/Kitty-compatible terminals can render the
same stream without a second renderer.

The terminal path may emit either Kitty PNG payloads (`f=100`) or raw RGB payloads
(`f=24`). The default `--graphics-codec auto` keeps PNG for compressible UI and
switches to raw RGB for high-entropy video-like frames to reduce CPU cost.
Flatpak app aliases are launched Wayland-only under cage; portal-correct full
desktop workflows should use an RDP client launched through `zuko app`.

A future custom GUI/video protocol could be valuable as an optional native-client
fast path: binary frames, damage rectangles or video codecs, explicit cursor /
touch / clipboard capabilities, and separate QUIC flow control. But it should be
additive. If it replaced Kitty graphics, zuko would lose interop with existing
Kitty-compatible terminals and make desktop/Ghostty usage harder, not easier.

The more complete product rationale is in [`DESIGN.md`](DESIGN.md).

### Why only a short lease, not full session replay

v0.4–v0.5 had mosh-style session persistence: ring buffer, session registry,
reaper, control socket. The current design keeps only the useful mobile part:
a short in-memory PTY lease keyed by a random token. The trade-off:

- **Loss:** output produced while detached is gone. Reattached fullscreen apps
  may need a redraw (`SIGWINCH`, refresh button, or app-specific redraw).
- **Gain:** short mobile drops keep the process alive without replay buffers,
  durable state, control sockets, or abandoned sessions that live forever. A
  replaced attachment is exclusive; abandoned leases are killed after minutes.

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
