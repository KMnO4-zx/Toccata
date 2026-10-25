import Foundation

/// Inclusive local calendar dates selected in a range calendar.
struct CalendarDateRange: Hashable {
    let start: Date
    let end: Date

    init(start: Date, end: Date, calendar: Calendar = .current) {
        let first = calendar.startOfDay(for: start)
        let last = calendar.startOfDay(for: end)
        self.start = min(first, last)
        self.end = max(first, last)
    }

    /// Bounds include the selected first day and exclude midnight after the last.
    /// Compare with `< interval.end`; DateInterval.contains also includes its end.
    func interval(calendar: Calendar = .current) -> DateInterval {
        let first = calendar.startOfDay(for: start)
        let last = calendar.startOfDay(for: end)
        let nextDay = calendar.date(byAdding: .day, value: 1, to: last) ?? last
        return DateInterval(start: first, end: nextDay)
    }
}
