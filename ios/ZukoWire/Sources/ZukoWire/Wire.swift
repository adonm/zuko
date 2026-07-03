import Foundation

/// Wire protocol shared with the host daemon. Each message is:
///
///   [type: u8][len: u16 big-endian][payload: `len` bytes]
///
/// - 0x00 DATA    — raw terminal bytes (keystrokes up, PTY output down)
/// - 0x01 RESIZE  — payload `[cols: u16 BE][rows: u16 BE][pixel_width: u16 BE][pixel_height: u16 BE]`
/// - 0x04 PING    — `[nonce: u64 BE]`, optional control (reply PONG)
/// - 0x05 PONG    — `[nonce: u64 BE]`, optional control
/// - 0x06 ATTACH  — `[token: 16 bytes][cols: u16 BE][rows: u16 BE][pixel_width: u16 BE][pixel_height: u16 BE]`
/// - 0x07 ATTACHED — `[token: 16 bytes]`
/// - 0x08 AUTHORIZE — `[token: 16 bytes][label: UTF-8]`, pairing-only
///
/// New clients open the stream with ATTACH: a 16-byte session token (zero for
/// first attach) plus terminal size. The host replies ATTACHED with the token
/// to reuse on short reconnects. Pixel dimensions are zero on iOS today because
/// GhosttyTerminal owns the surface; the fields still stay present so host-side
/// `zuko app` / PTY sizing stays protocol-compatible with the Rust CLI.
///
/// This mirrors the Rust `src/wire.rs` byte-for-byte; the package's tests pin
/// the layout so the two implementations can't drift (see `docs/PROTOCOL.md`).
public enum Wire {
    public static let data: UInt8 = 0x00
    public static let resize: UInt8 = 0x01
    public static let ping: UInt8 = 0x04
    public static let pong: UInt8 = 0x05
    public static let attach: UInt8 = 0x06
    public static let attached: UInt8 = 0x07
    public static let authorize: UInt8 = 0x08
    public static let maxPayloadLength = Int(UInt16.max)
    public static let sessionTokenLength = 16

    // Sendable so the read pump can hand decoded frames across actor/task
    // boundaries (the off-main `frameStream` producer → main-actor consumer).
    public struct Frame: Equatable, Sendable {
        public let type: UInt8
        public let payload: [UInt8]

        public init(type: UInt8, payload: [UInt8]) {
            self.type = type
            self.payload = payload
        }
    }

    /// Encode one length-prefixed frame ready to write to the stream.
    public static func encode(type: UInt8, payload: Data) -> Data {
        precondition(
            payload.count <= maxPayloadLength,
            "zuko frame payload exceeds u16 length prefix"
        )
        var out = Data(capacity: 3 + payload.count)
        out.append(type)
        let len = UInt16(payload.count)
        out.append(UInt8((len >> 8) & 0xFF))
        out.append(UInt8(len & 0xFF))
        out.append(payload)
        return out
    }

    public static func encodeResize(
        cols: UInt16,
        rows: UInt16,
        pixelWidth: UInt16 = 0,
        pixelHeight: UInt16 = 0
    ) -> Data {
        var payload = Data(capacity: 8)
        payload.append(UInt8((cols >> 8) & 0xFF))
        payload.append(UInt8(cols & 0xFF))
        payload.append(UInt8((rows >> 8) & 0xFF))
        payload.append(UInt8(rows & 0xFF))
        payload.append(UInt8((pixelWidth >> 8) & 0xFF))
        payload.append(UInt8(pixelWidth & 0xFF))
        payload.append(UInt8((pixelHeight >> 8) & 0xFF))
        payload.append(UInt8(pixelHeight & 0xFF))
        return encode(type: resize, payload: payload)
    }

    public static func encodeAttach(
        token: Data,
        cols: UInt16,
        rows: UInt16,
        pixelWidth: UInt16 = 0,
        pixelHeight: UInt16 = 0
    ) -> Data {
        precondition(token.count == sessionTokenLength, "zuko session token must be 16 bytes")
        var payload = Data(capacity: sessionTokenLength + 8)
        payload.append(token)
        payload.append(UInt8((cols >> 8) & 0xFF))
        payload.append(UInt8(cols & 0xFF))
        payload.append(UInt8((rows >> 8) & 0xFF))
        payload.append(UInt8(rows & 0xFF))
        payload.append(UInt8((pixelWidth >> 8) & 0xFF))
        payload.append(UInt8(pixelWidth & 0xFF))
        payload.append(UInt8((pixelHeight >> 8) & 0xFF))
        payload.append(UInt8(pixelHeight & 0xFF))
        return encode(type: attach, payload: payload)
    }

    public static func encodeAuthorize(token: Data, label: String) -> Data {
        precondition(token.count == sessionTokenLength, "zuko session token must be 16 bytes")
        let maxLabelBytes = maxPayloadLength - sessionTokenLength
        let labelBytes = Data(label.utf8).prefix(maxLabelBytes)
        var payload = Data(capacity: sessionTokenLength + labelBytes.count)
        payload.append(token)
        payload.append(labelBytes)
        return encode(type: authorize, payload: payload)
    }

    public static func isControlFrame(_ frame: Data) -> Bool {
        guard let type = frame.first else { return false }
        return type == resize || type == ping || type == pong
    }

    public static func parseAttached(_ payload: [UInt8]) -> Data? {
        guard payload.count == sessionTokenLength else { return nil }
        return Data(payload)
    }

    /// Try to pull one complete frame off the front of `buffer`, draining it.
    /// Returns nil when there aren't enough bytes yet.
    public static func parse(_ buffer: inout Data) -> Frame? {
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
