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
//!   0x02 HELLO   payload = [flags:u8][cols:u16 BE][rows:u16 BE][sid_len:u8][sid]  (client -> host, first frame)
//!   0x03 WELCOME payload = [flags:u8][sid_len:u8][sid]                            (host -> client, first frame)
//!   0x04 PING    payload = [nonce:u64 BE]   (bidirectional, heartbeat)
//!   0x05 PONG    payload = [nonce:u64 BE]   (bidirectional, heartbeat)
//! ```
//!
//! Unknown frame types **must be ignored** — the protocol is designed to gain
//! types over time without breaking old peers.
//!
//! ## Session resume & capabilities (v0.4)
//!
//! The client opens the stream with a single [`TYPE_HELLO`] carrying its
//! capability flags, its current terminal size, and an optional session id to
//! resume. The host replies with [`TYPE_WELCOME`] carrying its own flags and the
//! session id it'll use (newly minted for a fresh session, or the resumed id).
//! If the host supports resume and the client sent an id, the host replays the
//! session's recent-output ring buffer as `DATA` frames immediately after
//! `WELCOME`, then live-feeds new PTY output. See `docs/PROTOCOL.md`.
//!
//! For graceful interop with a v0.3 peer (which opens with a bare `RESIZE` and
//! knows no `HELLO`/`WELCOME`), the host treats a non-`HELLO` first frame as a
//! legacy handshake: spawn a fresh session at the size it carries (or the
//! default) and skip `WELCOME`. A v0.4 client sending `HELLO` to a v0.3 host
//! has its `HELLO` ignored as an unknown type; the host spawns at the default
//! size and the client's first layout-pass `RESIZE` corrects it.

use anyhow::{anyhow, bail, Result};

/// ALPN used for every zuko stream.
pub const ALPN: &[u8] = b"zuko/1";

pub const TYPE_DATA: u8 = 0x00;
pub const TYPE_RESIZE: u8 = 0x01;
pub const TYPE_HELLO: u8 = 0x02;
pub const TYPE_WELCOME: u8 = 0x03;
pub const TYPE_PING: u8 = 0x04;
pub const TYPE_PONG: u8 = 0x05;

// ───────────────────────── capability flags ───────────────────────────────

/// `HELLO`/`WELCOME` flag bits.
pub const FLAG_RESUME: u8 = 1 << 0;
pub const FLAG_HEARTBEAT: u8 = 1 << 1;
/// `WELCOME`-only: this is a resumed session (ring buffer was replayed).
pub const FLAG_RESUMED: u8 = 1 << 2;

/// A session id — 8 random bytes the host mints per session and the client
/// echoes back to resume. Not a secret: the ticket already gates access, so
/// anyone holding it can resume any of the host's sessions (a deliberate
/// simplification — same trust boundary as mosh's key).
pub type SessionId = [u8; 8];
pub const SESSION_ID_LEN: usize = 8;

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

// ─────────────────────────── HELLO ────────────────────────────────────────

/// Parsed `HELLO` payload.
pub struct Hello {
    pub flags: u8,
    pub cols: u16,
    pub rows: u16,
    /// `None` = start a fresh session; `Some(id)` = resume.
    pub session_id: Option<SessionId>,
}

impl Hello {
    pub fn encode(&self) -> Vec<u8> {
        let mut p = Vec::with_capacity(1 + 2 + 2 + 1 + SESSION_ID_LEN);
        p.push(self.flags);
        p.extend_from_slice(&self.cols.to_be_bytes());
        p.extend_from_slice(&self.rows.to_be_bytes());
        if let Some(id) = self.session_id {
            p.push(SESSION_ID_LEN as u8);
            p.extend_from_slice(&id);
        } else {
            p.push(0);
        }
        p
    }

    /// Build the `HELLO` frame (type + len-prefixed payload).
    pub fn frame(&self) -> Vec<u8> {
        frame(TYPE_HELLO, &self.encode())
    }

    pub fn decode(payload: &[u8]) -> Result<Self> {
        if payload.len() < 6 {
            bail!("HELLO too short ({} bytes)", payload.len());
        }
        let flags = payload[0];
        let cols = u16::from_be_bytes([payload[1], payload[2]]);
        let rows = u16::from_be_bytes([payload[3], payload[4]]);
        let sid_len = payload[5] as usize;
        if sid_len != 0 && sid_len != SESSION_ID_LEN {
            bail!("HELLO sid_len {sid_len} is neither 0 nor {SESSION_ID_LEN}");
        }
        if payload.len() != 6 + sid_len {
            bail!(
                "HELLO length mismatch: header says {sid_len}, got {}",
                payload.len() - 6
            );
        }
        let session_id = if sid_len == 0 {
            None
        } else {
            let mut id = [0u8; SESSION_ID_LEN];
            id.copy_from_slice(&payload[6..6 + SESSION_ID_LEN]);
            Some(id)
        };
        Ok(Self {
            flags,
            cols,
            rows,
            session_id,
        })
    }
}

// ─────────────────────────── WELCOME ──────────────────────────────────────

/// Parsed `WELCOME` payload.
pub struct Welcome {
    pub flags: u8,
    pub session_id: Option<SessionId>,
}

