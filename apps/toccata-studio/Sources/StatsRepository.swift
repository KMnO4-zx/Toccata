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
        case .today: return "今日"
        case .yesterday: return "昨日"
        case .week: return "近 7 日"
        case .month: return "近 30 日"
        case .day: return "指定日"
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

    /// 本地时区按自然日对齐的 [startMs, endMs) 区间。
    var intervalMs: (Int64, Int64) {
        let interval = interval()
        return (Int64(interval.start.timeIntervalSince1970 * 1000), Int64(interval.end.timeIntervalSince1970 * 1000))
    }
}

struct TodaySummary {
    var totalKeys = 0
    var holdMs: Int64 = 0
    var sessionMs: Int64 = 0
}

struct HourCount: Identifiable {
    let hour: Int
    let count: Int
    var id: Int { hour }
}

struct KeyRank: Identifiable {
    let keycode: Int
    let count: Int
    var id: Int { keycode }
}

struct AppRank: Identifiable {
    let app: String
    let usageMs: Int64
    let keyCount: Int64
    var id: String { app }
    /// bundle id 最后一段作为展示名。
    var shortName: String { app.split(separator: ".").last.map(String.init) ?? app }
}

/// 聚合查询层：所有 SQL 现算，数据量小无需缓存。DB 缺失/查询失败一律回退为空数据。
final class StatsRepository {
    private let url: URL

    init(url: URL = Database.defaultURL) {
        self.url = url
    }

    private func withDatabase<T>(_ fallback: T, _ work: (Database) throws -> T) -> T {
        do {
            return try work(Database(url: url))
        } catch {
            return fallback
        }
    }

    /// key_events 是否有任何记录（用于空态占位判断）。
    func hasAnyEvents() -> Bool {
        withDatabase(false) { db in
            ((try db.query("SELECT COUNT(*) FROM key_events") { columnInt($0, 0) }).first ?? 0) > 0
        }
    }

    func todaySummary() -> TodaySummary {
        let (start, end) = TimeRange.today.intervalMs
        return withDatabase(TodaySummary()) { db in
            var summary = TodaySummary()
            summary.totalKeys = try db.query(
                "SELECT COUNT(*) FROM key_events WHERE kind=0 AND ts_ms>=? AND ts_ms<?",
                params: [start, end]
            ) { columnInt($0, 0) }.first ?? 0
            summary.holdMs = try db.query(
                "SELECT COALESCE(SUM(hold_ms),0) FROM key_events WHERE kind=1 AND ts_ms>=? AND ts_ms<?",
                params: [start, end]
            ) { columnInt64($0, 0) }.first ?? 0
            summary.sessionMs = try db.query(
                "SELECT COALESCE(SUM(end_ms-start_ms),0) FROM app_sessions WHERE start_ms>=? AND start_ms<?",
                params: [start, end]
            ) { columnInt64($0, 0) }.first ?? 0
            return summary
        }
    }

    /// 24 小时分布（0..23 全量返回，缺的小时补 0）。
    func hourlyCounts(range: TimeRange) -> [HourCount] {
        let (start, end) = range.intervalMs
        var counts = [Int](repeating: 0, count: 24)
        withDatabase(()) { db in
            let rows = try db.query(
                """
                SELECT CAST(strftime('%H', ts_ms/1000,'unixepoch','localtime') AS INTEGER) h, COUNT(*) \
                FROM key_events WHERE kind=0 AND ts_ms>=? AND ts_ms<? GROUP BY h
                """,
                params: [start, end]
            ) { (columnInt($0, 0), columnInt($0, 1)) }
            for (hour, count) in rows where (0..<24).contains(hour) {
                counts[hour] = count
            }
        }
        return (0..<24).map { HourCount(hour: $0, count: counts[$0]) }
    }

    /// 每日按键总数，键为本地时区 "yyyy-MM-dd"。
    func dailyCounts() -> [String: Int] {
        withDatabase([:]) { db in
            let rows = try db.query(
                "SELECT date(ts_ms/1000,'unixepoch','localtime') d, COUNT(*) FROM key_events WHERE kind=0 GROUP BY d"
            ) { (columnText($0, 0), columnInt($0, 1)) }
            return Dictionary(uniqueKeysWithValues: rows)
        }
    }

    func topKeys(limit: Int = 20) -> [KeyRank] {
        withDatabase([]) { db in
            try db.query(
                "SELECT keycode, COUNT(*) n FROM key_events WHERE kind=0 GROUP BY keycode ORDER BY n DESC LIMIT ?",
                params: [Int64(limit)]
            ) { KeyRank(keycode: columnInt($0, 0), count: columnInt($0, 1)) }
        }
    }

    func keyCounts(range: TimeRange = .today, now: Date = Date(), calendar: Calendar = .current) -> [KeyRank] {
        let interval = range.interval(now: now, calendar: calendar)
        let start = Int64(interval.start.timeIntervalSince1970 * 1000)
        let end = Int64(interval.end.timeIntervalSince1970 * 1000)
        return withDatabase([]) { db in
            try db.query(
                """
                SELECT keycode, COUNT(*) n FROM key_events \
                WHERE kind=0 AND ts_ms>=? AND ts_ms<? \
                GROUP BY keycode ORDER BY n DESC, keycode ASC
                """,
                params: [start, end]
            ) { KeyRank(keycode: columnInt($0, 0), count: columnInt($0, 1)) }
        }
    }

    func topApps(range: TimeRange, limit: Int = 20, now: Date = Date(), calendar: Calendar = .current) -> [AppRank] {
        let interval = range.interval(now: now, calendar: calendar)
        let rangeStart = Int64(interval.start.timeIntervalSince1970 * 1000)
        let rangeEnd = Int64(interval.end.timeIntervalSince1970 * 1000)
        return withDatabase([]) { db in
            // Session counts can span midnight. Count dated key-down events
            // separately so clipping usage never imports an adjacent day's keys.
            try db.query(
                """
                WITH app_usage AS (
                    SELECT app, SUM(MIN(end_ms, ?)-MAX(start_ms, ?)) usage_ms
                    FROM app_sessions WHERE start_ms<? AND end_ms>?
                    GROUP BY app
                ), app_keys AS (
                    SELECT app, COUNT(*) key_count FROM key_events
                    WHERE kind=0 AND ts_ms>=? AND ts_ms<? AND app IS NOT NULL
                    GROUP BY app
                )
                SELECT app_usage.app, app_usage.usage_ms, COALESCE(app_keys.key_count, 0)
                FROM app_usage LEFT JOIN app_keys ON app_keys.app=app_usage.app
                ORDER BY app_usage.usage_ms DESC, app_usage.app ASC LIMIT ?
                """,
                params: [rangeEnd, rangeStart, rangeEnd, rangeStart, rangeStart, rangeEnd, Int64(limit)]
            ) { AppRank(app: columnText($0, 0), usageMs: columnInt64($0, 1), keyCount: columnInt64($0, 2)) }
        }
    }
}

enum Formatters {
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
            return remainder == 0 ? "\(seconds)秒" : "\(seconds).\(remainder)秒"
        }

        let totalSeconds = milliseconds / 1000
        let h = totalSeconds / 3600
        let m = (totalSeconds % 3600) / 60
        let s = totalSeconds % 60
        if h > 0 { return "\(h)小时\(m)分\(s)秒" }
        return "\(m)分\(s)秒"
    }
}
