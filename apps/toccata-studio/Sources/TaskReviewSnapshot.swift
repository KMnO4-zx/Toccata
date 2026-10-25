import Foundation

/// One immutable, read-only selection drives both the visible review and its export.
/// Pending tasks remain in every review range until they are completed, regardless
/// of their creation or planned date; completed tasks use the actual completion time.
struct TaskReviewSnapshot {
    let completed: [TodoTask]
    let pending: [TodoTask]
    let tasks: [TodoTask]
    let title: String
    let dateLabel: String

    /// Export is only formatted when requested, so ordinary view updates avoid
    /// walking every detail line and formatting every task timestamp.
    var markdown: String {
        Self.export(
            title: title, dateLabel: dateLabel, completed: completed, pending: pending,
            parentTitles: parentTitles, calendar: calendar
        )
    }

    private let parentTitles: [String: String]
    private let calendar: Calendar

    init(tasks sourceTasks: [TodoTask], period: TaskReviewPeriod,
         referenceDate: Date = Date(), calendar: Calendar = .current, query: String = "") {
        self.init(tasks: sourceTasks, range: .preset(period), referenceDate: referenceDate,
                  calendar: calendar, query: query)
    }

    init(tasks sourceTasks: [TodoTask], range: TaskReviewRange,
         referenceDate: Date = Date(), calendar: Calendar = .current, query: String = "") {
        let dates = range.dateRange(relativeTo: referenceDate, calendar: calendar)
        let interval = dates.interval(calendar: calendar)
        let knownTasks = sourceTasks.filter { $0.createdAt <= referenceDate }
        let byID = Dictionary(knownTasks.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        let eligible = byID.values.filter { task in
            guard let completedAt = task.completedAt else { return true }
            return completedAt >= interval.start && completedAt < interval.end && completedAt <= referenceDate
        }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let directlyMatches: (TodoTask) -> Bool = { task in
            [task.title, task.details].contains { $0.localizedCaseInsensitiveContains(needle) }
        }
        let matchingParentIDs = Set(eligible.filter(directlyMatches).compactMap(\.parentID))
        let visible = eligible.filter { task in
            guard !needle.isEmpty else { return true }
            if directlyMatches(task) || matchingParentIDs.contains(task.id) { return true }
            // A child is also discoverable by the parent context shown beside it.
            return task.parentID.flatMap { byID[$0] }.map(directlyMatches) ?? false
        }
        let completed = visible.filter(\.isCompleted).sorted {
            if $0.completedAt != $1.completedAt { return $0.completedAt! > $1.completedAt! }
            return $0.id < $1.id
        }
        let pending = visible.filter { !$0.isCompleted }.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.id < $1.id
        }
        let title = range.title
        let dateFormatter = Self.formatter("yyyy-MM-dd", calendar: calendar)
        let dateLabel = "\(dateFormatter.string(from: dates.start)) — \(dateFormatter.string(from: dates.end))"
        let parentTitles = byID.mapValues(\.title)

        self.completed = completed
        self.pending = pending
        self.tasks = completed + pending
        self.title = title
        self.dateLabel = dateLabel
        self.parentTitles = parentTitles
        self.calendar = calendar
    }

    func parentTitle(for task: TodoTask) -> String? {
        task.parentID.flatMap { parentTitles[$0] }
    }

    private static func formatter(_ pattern: String, calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = pattern
        return formatter
    }

    private static func export(title: String, dateLabel: String, completed: [TodoTask], pending: [TodoTask],
                               parentTitles: [String: String], calendar: Calendar) -> String {
        let dateFormatter = formatter("yyyy-MM-dd", calendar: calendar)
        let timestampFormatter = formatter("yyyy-MM-dd HH:mm", calendar: calendar)
        var lines = [
            "# \(title)", "", dateLabel, "",
            "已完成 \(completed.count) 项 · 未完成 \(pending.count) 项（含子任务）", ""
        ]

        for (heading, sectionTasks, isCompleted) in [("已完成", completed, true), ("未完成", pending, false)] {
            lines += ["## \(heading)", ""]
            if sectionTasks.isEmpty {
                lines += [isCompleted ? "暂无已完成任务。" : "暂无未完成任务。", ""]
                continue
            }
            for task in sectionTasks {
                let parent = task.parentID.flatMap { parentTitles[$0] }
                let name = parent.map { "\(inlineText($0)) / \(inlineText(task.title))" } ?? inlineText(task.title)
                let metadata: String
                if let completedAt = task.completedAt {
                    metadata = "完成于 \(timestampFormatter.string(from: completedAt))"
                } else {
                    let plan = task.plannedDate.map { " · 计划 \(dateFormatter.string(from: $0))" } ?? ""
                    metadata = "创建于 \(timestampFormatter.string(from: task.createdAt))\(plan)"
                }
                lines.append("- [\(isCompleted ? "x" : " ")] \(name)（\(metadata)）")
                if !task.details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    lines += ["", "  详情："]
                    let details = task.details.replacingOccurrences(of: "\r\n", with: "\n")
                        .replacingOccurrences(of: "\r", with: "\n")
                    lines += details.components(separatedBy: "\n").map { "  \($0)" }
                }
                lines.append("")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Titles stay one literal Markdown line; details retain the user's Markdown.
    private static func inlineText(_ value: String) -> String {
        let flattened = value.components(separatedBy: .newlines).joined(separator: " ")
        let special: Set<Character> = ["\\", "`", "*", "_", "[", "]", "<", ">", "#", "|"]
        return flattened.map { special.contains($0) ? "\\\($0)" : String($0) }.joined()
    }
}
