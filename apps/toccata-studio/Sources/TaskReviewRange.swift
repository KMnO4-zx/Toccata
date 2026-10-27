import Foundation

/// Review-only choices keep custom dates out of the task and menu presets.
enum TaskReviewRange: Hashable {
    case preset(TaskReviewPeriod)
    case custom(CalendarDateRange)

    var title: String {
        switch self {
        case .preset(.thisWeek): return L10n.tr("本周任务回顾")
        case .preset(.lastSevenDays): return L10n.tr("最近 7 天任务回顾")
        case .custom: return L10n.tr("自定义时段任务回顾")
        }
    }

    func dateRange(relativeTo referenceDate: Date, calendar: Calendar = .current) -> CalendarDateRange {
        switch self {
        case .preset(let period):
            let interval = period.interval(relativeTo: referenceDate, calendar: calendar)
            return CalendarDateRange(start: interval.start, end: interval.end, calendar: calendar)
        case .custom(let selected):
            return CalendarDateRange(start: selected.start, end: selected.end, calendar: calendar)
        }
    }
}
