import SwiftUI
import Charts

/// DB 不存在/为空时的占位视图。
struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "keyboard")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("暂无数据 — 请先运行 toccata-core")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct StatCard: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 28, weight: .semibold, design: .rounded))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary))
    }
}

struct OverviewView: View {
    @EnvironmentObject private var refresher: LiveRefresher

    private let repo = StatsRepository()

    @State private var range: TimeRange = .today
    @State private var summary = TodaySummary()
    @State private var hours: [HourCount] = []
    @State private var empty = false

    var body: some View {
        Group {
            if empty {
                EmptyStateView()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        cards
                        rangePicker
                        hourlyChart
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

    private var cards: some View {
        HStack(spacing: 16) {
            StatCard(title: "今日按键总数", value: "\(summary.totalKeys)")
            StatCard(title: "今日累计按住时长", value: Formatters.duration(ms: summary.holdMs))
            StatCard(title: "今日使用时长", value: Formatters.duration(ms: summary.sessionMs))
        }
    }

    private var rangePicker: some View {
        HStack {
            Text("24 小时分布")
                .font(.headline)
            Spacer()
            Picker("范围", selection: $range) {
                ForEach(TimeRange.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 280)
        }
    }

    private var hourlyChart: some View {
        Chart(hours) { item in
            BarMark(
                x: .value("时", item.hour),
                y: .value("次数", item.count)
            )
            .foregroundStyle(Color.accentColor)
            .cornerRadius(3)
        }
        .chartXScale(domain: -0.5...23.5)
        .chartXAxis {
            AxisMarks(values: [0, 3, 6, 9, 12, 15, 18, 21]) { value in
                AxisGridLine()
                AxisTick()
                AxisValueLabel {
                    if let hour = value.as(Int.self) {
                        Text("\(hour)时")
                    }
                }
            }
        }
        .chartYAxisLabel("次数")
        .frame(minHeight: 240)
    }

    private func reload() {
        guard repo.hasAnyEvents() else {
            empty = true
            return
        }
        empty = false
        summary = repo.todaySummary()
        hours = repo.hourlyCounts(range: range)
    }
}
