//! Wire protocol shared by the host and client (and the iOS app).
//!
//! ALPN [`ALPN_V2`] uses one data stream and permits a second control stream
//! for resize/ping traffic.
//! Every message is length-prefixed so nothing leaks into the terminal as
//! in-band escape sequences:
//!
//! ```text
//! [type: u8][len: u16 big-endian][payload: `len` bytes]
//!   0x00 DATA    payload = raw terminal bytes (keystrokes up, PTY output down)
//!   0x01 RESIZE  payload = [cols: u16 BE][rows: u16 BE][pixel_width: u16 BE][pixel_height: u16 BE]
//!                 (client -> host, after ATTACH). Pixels let a host-side
//!                 `zuko app` render at the client terminal's real resolution.
//!   0x04 PING    payload = [nonce: u64 BE]   (optional control)
//!   0x05 PONG    payload = [nonce: u64 BE]   (optional control)
//!   0x06 ATTACH  payload = [token: 16 bytes][cols: u16 BE][rows: u16 BE][pixel_width: u16 BE][pixel_height: u16 BE]
//!   0x07 ATTACHED payload = [token: 16 bytes]
//!   0x08 AUTHORIZE payload = [token: 16 bytes][label: UTF-8]
//!   0x09 ERROR    payload = [code: u8][message: UTF-8]   (host -> client, fatal)
//!                 code 0x01 = authorisation failure — re-pair with `zuko share`.
//!                 code 0x02 = protocol violation.
//! ```
//!
//! ## Handshake
//!
//! The client opens the stream with `ATTACH`: a non-zero, authorized 16-byte
//! session token plus terminal size. The host replies `ATTACHED` with the token
//! to reuse on short reconnects. Detached PTYs live only for a short in-memory
//! lease and output while detached is discarded; there is no replay buffer.
//!
//! Unknown frame types **must be ignored** — the protocol is designed to
//! gain types over time without breaking old peers.

use anyhow::{Result, anyhow};

/// Protocol v2 ALPN. v2 keeps v1 frame encoding but allows a second bidi
/// control stream so resize/ping traffic does not queue behind terminal DATA.
pub const ALPN_V2: &[u8] = b"zuko/2";

pub fn supported_alpns() -> Vec<Vec<u8>> {
    vec![ALPN_V2.to_vec()]
}

pub const TYPE_DATA: u8 = 0x00;
pub const TYPE_RESIZE: u8 = 0x01;
pub const TYPE_PING: u8 = 0x04;
pub const TYPE_PONG: u8 = 0x05;
pub const TYPE_ATTACH: u8 = 0x06;
pub const TYPE_ATTACHED: u8 = 0x07;
pub const TYPE_AUTHORIZE: u8 = 0x08;
pub const TYPE_ERROR: u8 = 0x09;
/// `ERROR` frame codes (the first byte of an ERROR payload).
pub const ERR_AUTHORIZATION: u8 = 0x01;
pub const ERR_PROTOCOL: u8 = 0x02;
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

/// A `0x01 RESIZE` frame (`client -> host`, after ATTACH). Carries cell size AND pixel size;
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
/// require app-level heartbeats; peers may still use these as cheap liveness
/// probes.
pub fn ping_frame(nonce: u64) -> Vec<u8> {
    frame(TYPE_PING, &nonce.to_be_bytes())
}
pub fn pong_frame(nonce: u64) -> Vec<u8> {
    frame(TYPE_PONG, &nonce.to_be_bytes())
}

/// A `0x06 ATTACH` frame. The non-zero token is both this client's host-side
/// authorisation token and its stable PTY lease key. Carries the client's cell
/// + pixel size like RESIZE.
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

/// A `0x07 ATTACHED` frame confirming the token the client should use on the
/// next reconnect.
pub fn attached_frame(token: SessionToken) -> Vec<u8> {
    frame(TYPE_ATTACHED, &token)
}

/// A `0x08 AUTHORIZE` frame used only during `zuko share` pairing. The claimer
/// sends the stable token it will use for future ATTACH handshakes plus a local
/// device label. Older hosts ignore it; newer hosts save it to their
/// authorised-clients list before handing out the ticket.
pub fn authorize_frame(token: SessionToken, label: &str) -> Vec<u8> {
    let label = label.as_bytes();
    let max_label = MAX_PAYLOAD_LEN.saturating_sub(SESSION_TOKEN_LEN);
    let label = &label[..label.len().min(max_label)];
    let mut payload = Vec::with_capacity(SESSION_TOKEN_LEN + label.len());
    payload.extend_from_slice(&token);
    payload.extend_from_slice(label);
    frame(TYPE_AUTHORIZE, &payload)
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

pub fn parse_authorize(payload: &[u8]) -> Option<(SessionToken, String)> {
    if payload.len() < SESSION_TOKEN_LEN {
        return None;
    }
    let mut token = [0u8; SESSION_TOKEN_LEN];
    token.copy_from_slice(&payload[..SESSION_TOKEN_LEN]);
    let label = String::from_utf8_lossy(&payload[SESSION_TOKEN_LEN..]).to_string();
    Some((token, label))
}

/// A `0x09 ERROR` frame (`host -> client`). Carries a 1-byte error code (see
/// `ERR_*`) and a UTF-8 human message. Receiving one is fatal: the client
/// must surface the message and stop reconnecting — the host has rejected the
/// connection deliberately (e.g. authorisation failure), so retrying would
/// just hammer the host. Older peers without `TYPE_ERROR` handling still see
/// the abrupt close they always did.
pub fn error_frame(code: u8, message: &str) -> Vec<u8> {
    let message = message.as_bytes();
    // Cap at MAX_PAYLOAD_LEN-1 so the [code, message] payload always fits the
    // u16 length prefix. A long message truncates; the code carries the
    // machine-readable signal clients act on.
    let max_msg = MAX_PAYLOAD_LEN.saturating_sub(1);
    let message = &message[..message.len().min(max_msg)];
    let mut payload = Vec::with_capacity(1 + message.len());
    payload.push(code);
    payload.extend_from_slice(message);
    frame(TYPE_ERROR, &payload)
}

/// Parse an `ERROR` payload into `(code, message)`. Returns `None` only for a
/// payload too short to carry the code byte; an empty message is valid.
pub fn parse_error(payload: &[u8]) -> Option<(u8, String)> {
    let (&code, rest) = payload.split_first()?;
    Some((code, String::from_utf8_lossy(rest).into_owned()))
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

    #[test]
    fn authorize_round_trip() {
        let token = [9u8; SESSION_TOKEN_LEN];
        let mut buf = authorize_frame(token, "phone");
        let f = try_parse_frame(&mut buf).unwrap();
        assert_eq!(f.typ, TYPE_AUTHORIZE);
        assert_eq!(parse_authorize(&f.payload), Some((token, "phone".into())));
    }

    #[test]
    fn error_round_trip() {
        let mut buf = error_frame(ERR_AUTHORIZATION, "not authorised; re-pair");
        let f = try_parse_frame(&mut buf).unwrap();
        assert_eq!(f.typ, TYPE_ERROR);
        assert_eq!(
            parse_error(&f.payload),
            Some((ERR_AUTHORIZATION, "not authorised; re-pair".into()))
        );
        // Empty message is still a valid ERROR frame (the code carries the
        // machine-readable signal).
        let mut buf = error_frame(ERR_PROTOCOL, "");
        let f = try_parse_frame(&mut buf).unwrap();
        assert_eq!(parse_error(&f.payload), Some((ERR_PROTOCOL, String::new())));
    }
}
