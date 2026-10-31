import Foundation

enum TimeRange: Hashable, CaseIterable, Identifiable {
    case today
    case yesterday
    case week
    case month
    case day(Date)

    static let allCases: [TimeRange] = [.today, .yesterday, .week, .month]

    var id: Self { self }

    var rawValue: String {
        switch self {
        case .today: return L10n.tr("今日")
        case .yesterday: return L10n.tr("昨日")
        case .week: return L10n.tr("近 7 日")
        case .month: return L10n.tr("近 30 日")
        case .day: return L10n.tr("指定日")
        }
    }

    func interval(now: Date = Date(), calendar: Calendar = .current) -> DateInterval {
        let startOfToday = calendar.startOfDay(for: now)
        let start: Date
        let lastDay: Date
        switch self {
        case .today:
            start = startOfToday
            lastDay = startOfToday
        case .yesterday:
            start = calendar.date(byAdding: .day, value: -1, to: startOfToday) ?? startOfToday
            lastDay = start
        case .week:
            start = calendar.date(byAdding: .day, value: -6, to: startOfToday) ?? startOfToday
            lastDay = startOfToday
        case .month:
            start = calendar.date(byAdding: .day, value: -29, to: startOfToday) ?? startOfToday
            lastDay = startOfToday
        case .day(let date):
            start = calendar.startOfDay(for: date)
            lastDay = start
        }
        let end = calendar.date(byAdding: .day, value: 1, to: lastDay) ?? lastDay
        return DateInterval(start: start, end: end)
    }
}

struct AppRank: Identifiable, Codable {
    let app: String
    let usageMs: Int64
    let keyCount: Int64
    var id: String { app }
    /// bundle id 最后一段作为展示名。
    var shortName: String { app.split(separator: ".").last.map(String.init) ?? app }
}

/// Reuses derived daily summaries for dashboard queries. The original SQL
/// remains the exact fallback and the consistent-snapshot path for exports.
final class StatsRepository {
    private let url: URL
    private let policy: ActivityPolicy

    init(url: URL = Database.defaultURL, policy: ActivityPolicy = .load()) {
        self.url = url
        self.policy = policy
    }

    private func withDatabase<T>(_ fallback: T, _ work: (Database) throws -> T) -> T {
        do {
            return try work(Database(url: url))
        } catch {
            return fallback
        }
    }

    /// 每日按键总数，键为本地时区 "yyyy-MM-dd"。
    func dailyCounts() -> [String: Int] {
        if let cached = try? DailyStatisticsCache.shared(for: url).dailyCounts(calendar: .current, policy: policy) {
            return cached
        }
        return uncachedDailyCounts()
    }

    /// Preserve the original raw down-event count, including duplicate rows.
    func uncachedDailyCounts() -> [String: Int] {
        withDatabase([:]) { db in
            let rows = try db.query(
                "SELECT date(ts_ms/1000,'unixepoch','localtime') d, COUNT(*) FROM key_events WHERE kind=0 GROUP BY d"
            ) { (columnText($0, 0), columnInt($0, 1)) }
            return Dictionary(uniqueKeysWithValues: rows)
        }
    }

    func topApps(range: TimeRange, limit: Int = 20, now: Date = Date(), calendar: Calendar = .current) -> [AppRank] {
        let interval = range.interval(now: now, calendar: calendar)
        return (try? topApps(interval: interval, limit: limit, now: now, calendar: calendar)) ?? []
    }

    /// Accept exact bounds so sharing uses the same custom range as the keyboard.
    /// Unlike the dashboard fallback, export callers must surface read failures.
    func topApps(interval: DateInterval, limit: Int = 20, now: Date = Date(),
                 calendar: Calendar = .current, database: Database? = nil) throws -> [AppRank] {
        // Daily totals can only be summed for whole natural-day boundaries.
        // Arbitrary export bounds and injected snapshots retain exact SQL.
        let wholeDays = interval.duration > 0
            && interval.start == calendar.startOfDay(for: interval.start)
            && interval.end == calendar.startOfDay(for: interval.end)
        if database == nil, wholeDays, let cached = try? DailyStatisticsCache.shared(for: url).topApps(
            interval: interval, limit: limit, now: now, calendar: calendar, policy: policy
        ) {
            return cached
        }
        return try uncachedTopApps(interval: interval, limit: limit, now: now, database: database)
    }

