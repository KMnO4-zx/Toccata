import SwiftUI

/// A task's planned day is edited locally until the user confirms it.
/// Unlike activity filters, planning allows dates in the future.
@MainActor
struct TaskPlannedDatePicker: View {
    @ObservedObject private var interfaceLanguage = LanguageSettings.shared
    let initialDate: Date?
    let referenceDate: Date
    let onCancel: () -> Void
    let onApply: (Date) -> Void
    let onClear: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedDate: Date
    @State private var displayedMonth: Date
    @State private var hoveredDate: Date?

    private let calendar = Calendar.current
    private var weekdays: [String] { [L10n.tr("一"), L10n.tr("二"), L10n.tr("三"), L10n.tr("四"), L10n.tr("五"), L10n.tr("六"), L10n.tr("日")] }

    init(initialDate: Date?, referenceDate: Date = Date(),
         onCancel: @escaping () -> Void, onApply: @escaping (Date) -> Void,
         onClear: (() -> Void)? = nil) {
        self.initialDate = initialDate
        self.referenceDate = referenceDate
        self.onCancel = onCancel
        self.onApply = onApply
        self.onClear = onClear
        let day = Calendar.current.startOfDay(for: initialDate ?? referenceDate)
        _selectedDate = State(initialValue: day)
        _displayedMonth = State(initialValue: TaskCalendarModel.month(byAdding: 0, to: day))
    }

    var body: some View {
        let _ = interfaceLanguage.language
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.tr("计划日期"))
                    .font(.system(size: 17, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(verbatim: fullDateLabel(selectedDate))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            HStack(spacing: 6) {
                shortcut(L10n.tr("今日"), date: today)
                shortcut(L10n.tr("明日"), date: calendar.date(byAdding: .day, value: 1, to: today) ?? today)
                shortcut(L10n.tr("下周一"), date: nextMonday)
            }

            VStack(spacing: 8) {
                monthNavigation
                calendarGrid
            }

            Divider().opacity(0.65)

            HStack(spacing: 9) {
                if let onClear {
                    Button(L10n.tr("清除日期"), action: onClear)
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("task-planned-date-clear")
                }
                Spacer(minLength: 0)
                Button(L10n.tr("取消"), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(L10n.tr("确定")) { onApply(calendar.startOfDay(for: selectedDate)) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("task-planned-date-apply")
            }
            .controlSize(.regular)
        }
        .padding(16)
        .frame(width: 320)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear(perform: resetDraft)
        .onExitCommand(perform: onCancel)
    }

    private var today: Date { calendar.startOfDay(for: referenceDate) }

    private var nextMonday: Date {
        let weekday = calendar.component(.weekday, from: today)
        let daysUntilMonday = (9 - weekday) % 7
        return calendar.date(byAdding: .day, value: daysUntilMonday == 0 ? 7 : daysUntilMonday,
                             to: today) ?? today
    }

    private func shortcut(_ title: String, date: Date) -> some View {
        let isSelected = calendar.isDate(date, inSameDayAs: selectedDate)
        return Button { select(date) } label: {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .frame(maxWidth: .infinity)
                .frame(height: 28)
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .background(isSelected ? Color.accentColor.opacity(0.1) : Color.primary.opacity(0.045),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.tr("选择\(title)，\(fullDateLabel(date))"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var monthNavigation: some View {
        HStack(spacing: 4) {
            Text(verbatim: L10n.monthTitle(displayedMonth, calendar: calendar))
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            Button(L10n.tr("本月")) { showMonth(containing: today) }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .buttonStyle(.plain)
                .padding(.horizontal, 7)
                .help(L10n.tr("回到本月"))
            monthButton(offset: -1, symbol: "chevron.left", label: L10n.tr("上个月"))
            monthButton(offset: 1, symbol: "chevron.right", label: L10n.tr("下个月"))
        }
        .frame(height: 26)
    }

    private func monthButton(offset: Int, symbol: String, label: String) -> some View {
        Button {
            showMonth(containing: TaskCalendarModel.month(byAdding: offset, to: displayedMonth, calendar: calendar))
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 6))
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(label)
    }

    private var calendarGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 3) {
            ForEach(Array(weekdays.enumerated()), id: \.offset) { index, day in
                Text(day)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(index >= 5 ? Color.secondary.opacity(0.6) : Color.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 16)
                    .accessibilityHidden(true)
            }
            ForEach(calendarCells) { cell in dayButton(cell) }
        }
        .frame(height: 214, alignment: .top)
        .id(displayedMonth)
        .transition(reduceMotion ? .identity : .opacity)
    }

    // A stable six-week grid keeps the popover still while moving between months.
    private var calendarCells: [CalendarDateCell] {
        var cells = TaskCalendarModel.days(in: displayedMonth, calendar: calendar)
        guard let last = cells.last?.date, cells.count < 42 else { return cells }
        for offset in 1...(42 - cells.count) {
            if let day = calendar.date(byAdding: .day, value: offset, to: last) {
                cells.append(CalendarDateCell(date: day, isInDisplayedMonth: false))
            }
        }
        return cells
    }

    private func dayButton(_ cell: CalendarDateCell) -> some View {
        let isSelected = calendar.isDate(cell.date, inSameDayAs: selectedDate)
        let isToday = calendar.isDate(cell.date, inSameDayAs: today)
        let isHovered = hoveredDate == cell.date
        return Button { select(cell.date) } label: {
            Text("\(calendar.component(.day, from: cell.date))")
                .font(.system(size: 12, weight: isSelected || isToday ? .semibold : .regular, design: .rounded))
                .foregroundStyle(isSelected ? Color.white : (isToday ? Color.accentColor : Color.primary))
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .background {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(isSelected ? Color.accentColor : (isHovered ? Color.accentColor.opacity(0.08) : Color.clear))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(isToday && !isSelected ? Color.accentColor.opacity(0.45) : Color.clear,
                                      lineWidth: 1)
                }
                .opacity(cell.isInDisplayedMonth || isSelected ? 1 : 0.35)
                .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering { hoveredDate = cell.date }
            else if hoveredDate == cell.date { hoveredDate = nil }
        }
        .accessibilityLabel(fullDateLabel(cell.date))
        .accessibilityValue(isSelected ? L10n.tr("已选日期") : (isToday ? L10n.tr("今天") : ""))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("task-planned-date-\(dateIdentifier(cell.date))")
    }

    private func resetDraft() {
        selectedDate = calendar.startOfDay(for: initialDate ?? referenceDate)
        displayedMonth = TaskCalendarModel.month(byAdding: 0, to: selectedDate, calendar: calendar)
        hoveredDate = nil
    }

    private func select(_ date: Date) {
        selectedDate = calendar.startOfDay(for: date)
        showMonth(containing: selectedDate)
    }

    private func showMonth(containing date: Date) {
        hoveredDate = nil
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.14)) {
            displayedMonth = TaskCalendarModel.month(byAdding: 0, to: date, calendar: calendar)
        }
    }

    private func fullDateLabel(_ date: Date) -> String {
        return L10n.date(date, full: true)
    }

    private func dateIdentifier(_ date: Date) -> String {
        String(format: "%04d-%02d-%02d", calendar.component(.year, from: date),
               calendar.component(.month, from: date), calendar.component(.day, from: date))
    }
}
