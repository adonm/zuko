import Foundation

/// Wire protocol shared with the host daemon (v0.6+). Each message is:
///
///   [type: u8][len: u16 big-endian][payload: `len` bytes]
///
/// - 0x00 DATA    — raw terminal bytes (keystrokes up, PTY output down)
/// - 0x01 RESIZE  — payload `[cols: u16 BE][rows: u16 BE]` (client -> host,
///                  also the first frame — acts as the v0.6 handshake)
/// - 0x04 PING    — `[nonce: u64 BE]`, bidirectional (legacy; kept for
///                  backward compat with older peers, ignored by v0.6+)
/// - 0x05 PONG    — `[nonce: u64 BE]`, bidirectional (legacy; same)
///
/// The client opens the stream with a single RESIZE carrying its initial
/// terminal size. The host spawns a fresh PTY at that size and starts
/// streaming. No HELLO/WELCOME exchange, no session ids — each connection
/// gets a new PTY, killed when the connection ends.
enum Wire {
    static let data: UInt8 = 0x00
    static let resize: UInt8 = 0x01
    // 0x02 (HELLO) and 0x03 (WELCOME) were used by v0.4–v0.5 for the
    // session-resume handshake. Removed in v0.6.
    static let ping: UInt8 = 0x04
    static let pong: UInt8 = 0x05

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

        // `Data.removeFirst` does not guarantee that future valid indices start
        // at integer 0. TestFlight crash CDCE664B showed `buffer[0]` trapping
        // here after at least one frame had been drained. Always walk from
        // `startIndex` instead of using absolute integer subscripts.
        let typeIndex = buffer.startIndex
        let lenHighIndex = buffer.index(after: typeIndex)
        let lenLowIndex = buffer.index(after: lenHighIndex)

        let type = buffer[typeIndex]
        let len = (Int(buffer[lenHighIndex]) << 8) | Int(buffer[lenLowIndex])
        guard buffer.count >= 3 + len else { return nil }
        let payloadStart = buffer.index(after: lenLowIndex)
        let payloadEnd = buffer.index(payloadStart, offsetBy: len)
        let payload = Array(buffer[payloadStart..<payloadEnd])
        buffer.removeSubrange(typeIndex..<payloadEnd)
        return Frame(type: type, payload: payload)
    }
}