    func uncachedTopApps(interval: DateInterval, limit: Int = 20, now: Date = Date(),
                         database: Database? = nil) throws -> [AppRank] {
        let nowMs = ActivityCalculator.milliseconds(now)
        let window = ActivitySpan(startMs: ActivityCalculator.milliseconds(interval.start),
                                  endMs: min(ActivityCalculator.milliseconds(interval.end), nowMs))
        guard window.endMs > window.startMs, limit > 0 else { return [] }
        let db = try database ?? Database(url: url)
        // Reconstruct historical and current rankings from raw events using
        // the same policy as the keyboard overview, without waiting for an
        // app_sessions segment to settle. Later releases can carry a hold
        // that crosses the selected end, so include those through now.
        // Union in SQLite so a month of raw events does not have to be
        // materialized as Swift objects on each refresh. The running MAX
        // handles nested holds as well as ordinary overlapping windows.
        return try db.query(
            """
            WITH selected_events AS (
                SELECT DISTINCT app, ts_ms, keycode, kind, hold_ms FROM key_events
                WHERE app IS NOT NULL AND ts_ms>=?3 AND ts_ms<=?4
                    AND (ts_ms<?2 OR (kind=1 AND hold_ms>0 AND ts_ms-hold_ms<?2))
            ), event_spans AS (
                SELECT app,
                    MAX(?1, CASE WHEN kind=0 THEN ts_ms ELSE ts_ms-hold_ms END) start_ms,
                    MIN(?2, CASE WHEN kind=0 THEN ts_ms+?5 ELSE ts_ms END) end_ms
                FROM selected_events WHERE kind=0 OR (kind=1 AND hold_ms>0)
            ), covered_spans AS (
                SELECT app, start_ms, end_ms,
                    MAX(end_ms) OVER (PARTITION BY app ORDER BY start_ms, end_ms
                        ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) previous_end
                FROM event_spans WHERE end_ms>start_ms
            ), app_usage AS (
                SELECT app, SUM(MAX(0, end_ms-MAX(start_ms, COALESCE(previous_end, start_ms)))) usage_ms
                FROM covered_spans GROUP BY app
            ), app_keys AS (
                SELECT app, COUNT(*) key_count FROM selected_events
                WHERE kind=0 AND ts_ms>=?1 AND ts_ms<?2 GROUP BY app
            ), apps AS (
                SELECT app FROM app_usage UNION SELECT app FROM app_keys
            )
            SELECT apps.app, COALESCE(app_usage.usage_ms, 0), COALESCE(app_keys.key_count, 0)
            FROM apps LEFT JOIN app_usage ON app_usage.app=apps.app
                LEFT JOIN app_keys ON app_keys.app=apps.app
            ORDER BY COALESCE(app_usage.usage_ms, 0) DESC, apps.app ASC LIMIT ?6
            """,
            params: [window.startMs, window.endMs, window.startMs - policy.activityWindowMs,
                     nowMs, policy.activityWindowMs, Int64(limit)]
        ) { AppRank(app: columnText($0, 0), usageMs: columnInt64($0, 1), keyCount: columnInt64($0, 2)) }
    }
}

enum Formatters {
    /// Share of all key presses in the selected period, rounded to at most one decimal place.
    static func keyPercentage(count: Int, totalCount: Int) -> String {
        guard count > 0, totalCount > 0 else { return "0%" }
        let tenths = Int((Double(min(count, totalCount)) / Double(totalCount) * 1_000).rounded())
        let whole = tenths / 10
        let fraction = tenths % 10
        return fraction == 0 ? "\(whole)%" : "\(whole).\(fraction)%"
    }

    /// 一千次起使用 K，保留至多两位小数；较小的计数保留原数字。
    static func keyCount(_ count: Int) -> String {
        let count = max(0, count)
        guard count >= 1_000 else { return String(count) }
        // One hundredth of K is ten presses. Integer rounding avoids overflow
        // and floating-point artifacts, including at very large counts.
        let hundredths = count / 10 + (count % 10 >= 5 ? 1 : 0)
        let whole = hundredths / 100
        let fraction = hundredths % 100
        if fraction == 0 { return "\(whole)K" }
        if fraction % 10 == 0 { return "\(whole).\(fraction / 10)K" }
        let decimal = fraction < 10 ? "0\(fraction)" : String(fraction)
        return "\(whole).\(decimal)K"
    }

    /// 不足 10 分钟显示秒；之后保留分、秒，满一小时再显示小时。
    static func duration(ms: Int64) -> String {
        let milliseconds = max(0, ms)
        if milliseconds < 600_000 {
            // Truncate to tenths so 599.99 seconds cannot round across the threshold.
            let tenths = milliseconds / 100
            let seconds = tenths / 10
            let remainder = tenths % 10
            return remainder == 0 ? L10n.tr("\(seconds)秒") : L10n.tr("\(seconds).\(remainder)秒")
        }

        let totalSeconds = milliseconds / 1000
        let h = totalSeconds / 3600
        let m = (totalSeconds % 3600) / 60
        let s = totalSeconds % 60
        if h > 0 { return L10n.tr("\(h)小时\(m)分\(s)秒") }
        return L10n.tr("\(m)分\(s)秒")
    }
}
