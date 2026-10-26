import XCTest
@testable import toccata_studio

final class KeyboardUsageRankingTests: XCTestCase {
    func testTopThreeUsesPositiveCountsAndKeepsExactTotals() {
        let entries = KeyboardUsageRanking.topThree(counts: [
            49: 4_281, 14: 1_234, 51: 1_008, 0: 999, 53: 0, 12: -1
        ])
        XCTAssertEqual(entries.map(\.keycode), [49, 14, 51])
        XCTAssertEqual(entries.map(\.count), [4_281, 1_234, 1_008])
        XCTAssertEqual(entries.map(\.name), ["空格", "E", "退格"])
    }

    func testTiesHaveStableOrderingRegardlessOfDictionaryInsertionOrder() {
        let forward = Dictionary(uniqueKeysWithValues: [49, 14, 51, 0].map { ($0, 25) })
        let backward = Dictionary(uniqueKeysWithValues: [0, 51, 14, 49].map { ($0, 25) })
        XCTAssertEqual(KeyboardUsageRanking.topThree(counts: forward),
                       KeyboardUsageRanking.topThree(counts: backward))
        XCTAssertEqual(KeyboardUsageRanking.topThree(counts: forward).map(\.keycode), [0, 14, 49])
    }

    func testEmptyAndPartialRankingsDoNotInventKeys() {
        XCTAssertTrue(KeyboardUsageRanking.topThree(counts: [:]).isEmpty)
        XCTAssertTrue(KeyboardUsageRanking.topThree(counts: [49: 0, 14: -1]).isEmpty)
        let entries = KeyboardUsageRanking.topThree(counts: [55: 100, 54: 10])
        XCTAssertEqual(entries.map(\.name), ["左 Command", "右 Command"])
        XCTAssertEqual(entries.map(\.count), [100, 10])
    }

    func testFnAndUnmappedKeysRemainVisibleWithTheirCounts() {
        let entries = KeyboardUsageRanking.topThree(counts: [63: 12, 999: 7])
        XCTAssertEqual(entries.map(\.name), ["Fn / 地球键", "Key999"])
        XCTAssertEqual(entries.map(\.count), [12, 7])
    }
}
