//! Wire protocol shared by the host and client (and the iOS app).
//!
//! One bidirectional Iroh stream, ALPN [`ALPN`] = `zuko/1`. Every message is
//! length-prefixed so the frame types share an ordering and nothing leaks into
//! the terminal as in-band escape sequences:
//!
//! ```text
//! [type: u8][len: u16 big-endian][payload: `len` bytes]
//!   0x00 DATA    payload = raw terminal bytes (keystrokes up, PTY output down)
//!   0x01 RESIZE  payload = [cols: u16 BE][rows: u16 BE][pixel_width: u16 BE][pixel_height: u16 BE]
//!                 (client -> host, also first frame). Pixels let a host-side
//!                 `zuko app` render at the client terminal's real resolution.
//!   0x04 PING    payload = [nonce: u64 BE]   (optional control/compat)
//!   0x05 PONG    payload = [nonce: u64 BE]   (optional control/compat)
//!   0x06 ATTACH  payload = [token: 16 bytes][cols: u16 BE][rows: u16 BE][pixel_width: u16 BE][pixel_height: u16 BE]
//! ```
//!
//! ## Handshake
//!
//! The client opens the stream with `ATTACH`: a 16-byte session token (zero for
//! first attach) plus terminal size. The host replies `ATTACHED` with the token
//! to reuse on short reconnects. Detached PTYs live only for a short in-memory
//! lease and output while detached is discarded; there is no replay buffer.
//!
//! Unknown frame types **must be ignored** — the protocol is designed to
//! gain types over time without breaking old peers. The legacy `HELLO`
//! (0x02) and `WELCOME` (0x03) frame types used by v0.4–v0.5 are reserved.

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
pub const TYPE_ATTACH: u8 = 0x06;
pub const TYPE_ATTACHED: u8 = 0x07;
pub const MAX_PAYLOAD_LEN: usize = u16::MAX as usize;
pub const SESSION_TOKEN_LEN: usize = 16;
pub type SessionToken = [u8; SESSION_TOKEN_LEN];

pub struct ParsedFrame {
    pub typ: u8,
    pub payload: Vec<u8>,
}

