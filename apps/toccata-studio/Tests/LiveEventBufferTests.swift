import XCTest
@testable import toccata_studio

final class LiveEventBufferTests: XCTestCase {
    func testLongFnReleaseKeepsDurationWhenOldDownIsPruned() {
        var buffer = LiveEventBuffer()
        buffer.append(ActivityKeyEvent(timestampMs: 1_000, keycode: 63, kind: 0))
        buffer.append(ActivityKeyEvent(timestampMs: 401_000, keycode: 63, kind: 1))
        XCTAssertEqual(buffer.events.count, 1)
        XCTAssertEqual(buffer.events.last?.holdMs, 400_000)
    }

    func testUnreleasedFnSurvivesRollingHistory() {
        var buffer = LiveEventBuffer()
        buffer.append(ActivityKeyEvent(timestampMs: 1_000, keycode: 63, kind: 0))
        buffer.append(ActivityKeyEvent(timestampMs: 401_000, keycode: 13, kind: 0))
        XCTAssertEqual(ActivityCalculator.openLiveKeys(buffer.events)[63], 1_000)
        buffer.append(ActivityKeyEvent(timestampMs: 402_000, keycode: 63, kind: 1))
        XCTAssertEqual(buffer.events.last?.holdMs, 401_000)
    }

    func testBatchedInputRetainsLongHoldAndPairsReleaseAcrossBatches() {
        var buffer = LiveEventBuffer()
        buffer.append(contentsOf: [
            ActivityKeyEvent(timestampMs: 1_000, keycode: 63, kind: 0),
            ActivityKeyEvent(timestampMs: 2_000, keycode: 13, kind: 0),
            ActivityKeyEvent(timestampMs: 2_050, keycode: 13, kind: 1),
            ActivityKeyEvent(timestampMs: 401_000, keycode: 14, kind: 0)
        ])
        XCTAssertEqual(buffer.events.map(\.timestampMs), [1_000, 401_000])
        XCTAssertEqual(ActivityCalculator.openLiveKeys(buffer.events)[63], 1_000)

        buffer.append(contentsOf: [
            ActivityKeyEvent(timestampMs: 402_000, keycode: 63, kind: 1),
            ActivityKeyEvent(timestampMs: 402_100, keycode: 14, kind: 1)
        ])
        XCTAssertEqual(buffer.events.filter { $0.keycode == 63 }.map(\.holdMs), [401_000])
        XCTAssertEqual(buffer.events.last?.holdMs, 1_100)
        XCTAssertTrue(ActivityCalculator.openLiveKeys(buffer.events).isEmpty)
    }

    func testReconnectCannotPairWithPreviousConnection() {
        var buffer = LiveEventBuffer()
        buffer.append(ActivityKeyEvent(timestampMs: 1_000, keycode: 63, kind: 0))
        buffer.reset()
        buffer.append(ActivityKeyEvent(timestampMs: 10_000, keycode: 63, kind: 1))
        XCTAssertEqual(buffer.events.count, 1)
        XCTAssertNil(buffer.events[0].holdMs)
    }
}
