# Clients

Reference clients:

| Client | Status | Source |
|--------|--------|--------|
| Rust CLI | shipped | `src/client.rs` |
| iOS/iPadOS | shipped | `ios/Zuko/` |
| Android | planned | — |

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

Operational details:

- First frame is mandatory; Iroh exposes streams to the peer after initiator data.
- Clamp terminal cells to at least `1x1`.
- Serialise writes; frame interleaving corrupts the stream.
- Bound outbound queues. Dropping impatient input is better than unbounded memory.
- Forward terminal bytes verbatim. Local Ctrl-C handling should be an explicit
  escape hatch only.
- Clean EOF means shell exit. Redial transient link errors.

Mobile clients should call the Rust FFI `derive_handoff_key(code)` instead of
reimplementing Argon2id. See `src/ffi.rs` and `ios/Zuko/`.

Reference code:

- Rust framing/session: `src/wire.rs`, `src/client.rs`, `src/handoff.rs`
- Swift framing/session: `ios/ZukoWire/`, `ios/Zuko/Zuko/Net/`