/// Encode one length-prefixed frame ready to write to the stream.
pub fn frame(typ: u8, payload: &[u8]) -> Vec<u8> {
    assert!(
        payload.len() <= MAX_PAYLOAD_LEN,
        "zuko frame payload exceeds u16 length prefix"
    );
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

/// A `0x01 RESIZE` frame (`client -> host`). Carries cell size AND pixel size;
/// pixels let a host-side `zuko app` render at the client terminal's real
/// resolution over the relay (the host sets them on the PTY winsize, which
/// `TIOCGWINSZ` reads back on the host side).
pub fn resize_frame(cols: u16, rows: u16, pixel_width: u16, pixel_height: u16) -> Vec<u8> {
    let payload = [
        cols.to_be_bytes(),
        rows.to_be_bytes(),
        pixel_width.to_be_bytes(),
        pixel_height.to_be_bytes(),
    ]
    .concat();
    frame(TYPE_RESIZE, &payload)
}

/// A `0x04 PING` / `0x05 PONG` frame carrying an 8-byte nonce. zuko doesn't
/// require app-level heartbeats; these stay for cheap peer compatibility.
pub fn ping_frame(nonce: u64) -> Vec<u8> {
    frame(TYPE_PING, &nonce.to_be_bytes())
}
pub fn pong_frame(nonce: u64) -> Vec<u8> {
    frame(TYPE_PONG, &nonce.to_be_bytes())
}

/// A `0x06 ATTACH` frame. An all-zero token asks the host for a fresh session;
/// any other token asks to reattach a still-leased detached PTY. Carries the
/// client's cell + pixel size like RESIZE.
pub fn attach_frame(
    token: SessionToken,
    cols: u16,
    rows: u16,
    pixel_width: u16,
    pixel_height: u16,
) -> Vec<u8> {
    let mut payload = Vec::with_capacity(SESSION_TOKEN_LEN + 8);
    payload.extend_from_slice(&token);
    payload.extend_from_slice(&cols.to_be_bytes());
    payload.extend_from_slice(&rows.to_be_bytes());
    payload.extend_from_slice(&pixel_width.to_be_bytes());
    payload.extend_from_slice(&pixel_height.to_be_bytes());
    frame(TYPE_ATTACH, &payload)
}

/// A `0x07 ATTACHED` frame carrying the token the client should use on the next
/// reconnect. If the requested token expired, this will be a new token.
pub fn attached_frame(token: SessionToken) -> Vec<u8> {
    frame(TYPE_ATTACHED, &token)
}

pub fn parse_attach(payload: &[u8]) -> Option<(SessionToken, u16, u16, u16, u16)> {
    if payload.len() != SESSION_TOKEN_LEN + 8 {
        return None;
    }
    let mut token = [0u8; SESSION_TOKEN_LEN];
    token.copy_from_slice(&payload[..SESSION_TOKEN_LEN]);
    let cols = u16::from_be_bytes([payload[SESSION_TOKEN_LEN], payload[SESSION_TOKEN_LEN + 1]]);
    let rows = u16::from_be_bytes([
        payload[SESSION_TOKEN_LEN + 2],
        payload[SESSION_TOKEN_LEN + 3],
    ]);
    let pixel_width = u16::from_be_bytes([
        payload[SESSION_TOKEN_LEN + 4],
        payload[SESSION_TOKEN_LEN + 5],
    ]);
    let pixel_height = u16::from_be_bytes([
        payload[SESSION_TOKEN_LEN + 6],
        payload[SESSION_TOKEN_LEN + 7],
    ]);
    Some((token, cols, rows, pixel_width, pixel_height))
}

pub fn parse_attached(payload: &[u8]) -> Option<SessionToken> {
    if payload.len() != SESSION_TOKEN_LEN {
        return None;
    }
    let mut token = [0u8; SESSION_TOKEN_LEN];
    token.copy_from_slice(payload);
    Some(token)
}

pub const fn empty_session_token(token: &SessionToken) -> bool {
    let mut i = 0;
    while i < SESSION_TOKEN_LEN {
        if token[i] != 0 {
            return false;
        }
        i += 1;
    }
    true
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
        buf.extend(resize_frame(120, 40, 1024, 768));
        // A deliberately truncated third frame (header claims 5 bytes, only 2 present).
        buf.extend_from_slice(&[0x00, 0x00, 0x05, b'x', b'y']);

        let f1 = try_parse_frame(&mut buf).unwrap();
        assert_eq!(f1.typ, TYPE_DATA);
        assert_eq!(f1.payload, b"hi");

        let f2 = try_parse_frame(&mut buf).unwrap();
        assert_eq!(f2.typ, TYPE_RESIZE);
        assert_eq!(f2.payload.len(), 8);
        let cols = u16::from_be_bytes([f2.payload[0], f2.payload[1]]);
        let rows = u16::from_be_bytes([f2.payload[2], f2.payload[3]]);
        let pw = u16::from_be_bytes([f2.payload[4], f2.payload[5]]);
        let ph = u16::from_be_bytes([f2.payload[6], f2.payload[7]]);
        assert_eq!((cols, rows), (120, 40));
        assert_eq!((pw, ph), (1024, 768));

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

    #[test]
    fn attach_round_trip() {
        let token = [7u8; SESSION_TOKEN_LEN];
        let mut buf = attach_frame(token, 100, 40, 1024, 768);
        let f = try_parse_frame(&mut buf).unwrap();
        assert_eq!(f.typ, TYPE_ATTACH);
        assert_eq!(parse_attach(&f.payload), Some((token, 100, 40, 1024, 768)));

        let mut buf = attached_frame(token);
        let f = try_parse_frame(&mut buf).unwrap();
        assert_eq!(f.typ, TYPE_ATTACHED);
        assert_eq!(parse_attached(&f.payload), Some(token));
        assert!(empty_session_token(&[0u8; SESSION_TOKEN_LEN]));
        assert!(!empty_session_token(&token));
    }
}
