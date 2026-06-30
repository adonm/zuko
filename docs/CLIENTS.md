# zuko clients

zuko is **remote terminals over Iroh**: a [host daemon](../src/) and a
[tiny wire protocol](PROTOCOL.md). Clients connect to a host and render its
shell. Anyone can write one — the protocol is Iroh streams and a handful of
frame types. Product/architecture rationale lives in [`DESIGN.md`](DESIGN.md).

## Status

| Client | Status | Stack | Source |
|--------|--------|-------|--------|
| **CLI** | shipped | Rust + [crossterm](https://crates.io/crates/crossterm) | [`src/`](../src) — `zuko connect` (part of the `zuko` binary) |
| **iOS / iPadOS** | shipped | Swift + [GhosttyTerminal](https://github.com/Lakr233/libghostty-spm) + [IrohLib](https://github.com/n0-computer/iroh-ffi) | [`ios/Zuko/`](../ios/Zuko) |
| Android | planned | Kotlin/Rust via the crate's [uniffi](https://mozilla.github.io/uniffi.rs/) FFI surface | — |
| Linux GUI | planned | Rust + [relm4](https://relm4.org/) | — |
| Web | idea | — | — |

The CLI lives in the same `zuko` binary as the host — `mise use --global
github:adonm/zuko` gives you both (`zuko host` to serve, `zuko connect` to
attach). The universal iOS/iPadOS app is built from source (or
[TestFlight from CI](../ios/DISTRIBUTION.md)).

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
   ([`src/ffi.rs`](../src/ffi.rs)) exposing `derive_handoff_key(code)`, so the
   derivation is bit-exact with the CLI by construction. Wrap the `staticlib`
   into an XCFramework (iOS) / AAR (Android); see [`ios/Zuko/`](../ios/Zuko)
   for the reference.
2. Parse the host's `endpointa…` ticket.
3. Connect over Iroh on ALPN `zuko/2`, falling back to `zuko/1` for older
   hosts. Open the data bidi stream and send `ATTACH` as the **first frame**
   (`[last_token_or_zero][cols][rows][pixel_width][pixel_height]`). For fresh
   process stability, persist a client secret and derive a host-scoped non-zero
   first token; otherwise send zero and use the host's `ATTACHED` reply for
   reconnects. Iroh only
   surfaces a stream to the peer once the initiator sends data, so `ATTACH`
   doubles as the stream-opening write and the entire handshake. Legacy clients
   may send first-frame `RESIZE`, but that always starts a fresh PTY.
4. Pump `[type:u8][len:u16 BE][payload]` frames (`0x00 DATA`, `0x01 RESIZE`)
   between Iroh and a terminal emulator: keystrokes → `DATA` → host → PTY; PTY
   output → `DATA` → client → render; window-size changes → `RESIZE`. On v2,
   route `RESIZE`/`PING`/`PONG` over the optional control stream; keep terminal
   `DATA` on the data stream.
5. Store `ATTACHED`'s token. End when `recv` closes (host closed the stream →
   the shell exited) or errors (network drop). A client may auto-redial
   transient link errors with the token (the iOS client does); clean EOF should
   not be retried. The host keeps detached PTYs for a short in-memory lease and
   discards output while detached. For long-lived work, run
   `tmux`/`zellij`/`screen` inside the zuko session.

The reference implementations are deliberately small and worth cribbing from:

- **Rust:** [`src/wire.rs`](../src/wire.rs) +
  [`client.rs`](../src/client.rs).
- **Swift:** [`ZukoWire/Wire.swift`](../ios/ZukoWire/Sources/ZukoWire/Wire.swift) +
  [`IrohSession.swift`](../ios/Zuko/Zuko/Net/IrohSession.swift).

The host sets `TERM=xterm-256color`, so pick an emulator that speaks it. Gotchas
that bit the existing clients (so you don't have to):

- The stream **opener must write first** — Iroh only surfaces a stream to the
  peer once the initiator sends data. Send `ATTACH` (with token + size) right
  after `open_bi`; it's the whole session handshake.
- Clamp reported terminal dimensions to at least `1×1` before sending `RESIZE`.
  Terminal APIs can transiently report zero during resize/minimize; forwarding
  that to a PTY confuses fullscreen TUIs.
- Answer `PING` with `PONG` carrying the same nonce. v0.6+ doesn't initiate
  app-level heartbeats, but replying keeps older/future peers compatible.
- Forward keystrokes **verbatim** (Ctrl-C is `0x03`, etc.) — don't trap
  signals locally; the host's PTY handles them. The corollary: a client in
  raw mode has no built-in escape from a wedged session, so consider an
  explicit one. The reference CLI force-exits on **Ctrl-C 3× within ~1 s,
  gated on no remote output between presses** — the gate is what
  distinguishes "interrupt this silent remote command" (responsive) from
  "the session is stuck" (no output). The same heuristic (or an ssh-style
  escape character) is worth having in any raw-mode client.
- Keep writes **serialised** so a burst of keystrokes + a resize never
  interleaves frames on the wire. (The iOS app runs its write pump on a
  background task for this, and so it isn't starved by output rendering.)
- Bound your outbound queue — without a cap, keystrokes typed during a
  network outage grow memory without limit. The reference clients cap theirs
  and drop under pressure rather than block.
- Hold the connection open until the client has finished reading any
  one-shot payload (relevant for the [ticket handoff](PROTOCOL.md#ticket-handoff),
  where the host opens `open_uni` and writes the ticket before closing).

If you build one, open a PR adding a row to the table above.
