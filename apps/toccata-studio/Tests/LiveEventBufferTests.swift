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

    func testReconnectCannotPairWithPreviousConnection() {
        var buffer = LiveEventBuffer()
        buffer.append(ActivityKeyEvent(timestampMs: 1_000, keycode: 63, kind: 0))
        buffer.reset()
        buffer.append(ActivityKeyEvent(timestampMs: 10_000, keycode: 63, kind: 1))
        XCTAssertEqual(buffer.events.count, 1)
        XCTAssertNil(buffer.events[0].holdMs)
    }
}
