import Foundation

enum CalendarDateSelectionMode: Equatable {
    case range
    case singleDay
}

/// Local-only editing state. Callers commit the selected range only on Apply.
struct CalendarDateRangeDraft: Equatable {
    private(set) var start: Date
    private(set) var end: Date?
    let selectionMode: CalendarDateSelectionMode

    init(initialRange: CalendarDateRange, referenceDate: Date,
         selectionMode: CalendarDateSelectionMode = .range, calendar: Calendar = .current) {
        self.selectionMode = selectionMode
        let normalized = CalendarDateRange(start: initialRange.start, end: initialRange.end, calendar: calendar)
        let latest = calendar.startOfDay(for: referenceDate)
        let end = min(normalized.end, latest)
        self.start = selectionMode == .singleDay ? end : min(normalized.start, latest)
        self.end = end
    }

    func selectedRange(calendar: Calendar = .current) -> CalendarDateRange? {
        guard let end else { return nil }
        return CalendarDateRange(start: start, end: end, calendar: calendar)
    }

    @discardableResult
    mutating func select(_ date: Date, through referenceDate: Date, calendar: Calendar = .current) -> Bool {
        let day = calendar.startOfDay(for: date)
        guard day <= calendar.startOfDay(for: referenceDate) else { return false }

        if selectionMode == .singleDay {
            start = day
            end = day
        } else if end != nil {
            start = day
            end = nil
        } else {
            let range = CalendarDateRange(start: start, end: day, calendar: calendar)
            start = range.start
            end = range.end
        }
        return true
    }
}
