import XCTest

@testable import ZukoWire

/// Mirrors the Rust `src/wire.rs` tests so the two protocol implementations
/// can't drift. The byte-layout assertions double as the on-the-wire spec
/// (see `docs/PROTOCOL.md`).
final class WireTests: XCTestCase {
    // MARK: - Round trips

    func testEncodeParseDataRoundTrip() {
        let payload = Data("hello".utf8)
        var buffer = Wire.encode(type: Wire.data, payload: payload)
        let frame = Wire.parse(&buffer)
        XCTAssertEqual(frame, Wire.Frame(type: Wire.data, payload: Array(payload)))
        XCTAssertTrue(buffer.isEmpty, "a fully consumed frame drains the buffer")
    }

    func testResizeRoundTripAndByteLayout() {
        let cols: UInt16 = 0x1234
        let rows: UInt16 = 0x5678
        var buffer = Wire.encodeResize(cols: cols, rows: rows)

        // type(1) + len(2) + payload(8)
        XCTAssertEqual(buffer.count, 11)
        XCTAssertEqual(Array(buffer.prefix(3)), [Wire.resize, 0x00, 0x08])
        // Big-endian cols, rows, then zero pixel dims.
        XCTAssertEqual(
            Array(buffer.suffix(8)),
            [0x12, 0x34, 0x56, 0x78, 0x00, 0x00, 0x00, 0x00]
        )

        let frame = Wire.parse(&buffer)
        XCTAssertEqual(frame?.type, Wire.resize)
        XCTAssertEqual(frame?.payload.count, 8)
    }

    func testAttachRoundTripAndByteLayout() throws {
        let token = Data((0..<16).map { UInt8($0) })
        var buffer = Wire.encodeAttach(token: token, cols: 80, rows: 24)

        XCTAssertEqual(buffer.count, 3 + 16 + 8)
        XCTAssertEqual(buffer.first, Wire.attach)
        let frame = try XCTUnwrap(Wire.parse(&buffer))
        XCTAssertEqual(frame.type, Wire.attach)
        // Token is the first 16 payload bytes; ATTACHED echoes exactly it.
        XCTAssertEqual(Array(frame.payload.prefix(16)), Array(token))
        XCTAssertEqual(Wire.parseAttached(Array(token)), token)
    }

    func testAuthorizeRoundTripAndByteLayout() throws {
        let token = Data((0..<16).map { UInt8($0) })
        var buffer = Wire.encodeAuthorize(token: token, label: "phone")

        XCTAssertEqual(buffer.first, Wire.authorize)
        let frame = try XCTUnwrap(Wire.parse(&buffer))
        XCTAssertEqual(frame.type, Wire.authorize)
        XCTAssertEqual(Array(frame.payload.prefix(16)), Array(token))
        XCTAssertEqual(String(decoding: frame.payload.dropFirst(16), as: UTF8.self), "phone")
    }

    func testErrorRoundTripAndByteLayout() throws {
        var buffer = Wire.encodeError(code: Wire.ErrorCode.authorization, message: "not authorised")

        XCTAssertEqual(buffer.first, Wire.error)
        let frame = try XCTUnwrap(Wire.parse(&buffer))
        XCTAssertEqual(frame.type, Wire.error)
        XCTAssertEqual(frame.payload.first, Wire.ErrorCode.authorization)
        XCTAssertEqual(String(decoding: frame.payload.dropFirst(), as: UTF8.self), "not authorised")

        // Mirror the Rust parser: parseError must agree on code + message.
        let parsed = try XCTUnwrap(Wire.parseError(frame.payload))
        XCTAssertEqual(parsed.code, Wire.ErrorCode.authorization)
        XCTAssertEqual(parsed.message, "not authorised")

        // Empty message is still a valid ERROR frame (the code carries the
        // machine-readable signal).
        var empty = Wire.encodeError(code: Wire.ErrorCode.proto, message: "")
        let emptyFrame = try XCTUnwrap(Wire.parse(&empty))
        let emptyParsed = try XCTUnwrap(Wire.parseError(emptyFrame.payload))
        XCTAssertEqual(emptyParsed.code, Wire.ErrorCode.proto)
        XCTAssertEqual(emptyParsed.message, "")
    }

    // MARK: - Streaming / partial frames

    func testParseReturnsNilUntilWholeFrameArrives() {
        let full = Wire.encode(type: Wire.data, payload: Data("abc".utf8))
        var partial = full.prefix(full.count - 1)  // one byte short
        var slice = Data(partial)
        XCTAssertNil(Wire.parse(&slice), "incomplete frame yields nil and consumes nothing")
        XCTAssertEqual(slice.count, full.count - 1)

        partial = full  // now complete
        var whole = Data(partial)
        XCTAssertNotNil(Wire.parse(&whole))
    }

