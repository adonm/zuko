# Wire protocol

## Transport

- Iroh QUIC endpoint ticket (`endpointa…`).
- Session ALPN: `zuko/2`.
- Handoff ALPN: `zuko/handoff/1`.
- First bidi stream is data. Optional second bidi stream is control.

## Frame format

```text
[type: u8][len: u16 BE][payload: len bytes]
```

`len` excludes the 3-byte header. Max payload: 65535 bytes. Receivers must
accumulate and parse greedily; frames can split/coalesce across QUIC reads.

## Frame types

| Type | Name | Direction | Payload |
|------|------|-----------|---------|
| `0x00` | `DATA` | both | terminal bytes |
| `0x01` | `RESIZE` | client → host | `cols:u16 rows:u16 pixel_width:u16 pixel_height:u16` |
| `0x04` | `PING` | both | `nonce:u64` |
| `0x05` | `PONG` | both | `nonce:u64` |
| `0x06` | `ATTACH` | client → host | `token:16 bytes` + resize payload |
| `0x07` | `ATTACHED` | host → client | `token:16 bytes` |
| `0x08` | `AUTHORIZE` | client → handoff host | `token:16 bytes` + UTF-8 label |

Unknown types are ignored.

## Session handshake

1. Client dials host ticket on `zuko/2`.
2. Client opens data bidi stream.
3. First frame must be `ATTACH` with a non-zero host-scoped token and current
   terminal size.
4. Host checks `authorized_clients` for the token.
5. Host creates or reattaches the PTY keyed by that token.
6. Host sends `ATTACHED(token)`.

`RESIZE` is valid only after `ATTACH`. Cell dimensions are clamped to at least
`1x1`. Pixel dimensions may be zero.

## Pump

- Keystrokes/stdin: `DATA` client → host.
- PTY output: `DATA` host → client.
- Size changes: `RESIZE` on control stream when available, otherwise data stream.
- `PING` replies with `PONG` carrying the same nonce.

Shell EOF closes the stream and kills the PTY. Network/client drop detaches the
PTY for 5 minutes; output while detached is discarded.

## Ticket handoff

Purpose: let a client learn the host ticket and register its future `ATTACH`
token without putting the ticket on argv/stdin/stdout.

Host (`zuko share`):

1. Generate memorable code.
2. Derive throwaway Iroh secret:
   `Argon2id(normalized_code, salt="zuko-share-handoff-v1") -> 32-byte seed`.
3. Bind endpoint on `zuko/handoff/1`.
4. Open uni stream and write:
   ```text
   <label>\n<ticket>
   ```
5. Wait briefly for client `AUTHORIZE` uni stream.
6. Save token + label to `authorized_clients`.

Client (`zuko claim` / `zuko <code>`):

1. Derive same throwaway endpoint id from code.
2. Dial `zuko/handoff/1`, retrying until timeout.
3. Read label + ticket.
4. Parse ticket host id.
5. Derive stable host-scoped token from local client secret + host id.
6. Open uni stream, send `AUTHORIZE(token, client_label)`.
7. Save ticket locally and optionally connect.

## Token derivation

Rust CLI:

```text
SHA256("zuko-session-token-v1" || client_key_bytes || host_id_bytes)[0..16]
```

iOS:

```text
SHA256("zuko-ios-session-token-v1" || keychain_seed || host_id_string)[0..16]
```

Tokens must be non-zero.

## Security notes

- Host ticket is a bearer secret.
- Host key stays on host at `~/.config/zuko/key`.
- Host admits only authorised client tokens.
- Iroh provides transport encryption; relays see encrypted traffic.
- Rotate host trust with `zuko reset`, restart, then re-pair clients.

Reference implementations: `src/wire.rs`, `src/client.rs`, `src/host.rs`,
`src/handoff.rs`, `ios/ZukoWire/`.
