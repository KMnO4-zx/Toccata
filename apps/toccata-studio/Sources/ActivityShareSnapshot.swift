import Foundation

/// A frozen, local-only report. Every section uses the same range, timestamp,
/// policy and committed database snapshot, independent of other page filters.
struct ActivityShareSnapshot {
    let dates: CalendarDateRange
    let calendar: Calendar
    let activity: ActivitySnapshot
    let apps: [AppRank]

    var dateLabel: String {
        let first = dateText(dates.start)
        return dates.start == dates.end ? first : "\(first) — \(dateText(dates.end))"
    }

    var filename: String {
        let first = dateText(dates.start)
        let suffix = dates.start == dates.end ? first : "\(first)_\(dateText(dates.end))"
        return "Toccata-活动-\(suffix).png"
    }

    private func dateText(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func load(range: ActivityRange, now: Date = Date(), calendar: Calendar = .current,
                     url: URL = Database.defaultURL, policy: ActivityPolicy = .load()) throws -> Self {
        let interval = range.interval(now: now, calendar: calendar)
        let last = calendar.date(byAdding: .day, value: -1, to: interval.end) ?? interval.start
        let dates = CalendarDateRange(start: interval.start, end: last, calendar: calendar)
        let database = try Database(url: url)
        return try database.readSnapshot {
            let activity = ActivityRepository(url: url, policy: policy, calendar: calendar)
                .snapshot(range: .custom(dates), now: now, database: database)
            if let message = activity.errorMessage { throw ActivityShareError.readFailed(message) }
            let apps = try StatsRepository(url: url, policy: policy)
                .topApps(interval: interval, limit: 6, now: now, database: database)
            return Self(dates: dates, calendar: calendar, activity: activity, apps: apps)
        }
    }
}

enum ActivityShareError: LocalizedError {
    case readFailed(String)
    case renderFailed
    case rangeTooLarge
    case copyFailed

    var errorDescription: String? {
        switch self {
        case .readFailed: return "暂时无法读取活动记录，请稍后重试。"
        case .renderFailed: return "图片生成失败，请重试。"
        case .rangeTooLarge: return "所选时段过长，请缩短范围后再生成图片。"
        case .copyFailed: return "无法写入剪贴板，请重试。"
        }
    }
}
