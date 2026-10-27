import SwiftUI

/// 最近 26 周的逐日按键热度；所有日期与统计均按本地自然日对齐。
struct CalendarHeatmapView: View {
    @ObservedObject private var interfaceLanguage = LanguageSettings.shared
    @EnvironmentObject private var refresher: LiveRefresher

    private let repo = StatsRepository()
    private let weekCount = 26
    private let cellSpacing: CGFloat = 3
    private let weekdayWidth: CGFloat = 28

    @State private var counts: [String: Int] = [:]
    @State private var today = Calendar.current.startOfDay(for: Date())
    @State private var maxCount = 0
    @State private var activeDays = 0
    @State private var totalCount = 0
    @State private var isReloading = false
    @State private var refreshPending = false
    @State private var hoveredDate: Date?

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        return formatter
    }()

    var embedded = false

    var body: some View {
        let _ = interfaceLanguage.language
        VStack(alignment: .leading, spacing: 16) {
            if !embedded {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L10n.tr("活跃日历")).font(.headline)
                    Text(L10n.tr("最近 26 周 · 每一格记录一天的输入"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(spacing: 9) {
                monthLabels
                    .frame(height: 16)
                calendarGrid
            }
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)

            footer
        }
        .padding(embedded ? 0 : 24)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(embedded ? AnyView(EmptyView()) : AnyView(TaskScrollerStyle()))
        .overlayPreferenceValue(CalendarDayBoundsKey.self) { bounds in
            GeometryReader { proxy in
                if let hoveredDate, let anchor = bounds[hoveredDate] {
                    let cell = proxy[anchor]
                    let width = min(200, max(0, proxy.size.width - 16))
                    let height: CGFloat = 74
                    let x = min(max(cell.midX, width / 2 + 8), proxy.size.width - width / 2 - 8)
                    let above = cell.minY - height / 2 - 9
                    let below = cell.maxY + height / 2 + 9
                    let preferredY = above >= height / 2 + 8 ? above : below
                    let y = min(max(preferredY, height / 2 + 8), proxy.size.height - height / 2 - 8)
                    dayTooltip(for: hoveredDate)
                        .frame(width: width, height: height)
                        .position(x: x, y: y)
                        .accessibilityHidden(true)
                }
                Color.clear
                    .onValueChange(of: proxy.frame(in: .global)) { hoveredDate = nil }
            }
            .allowsHitTesting(false)
        }
        .onHover { inside in if !inside { hoveredDate = nil } }
        .onValueChange(of: today) { hoveredDate = nil }
        .onDisappear { hoveredDate = nil }
        .onAppear(perform: reload)
        .onReceive(refresher.$generation.dropFirst()) { _ in reload() }
    }

    private var calendarGrid: some View {
        HStack(alignment: .top, spacing: cellSpacing) {
            ForEach(0..<weekCount, id: \.self) { week in
                VStack(spacing: cellSpacing) {
                    ForEach(0..<7, id: \.self) { day in
                        dayCell(date: date(week: week, day: day))
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.leading, weekdayWidth)
        .overlay(alignment: .leading) {
            GeometryReader { proxy in
                let cellHeight = (proxy.size.height - cellSpacing * 6) / 7
                ForEach([0, 2, 4, 6], id: \.self) { day in
                    Text([L10n.tr("一"), L10n.tr("二"), L10n.tr("三"), L10n.tr("四"), L10n.tr("五"), L10n.tr("六"), L10n.tr("日")][day])
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .frame(width: 18, height: cellHeight)
                        .position(x: 9, y: cellHeight / 2 + CGFloat(day) * (cellHeight + cellSpacing))
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.tr("最近 26 周的每日按键次数"))
    }

    private var monthLabels: some View {
        GeometryReader { proxy in
            let columnWidth = (proxy.size.width - weekdayWidth - cellSpacing * CGFloat(weekCount - 1)) / CGFloat(weekCount)
            ForEach(monthStarts, id: \.week) { month in
                Text(L10n.monthName(month.month))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .frame(width: 34, alignment: .leading)
                    .offset(x: weekdayWidth + CGFloat(month.week) * (columnWidth + cellSpacing))
            }
        }
        .accessibilityHidden(true)
    }

    /// Labels need two columns of breathing room, including a clipped first month.
    private var monthStarts: [(week: Int, month: Int)] {
        let calendar = Calendar.current
        var starts: [(week: Int, month: Int)] = []
        for week in 0..<weekCount {
            let month = calendar.component(.month, from: date(week: week, day: 0))
            if week == 0 || month != calendar.component(.month, from: date(week: week - 1, day: 0)) {
                starts.append((week, month))
            }
        }
        if starts.count > 1, starts[1].week < 2 {
            starts.removeFirst()
        }
        // A label at the final column would extend beyond the chart's trailing edge.
        return starts.filter { $0.week < weekCount - 1 }
    }

    private var footer: some View {
        HStack(alignment: .center, spacing: 16) {
            if activeDays == 0 {
                Text(L10n.tr("还没有键盘活动，开始输入后会在这里留下记录。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 14) {
                    Text(L10n.tr("\(activeDays) 天有输入"))
                    Text(L10n.tr("共 \(totalCount.formatted()) 次按键"))
                        .foregroundStyle(.tertiary)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
            Spacer(minLength: 8)
            legend
        }
    }

    private var legend: some View {
        HStack(spacing: 4) {
            Text(L10n.tr("少")).padding(.trailing, 2)
            ForEach(0..<5, id: \.self) { level in
                RoundedRectangle(cornerRadius: 3)
                    .fill(heatColor(intensity: Double(level) / 4))
                    .frame(width: 11, height: 11)
            }
            Text(L10n.tr("多")).padding(.leading, 2)
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.tr("颜色越深，表示当天按键次数越多"))
    }

    private var firstMonday: Date { firstMonday(for: today) }

    private func firstMonday(for day: Date) -> Date {
        let calendar = Calendar.current
        let weekday = calendar.component(.weekday, from: day)
        let mondayOfThisWeek = calendar.date(byAdding: .day, value: -((weekday + 5) % 7), to: day) ?? day
        return calendar.date(byAdding: .day, value: -(weekCount - 1) * 7, to: mondayOfThisWeek) ?? mondayOfThisWeek
    }

    private func date(week: Int, day: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: week * 7 + day, to: firstMonday) ?? firstMonday
    }

    @ViewBuilder
    private func dayCell(date: Date) -> some View {
        if date > today {
            Color.clear.aspectRatio(1, contentMode: .fit)
                .accessibilityHidden(true)
        } else {
            let key = Self.dateFormatter.string(from: date)
            let count = max(0, counts[key] ?? 0)
            let intensity = count > 0 && maxCount > 0 ? log1p(Double(count)) / log1p(Double(maxCount)) : 0
            let isToday = date == today
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(heatColor(intensity: intensity))
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    if isToday {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(Color.indigo.opacity(0.75), lineWidth: 1.5)
                            .padding(-2)
                    }
                }
                .overlay {
                    if hoveredDate == date {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(Color.indigo, lineWidth: 1.5)
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active:
                        hoveredDate = date
                    case .ended:
                        if hoveredDate == date { hoveredDate = nil }
                    }
                }
                .anchorPreference(key: CalendarDayBoundsKey.self, value: .bounds) { [date: $0] }
                .accessibilityLabel(L10n.tr("\(key)\(isToday ? L10n.tr("，今天") : "")，\(count) 次按键"))
        }
    }

    private func dayTooltip(for date: Date) -> some View {
        let key = Self.dateFormatter.string(from: date)
        let count = max(0, counts[key] ?? 0)
        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(key)
                if date == today {
                    Spacer(minLength: 8)
                    Text(L10n.tr("今天"))
                }
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            Text(L10n.tr("\(Formatters.keyCount(count)) 次按键"))
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .minimumScaleFactor(0.7)
        }
        .monospacedDigit()
        .lineLimit(1)
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.14), radius: 8, x: 0, y: 3)
    }

    private func heatColor(intensity: Double) -> Color {
        intensity > 0 ? Color.indigo.opacity(0.18 + intensity * 0.72) : Color.primary.opacity(0.055)
    }

    private func reload() {
        guard !isReloading else {
            refreshPending = true
            return
        }
        isReloading = true
        let selectedToday = Calendar.current.startOfDay(for: Date())
        let first = Self.dateFormatter.string(from: firstMonday(for: selectedToday))
        let last = Self.dateFormatter.string(from: selectedToday)
        let repo = repo
        Task {
            let result = await Task.detached(priority: .utility) {
                let visible = repo.dailyCounts().filter { $0.key >= first && $0.key <= last }
                return (
                    counts: visible,
                    maxCount: visible.values.max() ?? 0,
                    activeDays: visible.values.filter { $0 > 0 }.count,
                    totalCount: visible.values.reduce(0, +)
                )
            }.value
            today = selectedToday
            counts = result.counts
            maxCount = result.maxCount
            activeDays = result.activeDays
            totalCount = result.totalCount
            isReloading = false
            if refreshPending {
                refreshPending = false
                reload()
            }
        }
    }
}

private struct CalendarDayBoundsKey: PreferenceKey {
    static var defaultValue: [Date: Anchor<CGRect>] = [:]

    static func reduce(value: inout [Date: Anchor<CGRect>], nextValue: () -> [Date: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
