import SwiftUI

/// A compact version of the sidebar's language and appearance popovers.
struct TaskListDisplayModePicker: View {
    @ObservedObject private var interfaceLanguage = LanguageSettings.shared
    @Binding var selection: TaskListDisplayMode
    @State private var isPresented = false

    var body: some View {
        let _ = interfaceLanguage.language
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 8) {
                Text(selection.title)
                    .font(.system(size: 12))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            options
        }
        .accessibilityIdentifier("task-list-display-picker")
        .accessibilityLabel(L10n.tr("任务显示方式"))
        .accessibilityValue(selection.title)
        .help(L10n.tr("切换仅标题或标题与描述"))
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(L10n.tr("显示方式"))
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.bottom, 2)
            ForEach(TaskListDisplayMode.allCases) { option in
                Button {
                    selection = option
                    isPresented = false
                } label: {
                    HStack {
                        Text(option.title)
                            .lineLimit(1)
                        Spacer(minLength: 12)
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                            .opacity(selection == option ? 1 : 0)
                    }
                    .font(.system(size: 12))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(selection == option ? Color.accentColor.opacity(0.08) : .clear,
                                in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("task-list-display-\(option.rawValue)")
                .accessibilityAddTraits(selection == option ? [.isSelected] : [])
            }
        }
        .padding(8)
        .frame(width: interfaceLanguage.language == .english ? 200 : 160)
    }
}
