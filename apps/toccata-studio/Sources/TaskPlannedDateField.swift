import SwiftUI

/// A readable date control. Calendar edits stay local until the user confirms.
@MainActor
struct TaskPlannedDateField: View {
    @ObservedObject private var interfaceLanguage = LanguageSettings.shared
    let date: Date?
    let onChange: (Date?) -> Void

    @State private var showsCalendar = false
    @State private var initialDate: Date?
    @State private var referenceDate = Date()

    var body: some View {
        let _ = interfaceLanguage.language
        Button {
            initialDate = date
            referenceDate = Date()
            showsCalendar = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "calendar")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 38, height: 38)
                    .background(Color.accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 4) {
                    Text(date.map(dateLabel) ?? L10n.tr("安排日期"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                    Text(date.map { weekdayLabel($0) + L10n.tr(" · 点击调整") } ?? L10n.tr("暂未安排，点击选择"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 11))
            .overlay {
                RoundedRectangle(cornerRadius: 11)
                    .strokeBorder(Color.primary.opacity(0.055))
            }
            .contentShape(RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.tr("设置计划日期"))
        .accessibilityValue(date.map { dateLabel($0) + "，" + weekdayLabel($0) } ?? L10n.tr("未安排日期"))
        .popover(isPresented: $showsCalendar, arrowEdge: .bottom) {
            TaskPlannedDatePicker(
                initialDate: initialDate,
                referenceDate: referenceDate,
                onCancel: { showsCalendar = false },
                onApply: { selected in
                    showsCalendar = false
                    onChange(selected)
                },
                onClear: date == nil ? nil : {
                    showsCalendar = false
                    onChange(nil)
                }
            )
        }
        .onDisappear { showsCalendar = false }
    }

    private func dateLabel(_ date: Date) -> String {
        return date.formatted(.dateTime.year().month().day().locale(L10n.locale))
    }

    private func weekdayLabel(_ date: Date) -> String {
        [L10n.tr("周日"), L10n.tr("周一"), L10n.tr("周二"), L10n.tr("周三"), L10n.tr("周四"), L10n.tr("周五"), L10n.tr("周六")][Calendar.current.component(.weekday, from: date) - 1]
    }
}
