import SwiftUI

@MainActor
struct RankingView: View {
    @EnvironmentObject private var refresher: LiveRefresher
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let repo = StatsRepository()
    private let clock = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    @State private var requestedRange: TimeRange = .today
    @State private var snapshot = AppRankingSnapshot.empty()
    @State private var hasLoaded = false
    @State private var showsDayPicker = false
    @State private var pickerReferenceDate = Date()
    @State private var isReloading = false
    @State private var refreshPending = false
    @State private var loadedDay = Calendar.current.startOfDay(for: Date())
    @AppStorage("activity.showCalendar") private var showsCalendar = true

    var body: some View {
        StableWidthScrollView {
            VStack(alignment: .leading, spacing: 24) {
                calendarSection
                appSection
            }
            .padding(28)
            .frame(maxWidth: 1120, alignment: .leading)
            .frame(maxWidth: .infinity)
            .animation(reduceMotion ? nil : WorkspaceMotion.branchChange, value: showsCalendar)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear(perform: reload)
        .onReceive(refresher.$generation.dropFirst()) { _ in reload() }
        .onReceive(clock) { now in
            if !Calendar.current.isDate(now, inSameDayAs: loadedDay) { reload() }
        }
    }

    private var calendarSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                showsCalendar.toggle()
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("活跃日历").font(.headline)
                        Text("最近 26 周 · 颜色越深，按键次数越多")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(showsCalendar ? 0 : -90))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(showsCalendar ? "收起活跃日历" : "展开活跃日历")
            .accessibilityValue(showsCalendar ? "已展开" : "已收起")

