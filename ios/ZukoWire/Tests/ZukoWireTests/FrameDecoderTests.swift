import XCTest

@testable import ZukoWire

/// `FrameDecoder` must yield exactly the same frames as `Wire.parse`, but
/// without the per-frame front-drain, and must survive sliced/offset buffers.
final class FrameDecoderTests: XCTestCase {
    func testYieldsNothingUntilWholeFrameArrives() {
        var decoder = FrameDecoder()
        let frame = Wire.encode(type: Wire.data, payload: Data("abc".utf8))
        decoder.append(frame.prefix(frame.count - 1))  // one byte short
        XCTAssertNil(decoder.next())
        decoder.append(frame.suffix(1))  // the missing byte
        XCTAssertEqual(decoder.next(), Wire.Frame(type: Wire.data, payload: Array("abc".utf8)))
        XCTAssertNil(decoder.next())
        XCTAssertEqual(decoder.pendingByteCount, 0)
    }

    func testDrainsManyBackToBackFramesInOrder() {
        var decoder = FrameDecoder()
        for index in 0..<500 {
            decoder.append(Wire.encode(type: Wire.data, payload: Data([UInt8(index & 0xFF)])))
        }
        var seen = 0
        while let frame = decoder.next() {
            XCTAssertEqual(frame.payload, [UInt8(seen & 0xFF)])
            seen += 1
        }
        XCTAssertEqual(seen, 500)
        XCTAssertEqual(decoder.pendingByteCount, 0)
    }

    func testFrameSplitAcrossManyChunks() {
        var decoder = FrameDecoder()
        let frame = Wire.encodeAttach(token: Data((0..<16).map { UInt8($0) }), cols: 80, rows: 24)
        // Feed one byte at a time; only the final byte completes the frame.
        for (offset, byte) in frame.enumerated() {
            decoder.append(Data([byte]))
            if offset < frame.count - 1 {
                XCTAssertNil(decoder.next(), "incomplete at byte \(offset)")
            }
        }
        XCTAssertEqual(decoder.next()?.type, Wire.attach)
    }

    /// Compaction must not corrupt or drop frames: push well past the
    /// threshold so the internal `removeSubrange` fires repeatedly.
    func testCompactionPreservesFrameStreamAcrossThreshold() {
        var decoder = FrameDecoder(compactThreshold: 64)
        let payload = Data(repeating: 0xAB, count: 20)  // 23 bytes/frame > threshold quickly
        let total = 1000
        var produced = 0
        var consumed = 0
        for _ in 0..<total {
            decoder.append(Wire.encode(type: Wire.data, payload: payload))
            produced += 1
            while let frame = decoder.next() {
                XCTAssertEqual(frame.payload, Array(payload))
                consumed += 1
            }
        }
        XCTAssertEqual(consumed, produced)
        XCTAssertEqual(decoder.pendingByteCount, 0)
    }

    func testHandlesInitialOffsetBuffer() {
        // First append is itself a sliced Data with a non-zero startIndex.
        var decoder = FrameDecoder()
        let frame = Wire.encodeResize(cols: 100, rows: 40)
        let prefixed = Data([0xFF]) + frame
        decoder.append(prefixed[prefixed.index(after: prefixed.startIndex)...])
        XCTAssertEqual(decoder.next()?.type, Wire.resize)
        XCTAssertNil(decoder.next())
    }
}
