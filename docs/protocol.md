# Wire protocol

## Transport

- Iroh QUIC endpoint ticket (`endpointa…`).
- Session ALPN: `zuko/2`.
- Raw tunnel ALPN: `zuko/tunnel/1`.
- Handoff ALPN: `zuko/handoff/1`.
- On `zuko/2`, the first bidi stream is data. An optional second bidi stream
  is control.

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
| `0x09` | `ERROR` | host → client | `code:u8` + UTF-8 message |
| `0x0a` | `TUNNEL_OFFER` | host → terminal client | `id:16 bytes port:u16` |
| `0x0b` | `TUNNEL_CLOSE` | host → terminal client | `id:16 bytes` |
| `0x0c` | `TUNNEL_ATTACH` | client → tunnel host | `token:16 bytes id:16 bytes` |
| `0x0d` | `TUNNEL_ATTACHED` | tunnel host → client | `id:16 bytes` |

Unknown types are ignored.

`ERROR` is fatal. A client must show the message and stop reconnecting. Defined
codes are `0x01` (authorization failure; pair again) and `0x02` (protocol
violation).

## Session handshake

1. Client dials host ticket on `zuko/2`.
2. Client opens data bidi stream.
3. First frame must be `ATTACH` with a non-zero host-scoped token and current
   terminal size.
4. Host checks `authorized_clients` for the token.
5. Host creates or reattaches the PTY keyed by that token.
6. Host sends `ATTACHED(token)`.

The token identifies both an authorized client and that client's in-memory PTY
lease. A second connection with the same token takes over the same PTY.

`RESIZE` is valid only after `ATTACH`. Cell dimensions are clamped to at least
`1x1`. Pixel dimensions may be zero.

## Pump

- Keystrokes/stdin: `DATA` client → host.
- PTY output: `DATA` host → client.
- Size changes: `RESIZE` on control stream when available, otherwise data stream.
- `PING` replies with `PONG` carrying the same nonce.

Shell EOF closes the stream and kills the PTY. Network/client drop detaches the
PTY for 5 minutes; output while detached is discarded.

## Raw TCP tunnel

`zuko tunnel <port>` runs inside the hosted PTY and registers host
`127.0.0.1:<port>` with the parent host over a random, per-PTY loopback control
capability. The registration control connection is the tunnel's lifetime
lease. The host sends `TUNNEL_OFFER(id, port)` on the authenticated terminal
stream and replays active offers after terminal reattachment. A session may
register at most 64 active tunnels.

A native client then:

1. Dials the same endpoint on `zuko/tunnel/1`.
2. Opens a handshake bidi stream and sends `TUNNEL_ATTACH(token, id)`.
3. Requires `TUNNEL_ATTACHED(id)` before binding a local listener.
4. Binds an ephemeral port on client `127.0.0.1`.
5. Maps each accepted local TCP connection to one additional Iroh bidi stream.

The host validates the normal authorized-client token and random tunnel ID,
then maps each post-handshake bidi stream to a fresh TCP connection to the
registered host-loopback port. Bytes after the handshake are opaque. Zuko does
not parse HTTP, terminate TLS, rewrite traffic, or infer application protocol.

Control EOF removes the registration and emits `TUNNEL_CLOSE(id)`. Command
exit, PTY exit, explicit close, or Iroh connection closure tears down listeners
and active streams. Completed streams report byte counts to the foreground
command over the private control connection.

## Compatibility

- The ALPN is the incompatible-version boundary. There is no version
  negotiation or v1 fallback.
- New optional frame types may be added to `zuko/2`; receivers ignore unknown
  types.
- Existing frame meanings and required handshake order must not change within
  `zuko/2`.
- A deliberate host rejection uses `ERROR` and must not enter a retry loop.
- Malformed required frames or an unexpected stream close are fatal to that
  connection.

## Ticket handoff

Purpose: let a client learn the host ticket and register its future `ATTACH`
token without putting the ticket on argv/stdin/stdout.

Possession of the short code while `zuko share` is active grants enrollment. A
share accepts one claim by default; `--count` can explicitly allow more. Treat
the code as temporary sensitive data and do not leave an unlimited share
(`--timeout 0`) unattended.

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

The Flutter client uses the same derivation with its protected client key on
Android, iOS, macOS, web, Linux, and Windows.

iOS:

```text
SHA256("zuko-ios-session-token-v1" || keychain_seed || host_id_string)[0..16]
```

Tokens must be non-zero.

## Security notes

- A shell connection requires host dial information plus a token in the host's
  authorized-client list.
- Host key stays on host at `${XDG_CONFIG_HOME:-$HOME/.config}/zuko/key`.
- Host admits only authorised client tokens.
- Iroh provides transport encryption; relays see encrypted traffic.
- Rotate host trust with `zuko reset`, restart, then re-pair clients.

Reference implementations: `src/wire.rs`, `src/client.rs`, `src/host.rs`,
`src/handoff.rs`, `flutter/lib/src/`, and
`flutter/rust/web_transport/src/lib.rs`.
