import AppKit
import SQLite3
import XCTest
@testable import toccata_studio

final class ActivityShareTests: XCTestCase {
    override func setUp() {
        super.setUp()
        let original = L10n.language
        L10n.language = .simplifiedChinese
        addTeardownBlock { L10n.language = original }
    }

    private var calendar: Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return result
    }

    private func date(_ day: Int, hour: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!
    }

    func testCustomRangeUsesSameBoundsAcrossAllSectionsAndCapsAppsAtSix() throws {
        let start = ActivityCalculator.milliseconds(date(20))
        let end = ActivityCalculator.milliseconds(date(22))
        let rows = (0..<8).map { index in
            let stamp = start + Int64(index + 1) * 60_000
            return "INSERT INTO key_events VALUES(\(stamp),\(index),0,NULL,'app.\(index)');"
        }.joined(separator: "\n")
        let url = try database(sql: """
            \(rows)
            INSERT INTO key_events VALUES(\(start - 6_000),49,0,NULL,'excluded.before');
            INSERT INTO key_events VALUES(\(end),49,0,NULL,'excluded.after');
            INSERT INTO key_events VALUES(\(start + 500_000),63,0,NULL,'app.voice');
            INSERT INTO key_events VALUES(\(start + 512_000),63,1,12000,'app.voice');
            """)
        let report = try ActivityShareSnapshot.load(range: .custom(CalendarDateRange(start: date(20), end: date(21), calendar: calendar)),
                                                   now: date(26, hour: 12), calendar: calendar, url: url)
        XCTAssertEqual(report.dateLabel, "2026-10-20 — 2026-10-21")
        XCTAssertEqual(report.filename, "Toccata-活动-2026-10-20_2026-10-21.png")
        XCTAssertEqual(report.activity.keyCount, 9)
        XCTAssertEqual(report.activity.activeMs, 52_000)
        XCTAssertEqual(report.activity.fnMs, 12_000)
        XCTAssertEqual(report.activity.days.map(\.date), [date(20), date(21)])
        XCTAssertEqual(report.activity.days.flatMap(\.buckets).reduce(0) { $0 + $1.keyCount }, 9)
        XCTAssertEqual(report.apps.map(\.app), ["app.voice", "app.0", "app.1", "app.2", "app.3", "app.4"])
        XCTAssertEqual(report.apps.first?.usageMs, 12_000)
        XCTAssertEqual(report.apps.first?.keyCount, 1)
    }

    func testYesterdayAndSingleDayIncludeEmptyDaysWithoutInventingApps() throws {
        let url = try database(sql: "")
        let report = try ActivityShareSnapshot.load(range: .yesterday, now: date(26, hour: 12), calendar: calendar, url: url)
        XCTAssertEqual(report.dateLabel, "2026-10-25")
        XCTAssertEqual(report.filename, "Toccata-活动-2026-10-25.png")
        XCTAssertEqual(report.activity.days.count, 1)
        XCTAssertEqual(report.activity.days[0].buckets.count, 96)
        XCTAssertEqual(report.activity.keyCount, 0)
        XCTAssertTrue(report.apps.isEmpty)
    }

    func testTodayIsCappedAtSnapshotTimeAndDoesNotChangeAfterLoading() throws {
        let now = date(26, hour: 12)
        let stamp = ActivityCalculator.milliseconds(now)
        let url = try database(sql: """
            INSERT INTO key_events VALUES(\(stamp - 2000),49,0,NULL,'app.current');
            INSERT INTO key_events VALUES(\(stamp + 1000),14,0,NULL,'app.future');
            """)
        let report = try ActivityShareSnapshot.load(range: .today, now: now, calendar: calendar, url: url)
        XCTAssertEqual(report.activity.activeMs, 2000)
        XCTAssertEqual(report.activity.keyCounts, [49: 1])
        XCTAssertEqual(report.apps.map(\.app), ["app.current"])
        XCTAssertEqual(report.apps.first?.usageMs, 2000)
        // Re-reading later cannot mutate the already frozen preview.
        _ = try ActivityShareSnapshot.load(range: .today, now: now.addingTimeInterval(10), calendar: calendar, url: url)
        XCTAssertEqual(report.activity.keyCount, 1)
    }

    func testReadErrorsAreNotExportedAsZeroActivity() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertThrowsError(try ActivityShareSnapshot.load(range: .today, url: missing))
        let url = try database(sql: "DROP TABLE key_events;")
        XCTAssertThrowsError(try ActivityShareSnapshot.load(range: .today, url: url))
    }

    @MainActor
    func testPNGRenderCopyAndSaveUseIdenticalImageData() throws {
        _ = NSApplication.shared
        let url = try database(sql: "")
        let report = try ActivityShareSnapshot.load(range: .today, now: date(26, hour: 12), calendar: calendar, url: url)
        let rendered = try ActivityShareImage.render(report: report, identities: [:])
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: rendered.png))
        XCTAssertEqual(bitmap.pixelsWide, 1440)
        XCTAssertGreaterThan(bitmap.pixelsHigh, 1500)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        try rendered.copy(to: board)
        XCTAssertEqual(board.data(forType: .png), rendered.png)
        XCTAssertNotNil(NSImage(pasteboard: board))
        let destination = url.deletingLastPathComponent().appendingPathComponent(report.filename)
        try rendered.save(to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), rendered.png)
        XCTAssertThrowsError(try rendered.save(to: url.appendingPathComponent("invalid.png")))
    }

    private func database(sql: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ActivityShare-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("fixture.sqlite")
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        let database = try XCTUnwrap(handle)
        defer { sqlite3_close(database) }
        let statement = "CREATE TABLE key_events(ts_ms INTEGER, keycode INTEGER, kind INTEGER, hold_ms INTEGER, app TEXT);\n" + sql
        guard sqlite3_exec(database, statement, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "ActivityShareTests", code: 1)
        }
        return url
    }
}
