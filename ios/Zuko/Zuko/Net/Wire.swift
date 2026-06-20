import Foundation

/// Wire protocol shared with the host daemon. Each message is:
///
///   [type: u8][len: u16 big-endian][payload: `len` bytes]
///
/// - 0x00 DATA    — raw terminal bytes (keystrokes up, PTY output down)
/// - 0x01 RESIZE  — payload `[cols: u16 BE][rows: u16 BE]` (client -> host)
/// - 0x02 HELLO   — client -> host, first frame: caps + size + optional resume id
/// - 0x03 WELCOME — host -> client, first frame: caps + session id + resumed bit
/// - 0x04 PING    — `[nonce: u64 BE]`, bidirectional heartbeat
/// - 0x05 PONG    — `[nonce: u64 BE]`, bidirectional heartbeat
enum Wire {
    static let data: UInt8 = 0x00
    static let resize: UInt8 = 0x01
    static let hello: UInt8 = 0x02
    static let welcome: UInt8 = 0x03
    static let ping: UInt8 = 0x04
    static let pong: UInt8 = 0x05

    // Capability flag bits in HELLO/WELCOME `flags`.
    static let flagResume: UInt8 = 1 << 0
    static let flagHeartbeat: UInt8 = 1 << 1
    /// WELCOME-only: this is a resumed session (ring buffer was replayed).
    static let flagResumed: UInt8 = 1 << 2

    /// Session id length (8 bytes). Matches `wire::SESSION_ID_LEN` in Rust.
    static let sessionIdLen = 8

    struct Frame {
        let type: UInt8
        let payload: [UInt8]
    }

    /// Encode one length-prefixed frame ready to write to the stream.
    static func encode(type: UInt8, payload: Data) -> Data {
        var out = Data(capacity: 3 + payload.count)
        out.append(type)
        let len = UInt16(payload.count)
        out.append(UInt8((len >> 8) & 0xFF))
        out.append(UInt8(len & 0xFF))
        out.append(payload)
        return out
    }

    static func encodeResize(cols: UInt16, rows: UInt16) -> Data {
        var payload = Data(capacity: 4)
        payload.append(UInt8((cols >> 8) & 0xFF))
        payload.append(UInt8(cols & 0xFF))
        payload.append(UInt8((rows >> 8) & 0xFF))
        payload.append(UInt8(rows & 0xFF))
        return encode(type: resize, payload: payload)
    }

    /// Encode a PING/PONG frame carrying an 8-byte nonce.
    static func encodePing(nonce: UInt64) -> Data {
        var payload = Data(capacity: 8)
        for i in (0..<8).reversed() {
            payload.append(UInt8((nonce >> UInt64(i * 8)) & 0xFF))
        }
        return encode(type: ping, payload: payload)
    }
    static func encodePong(nonce: UInt64) -> Data {
        var payload = Data(capacity: 8)
        for i in (0..<8).reversed() {
            payload.append(UInt8((nonce >> UInt64(i * 8)) & 0xFF))
        }
        return encode(type: pong, payload: payload)
    }

    /// Encode a HELLO: `[flags:u8][cols:u16 BE][rows:u16 BE][sid_len:u8][sid]`.
    /// `sessionID` is nil for a fresh session, or 8 bytes to resume.
    static func encodeHello(
        flags: UInt8, cols: UInt16, rows: UInt16, sessionID: Data?
    ) -> Data {
        var payload = Data(capacity: 1 + 2 + 2 + 1 + (sessionID?.count ?? 0))
        payload.append(flags)
        payload.append(UInt8((cols >> 8) & 0xFF))
        payload.append(UInt8(cols & 0xFF))
        payload.append(UInt8((rows >> 8) & 0xFF))
        payload.append(UInt8(rows & 0xFF))
        if let sid = sessionID {
            payload.append(UInt8(sid.count))
            payload.append(sid)
        } else {
            payload.append(0)
        }
        return encode(type: hello, payload: payload)
    }

    /// Decode a WELCOME payload: `[flags:u8][sid_len:u8][sid]`.
    struct Welcome {
        let flags: UInt8
        let sessionID: Data?
        var resumed: Bool { flags & flagResumed != 0 }
    }

    static func decodeWelcome(_ payload: [UInt8]) -> Welcome? {
        guard payload.count >= 2 else { return nil }
        let flags = payload[0]
        let sidLen = Int(payload[1])
        guard sidLen == 0 || sidLen == sessionIdLen else { return nil }
        guard payload.count == 2 + sidLen else { return nil }
        let sid: Data? = sidLen == 0
            ? nil
            : Data(payload[2..<(2 + sidLen)])
        return Welcome(flags: flags, sessionID: sid)
    }

    /// Decode a PING/PONG nonce (8 bytes BE). Returns 0 for an empty payload.
    static func decodeNonce(_ payload: [UInt8]) -> UInt64 {
        guard payload.count >= 8 else { return 0 }
        var nonce: UInt64 = 0
        for byte in payload.prefix(8) {
            nonce = (nonce << 8) | UInt64(byte)
        }
        return nonce
    }

    /// Try to pull one complete frame off the front of `buffer`, draining it.
    /// Returns nil when there aren't enough bytes yet.
    static func parse(_ buffer: inout Data) -> Frame? {
        guard buffer.count >= 3 else { return nil }
        let type = buffer[0]
        let len = (Int(buffer[1]) << 8) | Int(buffer[2])
        guard buffer.count >= 3 + len else { return nil }
        let payload = Array(buffer[3..<(3 + len)])
        buffer.removeFirst(3 + len)
        return Frame(type: type, payload: payload)
    }
}
