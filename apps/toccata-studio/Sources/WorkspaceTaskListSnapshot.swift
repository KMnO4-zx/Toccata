import Foundation

enum TaskListDisplayMode: String, CaseIterable, Identifiable {
    case titles
    case details

    var id: Self { self }
    var title: String { self == .titles ? "仅标题" : "标题与描述" }
    var showsDescriptions: Bool { self == .details }
}

struct WorkspaceTaskListRow: Identifiable, Equatable {
    let node: MenuTaskTreeNode
    let depth: Int

    var task: TodoTask { node.task }
    var id: String { node.id }
}

/// Preserve scope membership while presenting every child below its parent.
/// Search only narrows this tree, so unrelated out-of-range siblings stay hidden.
struct WorkspaceTaskListSnapshot {
    let pendingRoots: [MenuTaskTreeNode]
    let completedRoots: [MenuTaskTreeNode]

    init(allTasks: [TodoTask], scopedTasks: [TodoTask], includeAllDescendants: Bool = false,
         query: String = "") {
        let roots = MenuTaskTree.roots(allTasks: allTasks, matchingTasks: scopedTasks,
                                       includeAllDescendants: includeAllDescendants)
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)

        func filtered(_ node: MenuTaskTreeNode) -> MenuTaskTreeNode? {
            guard !needle.isEmpty else { return node }
            if [node.task.title, node.task.details].contains(where: { $0.localizedCaseInsensitiveContains(needle) }) {
                return node
            }
            let children = node.children.compactMap(filtered)
            guard !children.isEmpty else { return nil }
            return MenuTaskTreeNode(task: node.task, children: children, isContextOnly: node.isContextOnly)
        }

        let matching = roots.compactMap(filtered)
        pendingRoots = matching.filter { !$0.task.isCompleted }
        completedRoots = matching.filter { $0.task.isCompleted }.sorted {
            let left = $0.task.completedAt ?? .distantPast
            let right = $1.task.completedAt ?? .distantPast
            return left == right ? $0.id < $1.id : left > right
        }
    }

    static func rows(from roots: [MenuTaskTreeNode], collapsedIDs: Set<String> = []) -> [WorkspaceTaskListRow] {
        var result: [WorkspaceTaskListRow] = []
        func append(_ node: MenuTaskTreeNode, depth: Int) {
            result.append(WorkspaceTaskListRow(node: node, depth: depth))
            guard !collapsedIDs.contains(node.id) else { return }
            node.children.forEach { append($0, depth: depth + 1) }
        }
        roots.forEach { append($0, depth: 0) }
        return result
    }
}
