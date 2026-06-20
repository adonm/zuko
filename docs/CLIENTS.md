# zuko clients

zuko is **remote terminals over Iroh**: a [host daemon](../src/) and a
[tiny wire protocol](PROTOCOL.md). Clients connect to a host and render its
shell. Anyone can write one — the protocol is one Iroh stream and a handful of
frame types.

## Status

| Client | Status | Stack | Source |
|--------|--------|-------|--------|
| **CLI** | shipped | Rust + [crossterm](https://crates.io/crates/crossterm) | [`src/`](../src) — `zuko connect` (part of the `zuko` binary) |
| **iOS** | shipped | Swift + [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) + [IrohLib](https://github.com/n0-computer/iroh-ffi) | [`ios/Zuko/`](../ios/Zuko) |
| Android | planned | Kotlin/Rust via the crate's [uniffi](https://mozilla.github.io/uniffi.rs/) FFI surface | — |
| Linux GUI | planned | Rust + [relm4](https://relm4.org/) | — |
| Web | idea | — | — |

The CLI lives in the same `zuko` binary as the host — `mise use --global
github:adonm/zuko` gives you both (`zuko host` to serve, `zuko connect` to
attach). The iOS app is built from source (or [TestFlight from CI](../ios/DISTRIBUTION.md)).

## Writing a client

Read [`PROTOCOL.md`](PROTOCOL.md) first — it's short. In brief:

1. **Get the host's ticket** by implementing the
   [ticket handoff](PROTOCOL.md#ticket-handoff): accept a short memorable code
   from the user, derive the throwaway key from it, dial the ephemeral host,
   and read the real ticket off the uni stream. The CLI flow is
   `zuko share` → `zuko <code>` (or `zuko claim <code>` with flags); the same
   UX is the goal for every client.
   
   **Mobile clients:** don't reimplement the Argon2id key derivation — the
   crate ships a [uniffi](https://mozilla.github.io/uniffi.rs/) FFI surface
   ([`src/ffi.rs`](../src/ffi.rs)) exposing `derive_handoff_key(code)`, which
   is literally `src/code.rs::derive_key`. Wrap the `staticlib` into an
   XCFramework (iOS) / AAR (Android) and call it from your client so the
   derivation is bit-exact with the CLI by construction. The iOS app uses this
   pattern; see [`ios/Zuko/`](../ios/Zuko).
2. Parse the host's `endpointa…` ticket.
3. Connect over Iroh on ALPN `zuko/1`, open one bidi stream, and send a
   `HELLO` as the **first frame** (carrying your capability flags, current
   terminal size, and an empty session id for a fresh session). Iroh only
   surfaces a stream to the peer once the initiator sends data, so `HELLO`
   doubles as the stream-opening write.
4. Read the host's `WELCOME` (its flags + the assigned session id), then pump
   `[type:u8][len:u16 BE][payload]` frames (`0x00 DATA`, `0x01 RESIZE`) between
   the stream and a terminal emulator. On a reconnect, send `HELLO` again with
   the session id from the first `WELCOME` to **resume** the same shell — the
   host replays recent output as `DATA` frames before live output. Answer
   inbound `PING` with `PONG` to take part in the heartbeat.
5. Distinguish the two read-half endings: EOF (host closed the stream → the
   shell exited → stop) vs. error (network drop → reconnect with the session
   id to resume). A bounded backoff spaces reconnect attempts.

The reference implementations are deliberately small and worth cribbing from:

- **Rust:** [`src/wire.rs`](../src/wire.rs) +
  [`client.rs`](../src/client.rs).
- **Swift:** [`Wire.swift`](../ios/Zuko/Zuko/Net/Wire.swift) +
  [`IrohSession.swift`](../ios/Zuko/Zuko/Net/IrohSession.swift).

The host sets `TERM=xterm-256color`, so pick an emulator that speaks it. Gotchas
that bit the existing clients (so you don't have to):

- The stream **opener must write first** — Iroh only surfaces a stream to the
  peer once the initiator sends data. Send `HELLO` (with your size) right
  after `open_bi`; it subsumes the v0.3 leading `RESIZE`.
- Send your **current size on every reconnect** — it resizes the PTY and
  delivers `SIGWINCH`, so full-screen apps (`vim`, `htop`) redraw a clean
  screen despite the raw-byte replay of recent output.
- Forward keystrokes **verbatim** (Ctrl-C is `0x03`, etc.) — don't trap signals
  locally; the host's PTY handles them.
- Keep writes **serialised** so a burst of keystrokes + a resize never
  interleaves frames on the wire. (The iOS app runs its write pump on a
  background task for this, and so it isn't starved by output rendering.)
- Bound your outbound queue — without a cap, keystrokes typed during a network
  outage grow memory without limit. The reference clients cap theirs and drop
  under pressure rather than block.
- Hold the connection open until the client has finished reading any
  one-shot payload (relevant for the [ticket handoff](PROTOCOL.md#ticket-handoff),
  where the host opens `open_uni` and writes the ticket before closing).

If you build one, open a PR adding a row to the table above.
