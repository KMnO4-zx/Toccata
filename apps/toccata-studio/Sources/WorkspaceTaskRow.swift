import SwiftUI

/// A light row shared by task lists. Child placement carries the relationship,
/// so children do not need to repeat their parent's title below every name.
struct WorkspaceTaskRow: View {
    @ObservedObject private var interfaceLanguage = LanguageSettings.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let task: TodoTask
    let displayMode: TaskListDisplayMode
    var depth = 0
    var parentTitle: String?
    var childCount = 0
    var isExpanded = true
    let onToggle: () -> Void
    var onToggleExpanded: (() -> Void)?

    var body: some View {
        let _ = interfaceLanguage.language
        HStack(alignment: .top, spacing: 10) {
            Button(action: onToggle) {
                Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: depth == 0 ? 19 : 17, weight: .regular))
                    .foregroundStyle(task.isCompleted ? Color.accentColor : Color.secondary.opacity(0.65))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(task.isCompleted ? L10n.tr("将\(task.title)恢复为待办") : L10n.tr("完成\(task.title)"))

            VStack(alignment: .leading, spacing: 5) {
                Text(task.title)
                    .font(.system(size: depth == 0 ? 14 : 13, weight: depth == 0 ? .medium : .regular))
                    .foregroundStyle(task.isCompleted ? .secondary : .primary)
                    .strikethrough(task.isCompleted, color: .secondary.opacity(0.5))
                    .lineLimit(2)
                    .frame(minHeight: 22, alignment: .leading)
                if let parentTitle {
                    Label(parentTitle, systemImage: "arrow.turn.down.right")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if displayMode.showsDescriptions, !task.details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(task.details)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            SubtaskDragHandle(task: task)

            if childCount > 0, let onToggleExpanded {
                Button(action: onToggleExpanded) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .animation(reduceMotion ? nil : WorkspaceMotion.branchChange, value: isExpanded)
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isExpanded ? L10n.tr("收起 \(childCount) 个子任务") : L10n.tr("展开 \(childCount) 个子任务"))
                .accessibilityLabel(isExpanded ? L10n.tr("收起\(task.title)的子任务") : L10n.tr("展开\(task.title)的子任务"))
                .accessibilityValue(isExpanded ? L10n.tr("已展开") : L10n.tr("已收起"))
            }
        }
        .padding(.leading, CGFloat(depth) * 26)
        .padding(.vertical, displayMode.showsDescriptions ? 9 : 6)
        .contentShape(Rectangle())
    }
}
