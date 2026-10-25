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

        let week = TimeRange.week.interval(now: now, calendar: calendar)
        XCTAssertEqual(week.start, date(19))
        XCTAssertEqual(week.end, date(26))

        let month = TimeRange.month.interval(now: now, calendar: calendar)
        XCTAssertEqual(month.start, date(26, month: 9))
        XCTAssertEqual(month.end, date(26))
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
        let interval = TimeRange.today.interval()
        let rangeStart = milliseconds(interval.start)
        let rangeEnd = milliseconds(interval.end)
        let repository = try makeRepository(seedSQL: """
            INSERT INTO app_sessions VALUES('cross.start',\(rangeStart - 5_000),\(rangeStart + 5_000),1);
            INSERT INTO app_sessions VALUES('cross.end',\(rangeEnd - 3_000),\(rangeEnd + 7_000),2);
            INSERT INTO app_sessions VALUES('inside',\(rangeStart + 1_000),\(rangeStart + 2_000),3);
            INSERT INTO app_sessions VALUES('past',\(rangeStart - 10_000),\(rangeStart),100);
            INSERT INTO app_sessions VALUES('future',\(rangeEnd),\(rangeEnd + 10_000),100);
            """)

        let ranks = repository.topApps(range: .today)

        XCTAssertEqual(ranks.map(\.app), ["cross.start", "cross.end", "inside"])
        XCTAssertEqual(ranks.map(\.usageMs), [5_000, 3_000, 1_000])
        XCTAssertEqual(ranks.map(\.keyCount), [1, 2, 3])
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
