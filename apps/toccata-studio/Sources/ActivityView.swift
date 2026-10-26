import SwiftUI

struct ActivityView: View {
    @EnvironmentObject private var refresher: LiveRefresher
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let repository = ActivityRepository()
    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    @State private var range: ActivityRange = .today
    @State private var displayedRange: ActivityRange = .today
    @State private var snapshot = ActivitySnapshot()
    @State private var timelineSelection: ActivityTimelineSelection = .followRange
    @State private var displayedTimelineRange: ActivityRange = .today
    @State private var timelineSnapshot = ActivitySnapshot()
    @State private var showsRangeCalendar = false
    @State private var showsTimelineCalendar = false
    @State private var loadedDay = Calendar.current.startOfDay(for: Date())
    @State private var isReloading = false
    @State private var refreshPending = false
    @State private var hoveredBucketID: Int64?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                summaryCards
                    .id(displayedRange)
                    .transition(contentTransition)
                keyboardSection
                    .id(displayedRange)
                    .transition(contentTransition)
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
        .onValueChange(of: range) {
            hoveredBucketID = nil
            reload()
        }
        .onValueChange(of: timelineSelection) {
            hoveredBucketID = nil
            reload()
        }
        .onValueChange(of: timelineSnapshot.days.map(\.id)) { hoveredBucketID = nil }
        .onDisappear { hoveredBucketID = nil }
        .onReceive(refresher.$generation.dropFirst()) { _ in reload() }
        .onReceive(clock) { now in
            let keyIsHeld = refresher.isConnected && !ActivityCalculator.openLiveKeys(refresher.liveEvents).isEmpty
            if keyIsHeld || !Calendar.current.isDate(now, inSameDayAs: loadedDay) {
                reload()
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("键盘活跃")
                        .font(.system(size: 28, weight: .bold))
                    Text("看看专注发生在什么时候。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 20)
                CaptureStatusView(connectedText: "正在记录键盘活动")
                    .font(.subheadline)
                    .padding(.top, 7)
            }
            HStack(spacing: 12) {
                Text("时间范围").font(.subheadline).foregroundStyle(.secondary)
                HStack(spacing: 2) {
                    ForEach(ActivityRange.allCases) { option in
                        rangeButton(option.rawValue, selected: range == option) { range = option }
                    }
                    rangeButton("自定义时段", selected: isCustomRange) { showsRangeCalendar = true }
                        .popover(isPresented: $showsRangeCalendar, arrowEdge: .bottom) {
                            CalendarDateRangePicker(
                                initialRange: calendarDates(for: range, relativeTo: Date()),
                                referenceDate: Date(),
                                onCancel: { showsRangeCalendar = false },
                                onApply: { dates in
                                    range = .custom(dates)
                                    showsRangeCalendar = false
                                }
                            )
                        }
                }
                .padding(3)
                .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
                .animation(reduceMotion ? nil : WorkspaceMotion.pageChange, value: range)
                ProgressView()
                    .controlSize(.small)
                    .opacity(isChangingRange ? 1 : 0)
                    .accessibilityHidden(!isChangingRange)
                    .accessibilityLabel("正在更新所选时段")
                Spacer(minLength: 0)
            }
            Text(dateDescription(for: displayedRange))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private var contentTransition: AnyTransition {
        reduceMotion ? .identity : WorkspaceMotion.pageTransition
    }

    private var isCustomRange: Bool {
        if case .custom = range { return true }
        return false
    }

    private var requestedTimelineRange: ActivityRange {
        switch timelineSelection {
        case .followRange: return range
        case .today: return .today
        case .yesterday: return .yesterday
        case .day(let dates): return .custom(dates)
        }
    }

    private var isChangingRange: Bool {
        isReloading && (range != displayedRange || requestedTimelineRange != displayedTimelineRange || snapshot.days.isEmpty)
    }

    private func rangeButton(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: selected ? .semibold : .medium))
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .background(selected ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
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
            KeyboardActivityHeader(title: keyboardTitle, totalCount: snapshot.keyCount, counts: snapshot.keyCounts)
            KeyboardHeatmapView(counts: snapshot.keyCounts, fnMs: snapshot.fnMs, periodDescription: keyboardPeriodDescription)
                .frame(maxWidth: 700)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 4)
            if snapshot.keyCounts.isEmpty {
                Text(snapshot.errorMessage == nil ? "\(keyboardPeriodDescription)没有按键记录。" : "暂无可读取的键盘记录。")
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

            timelineControls
            timelineRows
                .id(displayedTimelineRange)
                .transition(contentTransition)
        }
        .padding(22)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.055)))
        .overlayPreferenceValue(ActivityTimelineBoundsKey.self) { bounds in
            GeometryReader { proxy in
                if let day = timelineSnapshot.days.first(where: { $0.buckets.contains { $0.id == hoveredBucketID } }),
                   let index = day.buckets.firstIndex(where: { $0.id == hoveredBucketID }),
                   let anchor = bounds[day.id] {
                    let strip = proxy[anchor]
                    let width = min(240, max(0, proxy.size.width - 24))
                    let height: CGFloat = 132
                    let pitch = (strip.width + 2) / CGFloat(day.buckets.count)
                    let midpoint = strip.minX + pitch * (CGFloat(index) + 0.5) - 1
                    let x = min(max(midpoint, width / 2 + 12), proxy.size.width - width / 2 - 12)
                    let above = strip.minY - height / 2 - 10
                    let below = strip.maxY + height / 2 + 10
                    let preferredY = above >= height / 2 + 12 || below > proxy.size.height - height / 2 - 12 ? above : below
                    let y = min(max(preferredY, height / 2 + 12), proxy.size.height - height / 2 - 12)
                    bucketTooltip(day.buckets[index], day: day.date)
                        .frame(width: width, height: height)
                        .position(x: x, y: y)
                        .accessibilityHidden(true)
                }
                // A stationary pointer must not leave a stale tooltip behind
                // when the chart moves during scrolling or window resizing.
                Color.clear
                    .onValueChange(of: proxy.frame(in: .global)) { hoveredBucketID = nil }
            }
            .allowsHitTesting(false)
        }
        .onHover { inside in if !inside { hoveredBucketID = nil } }
    }

    private var timelineControls: some View {
        HStack(spacing: 2) {
            rangeButton("跟随范围", selected: timelineSelection == .followRange) { timelineSelection = .followRange }
            rangeButton("今日", selected: timelineSelection == .today) { timelineSelection = .today }
            rangeButton("昨日", selected: timelineSelection == .yesterday) { timelineSelection = .yesterday }
            rangeButton("指定日", selected: isTimelineSpecificDay) { showsTimelineCalendar = true }
                .popover(isPresented: $showsTimelineCalendar, arrowEdge: .bottom) {
                    CalendarDateRangePicker(
                        initialRange: timelineCalendarDates,
                        referenceDate: Date(),
                        selectionMode: .singleDay,
                        onCancel: { showsTimelineCalendar = false },
                        onApply: { dates in
                            timelineSelection = .day(dates)
                            showsTimelineCalendar = false
                        }
                    )
                }
        }
        .padding(3)
        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
        .animation(reduceMotion ? nil : WorkspaceMotion.pageChange, value: timelineSelection)
    }

    private var isTimelineSpecificDay: Bool {
        if case .day = timelineSelection { return true }
        return false
    }

    private var timelineCalendarDates: CalendarDateRange {
        if case .day(let dates) = timelineSelection { return dates }
        let dates = calendarDates(for: requestedTimelineRange, relativeTo: Date())
        return CalendarDateRange(start: dates.end, end: dates.end)
    }

    private var timelineRows: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(dateDescription(for: displayedTimelineRange))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            VStack(spacing: 14) {
                HStack(spacing: 12) {
                    Text("日期").frame(width: 70, alignment: .leading)
                    hourLabels
                    Text("活跃 / Fn").frame(width: 130, alignment: .trailing)
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                ForEach(timelineSnapshot.days) { day in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(day.date, format: .dateTime.month(.twoDigits).day(.twoDigits))
                                .font(.system(.callout, design: .rounded).weight(.medium))
                            Text(Calendar.current.isDateInToday(day.date) ? "今天" : weekday(day.date))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: 70, alignment: .leading)

                        timelineBuckets(for: day)

                        VStack(alignment: .trailing, spacing: 4) {
                            Text(Formatters.duration(ms: day.activeMs))
                                .font(.system(.callout, design: .rounded).weight(.semibold))
                            Text("Fn \(Formatters.duration(ms: day.fnMs))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .frame(width: 130, alignment: .trailing)
                    }
                }
            }

            if timelineSnapshot.keyCount == 0 && timelineSnapshot.activeMs == 0 {
                Label(timelineSnapshot.errorMessage == nil ? "这段时间还没有键盘活动。任务可以照常记在收集箱。" : "暂无可读取的键盘记录。采集服务运行后，这里会自动更新。", systemImage: "keyboard")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            }
        }
    }

    private func timelineBuckets(for day: ActivityDay) -> some View {
        GeometryReader { proxy in
            HStack(spacing: 2) {
                ForEach(day.buckets) { bucket in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(bucketColor(fraction: bucket.fraction))
                        .overlay {
                            if hoveredBucketID == bucket.id {
                                RoundedRectangle(cornerRadius: 2)
                                    .strokeBorder(Color.accentColor, lineWidth: 1.5)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityLabel("\(day.date.formatted(date: .abbreviated, time: .omitted))，\(bucketTimeRange(bucket))")
                        .accessibilityValue("活跃 \(Formatters.duration(ms: bucket.activeMs))，Fn 按住 \(Formatters.duration(ms: bucket.fnMs))，\(bucket.keyCount) 次按键")
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    guard proxy.size.width > 0, !day.buckets.isEmpty,
                          location.x >= 0, location.x <= proxy.size.width,
                          location.y >= 0, location.y <= proxy.size.height else {
                        hoveredBucketID = nil
                        return
                    }
                    // Split the 2-point gap between its neighboring bars so
                    // pointer movement never makes the tooltip flicker there.
                    let pitch = (proxy.size.width + 2) / CGFloat(day.buckets.count)
                    let index = min(day.buckets.count - 1, Int((location.x + 1) / pitch))
                    hoveredBucketID = day.buckets[index].id
                case .ended:
                    if day.buckets.contains(where: { $0.id == hoveredBucketID }) { hoveredBucketID = nil }
                }
            }
        }
        .frame(height: timelineSnapshot.days.count == 1 ? 68 : 30)
        .anchorPreference(key: ActivityTimelineBoundsKey.self, value: .bounds) { [day.id: $0] }
        .accessibilityElement(children: .contain)
    }

    private func bucketTooltip(_ bucket: ActivityBucket, day: Date) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(day, format: .dateTime.month(.twoDigits).day(.twoDigits))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(bucketTimeRange(bucket))
            }
            .font(.system(size: 12, weight: .semibold))
            Divider()
            tooltipValue("键盘活跃", value: Formatters.duration(ms: bucket.activeMs))
            tooltipValue("Fn 按住", value: Formatters.duration(ms: bucket.fnMs))
            tooltipValue("按键次数", value: "\(bucket.keyCount.formatted()) 次")
        }
        .font(.system(size: 12))
        .monospacedDigit()
        .lineLimit(1)
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.14), radius: 8, x: 0, y: 3)
    }

    private func tooltipValue(_ title: String, value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).fontWeight(.medium)
        }
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
            Text("每次有效按下覆盖后续 \(policy.activityWindowMs / 1000) 秒，持续按住按键的时间也计入；重叠区间只计算一次，未被覆盖的停顿不计入。Fn 只统计实际按住时长。")
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

    private func bucketTimeRange(_ bucket: ActivityBucket) -> String {
        let start = Date(timeIntervalSince1970: Double(bucket.startMs) / 1000)
        let end = Date(timeIntervalSince1970: Double(bucket.endMs) / 1000)
        let clock = Date.FormatStyle.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)
            .locale(Locale(identifier: "en_GB"))
        let endLabel = Calendar.current.isDate(start, inSameDayAs: end) ? end.formatted(clock) : "24:00"
        return "\(start.formatted(clock))–\(endLabel)"
    }

    private var keyboardTitle: String {
        switch displayedRange {
        case .today: return "今日键盘热力图"
        case .yesterday: return "昨日键盘热力图"
        case .lastSevenDays: return "最近 7 天键盘热力图"
        case .thisWeek: return "本周键盘热力图"
        case .custom: return "自定义时段键盘热力图"
        }
    }

    private var keyboardPeriodDescription: String {
        switch displayedRange {
        case .today: return "今天"
        case .yesterday: return "昨天"
        default: return "所选时段"
        }
    }

    private func calendarDates(for selectedRange: ActivityRange, relativeTo date: Date) -> CalendarDateRange {
        let interval = selectedRange.interval(now: date, calendar: .current)
        let end = Calendar.current.date(byAdding: .day, value: -1, to: interval.end) ?? interval.start
        return CalendarDateRange(start: interval.start, end: end)
    }

    private func dateDescription(for selectedRange: ActivityRange) -> String {
        let dates = calendarDates(for: selectedRange, relativeTo: loadedDay)
        let style = Date.FormatStyle.dateTime.year().month(.twoDigits).day(.twoDigits)
            .locale(Locale(identifier: "zh_CN"))
        let start = dates.start.formatted(style)
        if dates.start == dates.end { return start }
        return "\(start) — \(dates.end.formatted(style))"
    }

    private func reload() {
        guard !isReloading else {
            refreshPending = true
            return
        }
        isReloading = true
        let selectedRange = range
        let selectedTimelineRange = requestedTimelineRange
        let selectedTimelineSelection = timelineSelection
        let events = refresher.liveEvents
        let connected = refresher.isConnected
        let now = Date()
        let repository = repository
        Task {
            let (result, timelineResult) = await Task.detached(priority: .utility) {
                let selected = repository.snapshot(range: selectedRange, now: now, liveEvents: events, liveConnected: connected)
                let timeline = selectedRange == selectedTimelineRange ? selected : repository.snapshot(
                    range: selectedTimelineRange, now: now, liveEvents: events, liveConnected: connected
                )
                return (selected, timeline)
            }.value
            // Keep the previous labelled data visible until this request is
            // ready. A faster subsequent selection must never show old data
            // beneath its new heading.
            if range == selectedRange && timelineSelection == selectedTimelineSelection {
                let rangeChanged = displayedRange != selectedRange || displayedTimelineRange != selectedTimelineRange
                if rangeChanged { hoveredBucketID = nil }
                withAnimation(rangeChanged && !reduceMotion ? WorkspaceMotion.pageChange : nil) {
                    displayedRange = selectedRange
                    displayedTimelineRange = selectedTimelineRange
                    snapshot = result
                    timelineSnapshot = timelineResult
                    loadedDay = Calendar.current.startOfDay(for: now)
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

private enum ActivityTimelineSelection: Hashable {
    case followRange
    case today
    case yesterday
    case day(CalendarDateRange)
}

private struct ActivityTimelineBoundsKey: PreferenceKey {
    static var defaultValue: [Date: Anchor<CGRect>] = [:]

    static func reduce(value: inout [Date: Anchor<CGRect>], nextValue: () -> [Date: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
