import SwiftUI

/// GitHub 风格日历热力图：最近 26 周，列=周、行=周一~周日，
/// 颜色按当日总按键 log 归一化在主题 heatLow→heatHigh 间插值。
struct CalendarHeatmapView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var refresher: LiveRefresher

    private let repo = StatsRepository()
    private let weekCount = 26
    private let cellSize: CGFloat = 14
    private let cellSpacing: CGFloat = 3

    @State private var counts: [String: Int] = [:]
    @State private var maxCount = 0
    @State private var empty = false

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        return formatter
    }()

    var embedded = false

    var body: some View {
        Group {
            if empty {
                if embedded {
                    Text("还没有键盘活动")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    EmptyStateView()
                }
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    if !embedded {
                        header
                            .padding(.horizontal, 24)
                            .padding(.top, 20)
                            .padding(.bottom, 12)
                    }
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: cellSpacing) {
                            weekdayColumn
                            ForEach(0..<weekCount, id: \.self) { week in
                                weekColumn(week)
                            }
                            if embedded { legend.padding(.leading, 8) }
                        }
                        .padding(.horizontal, embedded ? 0 : 24)
                        .padding(.bottom, embedded ? 0 : 24)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: embedded ? nil : .infinity, alignment: .topLeading)
            }
        }
        .background(embedded ? AnyView(EmptyView()) : AnyView(TaskScrollerStyle()))
        .onAppear(perform: reload)
        .onReceive(refresher.$generation.dropFirst()) { _ in reload() }
    }

    private var header: some View {
        HStack {
            Text("最近 26 周")
                .font(.headline)
            Spacer()
            legend
        }
    }

    private var legend: some View {
        HStack(spacing: 3) {
            Text("少")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(0..<5, id: \.self) { i in
                RoundedRectangle(cornerRadius: 3)
                    .fill(palette.heatColor(t: Double(i) / 4))
                    .frame(width: 12, height: 12)
            }
            Text("多")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var palette: ThemePalette {
        ThemeStore.shared.palette(for: colorScheme)
    }

    /// 最近 26 周中第一周（最旧）的周一。
    private var firstMonday: Date {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let weekday = calendar.component(.weekday, from: today)
        let mondayOfThisWeek = calendar.date(byAdding: .day, value: -((weekday + 5) % 7), to: today) ?? today
        return calendar.date(byAdding: .day, value: -(weekCount - 1) * 7, to: mondayOfThisWeek) ?? mondayOfThisWeek
    }

    private var weekdayColumn: some View {
        VStack(spacing: cellSpacing) {
            Text(" ")
                .font(.caption)
                .frame(width: 16, height: cellSize)
            ForEach(0..<7, id: \.self) { day in
                Text([0: "一", 2: "三", 4: "五"][day] ?? " ")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: cellSize)
            }
        }
    }

    private func weekColumn(_ week: Int) -> some View {
        let calendar = Calendar.current
        let monday = calendar.date(byAdding: .day, value: week * 7, to: firstMonday) ?? firstMonday
        return VStack(spacing: cellSpacing) {
            monthLabel(week: week, monday: monday)
            ForEach(0..<7, id: \.self) { day in
                dayCell(monday: monday, offset: day)
            }
        }
    }

    private func monthLabel(week: Int, monday: Date) -> some View {
        let calendar = Calendar.current
        let month = calendar.component(.month, from: monday)
        var show = week == 0
        if !show, let prev = calendar.date(byAdding: .day, value: -7, to: monday) {
            show = calendar.component(.month, from: prev) != month
        }
        return Text(show ? "\(month)月" : " ")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize()
            .frame(width: cellSize, height: cellSize, alignment: .leading)
    }

    private func dayCell(monday: Date, offset: Int) -> some View {
        let calendar = Calendar.current
        let date = calendar.date(byAdding: .day, value: offset, to: monday) ?? monday
        if date > Date() {
            return AnyView(Color.clear.frame(width: cellSize, height: cellSize))
        }
        let key = Self.dateFormatter.string(from: date)
        let n = counts[key] ?? 0
        let color: Color
        if n <= 0 || maxCount <= 0 {
            color = Color.primary.opacity(0.08)
        } else {
            let t = log(1 + Double(n)) / log(1 + Double(maxCount))
            color = palette.heatColor(t: t)
        }
        return AnyView(
            RoundedRectangle(cornerRadius: 3)
                .fill(color)
                .frame(width: cellSize, height: cellSize)
                .help("\(key)：\(n) 次按键")
        )
    }

    private func reload() {
        guard repo.hasAnyEvents() else {
            empty = true
            return
        }
        empty = false
        counts = repo.dailyCounts()
        maxCount = counts.values.max() ?? 0
    }
}
