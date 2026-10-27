import Combine
import XCTest
@testable import toccata_studio

final class LiveKeyboardStateTests: XCTestCase {
    func testEveryVisibleKeySupportsTapHoldReleaseAndRepeatFeedback() throws {
        let layout = KeyboardLayout.magicKeyboard
        XCTAssertEqual(layout.keys.count, 78)
        for item in layout.keys {
            let code = try XCTUnwrap(item.code, item.id)
            var state = LiveKeyboardState()
            state.receive(key(code, .down, 1_000), at: 1)
            XCTAssertEqual(state.pressedKeys, [code], item.readableLabel)
            XCTAssertEqual(state.visibleBubbles(at: 1.1).map(\.keycode), [code], item.readableLabel)
            state.receive(key(code, .up, 1_030), at: 1.03)
            state.advance(to: 1.6)
            XCTAssertFalse(state.hasEffects, item.readableLabel)

            state.receive(key(code, .down, 2_000), at: 2)
            state.advance(to: 3)
            XCTAssertEqual(state.pressedKeys, [code], item.readableLabel)
            XCTAssertEqual(state.presses[code]?.startedAt, 2, item.readableLabel)
            XCTAssertTrue(state.visibleBubbles(at: 3).isEmpty, item.readableLabel)
            state.receive(key(code, .up, 3_100), at: 3.1)
            XCTAssertTrue(state.presses.isEmpty, item.readableLabel)
            XCTAssertEqual(state.visibleBubbles(at: 3.1).map(\.keycode), [code], item.readableLabel)
            state.advance(to: 3.7)
            XCTAssertFalse(state.hasEffects, item.readableLabel)
        }
    }

    func testBothCommandKeysRemainIndependentThroughOverlappingHolds() {
        var state = LiveKeyboardState()
        state.receive(key(55, .down, 1_000), at: 1)
        state.receive(key(54, .down, 1_050), at: 1.05)
        state.advance(to: 2)
        XCTAssertEqual(state.pressedKeys, [55, 54])
        state.receive(key(55, .up, 2_100), at: 2.1)
        XCTAssertEqual(state.pressedKeys, [54])
        XCTAssertEqual(state.visibleBubbles(at: 2.1).map(\.keycode), [55])
        state.receive(key(54, .up, 2_200), at: 2.2)
        XCTAssertTrue(state.pressedKeys.isEmpty)
        XCTAssertEqual(Set(state.visibleBubbles(at: 2.2).map(\.keycode)), [55, 54])
    }

    func testQuickTapHasOneBubbleAndRemainsVisibleForMinimumPressDuration() {
        var state = LiveKeyboardState()
        state.receive(key(0, .down, 1_000), at: 1)
        state.receive(key(0, .up, 1_020), at: 1.02)
        XCTAssertEqual(state.pressedKeys, [0])
        XCTAssertEqual(state.visibleBubbles(at: 1.02).count, 1)
        state.advance(to: 1.121)
        XCTAssertTrue(state.pressedKeys.isEmpty)
        XCTAssertEqual(state.visibleBubbles(at: 1.49).count, 1)
        state.advance(to: 1.5)
        XCTAssertFalse(state.hasEffects)
    }

    func testIndependentChordHoldsAndReleases() {
        var state = LiveKeyboardState()
        state.receive(key(55, .down, 1_000), at: 1)
        state.receive(key(56, .down, 1_050), at: 1.05)
        state.receive(key(0, .down, 1_070), at: 1.07)
        state.receive(key(0, .up, 1_100), at: 1.1)
        state.advance(to: 1.21)
        XCTAssertEqual(state.pressedKeys, [55, 56])
        state.receive(key(55, .up, 1_600), at: 1.6)
        XCTAssertEqual(state.pressedKeys, [56])
        XCTAssertEqual(state.visibleBubbles(at: 1.6).map(\.keycode), [55])
        XCTAssertNotNil(state.presses[56])
    }

    func testLongPressReplacesInitialBubbleAndAddsOneReleaseBubble() {
        var state = LiveKeyboardState()
        state.receive(key(63, .down, 1_000), at: 1)
        XCTAssertTrue(state.visibleBubbles(at: 1.36).isEmpty)
        state.advance(to: 30)
        XCTAssertEqual(state.presses[63]?.startedAt, 1)
        XCTAssertTrue(state.hasEffects)
        state.receive(key(63, .up, 30_000), at: 30)
        XCTAssertTrue(state.presses.isEmpty)
        XCTAssertEqual(state.visibleBubbles(at: 30).count, 1)
        state.advance(to: 30.5)
        XCTAssertFalse(state.hasEffects)
    }

    func testDuplicateDownDoesNotRestartHoldOrAddBubbles() {
        var state = LiveKeyboardState()
        state.receive(key(14, .down, 1_000), at: 1)
        state.receive(key(14, .down, 1_100), at: 1.1)
        XCTAssertEqual(state.bubbles.count, 1)
        XCTAssertEqual(state.presses[14]?.startedAt, 1)
        XCTAssertEqual(state.presses[14]?.timestampMs, 1_000)
    }

