import Foundation

/// Streaming decoder for the length-prefixed wire framing (see `Wire`).
///
/// `Wire.parse(&buffer)` drains the consumed bytes from the front of the buffer
/// on every frame, so feeding a fast stream (`cat bigfile`, `yes`) one frame at
/// a time is O(n²): each `removeSubrange(front)` memmoves the entire remaining
/// tail. `FrameDecoder` instead keeps a read cursor and only compacts the
/// buffer once the consumed prefix grows past a threshold — amortised O(1) per
/// byte, with the memmove cost paid at most once per `compactThreshold` bytes.
///
/// Like `Wire.parse`, all indexing is relative to `buffer.startIndex` so a
/// sliced/offset `Data` can never trap (TestFlight crash CDCE664B).
public struct FrameDecoder {
    /// Accumulated, not-yet-fully-consumed bytes. The live window is
    /// `[startIndex + readCursor ..< endIndex]`.
    private var buffer = Data()
    /// Bytes already handed out as frames, measured from `buffer.startIndex`.
    private var readCursor = 0
    /// Compact (drop the consumed prefix) once the cursor passes this many
    /// bytes, so the leading dead bytes can't grow unbounded on a long stream.
    private let compactThreshold: Int

    public init(compactThreshold: Int = 64 * 1024) {
        self.compactThreshold = max(compactThreshold, 1)
    }

    /// Append a freshly-read chunk to the decode buffer.
    public mutating func append(_ chunk: Data) {
        buffer.append(chunk)
    }

    /// Pull the next complete frame, or nil if the buffer doesn't hold a whole
    /// frame yet. Drain in a `while let` loop after each `append`.
    public mutating func next() -> Wire.Frame? {
        let available = buffer.count - readCursor
        guard available >= 3 else {
            compactIfNeeded()
            return nil
        }
        let base = buffer.startIndex + readCursor
        let type = buffer[base]
        let len = (Int(buffer[base + 1]) << 8) | Int(buffer[base + 2])
        guard available >= 3 + len else {
            compactIfNeeded()
            return nil
        }
        let payloadStart = base + 3
        let payloadEnd = payloadStart + len
        let payload = Array(buffer[payloadStart..<payloadEnd])
        readCursor += 3 + len
        return Wire.Frame(type: type, payload: payload)
    }

    /// Number of bytes buffered but not yet consumed (for tests / back-pressure).
    public var pendingByteCount: Int { buffer.count - readCursor }

    /// Drop the already-consumed prefix when it has grown large, resetting the
    /// cursor. A no-op until the threshold so the common case (small steady
    /// state) never memmoves.
    private mutating func compactIfNeeded() {
        guard readCursor >= compactThreshold else { return }
        buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + readCursor))
        readCursor = 0
    }
}
