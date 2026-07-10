import Foundation
import XCTest
@testable import ZukoWire

final class PairingLinkTests: XCTestCase {
    func testParsesPathAndQueryDeepLinks() throws {
        XCTAssertEqual(
            PairingLink.code(from: try XCTUnwrap(URL(string: "zuko://pair/iridescent-hilton"))),
            "iridescent-hilton"
        )
        XCTAssertEqual(
            PairingLink.code(from: try XCTUnwrap(URL(string: "zuko://pair?code=IRIDESCENT%20HILTON"))),
            "IRIDESCENT HILTON"
        )
    }

    func testAcceptsHumanFormatting() {
        XCTAssertEqual(PairingLink.code(from: "  IRIDESCENT HILTON  "), "IRIDESCENT HILTON")
        XCTAssertEqual(PairingLink.code(from: "iridescent_hilton"), "iridescent_hilton")
        XCTAssertEqual(PairingLink.code(from: "iridescenthilton"), "iridescenthilton")
    }

    func testRejectsOtherLinksAndNonASCIIMaterial() throws {
        XCTAssertNil(PairingLink.code(from: try XCTUnwrap(URL(string: "https://example.com/pair/code"))))
        XCTAssertNil(PairingLink.code(from: "zuko://other/iridescent-hilton"))
        XCTAssertNil(PairingLink.code(from: "iridescent/hilton"))
        XCTAssertNil(PairingLink.code(from: "iridescent-123"))
        XCTAssertNil(PairingLink.code(from: "iridescent-hiltön"))
        XCTAssertNil(PairingLink.code(from: String(repeating: "a", count: 129)))
    }
}
