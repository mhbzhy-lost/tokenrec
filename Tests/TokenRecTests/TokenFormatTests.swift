import XCTest
@testable import TokenRec

final class TokenFormatTests: XCTestCase {
    func testHundredMillionUsesE() {
        XCTAssertEqual(TokenFormat.compact(100_000_000), "1.0E")
        XCTAssertEqual(TokenFormat.compact(498_635_239), "5.0E")
        XCTAssertEqual(TokenFormat.compact(682_700_000), "6.8E")
    }

    func testMillionUsesM() {
        XCTAssertEqual(TokenFormat.compact(1_000_000), "1.0M")
        XCTAssertEqual(TokenFormat.compact(68_270_000), "68.3M")
    }

    func testThousandUsesK() {
        XCTAssertEqual(TokenFormat.compact(1_000), "1.0K")
        XCTAssertEqual(TokenFormat.compact(24_500), "24.5K")
    }

    func testSmallValuesRaw() {
        XCTAssertEqual(TokenFormat.compact(0), "0")
        XCTAssertEqual(TokenFormat.compact(500), "500")
        XCTAssertEqual(TokenFormat.compact(999), "999")
    }
}