            // Retain the loaded calendar while collapsed, so reopening does not
            // recreate it with empty counts before the database query finishes.
            CalendarHeatmapView(embedded: true)
                .fixedSize(horizontal: false, vertical: true)
                .frame(height: showsCalendar ? nil : 0, alignment: .top)
                .opacity(showsCalendar ? 1 : 0)
                // The outline around today extends two points past its cell.
                .padding(.horizontal, 2)
                .clipped()
                .padding(.horizontal, -2)
                .padding(.top, showsCalendar ? 18 : 0)
                .allowsHitTesting(showsCalendar)
                .accessibilityHidden(!showsCalendar)
        }
        .padding(22)
        .background(sectionBackground)
    }

    private var appSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("应用活跃度").font(.headline)
                    Text("按键盘活动估算使用时间")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if isReloading {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("正在更新应用活跃度")
                }
            }

            appRangeControls

            ZStack(alignment: .topLeading) {
                appResults(snapshot)
                    .id(snapshot.range)
                    .transition(reduceMotion ? .identity : WorkspaceMotion.pageTransition)
            }
        }
        .padding(22)
        .background(sectionBackground)
    }

    private var appRangeControls: some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                ForEach(TimeRange.allCases) { option in
                    Button {
                        selectRange(option)
                    } label: {
                        Text(option.rawValue)
                            .font(.subheadline.weight(.medium))
                            .fixedSize()
                            .padding(.horizontal, 13)
                            .padding(.vertical, 6)
                            .foregroundStyle(snapshot.range == option ? Color.white : Color.primary)
                            .background {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(snapshot.range == option ? Color.accentColor : Color.clear)
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(snapshot.range == option ? [.isSelected] : [])
                }
            }
            .padding(2)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))

            Button {
                pickerReferenceDate = Date()
                showsDayPicker = true
            } label: {
                Label("指定日", systemImage: "calendar")
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .foregroundStyle(isSpecificDay ? Color.white : Color.accentColor)
                    .background {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(isSpecificDay ? Color.accentColor : Color.accentColor.opacity(0.08))
                    }
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isSpecificDay ? [.isSelected] : [])
            .popover(isPresented: $showsDayPicker, arrowEdge: .bottom) {
                CalendarDateRangePicker(
                    initialRange: pickerInitialRange,
                    referenceDate: pickerReferenceDate,
                    selectionMode: .singleDay,
                    onCancel: { showsDayPicker = false },
                    onApply: { dates in
                        showsDayPicker = false
                        selectRange(.day(dates.start))
                    }
                )
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("应用统计范围")
    }

    private var isSpecificDay: Bool {
        if case .day = snapshot.range { return true }
        return false
    }

    private var pickerInitialRange: CalendarDateRange {
        let day: Date
        switch requestedRange {
        case .day(let date): day = date
        case .yesterday: day = requestedRange.interval(now: pickerReferenceDate).start
        default: day = pickerReferenceDate
        }
        return CalendarDateRange(start: day, end: day)
    }

    private func appResults(_ result: AppRankingSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(result.dateLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            if !hasLoaded {
                Text("正在读取应用使用记录…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 18)
            } else if result.apps.isEmpty {
                Label("暂无应用使用记录", systemImage: "app.dashed")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 18)
            } else {
                let maxUsage = max(1, result.apps.map(\.usageMs).max() ?? 1)
                VStack(spacing: 0) {
                    ForEach(Array(result.apps.enumerated()), id: \.element.id) { index, app in
                        appRow(index: index, app: app, maxUsage: maxUsage, identity: result.identities[app.app])
                        if index < result.apps.count - 1 {
                            Divider().opacity(0.45).padding(.leading, 40)
                        }
                    }
                }
            }
        }
    }

    private var sectionBackground: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.055))
            }
    }

    private func appRow(index: Int, app: AppRank, maxUsage: Int64, identity: ApplicationIdentityCache.Identity?) -> some View {
        HStack(spacing: 12) {
            Group {
                if let icon = identity?.icon {
                    Image(nsImage: icon).resizable().interpolation(.high)
                } else {
                    Image(systemName: "app.fill")
                        .resizable()
                        .foregroundStyle(.secondary)
                        .padding(5)
                }
            }
            .scaledToFit()
            .frame(width: 28, height: 28)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(identity?.name ?? app.shortName)
                        .font(.system(.body, design: .default).weight(.medium))
                        .lineLimit(1)
                        .help(app.app)
                    Spacer(minLength: 8)
                    Text(Formatters.duration(ms: app.usageMs))
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                        .fixedSize()
                    Text("\(app.keyCount.formatted()) 次按键")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 100, alignment: .trailing)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.045))
                        Capsule()
                            .fill(Color.indigo.opacity(index == 0 ? 0.8 : 0.55))
                            .frame(width: app.usageMs > 0 ? max(4, geo.size.width * CGFloat(app.usageMs) / CGFloat(maxUsage)) : 0)
                    }
                }
                .frame(height: 4)
                .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    private func selectRange(_ range: TimeRange) {
        requestedRange = range
        reload()
    }

    private func reload() {
        guard !isReloading else {
            refreshPending = true
            return
        }
        isReloading = true
        let selectedRange = requestedRange
        let now = Date()
        let calendar = Calendar.current
        let repo = repo
        Task {
            let rankings = await Task.detached(priority: .utility) {
                repo.topApps(range: selectedRange, now: now, calendar: calendar)
            }.value
            loadedDay = calendar.startOfDay(for: now)
            if requestedRange == selectedRange {
                let identities = Dictionary(uniqueKeysWithValues: rankings.map {
                    ($0.app, ApplicationIdentityCache.shared.identity(for: $0.app))
                })
                let result = AppRankingSnapshot(
                    range: selectedRange,
                    interval: selectedRange.interval(now: now, calendar: calendar),
                    apps: rankings,
                    identities: identities
                )
                // Keep the date label, selected control and data in one transaction.
                // Live recording updates the current range without replaying a transition.
                let animation = hasLoaded && snapshot.range != selectedRange && !reduceMotion
                    ? WorkspaceMotion.pageChange : nil
                withAnimation(animation) {
                    snapshot = result
                    hasLoaded = true
                }
            }
            isReloading = false
            if refreshPending {
                refreshPending = false
                reload()
            }
        }
    }
}

private struct AppRankingSnapshot {
    let range: TimeRange
    let interval: DateInterval
    let apps: [AppRank]
    let identities: [String: ApplicationIdentityCache.Identity]

    static func empty() -> Self {
        Self(range: .today, interval: TimeRange.today.interval(), apps: [], identities: [:])
    }

    var dateLabel: String {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let start = formatter.string(from: interval.start)
        let lastDay = calendar.date(byAdding: .day, value: -1, to: interval.end) ?? interval.start
        if calendar.isDate(interval.start, inSameDayAs: lastDay) {
            return "\(range.rawValue) · \(start)"
        }
        return "\(range.rawValue) · \(start) — \(formatter.string(from: lastDay))"
    }
}