    func testRepeatedTapsPushOlderBubblesAndBoundTheirNumber() {
        var state = LiveKeyboardState()
        for index in 0..<8 {
            let time = 1 + Double(index) * 0.05
            let timestamp = Int64(time * 1_000)
            state.receive(key(0, .down, timestamp), at: time)
            state.receive(key(0, .up, timestamp + 10), at: time + 0.01)
        }
        XCTAssertEqual(state.bubbles.count, LiveKeyboardState.bubblesPerKey)
        XCTAssertEqual(Set(state.bubbles.map(\.id)).count, state.bubbles.count)
        XCTAssertGreaterThan(state.bubbles[0].displacement(at: 1.4), 0)
        XCTAssertEqual(state.bubbles.last?.pushTo, 0)
        state.advance(to: 1.86)
        XCTAssertFalse(state.hasEffects)
    }

    func testOrphanStaleReleaseAndUnknownEventsDoNotCreateFeedback() {
        var state = LiveKeyboardState()
        state.receive(key(0, .up, 900), at: 0.9)
        state.receive(key(900, .down, 1_000), at: 1)
        state.receive(ActivityKeyEvent(timestampMs: 1_000, keycode: 0, kind: 9), at: 1)
        XCTAssertFalse(state.hasEffects)
        state.receive(key(0, .down, 2_000), at: 2)
        state.receive(key(0, .up, 1_900), at: 2.01)
        XCTAssertNotNil(state.presses[0])
    }

    private enum Kind { case down, up }
    private func key(_ code: Int, _ kind: Kind, _ timestamp: Int64) -> ActivityKeyEvent {
        ActivityKeyEvent(timestampMs: timestamp, keycode: code, kind: kind == .down ? 0 : 1)
    }
}

@MainActor
final class LiveKeyboardFeedbackTests: XCTestCase {
    func testSocketProtocolDeliversEveryLayoutKeyIncludingModifiersAndFunctionKeys() async throws {
        let refresher = LiveRefresher(refreshInterval: 1)
        let feedback = LiveKeyboardFeedback()
        defer { feedback.disconnect(); refresher.stop() }
        feedback.connect(to: refresher.keyboardUpdates.eraseToAnyPublisher())
        let codes = Set(KeyboardLayout.magicKeyboard.keys.compactMap(\.code))
        for code in codes { sendKey(code, down: true, to: refresher) }
        try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertEqual(feedback.state.pressedKeys, codes)
        XCTAssertEqual(Set(feedback.state.bubbles.map(\.keycode)), codes)
        XCTAssertTrue(refresher.liveEvents.isEmpty)
        for code in codes { sendKey(code, down: false, to: refresher) }
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(feedback.state.pressedKeys.isEmpty)
        XCTAssertEqual(feedback.state.bubbles.count, codes.count)
    }

    func testFeedbackArrivesBeforeStatisticsBatchAndStopsWhenHidden() async throws {
        let refresher = LiveRefresher(refreshInterval: 1)
        let feedback = LiveKeyboardFeedback()
        defer { feedback.disconnect(); refresher.stop() }
        feedback.connect(to: refresher.keyboardUpdates.eraseToAnyPublisher())
        sendKey(0, down: true, to: refresher)
        try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertEqual(feedback.state.pressedKeys, [0])
        XCTAssertTrue(refresher.liveEvents.isEmpty)
        XCTAssertEqual(refresher.generation, 0)

        feedback.disconnect()
        sendKey(1, down: true, to: refresher)
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertFalse(feedback.state.hasEffects)
        feedback.connect(to: refresher.keyboardUpdates.eraseToAnyPublisher())
        sendKey(1, down: false, to: refresher) // No replay of input while hidden.
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertFalse(feedback.state.hasEffects)
    }

    func testCaptureLossAndStopClearHeldKeysWithoutReleaseBubble() async throws {
        let refresher = LiveRefresher()
        let feedback = LiveKeyboardFeedback()
        defer { feedback.disconnect(); refresher.stop() }
        feedback.connect(to: refresher.keyboardUpdates.eraseToAnyPublisher())
        sendKey(63, down: true, to: refresher)
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertFalse(feedback.state.presses.isEmpty)
        refresher.receive(Data(#"{"type":"capture","enabled":false}"#.utf8))
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertFalse(feedback.state.hasEffects)
        sendKey(0, down: true, to: refresher)
        try await Task.sleep(nanoseconds: 20_000_000)
        refresher.stop()
        sendKey(1, down: true, to: refresher)
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertFalse(feedback.state.hasEffects)
    }

    func testShortTapExpiresAndReleasesRenderingClock() async throws {
        let refresher = LiveRefresher()
        let feedback = LiveKeyboardFeedback()
        defer { feedback.disconnect(); refresher.stop() }
        feedback.connect(to: refresher.keyboardUpdates.eraseToAnyPublisher())
        sendKey(127, down: true, to: refresher)
        sendKey(127, down: false, to: refresher)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(feedback.state.bubbles.count, 1)
        try await Task.sleep(nanoseconds: 550_000_000)
        XCTAssertFalse(feedback.state.hasEffects)
    }

    private func sendKey(_ code: Int, down: Bool, to refresher: LiveRefresher) {
        refresher.receive(try! JSONSerialization.data(withJSONObject: [
            "type": "key", "keycode": code, "kind": down ? "down" : "up", "ts": down ? 1_000 : 1_020
        ]))
    }
}
