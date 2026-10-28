import Foundation
import SQLite3

/// Activity is reconstructed from key events, including the current session;
/// historical app_sessions are deliberately not required for these metrics.
final class ActivityRepository {
    private let url: URL
    private let policy: ActivityPolicy
    private let calendar: Calendar

    init(url: URL = Database.defaultURL, policy: ActivityPolicy = .load(), calendar: Calendar = .current) {
        self.url = url
        self.policy = policy
        self.calendar = calendar
    }

    var calculationPolicy: ActivityPolicy { policy }

    /// Count only today's distinct key-downs. Read the count and the live overlap
    /// from one committed snapshot so a daemon flush cannot count a key twice.
    func todayKeyCount(now: Date = Date(), liveEvents: [ActivityKeyEvent] = [],
                       liveConnected: Bool = false) throws -> Int {
        let interval = ActivityRange.today.interval(now: now, calendar: calendar)
        let start = ActivityCalculator.milliseconds(interval.start)
        let end = min(ActivityCalculator.milliseconds(interval.end), ActivityCalculator.milliseconds(now))
        let live = Set((liveConnected ? liveEvents : []).filter {
            $0.kind == 0 && $0.timestampMs >= start && $0.timestampMs < end
        }.map { ActivityKeyEvent(timestampMs: $0.timestampMs, keycode: $0.keycode, kind: 0) })
        let database = try Database(url: url)
        return try database.readSnapshot {
            let count = try database.query("""
                SELECT COUNT(*) FROM (
                    SELECT DISTINCT ts_ms, keycode FROM key_events
                    WHERE kind=0 AND ts_ms>=? AND ts_ms<?
                )
                """, params: [start, end]) { columnInt($0, 0) }.first ?? 0
            guard let firstLive = live.map(\.timestampMs).min() else { return count }
            let persisted = Set(try database.query("""
                SELECT DISTINCT ts_ms, keycode FROM key_events
                WHERE kind=0 AND ts_ms>=? AND ts_ms<?
                """, params: [firstLive, end]) {
                ActivityKeyEvent(timestampMs: columnInt64($0, 0), keycode: columnInt($0, 1), kind: 0)
            })
            return count + live.subtracting(persisted).count
        }
    }

    func snapshot(
        range: ActivityRange, now: Date = Date(),
        liveEvents: [ActivityKeyEvent] = [], liveConnected: Bool = false, database: Database? = nil
    ) -> ActivitySnapshot {
        // Export callers supply one committed database snapshot for all report
        // sections. Keep that path independent of the shared derived cache.
        if database == nil, let cached = try? DailyStatisticsCache.shared(for: url).activity(
            range: range, now: now, calendar: calendar, policy: policy,
            liveEvents: liveEvents, liveConnected: liveConnected
        ) {
            return cached
        }
        return uncachedSnapshot(range: range, now: now, liveEvents: liveEvents,
                                liveConnected: liveConnected, database: database)
    }

    /// Exact reconstruction remains available if the disposable cache cannot
    /// be read or written, and as the reference for cache regression tests.
    func uncachedSnapshot(
        range: ActivityRange, now: Date = Date(),
        liveEvents: [ActivityKeyEvent] = [], liveConnected: Bool = false, database: Database? = nil
    ) -> ActivitySnapshot {
        let interval = range.interval(now: now, calendar: calendar)
        // Include key-down windows that started just before the selected day.
        let start = ActivityCalculator.milliseconds(interval.start) - policy.activityWindowMs
        // A key released after a historical selection can carry a hold that
        // overlaps it. Read through now, then clip reconstructed spans below.
        let end = ActivityCalculator.milliseconds(now)
        var events: [ActivityKeyEvent] = []
        var error: String?
        do {
            let database = try database ?? Database(url: url)
            events = try database.query(
                "SELECT ts_ms, keycode, kind, hold_ms FROM key_events WHERE ts_ms >= ? AND ts_ms <= ? ORDER BY ts_ms, rowid",
                params: [start, end]
            ) { statement in
                ActivityKeyEvent(timestampMs: columnInt64(statement, 0), keycode: columnInt(statement, 1),
                    kind: columnInt(statement, 2),
                    holdMs: sqlite3_column_type(statement, 3) == SQLITE_NULL ? nil : columnInt64(statement, 3))
            }
        } catch let failure {
            error = failure.localizedDescription
        }
        var result = ActivityCalculator.snapshot(events: events, range: range, now: now,
            calendar: calendar, policy: policy, liveEvents: liveEvents, liveConnected: liveConnected)
        result.errorMessage = error
        return result
    }
}
