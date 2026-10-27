import Foundation
import SQLite3
import XCTest
@testable import toccata_studio

final class DailyStatisticsCacheTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    private let policy = ActivityPolicy()

    private func date(_ day: Int, month: Int = 10, hour: Int = 0, minute: Int = 0,
                      calendar: Calendar? = nil) -> Date {
        (calendar ?? self.calendar).date(from: DateComponents(
            year: 2026, month: month, day: day, hour: hour, minute: minute
        ))!
    }

    private func ms(_ value: Date) -> Int64 { ActivityCalculator.milliseconds(value) }

    private func range(_ first: Date, _ last: Date? = nil, calendar: Calendar? = nil) -> ActivityRange {
        .custom(CalendarDateRange(start: first, end: last ?? first, calendar: calendar ?? self.calendar))
    }

    func testCompletedDayCacheSurvivesRestartWithoutReadingHistoricalRowsAgain() throws {
        let fixture = try makeFixture()
        let midnight = ms(date(20))
        try fixture.append([
            Row(midnight - 2_000, key: 49),
            Row(midnight + 10_000, key: 12, app: "app.a"),
            Row(midnight + 10_000, key: 12, app: "app.a"),
            Row(midnight + 10_100, key: 12, kind: 1, hold: 100, app: "app.a"),
            Row(midnight + 60_000, key: 63, app: "app.b"),
            Row(midnight + 90_000, key: 63, kind: 1, hold: 30_000, app: "app.b"),
            Row(ms(date(26, hour: 12)), key: 8)
        ])
        let selected = range(date(20))
        let now = date(27, hour: 12)
        var cache: DailyStatisticsCache? = fixture.cache()
        let first = try compare(try XCTUnwrap(cache), fixture: fixture, range: selected, now: now)
        XCTAssertEqual(first.keyCount, 2)
        let readCount = try XCTUnwrap(cache).diagnostics.sourceRowsRead
        let computedCount = try XCTUnwrap(cache).diagnostics.daysComputed
        _ = try compare(try XCTUnwrap(cache), fixture: fixture, range: selected, now: now.addingTimeInterval(1))
        XCTAssertEqual(try XCTUnwrap(cache).diagnostics.sourceRowsRead, readCount)
        XCTAssertEqual(try XCTUnwrap(cache).diagnostics.daysComputed, computedCount)
        XCTAssertGreaterThan(try XCTUnwrap(cache).diagnostics.dayCacheHits, 0)
        cache = nil

        let reopened = fixture.cache()
        _ = try compare(reopened, fixture: fixture, range: selected, now: now.addingTimeInterval(2))
        XCTAssertEqual(reopened.diagnostics.sourceRowsRead, 0, "Persistent completed days must not need a new raw-event scan")
        XCTAssertEqual(reopened.diagnostics.daysComputed, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.cacheURL.path))
    }

    func testNewOrdinaryEventsOnlyInvalidateTheirOwnDays() throws {
        let fixture = try makeFixture()
        try fixture.append([Row(ms(date(25, hour: 12)), key: 12)])
        let cache = fixture.cache()
        let now = date(27, hour: 12)
        let historical = range(date(25))
        _ = try compare(cache, fixture: fixture, range: historical, now: now)
        let computed = cache.diagnostics.daysComputed
        let reads = cache.diagnostics.sourceRowsRead

        try fixture.append([
            Row(ms(now) - 10_000, key: 49),
            Row(ms(now) - 9_900, key: 49, kind: 1, hold: 100)
        ])
        _ = try compare(cache, fixture: fixture, range: historical, now: now.addingTimeInterval(1))
        XCTAssertEqual(cache.diagnostics.daysComputed, computed)
        XCTAssertEqual(cache.diagnostics.sourceRowsRead - reads, 2, "Only the appended events should be consumed")
        let today = try compare(cache, fixture: fixture, range: .today, now: now.addingTimeInterval(1))
        XCTAssertEqual(today.keyCount, 1)
        XCTAssertEqual(today.activeMs, 5_000)
    }

    func testLateMultiDayReleaseRepairsAllAffectedHistoricalDays() throws {
        let fixture = try makeFixture()
        let down = ms(date(23, hour: 23, minute: 58))
        let up = ms(date(26, minute: 2))
        try fixture.append([Row(down, key: 63)])
        let cache = fixture.cache()
        let selected = range(date(23), date(25))
        let now = date(26, hour: 1)
        let before = try compare(cache, fixture: fixture, range: selected, now: now)
        XCTAssertEqual(before.fnMs, 0)
        let computed = cache.diagnostics.daysComputed

        try fixture.append([Row(up, key: 63, kind: 1, hold: up - down)])
        let after = try compare(cache, fixture: fixture, range: selected, now: now.addingTimeInterval(1))
        XCTAssertEqual(after.fnMs, ms(date(26)) - down)
        XCTAssertEqual(after.days.map(\.fnMs), [120_000, 86_400_000, 86_400_000])
        XCTAssertEqual(after.days.flatMap(\.buckets).reduce(Int64(0)) { $0 + $1.fnMs }, after.fnMs)
        XCTAssertEqual(cache.diagnostics.daysComputed - computed, 3)
    }

    func testLiveCrossMidnightHoldDoesNotPolluteCompletedDayCacheOrDoubleCount() throws {
        let fixture = try makeFixture()
        let down = ms(date(26, hour: 23, minute: 59))
        let up = ms(date(27, minute: 1))
        try fixture.append([Row(down, key: 63)])
        let cache = fixture.cache()
        let now = date(27, minute: 2)
        let live = [ActivityKeyEvent(timestampMs: down, keycode: 63, kind: 0)]
        let baseline = try compare(cache, fixture: fixture, range: .yesterday, now: now)
        XCTAssertEqual(baseline.fnMs, 0)
        let held = try compare(cache, fixture: fixture, range: .yesterday, now: now,
                               live: live, connected: true)
        XCTAssertEqual(held.fnMs, 60_000)
        XCTAssertEqual(held.keyCount, 1)
        let disconnected = try compare(cache, fixture: fixture, range: .yesterday, now: now,
                                       live: live, connected: false)
        XCTAssertEqual(disconnected.fnMs, 0)

        try fixture.append([Row(up, key: 63, kind: 1, hold: up - down)])
        let released = live + [ActivityKeyEvent(timestampMs: up, keycode: 63, kind: 1)]
        let persisted = try compare(cache, fixture: fixture, range: .yesterday, now: now,
                                    live: released, connected: true)
        XCTAssertEqual(persisted.fnMs, 60_000)
        XCTAssertEqual(persisted.keyCount, 1)
        _ = try compare(cache, fixture: fixture, range: .yesterday, now: now)
    }

    func testTodayUsesFreshNowForUnsettledWindowsAndLiveHolds() throws {
        let fixture = try makeFixture()
        let start = date(27, hour: 12)
        let down = ActivityKeyEvent(timestampMs: ms(start), keycode: 63, kind: 0)
        try fixture.append([Row(down.timestampMs, key: 63)])
        let cache = fixture.cache()
        let first = try compare(cache, fixture: fixture, range: .today, now: start.addingTimeInterval(2))
        XCTAssertEqual(first.activeMs, 2_000)
        let next = try compare(cache, fixture: fixture, range: .today, now: start.addingTimeInterval(10),
                              live: [down], connected: true)
        XCTAssertEqual(next.fnMs, 10_000)
        XCTAssertEqual(next.activeMs, 10_000)
        XCTAssertEqual(next.keyCount, 1)
    }

    func testFuturePersistedReleaseBecomesEffectiveWhenNowPassesIt() throws {
        let fixture = try makeFixture()
        let down = ms(date(25, hour: 23, minute: 59))
        let up = ms(date(26, minute: 10))
        try fixture.append([Row(down, key: 63), Row(up, key: 63, kind: 1, hold: up - down)])
        let cache = fixture.cache()
        let selected = range(date(25))
        let before = try compare(cache, fixture: fixture, range: selected, now: date(26, minute: 1))
        XCTAssertEqual(before.fnMs, 0)
        let after = try compare(cache, fixture: fixture, range: selected, now: date(26, minute: 11))
        XCTAssertEqual(after.fnMs, 60_000)
        // An earlier export/reference time must not inherit a later completed hold.
        let earlier = try compare(cache, fixture: fixture, range: selected, now: date(26, minute: 1))
        XCTAssertEqual(earlier.fnMs, 0)
    }

    func testPolicyAndTimeZoneChangesCannotReuseIncompatibleSummaries() throws {
        let fixture = try makeFixture()
        try fixture.append([Row(ms(date(20, hour: 20)), key: 12)])
        let cache = fixture.cache()
        let now = date(27, hour: 12)
        let normal = try compare(cache, fixture: fixture, range: range(date(20)), now: now)
        XCTAssertEqual(normal.activeMs, 5_000)
        let changed = try compare(cache, fixture: fixture, range: range(date(20)), now: now,
                                  policy: ActivityPolicy(activityWindowMs: 9_000))
        XCTAssertEqual(changed.activeMs, 9_000)
        var shanghai = calendar
        shanghai.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let localDay = date(20, calendar: shanghai)
        let local = try compare(cache, fixture: fixture, range: range(localDay, calendar: shanghai),
                                now: now, calendar: shanghai)
        XCTAssertEqual(local.keyCount, 0)
        let restored = try compare(cache, fixture: fixture, range: range(date(20)), now: now)
        XCTAssertEqual(restored.keyCount, 1)
        XCTAssertEqual(restored.activeMs, 5_000)
    }

    func testDaylightSavingSummariesRetainActualDayAndBucketLengths() throws {
        var local = calendar
        local.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        for (month, day, hours) in [(3, 8, 23), (11, 1, 25)] {
            let fixture = try makeFixture()
            let start = date(day, month: month, calendar: local)
            let end = local.date(byAdding: .day, value: 1, to: start)!
            let down = ms(start) - 60_000
            let up = ms(end) + 60_000
            try fixture.append([Row(down, key: 63), Row(up, key: 63, kind: 1, hold: up - down)])
            let cache = fixture.cache()
            let selected = range(start, calendar: local)
            let now = date(20, month: 12)
            for _ in 0..<2 {
                let result = try compare(cache, fixture: fixture, range: selected, now: now, calendar: local)
                XCTAssertEqual(result.activeMs, Int64(hours * 3_600_000))
                XCTAssertEqual(result.fnMs, result.activeMs)
                XCTAssertEqual(result.days.first?.buckets.count, hours * 4)
                let ranks = try cache.topApps(interval: DateInterval(start: start, end: end), limit: 20,
                                             now: now, calendar: local, policy: policy)
                XCTAssertEqual(ranks.first?.usageMs, result.activeMs)
            }
        }
    }

    func testSourceTruncationAndSamePathReplacementRebuildDerivedState() throws {
        let fixture = try makeFixture()
        let start = ms(date(20, hour: 12))
        try fixture.append([Row(start, key: 1), Row(start + 10_000, key: 2)])
        let cache = fixture.cache()
        let selected = range(date(20))
        let now = date(27, hour: 12)
        XCTAssertEqual(try compare(cache, fixture: fixture, range: selected, now: now).keyCount, 2)

        try fixture.execute("DELETE FROM key_events")
        try fixture.append([Row(start + 20_000, key: 3)])
        let truncated = try compare(cache, fixture: fixture, range: selected, now: now)
        XCTAssertEqual(truncated.keyCounts, [3: 1])

        let replacement = try makeFixture()
        try replacement.append([Row(start + 30_000, key: 4), Row(start + 40_000, key: 5)])
        let oldURL = fixture.sourceURL.appendingPathExtension("old")
        try FileManager.default.moveItem(at: fixture.sourceURL, to: oldURL)
        try FileManager.default.copyItem(at: replacement.sourceURL, to: fixture.sourceURL)
        let replaced = try compare(cache, fixture: fixture, range: selected, now: now)
        XCTAssertEqual(replaced.keyCounts, [4: 1, 5: 1])
    }

    func testInPlaceSourceCorrectionWithoutNewRowsInvalidatesSummary() throws {
        let fixture = try makeFixture()
        try fixture.append([Row(ms(date(20, hour: 12)), key: 1)])
        let cache = fixture.cache()
        let selected = range(date(20))
        let now = date(27, hour: 12)
        _ = try compare(cache, fixture: fixture, range: selected, now: now)
        try fixture.execute("UPDATE key_events SET keycode=12")
        let corrected = try compare(cache, fixture: fixture, range: selected, now: now)
        XCTAssertEqual(corrected.keyCounts, [12: 1])
    }

    func testAppLimitAppliesAfterCombiningAllDays() throws {
        let fixture = try makeFixture()
        var rows: [Row] = []
        for day in [20, 21] {
            let start = ms(date(day))
            for index in 0..<20 {
                let down = start + Int64(index) * 100_000
                let app = "day\(day).app\(index)"
                rows.append(Row(down, key: index, app: app))
                rows.append(Row(down + 70_000, key: index, kind: 1, hold: 70_000, app: app))
            }
            rows.append(Row(start + 3_000_000, key: 63, app: "consistent.app"))
            rows.append(Row(start + 3_060_000, key: 63, kind: 1, hold: 60_000, app: "consistent.app"))
        }
        try fixture.append(rows)
        let cache = fixture.cache()
        let now = date(27, hour: 12)
        for day in [20, 21] {
            let daily = try cache.topApps(interval: DateInterval(start: date(day), end: date(day + 1)),
                                         limit: 20, now: now, calendar: calendar, policy: policy)
            XCTAssertFalse(daily.contains { $0.app == "consistent.app" })
        }
        let interval = DateInterval(start: date(20), end: date(22))
        let combined = try cache.topApps(interval: interval, limit: 1, now: now, calendar: calendar, policy: policy)
        let expected = try StatsRepository(url: fixture.sourceURL, policy: policy)
            .uncachedTopApps(interval: interval, limit: 1, now: now)
        assertRanksEqual(combined, expected)
        XCTAssertEqual(combined.first?.app, "consistent.app")
        XCTAssertEqual(combined.first?.usageMs, 120_000)
        XCTAssertEqual(combined.first?.keyCount, 2)
    }

    func testDuplicateCountSemanticsRemainDifferentForCalendarKeyboardAndApps() throws {
        let fixture = try makeFixture()
        let stamp = ms(date(20, hour: 12))
        try fixture.append([
            Row(stamp, key: 12, app: "app.a"), Row(stamp, key: 12, app: "app.a"),
            Row(stamp, key: 12, app: "app.b")
        ])
        let cache = fixture.cache()
        let counts = try cache.dailyCounts(calendar: calendar, policy: policy)
        XCTAssertEqual(counts, ["2026-10-20": 3], "The calendar intentionally counts raw down rows")
        let activity = try compare(cache, fixture: fixture, range: range(date(20)), now: date(27, hour: 12))
        XCTAssertEqual(activity.keyCount, 1, "Keyboard identity does not include the foreground app")
        let apps = try cache.topApps(interval: DateInterval(start: date(20), end: date(21)), limit: 20,
                                    now: date(27, hour: 12), calendar: calendar, policy: policy)
        XCTAssertEqual(apps.map(\.app), ["app.a", "app.b"])
        XCTAssertEqual(apps.map(\.keyCount), [1, 1])
    }

    func testCorruptCacheRecoversWithoutAlteringRawSource() throws {
        let fixture = try makeFixture()
        try fixture.append([Row(ms(date(20, hour: 12)), key: 12)])
        let originalSource = try Data(contentsOf: fixture.sourceURL)
        try Data("not a SQLite database".utf8).write(to: fixture.cacheURL)
        let cache = fixture.cache()
        let selected = range(date(20))
        let now = date(27, hour: 12)
        let recovered = try compare(cache, fixture: fixture, range: selected, now: now)
        XCTAssertEqual(recovered.keyCount, 1)
        let reads = cache.diagnostics.sourceRowsRead
        let computed = cache.diagnostics.daysComputed
        let hits = cache.diagnostics.dayCacheHits
        _ = try compare(cache, fixture: fixture, range: selected, now: now)
        XCTAssertEqual(cache.diagnostics.sourceRowsRead, reads)
        XCTAssertEqual(cache.diagnostics.daysComputed, computed)
        XCTAssertGreaterThan(cache.diagnostics.dayCacheHits, hits)
        XCTAssertEqual(try Data(contentsOf: fixture.sourceURL), originalSource)
    }

    func testRepositoriesFallBackWhenTheirDerivedCacheIsUnreadable() throws {
        let fixture = try makeFixture()
        try fixture.append([Row(ms(date(20, hour: 12)), key: 12)])
        let defaultCacheURL = fixture.sourceURL.deletingPathExtension().appendingPathExtension("statistics-cache.sqlite")
        try FileManager.default.createDirectory(at: defaultCacheURL, withIntermediateDirectories: false)
        let sentinel = defaultCacheURL.appendingPathComponent("preserve.txt")
        let original = Data("A failed cache open must not delete this directory.".utf8)
        try original.write(to: sentinel)
        let now = date(27, hour: 12)
        let selected = range(date(20))
        let activity = ActivityRepository(url: fixture.sourceURL, policy: policy, calendar: calendar)
        assertSnapshotEqual(activity.snapshot(range: selected, now: now),
                            activity.uncachedSnapshot(range: selected, now: now))
        let stats = StatsRepository(url: fixture.sourceURL, policy: policy)
        let interval = DateInterval(start: date(20), end: date(21))
        assertRanksEqual(try stats.topApps(interval: interval, now: now, calendar: calendar),
                         try stats.uncachedTopApps(interval: interval, now: now))
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: defaultCacheURL.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertEqual(try Data(contentsOf: sentinel), original)
    }

    func testDailyCountKeysStayGregorianWithNonGregorianCalendar() throws {
        let fixture = try makeFixture()
        try fixture.append([Row(ms(date(19, hour: 20)), key: 12)])
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let counts = try fixture.cache().dailyCounts(calendar: buddhist, policy: policy)
        XCTAssertEqual(counts, ["2026-10-20": 1], "Calendar keys use Gregorian years while preserving the selected time zone")
    }

    func testInjectedExportSnapshotDoesNotMixInNewerCacheOrWriterData() throws {
        let fixture = try makeFixture()
        try fixture.execute("PRAGMA journal_mode=WAL")
        let start = ms(date(20, hour: 12))
        try fixture.append([Row(start, key: 12)])
        let now = date(27, hour: 12)
        let selected = range(date(20))
        let activity = ActivityRepository(url: fixture.sourceURL, policy: policy, calendar: calendar)
        let stats = StatsRepository(url: fixture.sourceURL, policy: policy)
        let interval = DateInterval(start: date(20), end: date(21))
        _ = activity.snapshot(range: selected, now: now)
        let source = try Database(url: fixture.sourceURL)
        try source.readSnapshot {
            _ = try source.query("SELECT count(*) FROM key_events") { columnInt($0, 0) }
            try fixture.append([Row(start + 20_000, key: 49)])
            XCTAssertEqual(activity.snapshot(range: selected, now: now).keyCount, 2)
            let exported = activity.snapshot(range: selected, now: now, database: source)
            XCTAssertEqual(exported.keyCount, 1)
            let apps = try stats.topApps(interval: interval, now: now, calendar: calendar, database: source)
            XCTAssertEqual(apps.first?.keyCount, 1)
        }
        XCTAssertEqual(activity.snapshot(range: selected, now: now).keyCount, 2)
    }

    func testWarmOldDayQueryDoesNotRescanLargeFollowingHistory() throws {
        let fixture = try makeFixture()
        let startDate = date(1, month: 6)
        let start = ms(startDate)
        try fixture.execute("""
            WITH RECURSIVE sequence(n) AS (
                SELECT 0 UNION ALL SELECT n+1 FROM sequence WHERE n<179999
            )
            INSERT INTO key_events(ts_ms,keycode,kind,hold_ms,app)
            SELECT \(start)+(n/2000)*86400000+((n%2000)/2)*60000+(n%2)*100,
                   (n/2)%64,n%2,CASE WHEN n%2=1 THEN 100 ELSE NULL END,'benchmark.app'
            FROM sequence;
            """)
        let cache = fixture.cache()
        let now = date(27, hour: 12)
        let selected = range(startDate)
        let baselineStart = ProcessInfo.processInfo.systemUptime
        let expected = ActivityRepository(url: fixture.sourceURL, policy: policy, calendar: calendar)
            .uncachedSnapshot(range: selected, now: now)
        let baselineSeconds = ProcessInfo.processInfo.systemUptime - baselineStart
        let coldStart = ProcessInfo.processInfo.systemUptime
        let cold = try cache.activity(range: selected, now: now, calendar: calendar, policy: policy)
        let coldSeconds = ProcessInfo.processInfo.systemUptime - coldStart
        assertSnapshotEqual(cold, expected)
        let reads = cache.diagnostics.sourceRowsRead
        let computed = cache.diagnostics.daysComputed
        let warmStart = ProcessInfo.processInfo.systemUptime
        for _ in 0..<5 {
            let warm = try cache.activity(range: selected, now: now, calendar: calendar, policy: policy)
            assertSnapshotEqual(warm, expected)
        }
        let warmSeconds = (ProcessInfo.processInfo.systemUptime - warmStart) / 5
        XCTAssertEqual(cache.diagnostics.sourceRowsRead, reads)
        XCTAssertEqual(cache.diagnostics.daysComputed, computed)
        let slightlyEarlier = try cache.activity(range: selected, now: now.addingTimeInterval(-0.001),
                                                  calendar: calendar, policy: policy)
        assertSnapshotEqual(slightlyEarlier, expected)
        XCTAssertEqual(cache.diagnostics.sourceRowsRead, reads, "A 1 ms request-order reversal must not rescan all historical rows")
        XCTAssertEqual(cache.diagnostics.daysComputed, computed)
        print(String(format: "Daily cache benchmark (180000 events): uncached %.4fs, cold %.4fs, warm %.4fs",
                     baselineSeconds, coldSeconds, warmSeconds))
    }

    @discardableResult
    private func compare(_ cache: DailyStatisticsCache, fixture: Fixture, range: ActivityRange, now: Date,
                         calendar: Calendar? = nil, policy: ActivityPolicy? = nil,
                         live: [ActivityKeyEvent] = [], connected: Bool = false,
                         file: StaticString = #filePath, line: UInt = #line) throws -> ActivitySnapshot {
        let calendar = calendar ?? self.calendar
        let policy = policy ?? self.policy
        let result = try cache.activity(range: range, now: now, calendar: calendar, policy: policy,
                                        liveEvents: live, liveConnected: connected)
        let expected = ActivityRepository(url: fixture.sourceURL, policy: policy, calendar: calendar)
            .uncachedSnapshot(range: range, now: now, liveEvents: live, liveConnected: connected)
        assertSnapshotEqual(result, expected, file: file, line: line)
        return result
    }

    private func assertSnapshotEqual(_ actual: ActivitySnapshot, _ expected: ActivitySnapshot,
                                     file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(actual.errorMessage, file: file, line: line)
        XCTAssertNil(expected.errorMessage, file: file, line: line)
        XCTAssertEqual(actual.activeMs, expected.activeMs, file: file, line: line)
        XCTAssertEqual(actual.fnMs, expected.fnMs, file: file, line: line)
        XCTAssertEqual(actual.keyCount, expected.keyCount, file: file, line: line)
        XCTAssertEqual(actual.keyCounts, expected.keyCounts, file: file, line: line)
        XCTAssertEqual(actual.days.count, expected.days.count, file: file, line: line)
        for (left, right) in zip(actual.days, expected.days) {
            XCTAssertEqual(left.date, right.date, file: file, line: line)
            XCTAssertEqual(left.activeMs, right.activeMs, file: file, line: line)
            XCTAssertEqual(left.fnMs, right.fnMs, file: file, line: line)
            XCTAssertEqual(left.keyCount, right.keyCount, file: file, line: line)
            XCTAssertEqual(left.buckets.count, right.buckets.count, file: file, line: line)
            for (a, b) in zip(left.buckets, right.buckets) {
                XCTAssertEqual(a.startMs, b.startMs, file: file, line: line)
                XCTAssertEqual(a.endMs, b.endMs, file: file, line: line)
                XCTAssertEqual(a.activeMs, b.activeMs, file: file, line: line)
                XCTAssertEqual(a.fnMs, b.fnMs, file: file, line: line)
                XCTAssertEqual(a.keyCount, b.keyCount, file: file, line: line)
            }
        }
    }

    private func assertRanksEqual(_ actual: [AppRank], _ expected: [AppRank],
                                  file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.map(\.app), expected.map(\.app), file: file, line: line)
        XCTAssertEqual(actual.map(\.usageMs), expected.map(\.usageMs), file: file, line: line)
        XCTAssertEqual(actual.map(\.keyCount), expected.map(\.keyCount), file: file, line: line)
    }

    private struct Row {
        let timestamp: Int64
        let key: Int
        let kind: Int
        let hold: Int64?
        let app: String?

        init(_ timestamp: Int64, key: Int, kind: Int = 0, hold: Int64? = nil, app: String? = "test.app") {
            self.timestamp = timestamp
            self.key = key
            self.kind = kind
            self.hold = hold
            self.app = app
        }
    }

    private struct Fixture {
        let sourceURL: URL
        let cacheURL: URL

        func cache() -> DailyStatisticsCache { DailyStatisticsCache(sourceURL: sourceURL, cacheURL: cacheURL) }

        func append(_ rows: [Row]) throws {
            let inserts = rows.map { row -> String in
                let app = row.app.map { "'\($0.replacingOccurrences(of: "'", with: "''"))'" } ?? "NULL"
                return "INSERT INTO key_events VALUES(\(row.timestamp),\(row.key),\(row.kind),\(row.hold.map(String.init) ?? "NULL"),\(app));"
            }.joined(separator: "\n")
            try execute("BEGIN;\n\(inserts)\nCOMMIT;")
        }

        func execute(_ sql: String) throws {
            var handle: OpaquePointer?
            let opened = sqlite3_open(sourceURL.path, &handle)
            guard opened == SQLITE_OK, let handle else {
                if let handle { sqlite3_close(handle) }
                throw NSError(domain: "DailyStatisticsCacheTests", code: Int(opened))
            }
            defer { sqlite3_close(handle) }
            sqlite3_busy_timeout(handle, 2_000)
            let result = sqlite3_exec(handle, sql, nil, nil, nil)
            guard result == SQLITE_OK else {
                throw NSError(domain: "DailyStatisticsCacheTests", code: Int(result),
                              userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(handle))])
            }
        }
    }

    private func makeFixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DailyStatisticsCacheTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let fixture = Fixture(sourceURL: directory.appendingPathComponent("events.db"),
                              cacheURL: directory.appendingPathComponent("cache.sqlite"))
        try fixture.execute("""
            CREATE TABLE key_events(ts_ms INTEGER NOT NULL, keycode INTEGER NOT NULL,
                                    kind INTEGER NOT NULL, hold_ms INTEGER, app TEXT);
            CREATE INDEX idx_key_events_ts ON key_events(ts_ms);
            """)
        return fixture
    }
}
