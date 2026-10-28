import Foundation
import SQLite3
import XCTest
@testable import toccata_studio

@MainActor
final class HydrationReminderTests: XCTestCase {
    func testDefaultsAreOptInAndStatusChecksNeverRequestPermission() async {
        let fixture = ReminderFixture()
        defer { fixture.cleanUp() }
        XCTAssertFalse(fixture.controller.isEnabled)
        XCTAssertEqual(fixture.controller.interval, 8_192)
        await fixture.controller.refreshAuthorization()
        await fixture.controller.update(keyCount: 16_384, at: fixture.clock.date)
        XCTAssertEqual(fixture.service.requests, 0)
        XCTAssertTrue(fixture.service.sent.isEmpty)
    }

    func testEnablingRequestsPermissionAndEachBoundaryNotifiesOnce() async {
        let f = ReminderFixture()
        defer { f.cleanUp() }
        f.service.status = .notDetermined
        await f.controller.setEnabled(true)
        XCTAssertEqual(f.service.requests, 1)
        await f.controller.update(keyCount: 8_191, at: f.clock.date)
        XCTAssertTrue(f.service.sent.isEmpty)
        for count in [8_192, 8_192, 8_193, 8_100, 8_192] {
            await f.controller.update(keyCount: count, at: f.clock.date)
        }
        XCTAssertEqual(f.service.sent.count, 1)
        XCTAssertTrue(f.service.sent[0].identifier.hasSuffix(".8192.8192"))
        await f.controller.update(keyCount: 16_384, at: f.clock.date)
        XCTAssertEqual(f.service.sent.count, 2)
        XCTAssertEqual(f.service.requests, 1)
    }

    func testRestartDoesNotReplayDeliveredMilestone() async {
        let f = ReminderFixture()
        defer { f.cleanUp() }
        await f.enableWithBaseline(0)
        await f.controller.update(keyCount: 8_192, at: f.clock.date)
        let restarted = f.makeController()
        XCTAssertTrue(restarted.isEnabled)
        await restarted.update(keyCount: 8_200, at: f.clock.date)
        XCTAssertEqual(f.service.sent.count, 1)
        await restarted.update(keyCount: 16_384, at: f.clock.date)
        XCTAssertEqual(f.service.sent.count, 2)
    }

    func testDayRolloverStartsNewMilestonesAndRejectsStaleCount() async {
        let f = ReminderFixture()
        defer { f.cleanUp() }
        await f.enableWithBaseline(0)
        await f.controller.update(keyCount: 8_192, at: f.clock.date)
        let yesterday = f.clock.date
        f.clock.date = f.calendar.date(byAdding: .day, value: 1, to: yesterday)!
        await f.controller.update(keyCount: 32_768, at: yesterday)
        XCTAssertEqual(f.service.sent.count, 1)
        await f.controller.update(keyCount: 1, at: f.clock.date)
        await f.controller.update(keyCount: 8_192, at: f.clock.date)
        XCTAssertEqual(f.service.sent.count, 2)
        XCTAssertNotEqual(f.service.sent[0].identifier, f.service.sent[1].identifier)
    }

    func testReconnectAcrossSeveralMilestonesSendsOnlyLatest() async {
        let f = ReminderFixture()
        defer { f.cleanUp() }
        await f.enableWithBaseline(100)
        await f.controller.update(keyCount: 30_000, at: f.clock.date)
        XCTAssertEqual(f.service.sent.count, 1)
        XCTAssertTrue(f.service.sent[0].identifier.hasSuffix(".8192.24576"))
        await f.controller.update(keyCount: 30_001, at: f.clock.date)
        await f.controller.update(keyCount: 32_768, at: f.clock.date)
        XCTAssertEqual(f.service.sent.count, 2)
    }

    func testDeniedPermissionDoesNotPromptOnKeysOrReplayAfterGrant() async {
        let f = ReminderFixture()
        defer { f.cleanUp() }
        f.service.status = .denied
        await f.enableWithBaseline(0)
        await f.controller.update(keyCount: 8_192, at: f.clock.date)
        XCTAssertTrue(f.service.sent.isEmpty)
        XCTAssertEqual(f.service.requests, 0)
        f.service.status = .authorized
        await f.controller.update(keyCount: 9_000, at: f.clock.date)
        XCTAssertTrue(f.service.sent.isEmpty)
        await f.controller.update(keyCount: 16_384, at: f.clock.date)
        XCTAssertEqual(f.service.sent.count, 1)
    }

    func testDisableReenableAndIntervalChangeStartAtNextMilestone() async {
        let f = ReminderFixture()
        defer { f.cleanUp() }
        await f.enableWithBaseline(0)
        await f.controller.update(keyCount: 8_192, at: f.clock.date)
        await f.controller.setEnabled(false)
        await f.controller.update(keyCount: 16_384, at: f.clock.date)
        await f.controller.setEnabled(true)
        await f.controller.update(keyCount: 20_000, at: f.clock.date)
        XCTAssertEqual(f.service.sent.count, 1)
        await f.controller.update(keyCount: 24_576, at: f.clock.date)
        XCTAssertEqual(f.service.sent.count, 2)
        f.controller.setInterval(4_096)
        await f.controller.update(keyCount: 25_000, at: f.clock.date)
        XCTAssertEqual(f.service.sent.count, 2)
        await f.controller.update(keyCount: 28_672, at: f.clock.date)
        XCTAssertEqual(f.service.sent.count, 3)
        XCTAssertEqual(f.makeController().interval, 4_096)
    }

