import SwiftUI

/// Edits a local draft; dismissing the popover never changes its caller's range.
@MainActor
struct CalendarDateRangePicker: View {
    let initialRange: CalendarDateRange
    let referenceDate: Date
    let selectionMode: CalendarDateSelectionMode
    let onCancel: () -> Void
    let onApply: (CalendarDateRange) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var draft: CalendarDateRangeDraft
    @State private var displayedMonth: Date
    private let calendar = Calendar.current
    private let weekdays = ["一", "二", "三", "四", "五", "六", "日"]

    init(initialRange: CalendarDateRange, referenceDate: Date,
         selectionMode: CalendarDateSelectionMode = .range,
         onCancel: @escaping () -> Void, onApply: @escaping (CalendarDateRange) -> Void) {
        self.initialRange = initialRange
        self.referenceDate = referenceDate
        self.selectionMode = selectionMode
        self.onCancel = onCancel
        self.onApply = onApply
        let draft = CalendarDateRangeDraft(initialRange: initialRange, referenceDate: referenceDate,
                                          selectionMode: selectionMode)
        _draft = State(initialValue: draft)
        _displayedMonth = State(initialValue: TaskCalendarModel.month(byAdding: 0, to: draft.end ?? draft.start))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(selectionMode == .range ? "自定义时段" : "选择日期")
                    .font(.system(size: 17, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(selectionMode == .singleDay ? "在日历上选择要查看的日期" :
                     (draft.end == nil ? "选择结束日期，也可以再次点击同一天" : "选择开始日期，再选择结束日期"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                dateSummary(selectionMode == .range ? "开始" : "日期", date: draft.start,
                            active: selectionMode == .singleDay || draft.end != nil)
                if selectionMode == .range {
                    dateSummary("结束", date: draft.end, active: draft.end == nil)
                }
            }

            VStack(spacing: 8) {
                monthNavigation
                calendarGrid
            }

            Divider()

            HStack(spacing: 10) {
                if selectionMode == .range, let range = draft.selectedRange(calendar: calendar) {
                    let days = (calendar.dateComponents([.day], from: range.start, to: range.end).day ?? 0) + 1
                    Text("已选 \(days) 天")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button("取消", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("应用") {
                    if let range = draft.selectedRange(calendar: calendar) { onApply(range) }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(draft.end == nil)
                .accessibilityIdentifier("calendar-date-range-apply")
            }
            .controlSize(.regular)
        }
        .padding(16)
        .frame(width: 340)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear(perform: resetDraft)
    }

    private func dateSummary(_ title: String, date: Date?, active: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Text(date.map(dateLabel) ?? "待选择")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(date == nil ? Color.secondary : Color.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(active ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.035),
                    in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7)
            .strokeBorder(active ? Color.accentColor.opacity(0.3) : Color.clear))
        .accessibilityElement(children: .combine)
    }

    private var monthNavigation: some View {
        HStack(spacing: 6) {
            Text(verbatim: "\(calendar.component(.year, from: displayedMonth))年\(calendar.component(.month, from: displayedMonth))月")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            Button("本月") { showMonth(containing: referenceDate) }
                .help("回到本月")
            Button { moveMonth(-1) } label: { Image(systemName: "chevron.left") }
                .accessibilityLabel("上个月")
                .help("上个月")
            Button { moveMonth(1) } label: { Image(systemName: "chevron.right") }
                .accessibilityLabel("下个月")
                .help("下个月")
                .disabled(displayedMonth >= TaskCalendarModel.month(byAdding: 0, to: referenceDate, calendar: calendar))
        }
        .controlSize(.small)
    }

    private var calendarGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 3) {
            ForEach(Array(weekdays.enumerated()), id: \.offset) { index, weekday in
                Text(weekday)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(index >= 5 ? Color.secondary.opacity(0.65) : Color.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 16)
                    .accessibilityHidden(true)
            }
            ForEach(calendarCells) { cell in dayButton(cell) }
        }
        .frame(height: 214, alignment: .top)
        .id(displayedMonth)
        .transition(.opacity)
    }

    // Keep six rows so month navigation does not resize the popover.
    private var calendarCells: [CalendarDateCell] {
        var cells = TaskCalendarModel.days(in: displayedMonth, calendar: calendar)
        guard let last = cells.last?.date, cells.count < 42 else { return cells }
        for offset in 1...(42 - cells.count) {
            if let date = calendar.date(byAdding: .day, value: offset, to: last) {
                cells.append(CalendarDateCell(date: date, isInDisplayedMonth: false))
            }
        }
        return cells
    }

    private func dayButton(_ cell: CalendarDateCell) -> some View {
        let day = cell.date
        let isStart = day == draft.start
        let isEnd = day == draft.end
        let endpoint = isStart || isEnd
        let inRange = day >= draft.start && day <= (draft.end ?? draft.start)
        let isToday = calendar.isDate(day, inSameDayAs: referenceDate)
        let canSelect = day <= calendar.startOfDay(for: referenceDate)
        let hasSpan = draft.end.map { $0 > draft.start } ?? false
        let selectionLabel: String
        if selectionMode == .singleDay && endpoint { selectionLabel = "已选日期" }
        else if isStart && isEnd { selectionLabel = "开始和结束日期" }
        else if isStart { selectionLabel = "开始日期" }
        else if isEnd { selectionLabel = "结束日期" }
        else { selectionLabel = inRange ? "已选时段" : "" }

        return Button {
            guard draft.select(day, through: referenceDate, calendar: calendar) else { return }
            if !cell.isInDisplayedMonth { showMonth(containing: day) }
        } label: {
            ZStack {
                HStack(spacing: 0) {
                    Rectangle().fill(inRange && hasSpan && !isStart ? Color.accentColor.opacity(0.14) : Color.clear)
                    Rectangle().fill(inRange && hasSpan && !isEnd ? Color.accentColor.opacity(0.14) : Color.clear)
                }
                .frame(height: 26)
                Circle()
                    .fill(endpoint ? Color.accentColor : Color.clear)
                    .frame(width: 28, height: 28)
                if isToday && !endpoint {
                    Circle().strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1)
                        .frame(width: 28, height: 28)
                }
                Text("\(calendar.component(.day, from: day))")
                    .font(.system(size: 12, weight: endpoint || isToday ? .semibold : .regular, design: .rounded))
                    .foregroundStyle(endpoint ? Color.white : (isToday ? Color.accentColor : Color.primary))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .opacity(canSelect ? (cell.isInDisplayedMonth ? 1 : 0.4) : 0.22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canSelect)
        .accessibilityLabel(fullDateLabel(day))
        .accessibilityValue(selectionLabel)
        .accessibilityHint(canSelect ? (selectionMode == .singleDay ? "选择此日期" :
                             (draft.end == nil ? "选择为结束日期" : "选择为开始日期")) : "未来日期不可选")
        .accessibilityAddTraits(inRange ? .isSelected : [])
        .accessibilityIdentifier("calendar-date-\(dateLabel(day))")
    }

    private func resetDraft() {
        draft = CalendarDateRangeDraft(initialRange: initialRange, referenceDate: referenceDate,
                                       selectionMode: selectionMode, calendar: calendar)
        displayedMonth = TaskCalendarModel.month(byAdding: 0, to: draft.end ?? draft.start, calendar: calendar)
    }

    private func moveMonth(_ offset: Int) {
        showMonth(containing: TaskCalendarModel.month(byAdding: offset, to: displayedMonth, calendar: calendar))
    }

    private func showMonth(containing date: Date) {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
            displayedMonth = TaskCalendarModel.month(byAdding: 0, to: date, calendar: calendar)
        }
    }

    private func dateLabel(_ date: Date) -> String {
        String(format: "%04d-%02d-%02d", calendar.component(.year, from: date),
               calendar.component(.month, from: date), calendar.component(.day, from: date))
    }

    private func fullDateLabel(_ date: Date) -> String {
        let weekday = ["日", "一", "二", "三", "四", "五", "六"][calendar.component(.weekday, from: date) - 1]
        return "\(calendar.component(.year, from: date))年\(calendar.component(.month, from: date))月\(calendar.component(.day, from: date))日，星期\(weekday)"
    }
}
