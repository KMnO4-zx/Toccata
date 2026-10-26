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

    func snapshot(
        range: ActivityRange, now: Date = Date(),
        liveEvents: [ActivityKeyEvent] = [], liveConnected: Bool = false
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
            let database = try Database(url: url)
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