    func testHeaderPresentButPayloadIncomplete() {
        // Header claims 5 payload bytes but only 2 are present.
        var buffer = Data([Wire.data, 0x00, 0x05, 0xAA, 0xBB])
        XCTAssertNil(Wire.parse(&buffer))
        XCTAssertEqual(buffer.count, 5, "nothing is drained until the frame completes")
    }

    /// Regression for TestFlight crash CDCE664B: a `Data` whose `startIndex`
    /// is non-zero (e.g. a slice left after an earlier frame was drained) made
    /// `parse` trap when it used absolute integer subscripts (`buffer[0]`).
    /// `parse` must walk from `startIndex`.
    ///
    /// Build the offset buffer explicitly (a `Data` slice past a sentinel byte)
    /// so the non-zero `startIndex` holds on every platform — Apple's
    /// Foundation keeps the offset after `removeSubrange`, but Linux's
    /// corelibs Foundation compacts it to 0, which wouldn't exercise the bug.
    func testParseHandlesBufferWithNonZeroStartIndex() {
        let frame = Wire.encodeResize(cols: 100, rows: 40)
        let prefixed = Data([0xFF]) + frame
        var sliced = prefixed[prefixed.index(after: prefixed.startIndex)...]
        XCTAssertNotEqual(sliced.startIndex, 0, "slice keeps a non-zero startIndex")

        // This is the call that crashed pre-fix.
        let parsed = Wire.parse(&sliced)
        XCTAssertEqual(parsed?.type, Wire.resize)
        XCTAssertEqual(parsed?.payload.count, 8)
        XCTAssertTrue(sliced.isEmpty)
    }

    func testParseDrainsTwoBackToBackFramesInOrder() {
        var buffer = Data()
        buffer.append(Wire.encode(type: Wire.data, payload: Data("ab".utf8)))
        buffer.append(Wire.encodeResize(cols: 100, rows: 40))

        let first = Wire.parse(&buffer)
        XCTAssertEqual(first, Wire.Frame(type: Wire.data, payload: Array("ab".utf8)))
        let second = Wire.parse(&buffer)
        XCTAssertEqual(second?.type, Wire.resize)
        XCTAssertTrue(buffer.isEmpty)
    }

    func testParseHandlesManyBackToBackFrames() {
        var buffer = Data()
        for index in 0..<50 {
            buffer.append(Wire.encode(type: Wire.data, payload: Data([UInt8(index)])))
        }
        var seen = 0
        while let frame = Wire.parse(&buffer) {
            XCTAssertEqual(frame.payload, [UInt8(seen)])
            seen += 1
        }
        XCTAssertEqual(seen, 50)
        XCTAssertTrue(buffer.isEmpty)
    }

    // MARK: - Classification helpers

    func testIsControlFrame() {
        XCTAssertTrue(Wire.isControlFrame(Wire.encodeResize(cols: 1, rows: 1)))
        XCTAssertTrue(Wire.isControlFrame(Wire.encode(type: Wire.ping, payload: Data(count: 8))))
        XCTAssertTrue(Wire.isControlFrame(Wire.encode(type: Wire.pong, payload: Data(count: 8))))
        XCTAssertFalse(Wire.isControlFrame(Wire.encode(type: Wire.data, payload: Data("x".utf8))))
        XCTAssertFalse(
            Wire.isControlFrame(Wire.encodeAttach(token: Data(count: 16), cols: 1, rows: 1))
        )
        XCTAssertFalse(Wire.isControlFrame(Data()), "an empty buffer is not a control frame")
    }

    func testParseAttachedRejectsWrongLength() {
        XCTAssertNil(Wire.parseAttached(Array(repeating: 0, count: 15)))
        XCTAssertNil(Wire.parseAttached(Array(repeating: 0, count: 17)))
        XCTAssertNotNil(Wire.parseAttached(Array(repeating: 0, count: 16)))
    }

    func testParseIgnoresUnknownFrameTypeButStillFrames() {
        // An unknown type still frames correctly (the session layer decides to
        // ignore it) — matches the Rust parser, which is type-agnostic.
        var buffer = Wire.encode(type: 0x7F, payload: Data("payload".utf8))
        let frame = Wire.parse(&buffer)
        XCTAssertEqual(frame?.type, 0x7F)
        XCTAssertEqual(frame?.payload, Array("payload".utf8))
    }
}
