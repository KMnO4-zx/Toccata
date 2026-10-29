import Foundation

enum MenuActivityPeriod: String, CaseIterable, Identifiable {
    case today, yesterday
    var id: String { rawValue }
    var title: String { self == .today ? L10n.tr("今日") : L10n.tr("昨日") }
    var range: ActivityRange { self == .today ? .today : .yesterday }
}

struct MenuActivitySnapshot {
    let period: MenuActivityPeriod
    let date: Date
    let activity: ActivitySnapshot
    let apps: [AppRank]

    /// Use the same repositories and derived daily cache as the workspace.
    /// App rankings, like the workspace, use committed records; live keyboard
    /// events supplement the keyboard view without being counted twice.
    static func load(period: MenuActivityPeriod, now: Date = Date(), calendar: Calendar = .current,
                     url: URL = Database.defaultURL, policy: ActivityPolicy = .load(),
                     liveEvents: [ActivityKeyEvent] = [], liveConnected: Bool = false) throws -> Self {
        let interval = period.range.interval(now: now, calendar: calendar)
        let date = interval.start
        let repository = ActivityRepository(url: url, policy: policy, calendar: calendar)
        let activity = repository.snapshot(range: period.range, now: now,
                                           liveEvents: liveEvents, liveConnected: liveConnected)
        if let error = activity.errorMessage { throw ActivityShareError.readFailed(error) }
        let apps = try StatsRepository(url: url, policy: policy)
            .topApps(interval: interval, limit: Int.max, now: now, calendar: calendar)
        return Self(period: period, date: date, activity: activity, apps: apps)
    }

    static func compactDuration(_ ms: Int64) -> String {
        guard ms >= 60_000 else { return Formatters.duration(ms: ms) }
        let minutes = ms / 60_000
        if minutes >= 60 { return L10n.tr("\(minutes / 60)小时\(minutes % 60)分") }
        return L10n.tr("\(minutes)分钟")
    }
}
