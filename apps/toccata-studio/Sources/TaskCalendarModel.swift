import Foundation

enum TaskCalendarMode: String, CaseIterable, Identifiable {
    case all
    case planned
    case created
    case completed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return L10n.tr("全部记录")
        case .planned: return L10n.tr("计划")
        case .created: return L10n.tr("创建")
        case .completed: return L10n.tr("完成")
        }
    }
}

struct CalendarDateCell: Identifiable, Equatable {
    let date: Date
    let isInDisplayedMonth: Bool
    var id: Date { date }
}

struct TaskCalendarEventCounts: Equatable {
    let created: Int
    let planned: Int
    let completed: Int

    /// Counts events, so one task may contribute to more than one kind on a day.
    var total: Int { created + planned + completed }
}

/// All grouping uses local calendar days. Planned dates remain optional; viewing
/// an unscheduled task never assigns it to today or changes its creation date.
enum TaskCalendarModel {
    /// A Monday-first grid padded to whole weeks, including adjacent-month days.
    static func days(in month: Date, calendar: Calendar = .current) -> [CalendarDateCell] {
        guard let monthInterval = calendar.dateInterval(of: .month, for: month),
              let numberOfDays = calendar.range(of: .day, in: .month, for: month)?.count else { return [] }
        let monthStart = monthInterval.start
        let weekday = calendar.component(.weekday, from: monthStart)
        let leadingDays = (weekday + 5) % 7
        guard let gridStart = calendar.date(byAdding: .day, value: -leadingDays, to: monthStart) else { return [] }
        let cellCount = ((leadingDays + numberOfDays + 6) / 7) * 7
        return (0..<cellCount).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: gridStart) else { return nil }
            return CalendarDateCell(date: day,
                                    isInDisplayedMonth: day >= monthInterval.start && day < monthInterval.end)
        }
    }

    /// Starts from the first day, avoiding end-of-month overflow during navigation.
    static func month(byAdding offset: Int, to date: Date, calendar: Calendar = .current) -> Date {
        let start = calendar.dateInterval(of: .month, for: date)?.start ?? calendar.startOfDay(for: date)
        return calendar.date(byAdding: .month, value: offset, to: start) ?? start
    }

    /// Children appear independently, with parent context supplied by the UI.
    /// The all-events mode returns each task only once even for multiple same-day events.
    static func tasks(on day: Date, from tasks: [TodoTask], mode: TaskCalendarMode = .all,
                      calendar: Calendar = .current) -> [TodoTask] {
        ordered(tasks.filter { task in
            switch mode {
            case .all:
                return matches(task.createdAt, day: day, calendar: calendar)
                    || matches(task.plannedDate, day: day, calendar: calendar)
                    || matches(task.completedAt, day: day, calendar: calendar)
            case .created: return matches(task.createdAt, day: day, calendar: calendar)
            case .planned: return matches(task.plannedDate, day: day, calendar: calendar)
            case .completed: return matches(task.completedAt, day: day, calendar: calendar)
            }
        })
    }

    static func unscheduledTasks(from tasks: [TodoTask]) -> [TodoTask] {
        ordered(tasks.filter { $0.plannedDate == nil })
    }

    static func eventCounts(on day: Date, from tasks: [TodoTask],
                            calendar: Calendar = .current) -> TaskCalendarEventCounts {
        TaskCalendarEventCounts(
            created: tasks.filter { matches($0.createdAt, day: day, calendar: calendar) }.count,
            planned: tasks.filter { matches($0.plannedDate, day: day, calendar: calendar) }.count,
            completed: tasks.filter { matches($0.completedAt, day: day, calendar: calendar) }.count)
    }

    private static func matches(_ date: Date?, day: Date, calendar: Calendar) -> Bool {
        date.map { calendar.isDate($0, inSameDayAs: day) } ?? false
    }

    private static func ordered(_ tasks: [TodoTask]) -> [TodoTask] {
        tasks.sorted {
            if $0.isCompleted != $1.isCompleted { return !$0.isCompleted }
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.id < $1.id
        }
    }
}
