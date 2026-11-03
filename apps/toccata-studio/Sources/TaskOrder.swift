import Foundation

enum TaskSortOrder: String, CaseIterable, Identifiable {
    case manual
    case createdDescending
    case createdAscending
    case title
    case plannedAscending

    static let storageKey = "tasks.sortOrder"
    var id: Self { self }
    var title: String {
        switch self {
        case .manual: return L10n.tr("手动排序")
        case .createdDescending: return L10n.tr("创建时间：从新到旧")
        case .createdAscending: return L10n.tr("创建时间：从旧到新")
        case .title: return L10n.tr("任务名称")
        case .plannedAscending: return L10n.tr("计划时间：从早到晚")
        }
    }
}

/// Sorting moves whole root branches. Children retain their own manual sibling order.
enum TaskOrder {
    static func precedes(_ lhs: TodoTask, _ rhs: TodoTask, sortOrder: TaskSortOrder) -> Bool {
        if lhs.isCompleted != rhs.isCompleted { return !lhs.isCompleted }
        if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
        switch sortOrder {
        case .manual:
            let left = lhs.subtaskOrder ?? -1
            let right = rhs.subtaskOrder ?? -1
            if left != right { return left < right }
        case .createdDescending:
            break
        case .createdAscending:
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        case .title:
            let comparison = lhs.title.localizedStandardCompare(rhs.title)
            if comparison != .orderedSame { return comparison == .orderedAscending }
        case .plannedAscending:
            switch (lhs.plannedDate, rhs.plannedDate) {
            case let (left?, right?) where left != right: return left < right
            case (_?, nil): return true
            case (nil, _?): return false
            default: break
            }
        }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
        return lhs.id < rhs.id
    }

    static func sortedRoots(_ roots: [MenuTaskTreeNode], sortOrder: TaskSortOrder) -> [MenuTaskTreeNode] {
        roots.sorted { precedes($0.task, $1.task, sortOrder: sortOrder) }
    }

    static func root(of task: TodoTask, in tasks: [TodoTask]) -> TodoTask? {
        var current = task
        var visited: Set<String> = [task.id]
        while let parentID = current.parentID {
            guard visited.insert(parentID).inserted,
                  let parent = tasks.first(where: { $0.id == parentID }) else { return nil }
            current = parent
        }
        return current
    }

    /// A root can be dropped over any row in another branch. Children stay siblings.
    static func target(for candidate: TodoTask, moving source: TodoTask, in tasks: [TodoTask]) -> TodoTask? {
        let target = source.parentID == nil ? root(of: candidate, in: tasks) : candidate
        guard let target, canMove(source, relativeTo: target) else { return nil }
        return target
    }

    static func canMove(_ source: TodoTask, relativeTo target: TodoTask) -> Bool {
        source.id != target.id && source.parentID == target.parentID &&
        source.isCompleted == target.isCompleted &&
        (source.parentID != nil || source.isPinned == target.isPinned)
    }

    /// Include hidden siblings so filtering never loses their persisted positions.
    static func reorderedIDs(in tasks: [TodoTask], moving sourceID: String,
                             relativeTo targetID: String, placement: SubtaskPlacement,
                             sortOrder: TaskSortOrder = .manual) -> [String]? {
        guard let source = tasks.first(where: { $0.id == sourceID }),
              let candidate = tasks.first(where: { $0.id == targetID }),
              let target = target(for: candidate, moving: source, in: tasks) else { return nil }
        var ids = tasks.filter {
            $0.parentID == source.parentID && $0.isCompleted == source.isCompleted &&
            (source.parentID != nil || $0.isPinned == source.isPinned) && $0.id != sourceID
        }.sorted {
            source.parentID == nil ? precedes($0, $1, sortOrder: sortOrder) : SubtaskOrder.precedes($0, $1)
        }.map(\.id)
        guard let index = ids.firstIndex(of: target.id) else { return nil }
        ids.insert(sourceID, at: placement == .before ? index : index + 1)
        return ids
    }
}
