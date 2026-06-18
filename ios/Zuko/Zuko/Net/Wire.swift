import Foundation

/// Wire protocol shared with the host daemon. Each message is:
///
///   [type: u8][len: u16 big-endian][payload: `len` bytes]
///
/// - 0x00 DATA   — raw terminal bytes (keystrokes up, PTY output down)
/// - 0x01 RESIZE — payload `[cols: u16 BE][rows: u16 BE]` (client -> host)
enum Wire {
    static let data: UInt8 = 0x00
    static let resize: UInt8 = 0x01

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
