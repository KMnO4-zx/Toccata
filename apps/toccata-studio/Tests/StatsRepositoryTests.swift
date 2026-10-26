import Foundation
import SQLite3
import XCTest
@testable import toccata_studio

final class StatsRepositoryTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(_ day: Int, year: Int = 2026, month: Int = 10,
                      hour: Int = 0, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day,
                                           hour: hour, minute: minute))!
    }

    private func milliseconds(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970 * 1000)
    }

    func testIntervalUsesInjectedNowAndCalendarForAllRanges() {
        let now = date(25, hour: 12)

        let today = TimeRange.today.interval(now: now, calendar: calendar)
        XCTAssertEqual(today.start, date(25))
        XCTAssertEqual(today.end, date(26))

        let yesterday = TimeRange.yesterday.interval(now: now, calendar: calendar)
        XCTAssertEqual(yesterday.start, date(24))
        XCTAssertEqual(yesterday.end, date(25))

        let week = TimeRange.week.interval(now: now, calendar: calendar)
        XCTAssertEqual(week.start, date(19))
        XCTAssertEqual(week.end, date(26))

        let month = TimeRange.month.interval(now: now, calendar: calendar)
        XCTAssertEqual(month.start, date(26, month: 9))
        XCTAssertEqual(month.end, date(26))
    }

    func testSelectedDayUsesLocalMidnightAndDoesNotDependOnReferenceDay() {
        var local = calendar
        local.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let selected = local.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 15))!

        let interval = TimeRange.day(selected).interval(now: date(25, hour: 12), calendar: local)

        XCTAssertEqual(interval.start, local.date(from: DateComponents(year: 2026, month: 10, day: 12))!)
        XCTAssertEqual(interval.end, local.date(from: DateComponents(year: 2026, month: 10, day: 13))!)
    }

    func testYesterdayAndSelectedDayFollowShortAndLongDaylightSavingDays() {
        var local = calendar
        local.timeZone = TimeZone(identifier: "America/Los_Angeles")!

        for (month, day, hours) in [(3, 8, 23), (11, 1, 25)] {
            let start = local.date(from: DateComponents(year: 2026, month: month, day: day))!
            let end = local.date(byAdding: .day, value: 1, to: start)!
            let selected = local.date(byAdding: .hour, value: 12, to: start)!
            let nextDay = local.date(byAdding: .hour, value: 12, to: end)!
            let intervals = [
                TimeRange.yesterday.interval(now: nextDay, calendar: local),
                TimeRange.day(selected).interval(now: date(20, month: 12), calendar: local)
            ]

            for interval in intervals {
                XCTAssertEqual(interval.start, start)
                XCTAssertEqual(interval.end, end)
                XCTAssertEqual(interval.duration, Double(hours * 3_600))
            }
        }
    }

    func testIntervalFollowsLocalNaturalDaysAcrossDaylightSavingTransition() {
        var local = calendar
        local.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let now = local.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 12))!
        let expectedStart = local.date(from: DateComponents(year: 2026, month: 11, day: 1))!
        let expectedEnd = local.date(from: DateComponents(year: 2026, month: 11, day: 2))!

        let today = TimeRange.today.interval(now: now, calendar: local)
        XCTAssertEqual(today.start, expectedStart)
        XCTAssertEqual(today.end, expectedEnd)
        XCTAssertEqual(today.duration, 25 * 3_600.0)

        let week = TimeRange.week.interval(now: now, calendar: local)
        XCTAssertEqual(week.start, local.date(from: DateComponents(year: 2026, month: 10, day: 26))!)
        XCTAssertEqual(week.end, expectedEnd)

        let month = TimeRange.month.interval(now: now, calendar: local)
        XCTAssertEqual(month.start, local.date(from: DateComponents(year: 2026, month: 10, day: 3))!)
        XCTAssertEqual(month.end, expectedEnd)
    }

    func testKeyCountsFiltersTodayAggregatesDownsAndDoesNotTruncate() throws {
        let now = date(25, hour: 12)
        let interval = TimeRange.today.interval(now: now, calendar: calendar)
        let start = milliseconds(interval.start)
        let end = milliseconds(interval.end)
        var seed = [
            "INSERT INTO key_events VALUES(\(start),0,0,NULL,'test.app');",
            "INSERT INTO key_events VALUES(\(start + 100),30,0,NULL,'test.app');",
            "INSERT INTO key_events VALUES(\(start + 101),30,0,NULL,'test.app');",
            "INSERT INTO key_events VALUES(\(start + 102),30,1,100,'test.app');",
            "INSERT INTO key_events VALUES(\(end),30,0,NULL,'test.app');",
            "INSERT INTO key_events VALUES(\(start - 1),99,0,NULL,'test.app');"
        ]
        for keycode in 1...24 {
            seed.append("INSERT INTO key_events VALUES(\(start + Int64(keycode)),\(keycode),0,NULL,'test.app');")
        }
        let repository = try makeRepository(seedSQL: seed.joined(separator: "\n"))

        let ranks = repository.keyCounts(now: now, calendar: calendar)

        XCTAssertEqual(ranks.count, 26)
        XCTAssertEqual(ranks.map(\.keycode), [30] + Array(0...24))
        XCTAssertEqual(ranks.map(\.count), [2] + Array(repeating: 1, count: 25))
    }

    func testTopAppsReconstructsCrossBoundaryHoldsAndIgnoresLegacySessions() throws {
        let now = date(26, hour: 12)
        let interval = TimeRange.yesterday.interval(now: now, calendar: calendar)
        let rangeStart = milliseconds(interval.start)
        let rangeEnd = milliseconds(interval.end)
        let repository = try makeRepository(seedSQL: """
            INSERT INTO app_sessions VALUES('cross.start',\(rangeStart - 5_000),\(rangeStart + 5_000),10);
            INSERT INTO app_sessions VALUES('cross.end',\(rangeEnd - 3_000),\(rangeEnd + 7_000),20);
            INSERT INTO app_sessions VALUES('inside',\(rangeStart + 1_000),\(rangeStart + 2_000),3);
            INSERT INTO app_sessions VALUES('past',\(rangeStart - 10_000),\(rangeStart),100);
            INSERT INTO app_sessions VALUES('future',\(rangeEnd),\(rangeEnd + 10_000),100);
            INSERT INTO key_events VALUES(\(rangeStart - 10_000),0,0,NULL,'cross.start');
            INSERT INTO key_events VALUES(\(rangeStart + 5_000),0,1,15000,'cross.start');
            INSERT INTO key_events VALUES(\(rangeEnd - 3_000),0,0,NULL,'cross.end');
            INSERT INTO key_events VALUES(\(rangeEnd + 7_000),0,1,10000,'cross.end');
            INSERT INTO key_events VALUES(\(rangeStart + 10_000),0,0,NULL,'inside');
            INSERT INTO key_events VALUES(\(rangeStart + 10_100),0,1,100,'inside');
            INSERT INTO key_events VALUES(\(rangeStart),0,1,10000,'past');
            INSERT INTO key_events VALUES(\(rangeEnd),0,0,NULL,'future');
            """)

        let ranks = repository.topApps(range: .yesterday, now: now, calendar: calendar)

        XCTAssertEqual(ranks.map(\.app), ["cross.start", "inside", "cross.end"])
        XCTAssertEqual(ranks.map(\.usageMs), [5_000, 5_000, 3_000])
        XCTAssertEqual(ranks.map(\.keyCount), [0, 1, 1])
    }

    func testTopAppsMergesWindowsAndHoldsPerAppWithoutBridgingPauses() throws {
        let now = date(25, hour: 12)
        let interval = TimeRange.today.interval(now: now, calendar: calendar)
        let start = milliseconds(interval.start)
        let repository = try makeRepository(seedSQL: """
            INSERT INTO app_sessions VALUES('multiple.sessions',\(start),\(start + 45_100),50);
            INSERT INTO app_sessions VALUES('no.events',\(start + 2_000),\(start + 3_000),25);
            INSERT INTO key_events VALUES(\(start),0,0,NULL,'multiple.sessions');
            INSERT INTO key_events VALUES(\(start + 500),0,1,500,'multiple.sessions');
            INSERT INTO key_events VALUES(\(start + 3_000),0,0,NULL,'multiple.sessions');
            INSERT INTO key_events VALUES(\(start + 3_100),0,1,100,'multiple.sessions');
            INSERT INTO key_events VALUES(\(start + 40_000),0,0,NULL,'multiple.sessions');
            INSERT INTO key_events VALUES(\(start + 40_100),0,1,100,'multiple.sessions');
            INSERT INTO key_events VALUES(\(start + 1_000),0,0,NULL,NULL);
            INSERT INTO key_events VALUES(\(start + 1_000),0,0,NULL,'unrelated.app');
            INSERT INTO key_events VALUES(\(start + 70_000),0,1,NULL,'orphan.up');
            """)

        let ranks = repository.topApps(range: .today, now: now, calendar: calendar)

        XCTAssertEqual(ranks.map(\.app), ["multiple.sessions", "unrelated.app"])
        XCTAssertEqual(ranks.map(\.usageMs), [13_000, 5_000])
        XCTAssertEqual(ranks.map(\.keyCount), [3, 1])
    }

    func testTopAppsYesterdayAndSelectedDayUseLocalBounds() throws {
        var local = calendar
        local.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let now = local.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 12))!
        let selected = local.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 18))!
        let start = milliseconds(local.startOfDay(for: selected))
        let end = milliseconds(local.startOfDay(for: now))
        let repository = try makeRepository(seedSQL: """
            INSERT INTO app_sessions VALUES('spans.day',\(start - 10_000),\(end + 10_000),10);
            INSERT INTO app_sessions VALUES('cross.start',\(start - 5_000),\(start + 5_000),2);
            INSERT INTO app_sessions VALUES('cross.end',\(end - 3_000),\(end + 3_000),2);
            INSERT INTO app_sessions VALUES('inside',\(start + 1_000),\(start + 2_000),1);
            INSERT INTO app_sessions VALUES('ends.at.start',\(start - 5_000),\(start),1);
            INSERT INTO app_sessions VALUES('starts.at.end',\(end),\(end + 5_000),1);
            INSERT INTO key_events VALUES(\(start - 1),0,0,NULL,'spans.day');
            INSERT INTO key_events VALUES(\(start),0,0,NULL,'spans.day');
            INSERT INTO key_events VALUES(\(end - 1),0,0,NULL,'spans.day');
            INSERT INTO key_events VALUES(\(end),0,0,NULL,'spans.day');
            INSERT INTO key_events VALUES(\(end + 10_000),0,1,\(end - start + 20_000),'spans.day');
            INSERT INTO key_events VALUES(\(start - 3_000),0,0,NULL,'cross.start');
            INSERT INTO key_events VALUES(\(end - 100),0,0,NULL,'cross.end');
            INSERT INTO key_events VALUES(\(start + 10_000),0,0,NULL,'inside');
            INSERT INTO key_events VALUES(\(start),0,1,5000,'ends.at.start');
            INSERT INTO key_events VALUES(\(end),0,0,NULL,'starts.at.end');
            """)

        for range in [TimeRange.yesterday, .day(selected)] {
            let ranks = repository.topApps(range: range, now: now, calendar: local)

            XCTAssertEqual(ranks.map(\.app), ["spans.day", "inside", "cross.start", "cross.end"])
            XCTAssertEqual(ranks.map(\.usageMs), [end - start, 5_000, 2_000, 100])
            XCTAssertEqual(ranks.map(\.keyCount), [2, 1, 0, 1])
        }
    }

    func testTopAppsSelectedDayClipsToActualDaylightSavingDuration() throws {
        var local = calendar
        local.timeZone = TimeZone(identifier: "America/Los_Angeles")!

        for (month, day, hours) in [(3, 8, 23), (11, 1, 25)] {
            let selected = local.date(from: DateComponents(year: 2026, month: month, day: day, hour: 12))!
            let startDate = local.startOfDay(for: selected)
            let endDate = local.date(byAdding: .day, value: 1, to: startDate)!
            let start = milliseconds(startDate)
            let end = milliseconds(endDate)
            let repository = try makeRepository(seedSQL: """
                INSERT INTO app_sessions VALUES('spans.day',\(start - 3_600_000),\(end + 3_600_000),5);
                INSERT INTO app_sessions VALUES('after.day',\(end),\(end + 3_600_000),5);
                INSERT INTO key_events VALUES(\(start),0,0,NULL,'spans.day');
                INSERT INTO key_events VALUES(\(end - 1),0,0,NULL,'spans.day');
                INSERT INTO key_events VALUES(\(end),0,0,NULL,'spans.day');
                INSERT INTO key_events VALUES(\(end + 3_600_000),0,1,\(end - start + 7_200_000),'spans.day');
                """)

            let ranks = repository.topApps(range: .day(selected), now: date(20, month: 12), calendar: local)

            XCTAssertEqual(ranks.map(\.app), ["spans.day"])
            XCTAssertEqual(ranks.map(\.usageMs), [Int64(hours * 3_600_000)])
            XCTAssertEqual(ranks.map(\.keyCount), [2])
        }
    }

    func testTopAppsCapsWindowsAtNowAndIncludesUnsettledApp() throws {
        let now = date(25, hour: 12)
        let nowMs = milliseconds(now)
        let repository = try makeRepository(seedSQL: """
            INSERT INTO key_events VALUES(\(nowMs - 2_000),0,0,NULL,'current.app');
            INSERT INTO key_events VALUES(\(nowMs - 1_900),0,1,100,'current.app');
            INSERT INTO key_events VALUES(\(nowMs + 1_000),0,0,NULL,'future.app');
            """)

        let ranks = repository.topApps(range: .today, now: now, calendar: calendar)
        XCTAssertEqual(ranks.map(\.app), ["current.app"])
        XCTAssertEqual(ranks.map(\.usageMs), [2_000])
        XCTAssertEqual(ranks.map(\.keyCount), [1])
        XCTAssertTrue(repository.topApps(range: .today, limit: 0, now: now, calendar: calendar).isEmpty)
    }

    func testAppAndKeyboardUseSameConfigurableWindowAndHoldUnion() throws {
        let now = date(25, hour: 12)
        let start = milliseconds(date(25))
        let policy = ActivityPolicy(activityWindowMs: 3_000)
        let repository = try makeRepository(seedSQL: """
            INSERT INTO key_events VALUES(\(start),0,0,NULL,'test.app');
            INSERT INTO key_events VALUES(\(start + 2_000),1,0,NULL,'test.app');
            INSERT INTO key_events VALUES(\(start + 8_000),1,1,6000,'test.app');
            """, policy: policy)
        let expected = ActivityCalculator.snapshot(events: [
            ActivityKeyEvent(timestampMs: start, keycode: 0, kind: 0),
            ActivityKeyEvent(timestampMs: start + 2_000, keycode: 1, kind: 0),
            ActivityKeyEvent(timestampMs: start + 8_000, keycode: 1, kind: 1, holdMs: 6_000)
        ], range: .today, now: now, calendar: calendar, policy: policy)

        let rank = try XCTUnwrap(repository.topApps(range: .today, now: now, calendar: calendar).first)
        XCTAssertEqual(rank.usageMs, expected.activeMs)
        XCTAssertEqual(rank.usageMs, 8_000)
        XCTAssertEqual(rank.keyCount, Int64(expected.keyCount))
    }

    func testSQLUnionMatchesKeyboardCalculationForNestedAndSeparatedHolds() throws {
        let now = date(25, hour: 12)
        let start = milliseconds(date(25))
        var events: [ActivityKeyEvent] = []
        for index in 0..<100 {
            let down = start + Int64((index * 37) % 400) * 1_000 - 10_000
            let hold = [Int64(100), 2_000, 9_000, 18_000][index % 4]
            events.append(ActivityKeyEvent(timestampMs: down, keycode: index, kind: 0))
            events.append(ActivityKeyEvent(timestampMs: down + hold, keycode: index, kind: 1, holdMs: hold))
        }
        // Include a hold spanning many nested windows and a later uncovered gap.
        events.append(ActivityKeyEvent(timestampMs: start + 600_000, keycode: 100, kind: 1, holdMs: 300_000))
        events.append(ActivityKeyEvent(timestampMs: start + 700_000, keycode: 101, kind: 0))
        let sql = events.map {
            "INSERT INTO key_events VALUES(\($0.timestampMs),\($0.keycode),\($0.kind),\($0.holdMs.map(String.init) ?? "NULL"),'test.app');"
        }.joined(separator: "\n")
        for seconds in [Int64(0), 3_000, 5_000, 9_000] {
            let policy = ActivityPolicy(activityWindowMs: seconds)
            let repository = try makeRepository(seedSQL: sql, policy: policy)
            let expected = ActivityCalculator.snapshot(events: events, range: .today, now: now,
                                                       calendar: calendar, policy: policy)
            let rank = try XCTUnwrap(repository.topApps(range: .today, now: now, calendar: calendar).first)
            XCTAssertEqual(rank.usageMs, expected.activeMs)
            XCTAssertEqual(rank.keyCount, Int64(expected.keyCount))
        }
    }

    private func makeRepository(seedSQL: String, policy: ActivityPolicy = ActivityPolicy()) throws -> StatsRepository {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StatsRepositoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("stats-test.db")
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK, let database = handle else {
            if let handle { sqlite3_close(handle) }
            throw NSError(domain: "StatsRepositoryTests", code: 1)
        }
        defer { sqlite3_close(database) }
        let sql = """
            CREATE TABLE key_events(ts_ms INTEGER NOT NULL, keycode INTEGER NOT NULL, kind INTEGER NOT NULL, hold_ms INTEGER, app TEXT);
            CREATE TABLE app_sessions(app TEXT NOT NULL, start_ms INTEGER NOT NULL, end_ms INTEGER NOT NULL, key_count INTEGER NOT NULL);
            \(seedSQL)
            """
        let result = sqlite3_exec(database, sql, nil, nil, nil)
        guard result == SQLITE_OK else {
            throw NSError(domain: "StatsRepositoryTests", code: Int(result),
                          userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(database))])
        }
        return StatsRepository(url: url, policy: policy)
    }
}
