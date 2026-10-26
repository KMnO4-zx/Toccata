import Foundation

enum SubtaskPlacement: Equatable {
    case before
    case after
}

enum SubtaskOrder {
    static func precedes(_ lhs: TodoTask, _ rhs: TodoTask) -> Bool {
        if lhs.isCompleted != rhs.isCompleted { return !lhs.isCompleted }
        // Newly added and legacy children retain newest-first order until moved.
        let left = lhs.subtaskOrder ?? -1
        let right = rhs.subtaskOrder ?? -1
        if left != right { return left < right }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
        return lhs.id < rhs.id
    }

    static func canMove(_ source: TodoTask, relativeTo target: TodoTask) -> Bool {
        source.id != target.id && source.parentID != nil &&
        source.parentID == target.parentID && source.isCompleted == target.isCompleted
    }

    /// Always includes hidden siblings, so filtered views cannot erase their order.
    static func reorderedIDs(in tasks: [TodoTask], moving sourceID: String,
                             relativeTo targetID: String, placement: SubtaskPlacement) -> [String]? {
        guard let source = tasks.first(where: { $0.id == sourceID }),
              let target = tasks.first(where: { $0.id == targetID }),
              canMove(source, relativeTo: target) else { return nil }
        var ids = tasks.filter {
            $0.parentID == source.parentID && $0.isCompleted == source.isCompleted && $0.id != sourceID
        }.sorted(by: precedes).map(\.id)
        guard let index = ids.firstIndex(of: targetID) else { return nil }
        ids.insert(sourceID, at: placement == .before ? index : index + 1)
        return ids
    }
}
