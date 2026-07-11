# Temporary TCP tunnels

`zuko tunnel <port>` forwards an ephemeral port on the attached client to
`127.0.0.1:<port>` on the host:

```sh
# Start a service in the background on host loopback, then tunnel it.
python3 -m http.server 8000 --bind 127.0.0.1 &
zuko tunnel 8000
```

The native client prints a line like:

```text
zuko tunnel: client 127.0.0.1:49152 -> host 127.0.0.1:8000
```

It also opens `http://127.0.0.1:49152/` for the common web-server case. The
port is not HTTP-specific: for a TLS service, open
`https://127.0.0.1:49152/`; for another TCP service, point its normal client at
`127.0.0.1:49152`. CLI users can set `ZUKO_NO_BROWSER=1` before connecting to
suppress automatic browser launch.

## Lifecycle and statistics

The host-side command stays in the foreground. It prints connection-open and
connection-close events plus uploaded/downloaded byte totals. Zuko cannot
print HTTP access logs because it deliberately does not inspect application
traffic.

Press Ctrl-C to stop. Command exit closes its control lease; the host removes
the tunnel, closes active Iroh streams, and tells the native client to close
its loopback listener. The target service is independent and is not started or
stopped by Zuko.

## Security boundary

- The destination is fixed to host `127.0.0.1` and the requested non-zero TCP
  port. A client cannot select another host or turn the tunnel into a LAN or
  Internet proxy.
- The client listener binds only to `127.0.0.1` on an ephemeral port.
- Tunnel negotiation uses the separate `zuko/tunnel/1` Iroh ALPN and requires
  both the existing authorized-client token and a random tunnel ID delivered
  over the authenticated terminal connection.
- The hosted PTY receives a random per-session control capability. Keeping the
  control connection open owns the tunnel lease.
- Each local TCP connection maps to one Iroh bidirectional stream. A session
  may own at most 64 active tunnels, and each tunnel shares one 64-connection
  host concurrency limit across all authenticated Iroh connections.

Any process on the client machine that can reach the ephemeral loopback port
can use it while the tunnel is active, matching normal local port-forwarding
semantics. Stop the foreground command when the tunnel is no longer needed.

Native Rust CLI and native Flutter clients support tunnels. Flutter Web cannot
bind a local TCP listener and therefore ignores optional tunnel offers.
