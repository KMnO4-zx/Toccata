import SQLite3
import XCTest
@testable import toccata_studio

final class MenuActivitySnapshotTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    private func date(_ day: Int, hour: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!
    }

    func testOverviewMatchesWorkspaceAndKeepsEveryApp() throws {
        let now = date(29, hour: 12)
        let stamp = ActivityCalculator.milliseconds(date(29, hour: 9))
        let rows = (0..<5).map { index in
            "INSERT INTO key_events VALUES(\(stamp + Int64(index) * 10_000),\(index),0,NULL,'app.\(index)');"
        }.joined(separator: "\n")
        let url = try database(sql: rows)
        let live = [ActivityKeyEvent(timestampMs: stamp, keycode: 0, kind: 0),
                    ActivityKeyEvent(timestampMs: stamp + 100_000, keycode: 49, kind: 0)]
        let result = try MenuActivitySnapshot.load(period: .today, now: now, calendar: calendar,
                                                   url: url, liveEvents: live, liveConnected: true)
        let workspace = ActivityRepository(url: url, calendar: calendar)
            .snapshot(range: .today, now: now, liveEvents: live, liveConnected: true)
        XCTAssertEqual(result.activity.keyCount, 6, "Live/persisted overlap must be counted once")
        XCTAssertEqual(result.activity.keyCounts, workspace.keyCounts)
        XCTAssertEqual(result.activity.activeMs, workspace.activeMs)
        XCTAssertEqual(result.apps.count, 5)
        XCTAssertEqual(Set(result.apps.map(\.app)), Set((0..<5).map { "app.\($0)" }))
        XCTAssertEqual(result.apps.reduce(0) { $0 + $1.keyCount }, 5)
        XCTAssertTrue(result.apps.allSatisfy { $0.usageMs == 5_000 && $0.keyCount == 1 })
    }

    func testYesterdayExcludesToday() throws {
        let yesterday = ActivityCalculator.milliseconds(date(28, hour: 10))
        let today = ActivityCalculator.milliseconds(date(29, hour: 10))
        let url = try database(sql: """
            INSERT INTO key_events VALUES(\(yesterday),0,0,NULL,'yesterday');
            INSERT INTO key_events VALUES(\(today),1,0,NULL,'today');
            """)
        let result = try MenuActivitySnapshot.load(period: .yesterday, now: date(29, hour: 12),
                                                   calendar: calendar, url: url)
        XCTAssertEqual(result.date, date(28))
        XCTAssertEqual(result.activity.keyCount, 1)
        XCTAssertEqual(result.apps.map(\.app), ["yesterday"])
        XCTAssertEqual(result.activity.days.count, 1)
        XCTAssertEqual(result.activity.days.first?.date, date(28))
    }

    func testEmptyDatabaseKeepsEmptyDayAndNoInventedApps() throws {
        let url = try database(sql: "")
        let result = try MenuActivitySnapshot.load(period: .today, now: date(29, hour: 12),
                                                   calendar: calendar, url: url)
        XCTAssertTrue(result.apps.isEmpty)
        XCTAssertEqual(result.activity.keyCount, 0)
        XCTAssertEqual(result.activity.days.first?.buckets.count, 96)
        XCTAssertEqual(result.activity.days.count, 1)
        XCTAssertEqual(result.activity.activeMs, 0)
    }

    func testReadFailureDoesNotBecomeZeroActivity() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertThrowsError(try MenuActivitySnapshot.load(period: .today, url: url))
    }

    private func database(sql: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MenuActivity-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("activity.sqlite")
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        let handleValue = try XCTUnwrap(handle)
        defer { sqlite3_close(handleValue) }
        let schema = "CREATE TABLE key_events(ts_ms INTEGER,keycode INTEGER,kind INTEGER,hold_ms INTEGER,app TEXT);"
        XCTAssertEqual(sqlite3_exec(handleValue, schema + sql, nil, nil, nil), SQLITE_OK)
        return url
    }
}
