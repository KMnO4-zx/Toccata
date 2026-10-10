import SwiftUI
import Charts

struct RankingView: View {
    @EnvironmentObject private var refresher: LiveRefresher

    private let repo = StatsRepository()

    @State private var range: TimeRange = .today
    @State private var keys: [(rank: KeyRank, category: String)] = []
    @State private var apps: [AppRank] = []
    @State private var empty = false

    var body: some View {
        Group {
            if empty {
                EmptyStateView()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        keySection
                        appSection
                        Spacer(minLength: 0)
                    }
                    .padding(24)
                }
            }
        }
        .onAppear(perform: reload)
        .onValueChange(of: range) { reload() }
        .onReceive(refresher.$generation.dropFirst()) { _ in reload() }
    }

    private var keySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("按键 Top 20（全部时间）")
                .font(.headline)
            if keys.isEmpty {
                Text("暂无按键记录")
                    .foregroundStyle(.secondary)
            } else {
                Chart(keys, id: \.category) { item in
                    BarMark(
                        x: .value("次数", item.rank.count),
                        y: .value("按键", item.category)
                    )
                    .foregroundStyle(Color.accentColor)
                    .cornerRadius(3)
                    .annotation(position: .trailing) {
                        Text("\(item.rank.count)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .chartYScale(domain: keys.map(\.category))
                .frame(height: CGFloat(keys.count) * 26 + 20)
            }
        }
    }

    private var appSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("应用使用时长排行")
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
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .trailing)
            Text(app.shortName)
                .font(.callout)
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
                .font(.caption)
                .frame(width: 72, alignment: .trailing)
            Text("\(app.keyCount) 键")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)
        }
    }

    private func reload() {
        guard repo.hasAnyEvents() else {
            empty = true
            return
        }
        empty = false

        // label 可能重复（左右 ⇧/⌘ 等），追加零宽空格保证图表分类唯一。
        var seen: [String: Int] = [:]
        keys = repo.topKeys().map { rank in
            let label = KeyLabels.shared.label(for: rank.keycode)
            let duplicate = seen[label, default: 0]
            seen[label] = duplicate + 1
            let category = label + String(repeating: "\u{200B}", count: duplicate)
            return (rank, category)
        }.sorted { $0.rank.count < $1.rank.count } // 升序喂给图表，使最大者显示在最上方

        apps = repo.topApps(range: range)
    }
}
