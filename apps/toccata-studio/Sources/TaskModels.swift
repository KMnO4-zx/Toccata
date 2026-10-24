import Foundation

enum TaskPriority: Int, CaseIterable, Identifiable {
    case none = 0
    case low = 1
    case medium = 2
    case high = 3

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .none: return "无优先级"
        case .low: return "低优先级"
        case .medium: return "中优先级"
        case .high: return "高优先级"
        }
    }
}

/// Tasks enter the inbox without a plan date. Their review date is the actual completion time.
struct TodoTask: Identifiable, Equatable {
    let id: String
    let parentID: String?
    let title: String
    let details: String
    let plannedDate: Date?
    let createdAt: Date
    let updatedAt: Date
    let completedAt: Date?
    let priority: TaskPriority

    init(id: String, parentID: String?, title: String, details: String, plannedDate: Date?,
         createdAt: Date, updatedAt: Date, completedAt: Date?, priority: TaskPriority = .none) {
        self.id = id
        self.parentID = parentID
        self.title = title
        self.details = details
        self.plannedDate = plannedDate
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
        self.priority = priority
    }

    var isCompleted: Bool { completedAt != nil }
}

struct TaskProgressEntry: Identifiable, Equatable {
    let id: String
    let taskID: String
    let text: String
    let createdAt: Date
}

enum TaskReviewPeriod: String, CaseIterable, Identifiable {
    case thisWeek = "本周"
    case lastSevenDays = "最近7天"

    var id: String { rawValue }

    /// Both windows use local calendar days, end now, and exclude future completion timestamps.
    /// The week always starts on Monday, independently of the system's first weekday.
    func interval(relativeTo date: Date, calendar suppliedCalendar: Calendar = .current) -> DateInterval {
        var calendar = suppliedCalendar
        calendar.firstWeekday = 2
        let today = calendar.startOfDay(for: date)
        let start: Date
        switch self {
        case .thisWeek:
            let weekday = calendar.component(.weekday, from: today)
            let daysSinceMonday = (weekday + 5) % 7
            start = calendar.date(byAdding: .day, value: -daysSinceMonday, to: today) ?? today
        case .lastSevenDays:
            start = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        }
        return DateInterval(start: start, end: date)
    }
}
