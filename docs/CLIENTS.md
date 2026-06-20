# zuko clients

zuko is **remote terminals over Iroh**: a [host daemon](../zuko/) and a
[tiny wire protocol](PROTOCOL.md). Clients connect to a host and render its
shell. Anyone can write one — the protocol is one Iroh stream and two frame
types.

## Status

| Client | Status | Stack | Source |
|--------|--------|-------|--------|
| **CLI** | shipped | Rust + [crossterm](https://crates.io/crates/crossterm) | [`zuko/`](../zuko) — `zuko connect` (part of the `zuko` binary) |
| **iOS** | shipped | Swift + [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) + [IrohLib](https://github.com/n0-computer/iroh-ffi) | [`ios/Zuko/`](../ios/Zuko) |
| Android | planned | Kotlin/Rust via [uniffi](https://github.com/mozilla/uniffi-rs)? | — |
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
2. Parse the host's `endpointa…` ticket.
3. Connect over Iroh on ALPN `zuko/1`, open one bidi stream, send an initial
   `RESIZE`.
4. Pump `[type:u8][len:u16 BE][payload]` frames (`0x00 DATA`, `0x01 RESIZE`)
   between the stream and a terminal emulator.
5. End on stream close / connection drop.

The reference implementations are deliberately small and worth cribbing from:

- **Rust:** [`src/wire.rs`](../src/wire.rs) +
  [`client.rs`](../src/client.rs).
- **Swift:** [`Wire.swift`](../ios/Zuko/Zuko/Net/Wire.swift) +
  [`IrohSession.swift`](../ios/Zuko/Zuko/Net/IrohSession.swift).

The host sets `TERM=xterm-256color`, so pick an emulator that speaks it. Gotchas
that bit the existing clients (so you don't have to):

- The stream **opener must write first** — Iroh only surfaces a stream to the
  peer once the initiator sends data. Send the initial `RESIZE` immediately
  after `open_bi`.
- Forward keystrokes **verbatim** (Ctrl-C is `0x03`, etc.) — don't trap signals
  locally; the host's PTY handles them.
- Keep writes **serialised** so a burst of keystrokes + a resize never
  interleaves frames on the wire.
- Hold the connection open until the client has finished reading any
  one-shot payload (relevant for the [ticket handoff](PROTOCOL.md#ticket-handoff),
  where the host opens `open_uni` and writes the ticket before closing).

If you build one, open a PR adding a row to the table above.
