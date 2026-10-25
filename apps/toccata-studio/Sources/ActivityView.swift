import SwiftUI

struct ActivityView: View {
    @EnvironmentObject private var refresher: LiveRefresher

    private let repository = ActivityRepository()
    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    @State private var range: ActivityRange = .today
    @State private var snapshot = ActivitySnapshot()
    @State private var todaySnapshot = ActivitySnapshot()
    @State private var loadedDay = Calendar.current.startOfDay(for: Date())
    @State private var isReloading = false
    @State private var refreshPending = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                summaryCards
                keyboardSection
                timeline
                calculationNote
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
            let keyIsHeld = refresher.isConnected && !ActivityCalculator.openLiveKeys(refresher.liveEvents).isEmpty
            if keyIsHeld || !Calendar.current.isDate(now, inSameDayAs: loadedDay) {
                reload()
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 7) {
                Text("键盘活跃")
                    .font(.system(size: 28, weight: .bold))
                Text("看看专注发生在什么时候。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 20)
            VStack(alignment: .trailing, spacing: 10) {
                Picker("时间范围", selection: $range) {
                    ForEach(ActivityRange.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 265)
                CaptureStatusView(connectedText: "正在记录键盘活动")
                    .font(.subheadline)
            }
        }
    }

    private var summaryCards: some View {
        HStack(alignment: .top, spacing: 14) {
            metric(title: "键盘活跃时间", value: Formatters.duration(ms: snapshot.activeMs), hint: "合并连续输入与按住区间")
            metric(title: "按键次数", value: snapshot.keyCount.formatted(), hint: "包含修饰键，过滤长按重复")
            metric(title: "语音输出估算 · Fn", value: Formatters.duration(ms: snapshot.fnMs), hint: "按 Fn 累计按住时间估算")
        }
    }

    private func metric(title: String, value: String, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            StatCard(title: title, value: value)
            Text(hint)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.leading, 5)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var keyboardSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("今日键盘热力图").font(.headline)
                    Text("悬停查看今日次数 · Fn 显示按住秒数")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(todaySnapshot.keyCount.formatted()) 次")
                    .font(.system(.subheadline, design: .rounded).weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            KeyboardHeatmapView(counts: todaySnapshot.keyCounts, fnMs: todaySnapshot.fnMs)
                .frame(maxWidth: 700)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 4)
            if todaySnapshot.keyCounts.isEmpty {
                Text("今天还没有按键记录，开始使用键盘后，这里会显示每个按键的热度。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(22)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.055)))
    }

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("活跃时间线")
                        .font(.headline)
                    Text("每格 15 分钟，颜色越深表示活跃时间越长")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 5) {
                    Text("少")
                    ForEach(0..<5) { level in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(bucketColor(fraction: Double(level) / 4))
                            .frame(width: 11, height: 11)
                    }
                    Text("多")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel("图例：颜色由浅到深表示活跃时间由少到多")
            }

            VStack(spacing: 14) {
                HStack {
                    Text("日期").frame(width: 82, alignment: .leading)
                    hourLabels
                    Text("活跃 / Fn").frame(width: 108, alignment: .trailing)
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                ForEach(snapshot.days) { day in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(day.date, format: .dateTime.month(.twoDigits).day(.twoDigits))
                                .font(.system(.callout, design: .rounded).weight(.medium))
                            Text(Calendar.current.isDateInToday(day.date) ? "今天" : weekday(day.date))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: 70, alignment: .leading)

                        HStack(spacing: 2) {
                            ForEach(day.buckets) { bucket in
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(bucketColor(fraction: bucket.fraction))
                                    .frame(maxWidth: .infinity)
                                    .frame(height: range == .today ? 68 : 30)
                                    .help(bucketHint(bucket))
                            }
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(day.date.formatted(date: .abbreviated, time: .omitted))，活跃 \(Formatters.duration(ms: day.activeMs))，\(day.keyCount) 次按键")

                        VStack(alignment: .trailing, spacing: 4) {
                            Text(Formatters.duration(ms: day.activeMs))
                                .font(.system(.callout, design: .rounded).weight(.semibold))
                            Text("Fn \(Formatters.duration(ms: day.fnMs))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: 96, alignment: .trailing)
                    }
                }
            }

            if snapshot.keyCount == 0 && snapshot.activeMs == 0 {
                Label(snapshot.errorMessage == nil ? "这段时间还没有键盘活动。任务可以照常记在收集箱。" : "暂无可读取的键盘记录。采集服务运行后，这里会自动更新。", systemImage: "keyboard")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            }
        }
        .padding(22)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.055)))
    }

    private var hourLabels: some View {
        HStack(spacing: 0) {
            Text("00:00")
            Spacer()
            Text("06:00")
            Spacer()
            Text("12:00")
            Spacer()
            Text("18:00")
            Spacer()
            Text("24:00")
        }
    }

    private var calculationNote: some View {
        let policy = repository.calculationPolicy
        return VStack(alignment: .leading, spacing: 8) {
            Label("关于这些数字", systemImage: "info.circle")
                .font(.callout.weight(.medium))
            Text("相邻输入间隔小于 \(policy.idleGapMs / 1000) 秒计为连续活跃，末次输入后补 \(policy.trailingGraceMs / 1000) 秒；持续按住按键的时间也计入，重叠区间只计算一次。")
            Text("键盘活跃时间是一种使用时间估算，阅读、看视频或仅用鼠标时可能没有记录。Fn 时长用于估算你的语音输出，也可能包含快捷键操作；Toccata 不检测录音。")
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 3)
    }

    private func bucketColor(fraction: Double) -> Color {
        fraction > 0 ? Color.accentColor.opacity(0.18 + fraction * 0.82) : Color.primary.opacity(0.045)
    }

    private func weekday(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.wide).locale(Locale(identifier: "zh_CN")))
    }

    private func bucketHint(_ bucket: ActivityBucket) -> String {
        let start = Date(timeIntervalSince1970: Double(bucket.startMs) / 1000)
        let end = Date(timeIntervalSince1970: Double(bucket.endMs) / 1000)
        let clock = Date.FormatStyle.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)
        return "\(start.formatted(clock))–\(end.formatted(clock)) · 活跃 \(Formatters.duration(ms: bucket.activeMs)) · \(bucket.keyCount) 次按键"
    }

    private func reload() {
        guard !isReloading else {
            refreshPending = true
            return
        }
        isReloading = true
        let selectedRange = range
        let events = refresher.liveEvents
        let connected = refresher.isConnected
        let now = Date()
        let repository = repository
        Task {
            let (result, today) = await Task.detached(priority: .utility) {
                let selected = repository.snapshot(range: selectedRange, now: now, liveEvents: events, liveConnected: connected)
                let today = selectedRange == .today ? selected : repository.snapshot(
                    range: .today, now: now, liveEvents: events, liveConnected: connected
                )
                return (selected, today)
            }.value
            if range == selectedRange { snapshot = result }
            todaySnapshot = today
            loadedDay = Calendar.current.startOfDay(for: now)
            isReloading = false
            if refreshPending {
                refreshPending = false
                reload()
            }
        }
    }
}