    func testFailedSubmissionRemainsRetryableAfterRestart() async {
        let f = ReminderFixture()
        defer { f.cleanUp() }
        await f.enableWithBaseline(0)
        f.service.rejectSend = true
        await f.controller.update(keyCount: 8_192, at: f.clock.date)
        XCTAssertNotNil(f.controller.errorMessage)
        XCTAssertTrue(f.service.sent.isEmpty)
        f.service.rejectSend = false
        let restarted = f.makeController()
        await restarted.update(keyCount: 8_192, at: f.clock.date)
        XCTAssertEqual(f.service.sent.count, 1)
        await restarted.update(keyCount: 8_192, at: f.clock.date)
        XCTAssertEqual(f.service.sent.count, 1)
    }

    func testConcurrentUpdatesCannotDoubleSubmitSameMilestone() async {
        let f = ReminderFixture()
        defer { f.cleanUp() }
        await f.enableWithBaseline(0)
        f.service.sendDelay = 20_000_000
        async let first: Void = f.controller.update(keyCount: 8_192, at: f.clock.date)
        async let second: Void = f.controller.update(keyCount: 8_192, at: f.clock.date)
        _ = await (first, second)
        XCTAssertEqual(f.service.sent.count, 1)
    }

    func testDisablingWhileAuthorizationIsBeingReadPreventsSubmission() async throws {
        let f = ReminderFixture()
        defer { f.cleanUp() }
        await f.enableWithBaseline(0)
        f.service.authorizationDelay = 20_000_000
        let update = Task { await f.controller.update(keyCount: 8_192, at: f.clock.date) }
        try await Task.sleep(nanoseconds: 2_000_000)
        await f.controller.setEnabled(false)
        await update.value
        XCTAssertTrue(f.service.sent.isEmpty)
    }

    func testTestNotificationDoesNotConsumeRealMilestone() async {
        let f = ReminderFixture()
        defer { f.cleanUp() }
        await f.enableWithBaseline(0)
        await f.controller.sendTestNotification()
        XCTAssertTrue(f.service.sent.first?.identifier.hasPrefix("hydration.test.") == true)
        await f.controller.update(keyCount: 8_192, at: f.clock.date)
        XCTAssertEqual(f.service.sent.count, 2)
        XCTAssertTrue(f.service.sent[1].identifier.hasSuffix(".8192.8192"))
    }

    func testBackgroundMonitorCombinesCommittedCountWithLiveKeyWithoutWindow() async throws {
        let data = try ReminderCountDatabase()
        defer { data.cleanUp() }
        let f = ReminderFixture(databaseURL: data.url)
        defer { f.cleanUp() }
        let time = ActivityCalculator.milliseconds(f.clock.date)
        try data.execute("""
            WITH RECURSIVE keys(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM keys WHERE n<8191)
            INSERT INTO key_events SELECT \(time)-10000-n, 0, 0, NULL FROM keys;
            """)
        await f.enableWithBaseline(8_191)
        let refresher = LiveRefresher(refreshInterval: 0.01)
        defer { f.controller.stop(); refresher.stop() }
        f.controller.start(refresher: refresher)
        for payload: [String: Any] in [
            ["type": "hello", "capture_enabled": true],
            ["type": "key", "ts": time - 100, "keycode": 5, "kind": "down"]
        ] {
            refresher.receive(try JSONSerialization.data(withJSONObject: payload))
        }
        let deadline = Date().addingTimeInterval(2)
        while f.service.sent.isEmpty && Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(f.service.sent.count, 1)
        XCTAssertEqual(f.service.requests, 0)
    }

    func testInvalidSavedIntervalFallsBackToDefault() {
        let f = ReminderFixture()
        defer { f.cleanUp() }
        f.defaults.set(-1, forKey: HydrationReminderController.intervalKey)
        let controller = f.makeController()
        XCTAssertEqual(controller.interval, 8_192)
        controller.setInterval(0)
        XCTAssertEqual(controller.interval, 8_192)
    }

    func testIntervalChangeSurvivesRestartBeforeNextSnapshot() async {
        let f = ReminderFixture()
        defer { f.cleanUp() }
        await f.enableWithBaseline(0)
        await f.controller.update(keyCount: 8_192, at: f.clock.date)
        f.controller.setInterval(4_096)
        let restarted = f.makeController()
        await restarted.update(keyCount: 15_000, at: f.clock.date)
        XCTAssertEqual(f.service.sent.count, 1)
        await restarted.update(keyCount: 16_384, at: f.clock.date)
        XCTAssertEqual(f.service.sent.count, 2)
    }
}

