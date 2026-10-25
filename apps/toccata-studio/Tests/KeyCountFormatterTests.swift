import XCTest
@testable import toccata_studio

final class KeyCountFormatterTests: XCTestCase {
    func testCountsBelowOneThousandKeepTheirExactDigits() {
        XCTAssertEqual(Formatters.keyCount(-1), "0")
        XCTAssertEqual(Formatters.keyCount(0), "0")
        XCTAssertEqual(Formatters.keyCount(356), "356")
        XCTAssertEqual(Formatters.keyCount(999), "999")
    }

    func testThousandsUseAtMostTwoDecimalPlacesWithoutTrailingZeros() {
        XCTAssertEqual(Formatters.keyCount(1_000), "1K")
        XCTAssertEqual(Formatters.keyCount(1_004), "1K")
        XCTAssertEqual(Formatters.keyCount(1_005), "1.01K")
        XCTAssertEqual(Formatters.keyCount(1_050), "1.05K")
        XCTAssertEqual(Formatters.keyCount(1_100), "1.1K")
        XCTAssertEqual(Formatters.keyCount(1_999), "2K")
        XCTAssertEqual(Formatters.keyCount(10_328), "10.33K")
    }

    func testLargeCountsRemainInThousandsWithoutOverflow() {
        XCTAssertEqual(Formatters.keyCount(1_000_000), "1000K")
        XCTAssertEqual(Formatters.keyCount(.max), "9223372036854775.81K")
        XCTAssertEqual(Formatters.keyCount(.min), "0")
    }
}
