import SwiftUI

/// A readable date control. Calendar edits stay local until the user confirms.
@MainActor
struct TaskPlannedDateField: View {
    let date: Date?
    let onChange: (Date?) -> Void

    @State private var showsCalendar = false
    @State private var initialDate: Date?
    @State private var referenceDate = Date()

    var body: some View {
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
                    Text(date.map(dateLabel) ?? "安排日期")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                    Text(date.map { weekdayLabel($0) + " · 点击调整" } ?? "暂未安排，点击选择")
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
        .accessibilityLabel("设置计划日期")
        .accessibilityValue(date.map { dateLabel($0) + "，" + weekdayLabel($0) } ?? "未安排日期")
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
        let calendar = Calendar.current
        return "\(calendar.component(.year, from: date))年\(calendar.component(.month, from: date))月\(calendar.component(.day, from: date))日"
    }

    private func weekdayLabel(_ date: Date) -> String {
        ["周日", "周一", "周二", "周三", "周四", "周五", "周六"][Calendar.current.component(.weekday, from: date) - 1]
    }
}
