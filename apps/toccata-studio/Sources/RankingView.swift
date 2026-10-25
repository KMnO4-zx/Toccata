import SwiftUI

struct RankingView: View {
    @EnvironmentObject private var refresher: LiveRefresher

    private let repo = StatsRepository()
    private let keyboardLayout = KeyboardLayout.magicKeyboard

    @State private var range: TimeRange = .today
    @State private var counts: [Int: Int] = [:]
    @State private var apps: [AppRank] = []
    @AppStorage("activity.showCalendar") private var showsCalendar = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                keyboardSection
                appSection
                calendarSection
                Spacer(minLength: 0)
            }
            .padding(24)
        }
        .background(TaskScrollerStyle())
        .onAppear(perform: reload)
        .onValueChange(of: range) { reload() }
        .onReceive(refresher.$generation.dropFirst()) { _ in reload() }
    }

    private var keyboardSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("键盘活跃度").font(.headline)
                    Text("今天每个按键的使用次数")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(counts.values.reduce(0, +)) 次")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            KeyboardHeatmapView(layout: keyboardLayout, counts: counts)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity, alignment: .center)
            if counts.isEmpty {
                Text("今天还没有按键记录，开始使用键盘后，这里会显示每个按键的热度。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var calendarSection: some View {
        DisclosureGroup(isExpanded: $showsCalendar) {
            CalendarHeatmapView(embedded: true)
                .padding(.top, 12)
        } label: {
            Label("活跃日历 · 最近 26 周", systemImage: "calendar")
                .font(.headline)
        }
    }

    private var appSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("应用活跃度")
                    .font(.headline)
                Spacer()
                Picker("范围", selection: $range) {
                    ForEach(TimeRange.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 280)
            }
            if apps.isEmpty {
                Text("暂无应用使用记录")
                    .foregroundStyle(.secondary)
            } else {
                let maxUsage = max(1, apps.map(\.usageMs).max() ?? 1)
                VStack(spacing: 8) {
                    ForEach(Array(apps.enumerated()), id: \.element.id) { index, app in
                        appRow(index: index, app: app, maxUsage: maxUsage)
                    }
                }
            }
        }
    }

    private func appRow(index: Int, app: AppRank, maxUsage: Int64) -> some View {
        HStack(spacing: 12) {
            Text("\(index + 1)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .trailing)
            Text(app.shortName)
                .font(.body)
                .frame(width: 160, alignment: .leading)
                .lineLimit(1)
                .help(app.app)
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.accentColor.opacity(0.8))
                    .frame(width: max(2, geo.size.width * CGFloat(app.usageMs) / CGFloat(maxUsage)))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 12)
            Text(Formatters.duration(ms: app.usageMs))
                .font(.subheadline)
                .frame(width: 72, alignment: .trailing)
            Text("\(app.keyCount) 键")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)
        }
    }

    private func reload() {
        counts = Dictionary(uniqueKeysWithValues: repo.keyCounts().map { ($0.keycode, $0.count) })
        apps = repo.topApps(range: range)
    }
}
