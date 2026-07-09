# Clients

Client tiers follow the [roadmap](roadmap.md):

| Client | Status | Source |
|--------|--------|--------|
| Rust CLI | Core | Linux/macOS release binary; `src/client.rs` |
| iOS/iPadOS | Beta | iOS/iPadOS 26.5; `ios/Zuko/` |
| Web | Labs | [Open client](https://adonm.github.io/zuko/web/); `web/` |

**Core** is release-gated and supported. **Beta** is intended for use but still
has availability or compatibility constraints. **Labs** is opt-in and may have
known reliability or security-boundary gaps.

The iOS/iPadOS app is built in CI and has a signed/TestFlight release pipeline,
but this repository does not currently document a public TestFlight or App
Store install path. Build instructions are in [`ios/Zuko/README.md`](../ios/Zuko/README.md).

The web client is published with the docs. It uses browser Iroh over relays,
lacks automatic reconnect, and stores connection state in IndexedDB. See
[Targets](targets.md#browser-client) for its promotion criteria, security
boundary, and known gaps.

## Implementing a client

Read [`protocol.md`](protocol.md). Checklist:

1. Claim ticket via `zuko/handoff/1`:
   - derive handoff key from code;
   - dial throwaway endpoint;
   - read `<label>\n<ticket>`;
   - derive host-scoped token;
   - send `AUTHORIZE` before closing handoff connection.
2. Persist a client secret. Derive non-zero token from `(client secret, host id)`.
3. Dial host ticket with ALPN `zuko/2`.
4. `open_bi`; first frame must be `ATTACH(token, cols, rows, pixels)`.
5. Pump length-prefixed frames:
   - stdin/terminal bytes → `DATA`;
   - remote `DATA` → terminal emulator;
   - size changes → `RESIZE`;
   - optional control stream for `RESIZE`/`PING`/`PONG`.
6. Store `ATTACHED` token. Reuse it for short reconnects.
7. Surface `ERROR` as fatal; do not retry an authorization or protocol failure.

Operational details:

- First frame is mandatory; Iroh exposes streams to the peer after initiator data.
- Clamp terminal cells to at least `1x1`.
- Serialise writes; frame interleaving corrupts the stream.
- Bound outbound queues. Dropping impatient input is better than unbounded memory.
- Forward terminal bytes verbatim. Local Ctrl-C handling should be an explicit
  escape hatch only.
- Clean EOF means shell exit. Redial transient link errors.
- Apply bounded backoff and stop reconnecting when the user leaves the session.

Mobile clients should call the Rust FFI `derive_handoff_key(code)` instead of
reimplementing Argon2id. See `src/ffi.rs` and `ios/Zuko/`.

Reference code:

- Rust framing/session: `src/wire.rs`, `src/client.rs`, `src/handoff.rs`
- Swift framing/session: `ios/ZukoWire/`, `ios/Zuko/Zuko/Net/`
- Browser framing/session: `web/wasm/src/lib.rs`, `web/src/`