@MainActor
private final class ReminderFixture {
    let suite = "Toccata.HydrationTests.\(UUID().uuidString)"
    let defaults: UserDefaults
    let service = MockHydrationNotificationService()
    let clock = ReminderClock()
    let calendar: Calendar
    let databaseURL: URL
    lazy var controller = makeController()

    init(databaseURL: URL = URL(fileURLWithPath: "/unavailable-reminder-test.db")) {
        defaults = UserDefaults(suiteName: suite)!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        self.calendar = calendar
        self.databaseURL = databaseURL
        clock.date = calendar.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: 12))!
    }

    func makeController() -> HydrationReminderController {
        HydrationReminderController(defaults: defaults, service: service, calendar: calendar,
                                    now: { [clock] in clock.date }, databaseURL: databaseURL)
    }

    func enableWithBaseline(_ count: Int) async {
        await controller.setEnabled(true)
        await controller.update(keyCount: count, at: clock.date)
    }

    func cleanUp() { controller.stop(); defaults.removePersistentDomain(forName: suite) }
}

private final class ReminderClock { var date = Date() }

@MainActor
private final class MockHydrationNotificationService: HydrationNotificationServicing {
    var status: HydrationNotificationAuthorization = .authorized
    var requests = 0
    var sent: [HydrationNotification] = []
    var rejectSend = false
    var sendDelay: UInt64 = 0
    var authorizationDelay: UInt64 = 0
    func authorization() async -> HydrationNotificationAuthorization {
        if authorizationDelay > 0 { try? await Task.sleep(nanoseconds: authorizationDelay) }
        return status
    }
    func requestAuthorization() async throws { requests += 1; status = .authorized }
    func send(_ notification: HydrationNotification) async throws {
        if sendDelay > 0 { try await Task.sleep(nanoseconds: sendDelay) }
        if rejectSend { throw NSError(domain: "ReminderTests", code: 1) }
        sent.append(notification)
    }
    func openSettings() {}
}

final class HydrationKeyCountTests: XCTestCase {
    func testCountMatchesActivitySnapshotAndDoesNotDoubleCountLiveFlush() throws {
        let database = try ReminderCountDatabase()
        defer { database.cleanUp() }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: 12))!
        let start = ActivityCalculator.milliseconds(calendar.startOfDay(for: now))
        let end = ActivityCalculator.milliseconds(now)
        try database.execute("""
            INSERT INTO key_events VALUES(\(start-1),0,0,NULL), (\(start),0,0,NULL),
                (\(start),0,0,NULL), (\(start+100),1,0,NULL), (\(start+101),1,1,1),
                (\(end),2,0,NULL), (\(end+1),3,0,NULL);
            """)
        let live = [
            ActivityKeyEvent(timestampMs: start, keycode: 0, kind: 0),
            ActivityKeyEvent(timestampMs: start + 100, keycode: 1, kind: 0, holdMs: 10),
            ActivityKeyEvent(timestampMs: start + 200, keycode: 2, kind: 0),
            ActivityKeyEvent(timestampMs: start + 200, keycode: 2, kind: 0),
            ActivityKeyEvent(timestampMs: start + 201, keycode: 2, kind: 1),
            ActivityKeyEvent(timestampMs: end, keycode: 3, kind: 0)
        ]
        let repository = ActivityRepository(url: database.url, policy: ActivityPolicy(), calendar: calendar)
        XCTAssertEqual(try repository.todayKeyCount(now: now, liveEvents: live, liveConnected: false), 2)
        XCTAssertEqual(try repository.todayKeyCount(now: now, liveEvents: live, liveConnected: true), 3)
        XCTAssertEqual(try repository.todayKeyCount(now: now, liveEvents: live, liveConnected: true),
                       repository.uncachedSnapshot(range: .today, now: now, liveEvents: live, liveConnected: true).keyCount)
        try database.execute("INSERT INTO key_events VALUES(\(start+200),2,0,NULL);")
        XCTAssertEqual(try repository.todayKeyCount(now: now, liveEvents: live, liveConnected: true), 3)
        XCTAssertEqual(try repository.todayKeyCount(now: now), 3)
    }

    func testUnavailableDatabaseThrowsInsteadOfResettingCountToZero() {
        let repository = ActivityRepository(url: URL(fileURLWithPath: "/unavailable-reminder-test.db"))
        XCTAssertThrowsError(try repository.todayKeyCount())
    }
}

private final class ReminderCountDatabase {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hydration-count-\(UUID().uuidString)")
    var url: URL { directory.appendingPathComponent("keys.db") }
    init() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try execute("CREATE TABLE key_events(ts_ms INTEGER, keycode INTEGER, kind INTEGER, hold_ms INTEGER);")
    }
    func execute(_ sql: String) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK, let handle else {
            throw NSError(domain: "ReminderCountTests.Open", code: 1)
        }
        defer { sqlite3_close(handle) }
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "ReminderCountTests.SQL", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(handle))])
        }
    }
    func cleanUp() { try? FileManager.default.removeItem(at: directory) }
}
