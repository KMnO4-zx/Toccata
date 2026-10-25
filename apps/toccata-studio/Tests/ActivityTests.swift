import XCTest
import SQLite3
@testable import toccata_studio

final class ActivityTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(_ year: Int = 2026, _ month: Int = 10, _ day: Int = 19, hour: Int = 0, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func event(_ offsetMs: Int64, key: Int = 0, kind: Int, hold: Int64? = nil, day: Date? = nil) -> ActivityKeyEvent {
        ActivityKeyEvent(timestampMs: ActivityCalculator.milliseconds(day ?? date()) + offsetMs,
            keycode: key, kind: kind, holdMs: hold)
    }

    private func snapshot(_ events: [ActivityKeyEvent], nowOffset: Int64 = 180_000,
                          liveEvents: [ActivityKeyEvent] = [], connected: Bool = false) -> ActivitySnapshot {
        ActivityCalculator.snapshot(events: events, range: .today,
            now: date().addingTimeInterval(Double(nowOffset) / 1000), calendar: calendar,
            liveEvents: liveEvents, liveConnected: connected)
    }

    func testContinuousInputIncludesGapsAndTrailingGrace() {
        let result = snapshot([
            event(0, kind: 0), event(100, kind: 1, hold: 100),
            event(20_000, kind: 0), event(20_100, kind: 1, hold: 100)
        ])
        XCTAssertEqual(result.activeMs, 25_100)
        XCTAssertEqual(result.keyCount, 2)
        XCTAssertEqual(result.days.reduce(0) { $0 + $1.activeMs }, result.activeMs)
        XCTAssertEqual(result.days.flatMap(\.buckets).reduce(0) { $0 + $1.activeMs }, result.activeMs)
    }

    func testExactIdleThresholdStartsNewInterval() {
        let result = snapshot([
            event(0, kind: 0), event(100, kind: 1, hold: 100),
            event(60_100, kind: 0), event(60_200, kind: 1, hold: 100)
        ])
        XCTAssertEqual(result.activeMs, 10_200)
    }

    func testConcurrentHoldsAreUnionedAndLongFnHoldSurvivesIdleGaps() {
        let result = snapshot([
            event(0, key: 63, kind: 0), event(1_000, key: 12, kind: 0),
            event(110_000, key: 12, kind: 1, hold: 109_000),
            event(120_000, key: 63, kind: 1, hold: 120_000)
        ])
        XCTAssertEqual(result.activeMs, 125_000)
        XCTAssertEqual(result.fnMs, 120_000)
        XCTAssertEqual(result.keyCount, 2)
    }

    func testCrossMidnightHoldIsClippedToSelectedDay() {
        let result = snapshot([
            event(-60_000, key: 63, kind: 0),
            event(120_000, key: 63, kind: 1, hold: 180_000)
        ])
        XCTAssertEqual(result.fnMs, 120_000)
        XCTAssertEqual(result.activeMs, 125_000)
        XCTAssertEqual(result.keyCount, 0)
        XCTAssertEqual(result.days[0].buckets[0].fnMs, 120_000)
        XCTAssertEqual(result.days[0].buckets.reduce(0) { $0 + $1.fnMs }, result.fnMs)
    }

    func testFnTimeIsSplitAcrossBucketsWithoutCountingBoundaryPressTwice() {
        let down = event(840_000, key: 63, kind: 0)
        let up = event(1_980_000, key: 63, kind: 1, hold: 1_140_000)
        let result = snapshot([
            down, event(900_000, key: 12, kind: 0),
            event(900_100, key: 12, kind: 1, hold: 100), up
        ], nowOffset: 2_100_000, liveEvents: [down, up], connected: true)

        let buckets = result.days[0].buckets
        XCTAssertEqual(Array(buckets.prefix(4).map(\.fnMs)), [60_000, 900_000, 180_000, 0])
        XCTAssertEqual(Array(buckets.prefix(3).map(\.keyCount)), [1, 1, 0])
        XCTAssertEqual(buckets.reduce(0) { $0 + $1.fnMs }, result.fnMs)
        XCTAssertTrue(buckets.allSatisfy { $0.fnMs <= $0.activeMs && $0.fnMs <= $0.endMs - $0.startMs })
    }

    func testFnBucketTimeAcrossMidnightReconcilesWithBothDays() {
        let midnight = date(2026, 10, 20)
        let events = [
            event(-60_000, key: 63, kind: 0, day: midnight),
            event(120_000, key: 63, kind: 1, hold: 180_000, day: midnight)
        ]
        let result = ActivityCalculator.snapshot(events: events, range: .thisWeek,
            now: midnight.addingTimeInterval(180), calendar: calendar)

        XCTAssertEqual(result.days.count, 2)
        XCTAssertEqual(result.days[0].buckets.last?.fnMs, 60_000)
        XCTAssertEqual(result.days[1].buckets.first?.fnMs, 120_000)
        for day in result.days {
            XCTAssertEqual(day.buckets.reduce(0) { $0 + $1.fnMs }, day.fnMs)
        }
        XCTAssertEqual(result.days.flatMap(\.buckets).reduce(0) { $0 + $1.fnMs }, 180_000)
    }

    func testLiveFnBucketEndsAtNowAndLeavesFutureBucketsEmpty() {
        let result = snapshot([], nowOffset: 920_000,
            liveEvents: [event(880_000, key: 63, kind: 0)], connected: true)
        let buckets = result.days[0].buckets
        XCTAssertEqual(Array(buckets.prefix(3).map(\.fnMs)), [20_000, 20_000, 0])
        XCTAssertEqual(buckets.reduce(0) { $0 + $1.fnMs }, 40_000)
    }

    func testLiveFnAccumulatesWithoutAnUpOrPersistedSession() {
        let down = event(10_000, key: 63, kind: 0)
        let live = snapshot([], nowOffset: 130_000, liveEvents: [down], connected: true)
        XCTAssertEqual(live.fnMs, 120_000)
        XCTAssertEqual(live.activeMs, 120_000)
        XCTAssertEqual(live.keyCount, 1)

        let stale = snapshot([down], nowOffset: 130_000, connected: false)
        XCTAssertEqual(stale.fnMs, 0, "An orphan down from an earlier daemon must not inflate voice estimates")
        XCTAssertEqual(stale.activeMs, 5_000)
    }

    func testLiveAndPersistedEventsDoNotCountTwice() {
        let down = event(10_000, key: 63, kind: 0)
        let up = event(20_000, key: 63, kind: 1, hold: 10_000)
        let result = snapshot([down, up], liveEvents: [down, event(20_000, key: 63, kind: 1)], connected: true)
        XCTAssertEqual(result.keyCount, 1)
        XCTAssertEqual(result.fnMs, 10_000)
        XCTAssertEqual(result.activeMs, 15_000)
    }

    func testPerKeyCountsMergeLiveAndPersistedDownsWithinToday() {
        let sharedDown = event(10_000, key: 12, kind: 0)
        let result = snapshot([
            event(-1, key: 13, kind: 0),
            event(0, key: 0, kind: 0),
            sharedDown,
            event(10_100, key: 12, kind: 1, hold: 100),
            event(180_001, key: 14, kind: 0)
        ], liveEvents: [
            sharedDown,
            event(10_100, key: 12, kind: 1),
            event(20_000, key: 12, kind: 0),
            event(30_000, key: 63, kind: 0),
            event(180_001, key: 15, kind: 0)
        ], connected: true)

        XCTAssertEqual(result.keyCounts, [0: 1, 12: 2, 63: 1])
        XCTAssertEqual(result.keyCount, 4)
        XCTAssertEqual(result.keyCounts.values.reduce(0, +), result.keyCount)
    }

    func testPerKeyCountsIgnoreDisconnectedLiveEvents() {
        let result = snapshot([event(10_000, key: 12, kind: 0)],
            liveEvents: [event(20_000, key: 13, kind: 0)], connected: false)

        XCTAssertEqual(result.keyCounts, [12: 1])
        XCTAssertEqual(result.keyCounts.values.reduce(0, +), result.keyCount)
        XCTAssertTrue(ActivitySnapshot().keyCounts.isEmpty)
    }

    func testIncompleteLiveHoldCanBeClosedBeforePersistence() {
        let down = event(0, key: 63, kind: 0)
        let result = snapshot([], liveEvents: [down, event(120_000, key: 63, kind: 1)], connected: true)
        XCTAssertEqual(result.fnMs, 120_000)
        XCTAssertEqual(result.activeMs, 125_000)
    }

    func testOldOrphanDownNeverPairsAcrossDaemonConnections() {
        let oldDown = event(0, key: 63, kind: 0)
        let orphanUp = event(120_000, key: 63, kind: 1)
        let result = snapshot([oldDown], liveEvents: [orphanUp], connected: true)
        XCTAssertEqual(result.fnMs, 0)
        XCTAssertEqual(result.activeMs, 10_000)
    }

    func testDuplicateFnDownPreservesFirstPress() {
        let live = [event(0, key: 63, kind: 0), event(20_000, key: 63, kind: 0)]
        XCTAssertEqual(ActivityCalculator.openLiveKeys(live)[63], ActivityCalculator.milliseconds(date()))
        let result = snapshot([], nowOffset: 130_000, liveEvents: live, connected: true)
        XCTAssertEqual(result.fnMs, 130_000)
        XCTAssertEqual(result.activeMs, 130_000)
    }

    func testTrailingGraceNeverCountsFutureTime() {
        let result = snapshot([event(10_000, kind: 0)], nowOffset: 11_000)
        XCTAssertEqual(result.activeMs, 1_000)
    }

    func testWeekStartsMondayAndRecentSevenDaysIsRolling() {
        let now = date(2026, 10, 22, hour: 12)
        let week = ActivityRange.thisWeek.interval(now: now, calendar: calendar)
        let recent = ActivityRange.lastSevenDays.interval(now: now, calendar: calendar)
        XCTAssertEqual(week.start, date(2026, 10, 19))
        XCTAssertEqual(recent.start, date(2026, 10, 16))
        XCTAssertEqual(week.end, date(2026, 10, 23))
        XCTAssertEqual(recent.end, week.end)
    }

    func testBucketsFollowLocalDayOnDaylightSavingTransition() {
        var local = calendar
        local.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let now = local.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 23, minute: 59))!
        let result = ActivityCalculator.snapshot(events: [], range: .today, now: now, calendar: local)
        XCTAssertEqual(result.days.count, 1)
        XCTAssertEqual(result.days[0].buckets.count, 92)
        XCTAssertEqual(result.days[0].buckets.reduce(0) { $0 + ($1.endMs - $1.startMs) }, 23 * 60 * 60 * 1000)
    }

    func testFnBucketsUseElapsedTimeAcrossDaylightSavingJump() {
        var local = calendar
        local.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let start = local.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 1, minute: 50))!
        let end = local.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 3, minute: 10))!
        let startMs = ActivityCalculator.milliseconds(start)
        let endMs = ActivityCalculator.milliseconds(end)
        let result = ActivityCalculator.snapshot(events: [
            ActivityKeyEvent(timestampMs: startMs, keycode: 63, kind: 0),
            ActivityKeyEvent(timestampMs: endMs, keycode: 63, kind: 1, holdMs: endMs - startMs)
        ], range: .today, now: end.addingTimeInterval(60), calendar: local)

        XCTAssertEqual(result.fnMs, 1_200_000)
        XCTAssertEqual(result.days[0].buckets.filter { $0.fnMs > 0 }.map(\.fnMs), [600_000, 600_000])
        XCTAssertEqual(result.days[0].buckets.reduce(0) { $0 + $1.fnMs }, result.fnMs)
    }

    func testRepositoryReadsEventsWithoutAnyAppSessionsTable() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("activity-test.db")
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        let database = try XCTUnwrap(handle)
        defer { sqlite3_close(database) }
        let midnight = ActivityCalculator.milliseconds(date())
        let sql = """
            CREATE TABLE key_events(ts_ms INTEGER NOT NULL, keycode INTEGER NOT NULL, kind INTEGER NOT NULL, hold_ms INTEGER, app TEXT);
            INSERT INTO key_events VALUES(\(midnight - 180_000),63,0,NULL,NULL);
            INSERT INTO key_events VALUES(\(midnight + 30_000),63,1,210000,NULL);
            INSERT INTO key_events VALUES(\(midnight + 90_000),0,0,NULL,NULL);
            INSERT INTO key_events VALUES(\(midnight + 90_100),0,1,100,NULL);
            """
        XCTAssertEqual(sqlite3_exec(database, sql, nil, nil, nil), SQLITE_OK)
        let repository = ActivityRepository(url: url, policy: ActivityPolicy(), calendar: calendar)
        let result = repository.snapshot(range: .today, now: date().addingTimeInterval(180))
        XCTAssertNil(result.errorMessage)
        XCTAssertEqual(result.fnMs, 30_000)
        XCTAssertEqual(result.keyCount, 1)
        XCTAssertEqual(result.activeMs, 40_100, "The cross-day hold and two separate input intervals should be clipped and unioned")
    }

    func testMissingDatabaseCanStillRenderLiveEvents() {
        let repository = ActivityRepository(url: URL(fileURLWithPath: "/tmp/\(UUID().uuidString)/missing.db"),
            policy: ActivityPolicy(), calendar: calendar)
        let result = repository.snapshot(range: .today, now: date().addingTimeInterval(120),
            liveEvents: [event(0, key: 63, kind: 0)], liveConnected: true)
        XCTAssertNotNil(result.errorMessage)
        XCTAssertEqual(result.fnMs, 120_000)
        XCTAssertEqual(result.activeMs, 120_000)
    }

    func testCustomPolicyAndInvalidFields() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("config.json")
        try Data(#"{"idle_gap_secs":30,"trailing_grace_secs":2}"#.utf8).write(to: url)
        XCTAssertEqual(ActivityPolicy.load(configURL: url), ActivityPolicy(idleGapMs: 30_000, trailingGraceMs: 2_000))
        try Data(#"{"idle_gap_secs":true,"trailing_grace_secs":-2}"#.utf8).write(to: url)
        XCTAssertEqual(ActivityPolicy.load(configURL: url), ActivityPolicy())
    }
}
