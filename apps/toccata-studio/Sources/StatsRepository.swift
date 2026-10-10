import Foundation

enum TimeRange: String, CaseIterable, Identifiable {
    case today = "今日"
    case week = "近 7 日"
    case month = "近 30 日"

    var id: String { rawValue }

    /// 本地时区按自然日对齐的 [startMs, endMs) 区间。
    var intervalMs: (Int64, Int64) {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        let daysBack: Int
        switch self {
        case .today: daysBack = 0
        case .week: daysBack = 6
        case .month: daysBack = 29
        }
        let start = calendar.date(byAdding: .day, value: -daysBack, to: startOfToday) ?? startOfToday
        let end = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? startOfToday
        return (Int64(start.timeIntervalSince1970 * 1000), Int64(end.timeIntervalSince1970 * 1000))
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

    func topApps(range: TimeRange, limit: Int = 20) -> [AppRank] {
        let (start, _) = range.intervalMs
        return withDatabase([]) { db in
            try db.query(
                """
                SELECT app, SUM(end_ms-start_ms) u, SUM(key_count) \
                FROM app_sessions WHERE start_ms>=? GROUP BY app ORDER BY u DESC LIMIT ?
                """,
                params: [start, Int64(limit)]
            ) { AppRank(app: columnText($0, 0), usageMs: columnInt64($0, 1), keyCount: columnInt64($0, 2)) }
        }
    }
}

enum Formatters {
    /// 时长格式化为 "xh ym"；不足 1 小时只显示分钟，不足 1 分钟显示秒。
    static func duration(ms: Int64) -> String {
        let totalSeconds = max(0, ms / 1000)
        let h = totalSeconds / 3600
        let m = (totalSeconds % 3600) / 60
        let s = totalSeconds % 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m" }
        return "\(s)s"
    }
}
