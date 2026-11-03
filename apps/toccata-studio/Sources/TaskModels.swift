import Foundation

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
    let isPinned: Bool
    /// Manual order among roots or siblings in the same completion/pin group.
    let subtaskOrder: Int?

    init(id: String, parentID: String?, title: String, details: String, plannedDate: Date?,
         createdAt: Date, updatedAt: Date, completedAt: Date?, isPinned: Bool = false,
         subtaskOrder: Int? = nil) {
        self.id = id
        self.parentID = parentID
        self.title = title
        self.details = details
        self.plannedDate = plannedDate
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
        self.isPinned = isPinned
        self.subtaskOrder = subtaskOrder
    }

    var isCompleted: Bool { completedAt != nil }
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
