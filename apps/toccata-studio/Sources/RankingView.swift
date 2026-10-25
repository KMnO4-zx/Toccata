import SwiftUI

struct RankingView: View {
    @EnvironmentObject private var refresher: LiveRefresher
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let repo = StatsRepository()
    private let clock = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    @State private var range: TimeRange = .today
    @State private var apps: [AppRank] = []
    @State private var identities: [String: ApplicationIdentityCache.Identity] = [:]
    @State private var isReloading = false
    @State private var refreshPending = false
    @State private var loadedDay = Calendar.current.startOfDay(for: Date())
    @AppStorage("activity.showCalendar") private var showsCalendar = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                appSection
                calendarSection
            }
            .padding(28)
            .frame(maxWidth: 1120, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .background(TaskScrollerStyle())
        .onAppear(perform: reload)
        .onValueChange(of: range) { reload() }
        .onReceive(refresher.$generation.dropFirst()) { _ in reload() }
        .onReceive(clock) { now in
            if !Calendar.current.isDate(now, inSameDayAs: loadedDay) { reload() }
        }
    }

    private var calendarSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : WorkspaceMotion.pageChange) {
                    showsCalendar.toggle()
                }
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

            if showsCalendar {
                CalendarHeatmapView(embedded: true)
                    .padding(.top, 22)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(22)
        .background(sectionBackground)
    }

    private var appSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 20) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("应用活跃度").font(.headline)
                    Text("按键盘活动估算使用时间")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Picker("应用统计范围", selection: $range) {
                    ForEach(TimeRange.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 240)
            }
            if apps.isEmpty {
                Label("暂无应用使用记录", systemImage: "app.dashed")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 18)
            } else {
                let maxUsage = max(1, apps.map(\.usageMs).max() ?? 1)
                VStack(spacing: 0) {
                    ForEach(Array(apps.enumerated()), id: \.element.id) { index, app in
                        appRow(index: index, app: app, maxUsage: maxUsage)
                        if index < apps.count - 1 {
                            Divider().opacity(0.45).padding(.leading, 46)
                        }
                    }
                }
            }
        }
        .padding(22)
        .background(sectionBackground)
    }

    private var sectionBackground: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.055))
            }
    }

    private func appRow(index: Int, app: AppRank, maxUsage: Int64) -> some View {
        let identity = identities[app.app]
        return HStack(spacing: 14) {
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
            .frame(width: 32, height: 32)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(identity?.name ?? app.shortName)
                        .font(.system(.body, design: .default).weight(.medium))
                        .lineLimit(1)
                        .help(app.app)
                    Spacer(minLength: 8)
                    Text(Formatters.duration(ms: app.usageMs))
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .monospacedDigit()
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
                .frame(height: 5)
                .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    private func reload() {
        guard !isReloading else {
            refreshPending = true
            return
        }
        isReloading = true
        let selectedRange = range
        let now = Date()
        let repo = repo
        Task {
            let rankings = await Task.detached(priority: .utility) {
                repo.topApps(range: selectedRange)
            }.value
            loadedDay = Calendar.current.startOfDay(for: now)
            if range == selectedRange {
                identities = Dictionary(uniqueKeysWithValues: rankings.map {
                    ($0.app, ApplicationIdentityCache.shared.identity(for: $0.app))
                })
                apps = rankings
            }
            isReloading = false
            if refreshPending {
                refreshPending = false
                reload()
            }
        }
    }
}
