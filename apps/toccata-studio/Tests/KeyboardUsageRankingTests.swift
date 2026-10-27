import XCTest
@testable import toccata_studio

final class KeyboardUsageRankingTests: XCTestCase {
    override func setUp() {
        super.setUp()
        let original = L10n.language
        L10n.language = .simplifiedChinese
        addTeardownBlock { L10n.language = original }
    }

    func testTopFiveUsesPositiveCountsAndKeepsExactTotals() {
        let entries = KeyboardUsageRanking.topFive(counts: [
            49: 4_281, 14: 1_234, 51: 1_008, 0: 999, 1: 50, 2: 40, 53: 0, 12: -1
        ])
        XCTAssertEqual(entries.map(\.keycode), [49, 14, 51, 0, 1])
        XCTAssertEqual(entries.map(\.count), [4_281, 1_234, 1_008, 999, 50])
        XCTAssertEqual(entries.map(\.name), ["空格", "E", "退格", "A", "S"])
    }

    func testTiesHaveStableOrderingRegardlessOfDictionaryInsertionOrder() {
        let forward = Dictionary(uniqueKeysWithValues: [49, 14, 51, 0].map { ($0, 25) })
        let backward = Dictionary(uniqueKeysWithValues: [0, 51, 14, 49].map { ($0, 25) })
        XCTAssertEqual(KeyboardUsageRanking.topFive(counts: forward),
                       KeyboardUsageRanking.topFive(counts: backward))
        XCTAssertEqual(KeyboardUsageRanking.topFive(counts: forward).map(\.keycode), [0, 14, 49, 51])
    }

    func testEmptyAndPartialRankingsDoNotInventKeys() {
        XCTAssertTrue(KeyboardUsageRanking.topFive(counts: [:]).isEmpty)
        XCTAssertTrue(KeyboardUsageRanking.topFive(counts: [49: 0, 14: -1]).isEmpty)
        let entries = KeyboardUsageRanking.topFive(counts: [55: 100, 54: 10])
        XCTAssertEqual(entries.map(\.name), ["左 Command", "右 Command"])
        XCTAssertEqual(entries.map(\.count), [100, 10])
    }

    func testFnAndUnmappedKeysRemainVisibleWithTheirCounts() {
        let entries = KeyboardUsageRanking.topFive(counts: [63: 12, 999: 7])
        XCTAssertEqual(entries.map(\.name), ["Fn / 地球键", "Key999"])
        XCTAssertEqual(entries.map(\.count), [12, 7])
    }
}
