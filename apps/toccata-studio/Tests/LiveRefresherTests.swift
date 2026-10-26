import Combine
import XCTest
@testable import toccata_studio

@MainActor
final class LiveRefresherTests: XCTestCase {
    func testTypingBurstPublishesOneCompleteSnapshotAndOneRefresh() async throws {
        let refresher = LiveRefresher(refreshInterval: 0.01)
        defer { refresher.stop() }
        var snapshots = 0
        var enabledChanges = 0
        var permissionChanges = 0
        let subscriptions = [
            refresher.$liveEvents.dropFirst().sink { _ in snapshots += 1 },
            refresher.$captureEnabled.dropFirst().sink { _ in enabledChanges += 1 },
            refresher.$permissionRequired.dropFirst().sink { _ in permissionChanges += 1 }
        ]
        defer { subscriptions.forEach { $0.cancel() } }
        send(["type": "hello", "capture_enabled": true], to: refresher)
        for index in 0..<1_000 {
            sendKey(timestamp: Int64(index * 10), kind: "down", to: refresher)
            sendKey(timestamp: Int64(index * 10 + 5), kind: "up", to: refresher)
        }
        // Persistence notifications in the same burst do not trigger another render.
        for _ in 0..<10 { send(["type": "updated"], to: refresher) }
        XCTAssertEqual(refresher.liveEvents.count, 0)
        XCTAssertEqual(refresher.generation, 0)

        try await waitForGeneration(1, in: refresher)

        XCTAssertEqual(snapshots, 1)
        XCTAssertEqual(enabledChanges, 1)
        XCTAssertEqual(permissionChanges, 0)
        XCTAssertEqual(refresher.liveEvents.count, 2_000)
        XCTAssertEqual(refresher.liveEvents.filter { $0.kind == 0 }.count, 1_000)
        XCTAssertEqual(refresher.liveEvents.filter { $0.kind == 1 }.map(\.holdMs), Array(repeating: 5, count: 1_000))
        XCTAssertTrue(refresher.isConnected)
    }

    func testUnchangedStatusMessagesDoNotPublishOrRefreshAgain() async throws {
        let refresher = LiveRefresher(refreshInterval: 0.01)
        defer { refresher.stop() }
        send(["type": "hello", "capture_enabled": true], to: refresher)
        try await waitForGeneration(1, in: refresher)
        let notification = expectation(description: "unchanged status must not invalidate views")
        notification.isInverted = true
        let subscription = refresher.objectWillChange.sink { notification.fulfill() }
        defer { subscription.cancel() }
        for _ in 0..<100 {
            send(["type": "hello", "capture_enabled": true], to: refresher)
            send(["type": "capture", "enabled": true, "permission_required": false], to: refresher)
        }

        await fulfillment(of: [notification], timeout: 0.05)

        XCTAssertEqual(refresher.generation, 1)
        XCTAssertTrue(refresher.captureEnabled)
    }

    func testCaptureStateChangeRefreshesWithoutInput() async throws {
        let refresher = LiveRefresher(refreshInterval: 0.01)
        defer { refresher.stop() }
        send(["type": "hello", "capture_enabled": true], to: refresher)
        try await waitForGeneration(1, in: refresher)
        send(["type": "capture", "enabled": false, "permission_required": true], to: refresher)

        try await waitForGeneration(2, in: refresher)

        XCTAssertFalse(refresher.captureEnabled)
        XCTAssertTrue(refresher.permissionRequired)
        XCTAssertTrue(refresher.liveEvents.isEmpty)
    }

    func testStopDiscardsQueuedInputAndScheduledRefresh() async throws {
        let refresher = LiveRefresher(refreshInterval: 0.01)
        let notification = expectation(description: "stopped refresher must not publish queued data")
        notification.isInverted = true
        let subscription = refresher.objectWillChange.sink { notification.fulfill() }
        defer { subscription.cancel() }
        sendKey(timestamp: 1_000, kind: "down", to: refresher)
        refresher.stop()

        await fulfillment(of: [notification], timeout: 0.05)

        XCTAssertTrue(refresher.liveEvents.isEmpty)
        XCTAssertEqual(refresher.generation, 0)
    }

    private func sendKey(timestamp: Int64, kind: String, to refresher: LiveRefresher) {
        send(["type": "key", "ts": timestamp, "keycode": 63, "kind": kind], to: refresher)
    }

    private func send(_ payload: [String: Any], to refresher: LiveRefresher) {
        refresher.receive(try! JSONSerialization.data(withJSONObject: payload))
    }

    private func waitForGeneration(_ generation: Int, in refresher: LiveRefresher) async throws {
        let deadline = Date().addingTimeInterval(1)
        while refresher.generation < generation && Date() < deadline {
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertEqual(refresher.generation, generation)
    }
}
