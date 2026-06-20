//! Wire protocol shared by the host and client (and the iOS app).
//!
//! One bidirectional Iroh stream, ALPN [`ALPN`] = `zuko/1`. Every message is
//! length-prefixed so resize and data stay ordered and nothing leaks into the
//! terminal as in-band escape sequences:
//!
//! ```text
//! [type: u8][len: u16 big-endian][payload: `len` bytes]
//!   0x00 DATA   payload = raw terminal bytes (keystrokes up, PTY output down)
//!   0x01 RESIZE payload = [cols: u16 BE][rows: u16 BE]   (client -> host)
//! ```

/// ALPN used for every zuko stream.
pub const ALPN: &[u8] = b"zuko/1";

pub const TYPE_DATA: u8 = 0x00;
pub const TYPE_RESIZE: u8 = 0x01;

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
}
