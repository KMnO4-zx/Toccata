import SwiftUI

@MainActor
struct TaskMonthGrid: View {
    let tasks: [TodoTask]
    @Binding var displayedMonth: Date
    @Binding var selectedDay: Date
    var compact = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let calendar = Calendar.current
    private let weekdayLabels = ["一", "二", "三", "四", "五", "六", "日"]
    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: compact ? 1 : 4), count: 7)
    }

    var body: some View {
        VStack(spacing: compact ? 9 : 14) {
            HStack(spacing: compact ? 5 : 9) {
                Text(monthLabel)
                    .font(.system(size: compact ? 14 : 17, weight: .semibold, design: .rounded))
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                Button("今天", action: showToday)
                    .controlSize(.small)
                    .help("回到今天")
                Button { moveMonth(-1) } label: { Image(systemName: "chevron.left") }
                    .controlSize(.small)
                    .help("上个月")
                    .accessibilityLabel("上个月")
                Button { moveMonth(1) } label: { Image(systemName: "chevron.right") }
                    .controlSize(.small)
                    .help("下个月")
                    .accessibilityLabel("下个月")
            }

            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(Array(weekdayLabels.enumerated()), id: \.offset) { index, label in
                    Text(label)
                        .font(.system(size: compact ? 9 : 10, weight: .medium))
                        .foregroundStyle(index >= 5 ? Color.secondary.opacity(0.6) : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 3)
                }
                ForEach(TaskCalendarModel.days(in: displayedMonth, calendar: calendar)) { cell in
                    calendarCell(cell)
                }
            }
            .id(displayedMonth)
            .transition(WorkspaceMotion.calendarTransition)
            .animation(reduceMotion ? nil : WorkspaceMotion.menuChange, value: displayedMonth)
            .clipped()

            if !compact {
                HStack(spacing: 15) {
                    eventLegend("创建", color: .blue)
                    eventLegend("计划", color: .orange)
                    eventLegend("完成", color: .green)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(compact ? 0 : 15)
        .background(Color(nsColor: .controlBackgroundColor).opacity(compact ? 0 : 0.65),
                    in: RoundedRectangle(cornerRadius: 13))
    }

    private func calendarCell(_ cell: CalendarDateCell) -> some View {
        let counts = TaskCalendarModel.eventCounts(on: cell.date, from: tasks, calendar: calendar)
        let selected = calendar.isDate(cell.date, inSameDayAs: selectedDay)
        let today = calendar.isDateInToday(cell.date)

        return Button {
            selectedDay = cell.date
            if !cell.isInDisplayedMonth { displayedMonth = cell.date }
        } label: {
            VStack(spacing: compact ? 2 : 5) {
                Text("\(calendar.component(.day, from: cell.date))")
                    .font(.system(size: compact ? 11 : 12,
                                  weight: today || selected ? .semibold : .regular, design: .rounded))
                    .foregroundStyle(selected ? Color.white : (today ? Color.accentColor : Color.primary))
                    .frame(width: compact ? 22 : 24, height: compact ? 22 : 24)
                    .background(selected ? Color.accentColor : (today ? Color.accentColor.opacity(0.11) : Color.clear), in: Circle())
                HStack(spacing: 3) {
                    eventDot(counts.created, color: .blue)
                    eventDot(counts.planned, color: .orange)
                    eventDot(counts.completed, color: .green)
                }
                .frame(height: 5)
            }
            .frame(maxWidth: .infinity)
            .frame(height: compact ? 31 : 46)
            .contentShape(RoundedRectangle(cornerRadius: 7))
            .background(selected ? Color.accentColor.opacity(0.08) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 7))
            .opacity(cell.isInDisplayedMonth ? 1 : 0.36)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(dateLabel(cell.date))，创建 \(counts.created) 项，计划 \(counts.planned) 项，完成 \(counts.completed) 项")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help("\(dateLabel(cell.date)) · 创建 \(counts.created) · 计划 \(counts.planned) · 完成 \(counts.completed)")
    }

    private func eventLegend(_ title: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    private func eventDot(_ count: Int, color: Color) -> some View {
        Circle()
            .fill(count > 0 ? color : Color.clear)
            .frame(width: compact ? 3 : 4, height: compact ? 3 : 4)
    }

    private var monthLabel: String {
        "\(calendar.component(.year, from: displayedMonth))年\(calendar.component(.month, from: displayedMonth))月"
    }

    private func dateLabel(_ date: Date) -> String {
        "\(calendar.component(.month, from: date))月\(calendar.component(.day, from: date))日"
    }

    private func moveMonth(_ amount: Int) {
        let month = TaskCalendarModel.month(byAdding: amount, to: displayedMonth, calendar: calendar)
        displayedMonth = month
        selectedDay = calendar.dateInterval(of: .month, for: month)?.start ?? month
    }

    private func showToday() {
        let today = calendar.startOfDay(for: Date())
        displayedMonth = today
        selectedDay = today
    }
}
