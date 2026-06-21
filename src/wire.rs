//! Wire protocol shared by the host and client (and the iOS app).
//!
//! One bidirectional Iroh stream, ALPN [`ALPN`] = `zuko/1`. Every message is
//! length-prefixed so the frame types share an ordering and nothing leaks into
//! the terminal as in-band escape sequences:
//!
//! ```text
//! [type: u8][len: u16 big-endian][payload: `len` bytes]
//!   0x00 DATA    payload = raw terminal bytes (keystrokes up, PTY output down)
//!   0x01 RESIZE  payload = [cols: u16 BE][rows: u16 BE]   (client -> host)
//!   0x04 PING    payload = [nonce: u64 BE]   (bidirectional, heartbeat)
//!   0x05 PONG    payload = [nonce: u64 BE]   (bidirectional, heartbeat)
//! ```
//!
//! ## Handshake (v0.6 — session-resume removed)
//!
//! The client opens the stream with a single `RESIZE` carrying its initial
//! terminal size. The host spawns a fresh PTY at that size and starts
//! streaming. No `HELLO`/`WELCOME` exchange, no session ids — each
//! connection gets a new PTY, and when the connection ends (for any reason)
//! the host kills the PTY. Users who want resumability run `tmux`/`zellij`/
//! `screen` *inside* the zuko session; that's the proper layer for it.
//!
//! Unknown frame types **must be ignored** — the protocol is designed to
//! gain types over time without breaking old peers. The legacy `HELLO`
//! (0x02) and `WELCOME` (0x03) frame types used by v0.4–v0.5 are dropped
//! from this module; if an old client sends a `HELLO`, a v0.6 host treats
//! it as an unknown type and ignores it (then defaults to 80×24 until the
//! first `RESIZE` arrives).

use anyhow::{Result, anyhow};

/// ALPN used for every zuko stream.
pub const ALPN: &[u8] = b"zuko/1";

pub const TYPE_DATA: u8 = 0x00;
pub const TYPE_RESIZE: u8 = 0x01;
// 0x02 (TYPE_HELLO) and 0x03 (TYPE_WELCOME) were used by v0.4–v0.5 for the
// session-resume handshake. Removed in v0.6 — leave the gap so future
// frames don't reuse the numbers if any old peer is still in the wild.
pub const TYPE_PING: u8 = 0x04;
pub const TYPE_PONG: u8 = 0x05;

pub struct ParsedFrame {
    pub typ: u8,
    pub payload: Vec<u8>,
}

/// Encode one length-prefixed frame ready to write to the stream.
pub fn frame(typ: u8, payload: &[u8]) -> Vec<u8> {
    let mut f = Vec::with_capacity(3 + payload.len());
    f.push(typ);
    f.extend_from_slice(&(payload.len() as u16).to_be_bytes());
    f.extend_from_slice(payload);
    f
}

/// A `0x00 DATA` frame carrying raw terminal bytes.
pub fn data_frame(bytes: &[u8]) -> Vec<u8> {
    frame(TYPE_DATA, bytes)
}

/// A `0x01 RESIZE` frame (`client -> host`).
pub fn resize_frame(cols: u16, rows: u16) -> Vec<u8> {
    let payload = [cols.to_be_bytes(), rows.to_be_bytes()].concat();
    frame(TYPE_RESIZE, &payload)
}

/// A `0x04 PING` / `0x05 PONG` frame carrying an 8-byte nonce.
pub fn ping_frame(nonce: u64) -> Vec<u8> {
    frame(TYPE_PING, &nonce.to_be_bytes())
}
pub fn pong_frame(nonce: u64) -> Vec<u8> {
    frame(TYPE_PONG, &nonce.to_be_bytes())
}

/// Decode a PING/PONG nonce. Returns 0 for an empty payload (a peer that sends
/// an empty ping is still valid — the nonce is optional).
pub fn decode_nonce(payload: &[u8]) -> u64 {
    if payload.len() >= 8 {
        u64::from_be_bytes(payload[..8].try_into().unwrap_or([0u8; 8]))
    } else {
        0
    }
}

// ────────────────────────── frame parser ──────────────────────────────────

/// Pull one complete length-prefixed frame off the front of `buf`, draining it.
/// Returns `None` when there aren't enough bytes yet, leaving `buf` intact.
pub fn try_parse_frame(buf: &mut Vec<u8>) -> Option<ParsedFrame> {
    if buf.len() < 3 {
        return None;
    }
    let typ = buf[0];
    let len = u16::from_be_bytes([buf[1], buf[2]]) as usize;
    if buf.len() < 3 + len {
        return None;
    }
    let payload = buf[3..3 + len].to_vec();
    buf.drain(..3 + len);
    Some(ParsedFrame { typ, payload })
}

/// Read exactly one complete frame from `buf`, returning an error if the buffer
/// doesn't hold a full frame (used for the must-have-first-frame handshake).
pub fn parse_one(buf: &mut Vec<u8>) -> Result<ParsedFrame> {
    try_parse_frame(buf)
        .ok_or_else(|| anyhow!("expected a complete frame, have {} bytes", buf.len()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trips_data_resize_and_partial() {
        let mut buf = Vec::new();
        buf.extend(data_frame(b"hi"));
        buf.extend(resize_frame(120, 40));
        // A deliberately truncated third frame (header claims 5 bytes, only 2 present).
        buf.extend_from_slice(&[0x00, 0x00, 0x05, b'x', b'y']);

        let f1 = try_parse_frame(&mut buf).unwrap();
        assert_eq!(f1.typ, TYPE_DATA);
        assert_eq!(f1.payload, b"hi");

        let f2 = try_parse_frame(&mut buf).unwrap();
        assert_eq!(f2.typ, TYPE_RESIZE);
        assert_eq!(f2.payload.len(), 4);
        let cols = u16::from_be_bytes([f2.payload[0], f2.payload[1]]);
        let rows = u16::from_be_bytes([f2.payload[2], f2.payload[3]]);
        assert_eq!((cols, rows), (120, 40));

        // Partial frame: parser must wait for more bytes, leaving the remainder intact.
        assert!(try_parse_frame(&mut buf).is_none());
        assert_eq!(buf, vec![0x00, 0x00, 0x05, b'x', b'y']);
    }

    #[test]
    fn ignores_unknown_frame_type() {
        let mut buf = vec![0x42, 0x00, 0x01, 0xFF];
        let f = try_parse_frame(&mut buf).unwrap();
        assert_eq!(f.typ, 0x42);
        assert_eq!(f.payload, vec![0xFF]);
    }

    #[test]
    fn ping_pong_nonce_round_trip() {
        let mut buf = ping_frame(0xDEAD_BEEF_CAFE_BABE);
        let f = try_parse_frame(&mut buf).unwrap();
        assert_eq!(f.typ, TYPE_PING);
        assert_eq!(decode_nonce(&f.payload), 0xDEAD_BEEF_CAFE_BABE);

        let mut buf = pong_frame(0x0102_0304_0506_0708);
        let f = try_parse_frame(&mut buf).unwrap();
        assert_eq!(f.typ, TYPE_PONG);
        assert_eq!(decode_nonce(&f.payload), 0x0102_0304_0506_0708);

        // Empty-nonce pings are valid (degrade to 0).
        assert_eq!(decode_nonce(&[]), 0);
    }
}
