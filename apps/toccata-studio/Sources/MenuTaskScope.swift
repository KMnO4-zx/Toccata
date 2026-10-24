import Foundation

enum MenuTaskScope: String, CaseIterable, Identifiable {
    case inbox
    case lastSevenDays
    case thisWeek

    var id: String { rawValue }

    var title: String {
        switch self {
        case .inbox: return "收集箱"
        case .lastSevenDays: return "最近 7 天"
        case .thisWeek: return "本周任务"
        }
    }

    var symbol: String {
        switch self {
        case .inbox: return "tray"
        case .lastSevenDays: return "clock.arrow.circlepath"
        case .thisWeek: return "calendar"
        }
    }

    var titleExplanation: String {
        switch self {
        case .inbox: return "想到的任务都留在这里，计划日期可以留空。"
        case .lastSevenDays: return "最近 7 天创建的任务，包含已完成事项。"
        case .thisWeek: return "本周新建、之前未完成，以及本周完成的任务。"
        }
    }

    /// Task views use creation dates and current state. Completion review remains a
    /// separate projection for weekly reports. Time views include matching children
    /// so a recent step is visible even when its parent was created earlier.
    func tasks(from tasks: [TodoTask], relativeTo date: Date = Date(),
               calendar: Calendar = .current) -> [TodoTask] {
        let period: TaskReviewPeriod = self == .lastSevenDays ? .lastSevenDays : .thisWeek
        let interval = period.interval(relativeTo: date, calendar: calendar)
        return tasks.filter { task in
            guard task.createdAt <= date else { return false }
            switch self {
            case .inbox:
                return task.parentID == nil
            case .lastSevenDays:
                return task.createdAt >= interval.start
            case .thisWeek:
                let completedThisWeek = task.completedAt.map {
                    $0 >= interval.start && $0 <= interval.end
                } ?? false
                return task.createdAt >= interval.start || !task.isCompleted || completedThisWeek
            }
        }.sorted {
            if $0.isCompleted != $1.isCompleted { return !$0.isCompleted }
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.id < $1.id
        }
    }

    // Kept for callers that need to open the corresponding completion review.
    var reviewPeriod: TaskReviewPeriod? {
        switch self {
        case .inbox: return nil
        case .lastSevenDays: return .lastSevenDays
        case .thisWeek: return .thisWeek
        }
    }
}

@MainActor
extension TaskStore {
    func menuTasks(for scope: MenuTaskScope, relativeTo date: Date = Date(),
                   calendar: Calendar = .current) -> [TodoTask] {
        scope.tasks(from: tasks, relativeTo: date, calendar: calendar)
    }
}
