import Foundation

struct MenuTaskTreeNode: Identifiable, Equatable {
    let task: TodoTask
    let children: [MenuTaskTreeNode]
    /// Ancestors included to explain a matching descendant, rather than matching
    /// the selected time window themselves.
    let isContextOnly: Bool

    var id: String { task.id }
}

enum MenuTaskTree {
    /// Builds a unique task hierarchy without changing the scope's date rules.
    /// Inbox callers include descendants; time views include matches and ancestors.
    static func roots(allTasks: [TodoTask], matchingTasks: [TodoTask],
                      includeAllDescendants: Bool = false) -> [MenuTaskTreeNode] {
        var tasksByID: [String: TodoTask] = [:]
        for task in allTasks where tasksByID[task.id] == nil {
            tasksByID[task.id] = task
        }
        // A caller can provide a just-created match before its full snapshot updates.
        for task in matchingTasks where tasksByID[task.id] == nil {
            tasksByID[task.id] = task
        }

        var matchingIDs = Set(matchingTasks.map(\.id))
        if includeAllDescendants {
            let childrenByParent = Dictionary(grouping: tasksByID.values.compactMap { task in
                task.parentID.map { (parent: $0, child: task.id) }
            }, by: \.parent)
            var pending = Array(matchingIDs)
            while let parent = pending.popLast() {
                for child in childrenByParent[parent] ?? [] {
                    if matchingIDs.insert(child.child).inserted {
                        pending.append(child.child)
                    }
                }
            }
        }

        var includedIDs = matchingIDs
        var pending = Array(matchingIDs)
        while let id = pending.popLast() {
            guard let parent = tasksByID[id]?.parentID, tasksByID[parent] != nil else { continue }
            if includedIDs.insert(parent).inserted {
                pending.append(parent)
            }
        }

        var parentByID: [String: String] = [:]
        for id in includedIDs {
            if let parent = tasksByID[id]?.parentID, includedIDs.contains(parent) {
                parentByID[id] = parent
            }
        }

        // Persisted records normally form a tree. If damaged/imported records form
        // a cycle, detach its smallest ID so the result remains stable and finite.
        var settled = Set<String>()
        for id in includedIDs.sorted() where !settled.contains(id) {
            var path: [String] = []
            var indexByID: [String: Int] = [:]
            var cursor: String? = id
            while let current = cursor, !settled.contains(current) {
                if let cycleStart = indexByID[current] {
                    if let root = path[cycleStart...].min() {
                        parentByID.removeValue(forKey: root)
                    }
                    break
                }
                indexByID[current] = path.count
                path.append(current)
                cursor = parentByID[current]
            }
            settled.formUnion(path)
        }

        let childrenByParent = Dictionary(grouping: includedIDs.compactMap { id in
            parentByID[id].map { (parent: $0, child: id) }
        }, by: \.parent)

        func precedes(_ lhs: String, _ rhs: String) -> Bool {
            guard let left = tasksByID[lhs], let right = tasksByID[rhs] else { return lhs < rhs }
            if left.isCompleted != right.isCompleted { return !left.isCompleted }
            if left.createdAt != right.createdAt { return left.createdAt > right.createdAt }
            return lhs < rhs
        }

        func node(for id: String) -> MenuTaskTreeNode {
            let children = (childrenByParent[id] ?? []).map(\.child).sorted {
                SubtaskOrder.precedes(tasksByID[$0]!, tasksByID[$1]!)
            }
            return MenuTaskTreeNode(task: tasksByID[id]!, children: children.map(node),
                                    isContextOnly: !matchingIDs.contains(id))
        }

        return includedIDs.filter { parentByID[$0] == nil }
            .sorted(by: precedes).map(node)
    }
}
