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

    func testTopAppsClipsSessionsToRangeAndExcludesFutureSessions() throws {
        let now = date(25, hour: 12)
        let interval = TimeRange.today.interval(now: now, calendar: calendar)
        let rangeStart = milliseconds(interval.start)
        let rangeEnd = milliseconds(interval.end)
        let repository = try makeRepository(seedSQL: """
            INSERT INTO app_sessions VALUES('cross.start',\(rangeStart - 5_000),\(rangeStart + 5_000),10);
            INSERT INTO app_sessions VALUES('cross.end',\(rangeEnd - 3_000),\(rangeEnd + 7_000),20);
            INSERT INTO app_sessions VALUES('inside',\(rangeStart + 1_000),\(rangeStart + 2_000),3);
            INSERT INTO app_sessions VALUES('past',\(rangeStart - 10_000),\(rangeStart),100);
            INSERT INTO app_sessions VALUES('future',\(rangeEnd),\(rangeEnd + 10_000),100);
            INSERT INTO key_events VALUES(\(rangeStart - 1),0,0,NULL,'cross.start');
            INSERT INTO key_events VALUES(\(rangeStart),0,0,NULL,'cross.start');
            INSERT INTO key_events VALUES(\(rangeEnd - 1),0,0,NULL,'cross.end');
            INSERT INTO key_events VALUES(\(rangeEnd),0,0,NULL,'cross.end');
            INSERT INTO key_events VALUES(\(rangeStart + 1_000),0,0,NULL,'inside');
            INSERT INTO key_events VALUES(\(rangeStart + 1_500),0,0,NULL,'inside');
            """)

        let ranks = repository.topApps(range: .today, now: now, calendar: calendar)

        XCTAssertEqual(ranks.map(\.app), ["cross.start", "cross.end", "inside"])
        XCTAssertEqual(ranks.map(\.usageMs), [5_000, 3_000, 1_000])
        XCTAssertEqual(ranks.map(\.keyCount), [1, 1, 2])
    }

    func testTopAppsCountsOnlyMatchingDownEventsWithoutMultiplyingAcrossSessions() throws {
        let now = date(25, hour: 12)
        let interval = TimeRange.today.interval(now: now, calendar: calendar)
        let start = milliseconds(interval.start)
        let end = milliseconds(interval.end)
        let repository = try makeRepository(seedSQL: """
            INSERT INTO app_sessions VALUES('multiple.sessions',\(start - 1_000),\(start + 2_000),50);
            INSERT INTO app_sessions VALUES('multiple.sessions',\(end - 3_000),\(end + 1_000),50);
            INSERT INTO app_sessions VALUES('no.events',\(start + 2_000),\(start + 3_000),25);
            INSERT INTO key_events VALUES(\(start - 1),0,0,NULL,'multiple.sessions');
            INSERT INTO key_events VALUES(\(start),0,0,NULL,'multiple.sessions');
            INSERT INTO key_events VALUES(\(start + 500),0,1,500,'multiple.sessions');
            INSERT INTO key_events VALUES(\(end - 1),0,0,NULL,'multiple.sessions');
            INSERT INTO key_events VALUES(\(end),0,0,NULL,'multiple.sessions');
            INSERT INTO key_events VALUES(\(start + 1_000),0,0,NULL,NULL);
            INSERT INTO key_events VALUES(\(start + 1_000),0,0,NULL,'unrelated.app');
            """)

        let ranks = repository.topApps(range: .today, now: now, calendar: calendar)

        XCTAssertEqual(ranks.map(\.app), ["multiple.sessions", "no.events"])
        XCTAssertEqual(ranks.map(\.usageMs), [5_000, 1_000])
        XCTAssertEqual(ranks.map(\.keyCount), [2, 0])
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
            INSERT INTO key_events VALUES(\(start + 100),0,0,NULL,'cross.start');
            INSERT INTO key_events VALUES(\(end - 100),0,0,NULL,'cross.end');
            """)

        for range in [TimeRange.yesterday, .day(selected)] {
            let ranks = repository.topApps(range: range, now: now, calendar: local)

            XCTAssertEqual(ranks.map(\.app), ["spans.day", "cross.start", "cross.end", "inside"])
            XCTAssertEqual(ranks.map(\.usageMs), [end - start, 5_000, 3_000, 1_000])
            XCTAssertEqual(ranks.map(\.keyCount), [2, 1, 1, 0])
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
                """)

            let ranks = repository.topApps(range: .day(selected), now: date(20, month: 12), calendar: local)

            XCTAssertEqual(ranks.map(\.app), ["spans.day"])
            XCTAssertEqual(ranks.map(\.usageMs), [Int64(hours * 3_600_000)])
            XCTAssertEqual(ranks.map(\.keyCount), [2])
        }
    }

    private func makeRepository(seedSQL: String) throws -> StatsRepository {
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
        return StatsRepository(url: url)
    }
}
