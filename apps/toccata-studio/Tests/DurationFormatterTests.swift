import XCTest
@testable import toccata_studio

final class DurationFormatterTests: XCTestCase {
    func testShortDurationsStayInSecondsWithAtMostOneDecimal() {
        XCTAssertEqual(Formatters.duration(ms: 0), "0秒")
        XCTAssertEqual(Formatters.duration(ms: 99), "0秒")
        XCTAssertEqual(Formatters.duration(ms: 100), "0.1秒")
        XCTAssertEqual(Formatters.duration(ms: 5_000), "5秒")
        XCTAssertEqual(Formatters.duration(ms: 60_000), "60秒")
        XCTAssertEqual(Formatters.duration(ms: 362_799), "362.7秒")
    }

    func testTenMinuteBoundaryDoesNotRoundUpFromSeconds() {
        XCTAssertEqual(Formatters.duration(ms: 599_999), "599.9秒")
        XCTAssertEqual(Formatters.duration(ms: 600_000), "10分0秒")
        XCTAssertEqual(Formatters.duration(ms: 636_000), "10分36秒")
        XCTAssertEqual(Formatters.duration(ms: 672_999), "11分12秒")
    }

    func testHourBoundaryKeepsMinutesAndSeconds() {
        XCTAssertEqual(Formatters.duration(ms: 3_599_999), "59分59秒")
        XCTAssertEqual(Formatters.duration(ms: 3_600_000), "1小时0分0秒")
        XCTAssertEqual(Formatters.duration(ms: 5_772_000), "1小时36分12秒")
        XCTAssertEqual(Formatters.duration(ms: 90_061_000), "25小时1分1秒")
    }

    func testNegativeAndLargestDurationsAreSafe() {
        XCTAssertEqual(Formatters.duration(ms: -1), "0秒")
        XCTAssertEqual(Formatters.duration(ms: .min), "0秒")
        XCTAssertEqual(Formatters.duration(ms: .max), "2562047788015小时12分55秒")
    }
}
