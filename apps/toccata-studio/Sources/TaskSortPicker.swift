import SwiftUI

/// Both task surfaces use the same choices and persisted selection.
struct TaskSortPicker: View {
    @ObservedObject private var interfaceLanguage = LanguageSettings.shared
    @Binding var selection: TaskSortOrder
    var menuStyle = false

    var body: some View {
        let _ = interfaceLanguage.language
        Menu {
            Picker(L10n.tr("排序"), selection: $selection) {
                ForEach(TaskSortOrder.allCases) { order in
                    Text(order.title).tag(order)
                }
            }
            .pickerStyle(.inline)
            .id(interfaceLanguage.language)
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: 14))
                .foregroundStyle(menuStyle ? TaskMenuStyle.primary : Color.primary)
                .frame(width: 26, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityIdentifier("task-sort-picker")
        .accessibilityLabel(L10n.tr("任务排序"))
        .accessibilityValue(selection.title)
        .help(selection.title)
    }
}