impl Welcome {
    pub fn encode(&self) -> Vec<u8> {
        let mut p = Vec::with_capacity(1 + 1 + SESSION_ID_LEN);
        p.push(self.flags);
        if let Some(id) = self.session_id {
            p.push(SESSION_ID_LEN as u8);
            p.extend_from_slice(&id);
        } else {
            p.push(0);
        }
        p
    }

    pub fn frame(&self) -> Vec<u8> {
        frame(TYPE_WELCOME, &self.encode())
    }

    pub fn decode(payload: &[u8]) -> Result<Self> {
        if payload.len() < 2 {
            bail!("WELCOME too short ({} bytes)", payload.len());
        }
        let flags = payload[0];
        let sid_len = payload[1] as usize;
        if sid_len != 0 && sid_len != SESSION_ID_LEN {
            bail!("WELCOME sid_len {sid_len} is neither 0 nor {SESSION_ID_LEN}");
        }
        if payload.len() != 2 + sid_len {
            bail!(
                "WELCOME length mismatch: header says {sid_len}, got {}",
                payload.len() - 2
            );
        }
        let session_id = if sid_len == 0 {
            None
        } else {
            let mut id = [0u8; SESSION_ID_LEN];
            id.copy_from_slice(&payload[2..2 + SESSION_ID_LEN]);
            Some(id)
        };
        Ok(Self { flags, session_id })
    }

    pub fn resumed(&self) -> bool {
        self.flags & FLAG_RESUMED != 0
    }
}

// ────────────────────────── PING / PONG ───────────────────────────────────

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

    // ── HELLO / WELCOME round trips ──

    #[test]
    fn hello_round_trip_new_session() {
        let h = Hello {
            flags: FLAG_RESUME | FLAG_HEARTBEAT,
            cols: 200,
            rows: 50,
            session_id: None,
        };
        let f = h.frame();
        assert_eq!(f[0], TYPE_HELLO);
        let parsed = Hello::decode(&parse_one(&mut f.clone()).unwrap().payload).unwrap();
        assert_eq!(parsed.flags, h.flags);
        assert_eq!(parsed.cols, 200);
        assert_eq!(parsed.rows, 50);
        assert!(parsed.session_id.is_none());
    }

    #[test]
    fn hello_round_trip_resume() {
        let id: SessionId = [0xAB; 8];
        let h = Hello {
            flags: FLAG_RESUME,
            cols: 80,
            rows: 24,
            session_id: Some(id),
        };
        let mut buf = h.frame();
        let frame = try_parse_frame(&mut buf).unwrap();
        assert_eq!(frame.typ, TYPE_HELLO);
        let parsed = Hello::decode(&frame.payload).unwrap();
        assert_eq!(parsed.session_id, Some(id));
    }

    #[test]
    fn welcome_round_trip_and_resumed_bit() {
        let id: SessionId = [0x11; 8];
        let w = Welcome {
            flags: FLAG_RESUME | FLAG_HEARTBEAT | FLAG_RESUMED,
            session_id: Some(id),
        };
        let mut buf = w.frame();
        assert_eq!(buf[0], TYPE_WELCOME);
        let parsed = Welcome::decode(&try_parse_frame(&mut buf).unwrap().payload).unwrap();
        assert_eq!(parsed.session_id, Some(id));
        assert!(parsed.resumed());
        assert_eq!(parsed.flags & FLAG_RESUME, FLAG_RESUME);
    }

    #[test]
    fn welcome_without_session_id_for_legacy_host() {
        // A host that doesn't support resume sends WELCOME with sid_len=0.
        let w = Welcome {
            flags: 0,
            session_id: None,
        };
        let mut buf = w.frame();
        let parsed = Welcome::decode(&try_parse_frame(&mut buf).unwrap().payload).unwrap();
        assert!(parsed.session_id.is_none());
        assert!(!parsed.resumed());
    }

    #[test]
    fn hello_rejects_truncated_and_bad_sid_len() {
        assert!(Hello::decode(&[0x01, 0, 80, 0, 24]).is_err()); // 5 bytes, < 6
        assert!(Hello::decode(&[0x01, 0, 80, 0, 24, 3]).is_err()); // sid_len=3 invalid
        let mut ok = vec![0x01, 0, 80, 0, 24, 0];
        assert!(Hello::decode(&ok).is_ok());
        ok.push(0xAB); // header said 0 but extra byte present
        assert!(Hello::decode(&ok).is_err());
    }

    #[test]
    fn ping_pong_nonce_round_trip() {
        let mut buf = ping_frame(0xDEADBEEFCAFEBABE);
        let f = try_parse_frame(&mut buf).unwrap();
        assert_eq!(f.typ, TYPE_PING);
        assert_eq!(decode_nonce(&f.payload), 0xDEADBEEFCAFEBABE);

        let mut buf = pong_frame(0x0102030405060708);
        let f = try_parse_frame(&mut buf).unwrap();
        assert_eq!(f.typ, TYPE_PONG);
        assert_eq!(decode_nonce(&f.payload), 0x0102030405060708);

        // Empty-nonce pings are valid (degrade to 0).
        assert_eq!(decode_nonce(&[]), 0);
    }
}
