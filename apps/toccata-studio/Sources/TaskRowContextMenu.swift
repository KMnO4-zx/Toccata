import SwiftUI

/// Keep task actions available wherever a task row is shown.
@MainActor
private struct TaskRowContextMenu: ViewModifier {
    @EnvironmentObject private var store: TaskStore
    @State private var confirmsDeletion = false

    let task: TodoTask
    let onEdit: () -> Void

    func body(content: Content) -> some View {
        content
            .contextMenu {
                Button(action: onEdit) {
                    Label(L10n.tr("编辑详情"), systemImage: "square.and.pencil")
                }
                Button {
                    _ = store.setCompleted(id: task.id, completed: !task.isCompleted)
                } label: {
                    Label(task.isCompleted ? L10n.tr("恢复为待办") : L10n.tr("标记完成"), systemImage: task.isCompleted ? "arrow.uturn.backward" : "checkmark.circle")
                }
                Divider()
                Button(role: .destructive) {
                    confirmsDeletion = true
                } label: {
                    Label(L10n.tr("删除任务…"), systemImage: "trash")
                }
            }
            .alert(L10n.tr("删除这个任务？"), isPresented: $confirmsDeletion) {
                Button(L10n.tr("取消"), role: .cancel) {}
                Button(L10n.tr("删除任务"), role: .destructive) {
                    _ = store.deleteTask(id: task.id)
                }
            } message: {
                Text(store.children(of: task.id).isEmpty
                     ? L10n.tr("任务详情也会删除。此操作无法撤销。")
                     : L10n.tr("任务、所有子任务及其详情都会删除。此操作无法撤销。"))
            }
    }
}

extension View {
    @MainActor
    func taskContextMenu(task: TodoTask, onEdit: @escaping () -> Void) -> some View {
        modifier(TaskRowContextMenu(task: task, onEdit: onEdit))
    }
}
