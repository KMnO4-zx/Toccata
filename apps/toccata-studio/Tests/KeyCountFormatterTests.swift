import XCTest
@testable import toccata_studio

final class KeyCountFormatterTests: XCTestCase {
    func testKeyPercentagesUseAtMostOneDecimalWithoutTrailingZeros() {
        XCTAssertEqual(Formatters.keyPercentage(count: 54, totalCount: 485), "11.1%")
        XCTAssertEqual(Formatters.keyPercentage(count: 9, totalCount: 485), "1.9%")
        XCTAssertEqual(Formatters.keyPercentage(count: 1, totalCount: 16), "6.3%")
        XCTAssertEqual(Formatters.keyPercentage(count: 1, totalCount: 4), "25%")
        XCTAssertEqual(Formatters.keyPercentage(count: 485, totalCount: 485), "100%")
        XCTAssertEqual(Formatters.keyPercentage(count: 1, totalCount: 10_000), "0%")
    }

    func testKeyPercentagesHandleEmptyInvalidAndLargeCounts() {
        XCTAssertEqual(Formatters.keyPercentage(count: 0, totalCount: 0), "0%")
        XCTAssertEqual(Formatters.keyPercentage(count: 5, totalCount: 0), "0%")
        XCTAssertEqual(Formatters.keyPercentage(count: -1, totalCount: 10), "0%")
        XCTAssertEqual(Formatters.keyPercentage(count: 1, totalCount: -10), "0%")
        XCTAssertEqual(Formatters.keyPercentage(count: 20, totalCount: 10), "100%")
        XCTAssertEqual(Formatters.keyPercentage(count: .max, totalCount: .max), "100%")
        XCTAssertEqual(Formatters.keyPercentage(count: Int.max / 2, totalCount: .max), "50%")
    }

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
