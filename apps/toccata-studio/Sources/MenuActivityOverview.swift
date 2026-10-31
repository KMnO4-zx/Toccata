import AppKit
import SwiftUI

@MainActor
struct MenuActivityOverview: View {
    @ObservedObject private var language = LanguageSettings.shared
    @EnvironmentObject private var presentation: MenuTaskPresentation
    @EnvironmentObject private var refresher: LiveRefresher
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var tabSelection
    @State private var period: MenuActivityPeriod = .today
    private var tab: MenuActivityTab { presentation.activityTab }
    @State private var showsPeriodPicker = false
    @State private var snapshot: MenuActivitySnapshot?
    @State private var errorMessage: String?
    @State private var refreshTick = 0
    private let clock = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    private struct QueryKey: Equatable {
        let period: MenuActivityPeriod
        let opening: UUID
        let tick: Int
        let visible: Bool
    }

    private struct ContentKey: Hashable {
        let tab: MenuActivityTab
        let period: MenuActivityPeriod
    }

    private var contentKey: ContentKey {
        ContentKey(tab: tab, period: snapshot?.period ?? period)
    }

    var body: some View {
        let _ = language.language
        VStack(spacing: 0) {
            header.fixedSize(horizontal: false, vertical: true)
            ZStack(alignment: .top) {
                Group {
                    if tab == .apps {
                        ScrollView { pageContent }
                            .scrollIndicators(.never)
                    } else {
                        pageContent
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    }
                }
                // Only the app list scrolls; switching page/day resets its position.
                .id(contentKey)
                .transition(reduceMotion ? .identity : WorkspaceMotion.menuTransition)
            }
            .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            .clipped()
            .animation(reduceMotion ? nil : WorkspaceMotion.pageChange, value: contentKey)
        }
        .foregroundStyle(TaskMenuStyle.primary)
        .task(id: QueryKey(period: period, opening: presentation.openGeneration,
                           tick: refreshTick, visible: presentation.isMenuVisible)) {
            guard presentation.isMenuVisible else { return }
            await reload()
        }
        .onReceive(clock) { _ in
            if presentation.isMenuVisible { refreshTick += 1 }
        }
    }

    private var pageContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let errorMessage {
                VStack(alignment: .leading, spacing: 10) {
                    Text(errorMessage).font(.system(size: 12)).foregroundStyle(.secondary)
                    Button(L10n.tr("重试")) { refreshTick += 1 }
                }
            } else if let snapshot {
                if tab == .keyboard { keyboard(snapshot) }
                else { applications(snapshot) }
            } else {
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity).padding(.top, 40)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .padding(.bottom, 16)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L10n.tr("活动速览")).font(.system(size: 17, weight: .bold))
                Spacer(minLength: 8)
                Button { showsPeriodPicker.toggle() } label: {
                    HStack(spacing: 7) {
                        ZStack {
                            Text(period.title)
                                .id(period)
                                .transition(reduceMotion ? .identity : .opacity)
                        }
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(TaskMenuStyle.accent)
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(TaskMenuStyle.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
                    .animation(reduceMotion ? nil : WorkspaceMotion.pageChange, value: period)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("menu-activity-period")
                .popover(isPresented: $showsPeriodPicker, arrowEdge: .top) {
                    SettingsPopoverOptions(title: L10n.tr("时间范围"), options: MenuActivityPeriod.allCases,
                                           selection: period, optionTitle: { $0.title }) { value in
                        showsPeriodPicker = false
                        guard value != period else { return }
                        errorMessage = nil
                        period = value
                    }
                    .frame(width: 170)
                    .background(MenuCompanionWindow(presentation: presentation))
                }
            }
            ZStack(alignment: .leading) {
                Text(displayedDate.formatted(.dateTime.month().day().weekday(.wide).locale(L10n.locale)))
                    .id(displayedDate)
                    .transition(reduceMotion ? .identity : .opacity)
            }
            .font(.system(size: 11)).foregroundStyle(TaskMenuStyle.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(reduceMotion ? nil : WorkspaceMotion.pageChange, value: displayedDate)
            HStack(spacing: 0) {
                ForEach(MenuActivityTab.allCases, id: \.self) { item in
                    Button { presentation.activityTab = item } label: {
                        Text(item.title).font(.system(size: 12, weight: .medium))
                            .foregroundStyle(tab == item ? .white : TaskMenuStyle.secondary)
                            .frame(maxWidth: .infinity).frame(height: 28)
                            .background {
                                if tab == item {
                                    RoundedRectangle(cornerRadius: 7)
                                        .fill(TaskMenuStyle.accent)
                                        .matchedGeometryEffect(id: "activity-tab", in: tabSelection)
                                }
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(item == .keyboard ? "menu-activity-keyboard" : "menu-activity-apps")
                    .accessibilityAddTraits(tab == item ? [.isSelected] : [])
                }
            }
            .padding(2)
            .background(TaskMenuStyle.input, in: RoundedRectangle(cornerRadius: 8))
            .animation(reduceMotion ? nil : WorkspaceMotion.sidebarSelection, value: tab)
        }
        .padding(.horizontal, 16).padding(.top, 16)
    }

    private var displayedDate: Date {
        if let snapshot { return snapshot.date }
        return period.range.interval(now: Date(), calendar: .current).start
    }

    private func keyboard(_ data: MenuActivitySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                metric(MenuActivitySnapshot.compactDuration(data.activity.activeMs), title: L10n.tr("键盘活跃"))
                    .help(Formatters.duration(ms: data.activity.activeMs))
                Rectangle().fill(TaskMenuStyle.divider).frame(width: 1, height: 34)
                metric(data.activity.keyCount.formatted(.number.locale(L10n.locale)), title: L10n.tr("按键次数"))
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle(L10n.tr("键盘热力图"))
                KeyboardHeatmapView(counts: data.activity.keyCounts, totalCount: data.activity.keyCount,
                                    fnMs: data.activity.fnMs,
                                    periodDescription: data.period.title, labelScale: 0.75,
                                    compactTooltip: true)
                    .id(presentation.openGeneration)
                Text(data.activity.keyCount == 0 && data.activity.activeMs == 0
                     ? L10n.tr("这一天还没有键盘活动记录。") : L10n.tr("颜色越深，按键越多"))
                    .font(.system(size: 9)).foregroundStyle(TaskMenuStyle.secondary)
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle(L10n.tr("活跃时段"))
                MenuActivityTimeline(buckets: data.activity.days.first?.buckets ?? [])
                    .id(presentation.openGeneration)
                Text(L10n.tr("每格 15 分钟，颜色越深表示活跃时间越长"))
                    .font(.system(size: 9)).foregroundStyle(TaskMenuStyle.secondary)
            }
        }
    }

    private func metric(_ value: String, title: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(value).font(.system(size: 19, weight: .semibold)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.65)
            Text(title).font(.system(size: 11)).foregroundStyle(TaskMenuStyle.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func applications(_ data: MenuActivitySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                sectionTitle(L10n.tr("应用活跃度"))
                Text(L10n.tr("按键盘活动估算使用时间"))
                    .font(.system(size: 10)).foregroundStyle(TaskMenuStyle.secondary)
            }
            if data.apps.isEmpty {
                Text(L10n.tr("暂无应用使用记录"))
                    .font(.system(size: 12)).foregroundStyle(TaskMenuStyle.secondary)
                    .frame(maxWidth: .infinity, minHeight: 100)
            } else {
                LazyVStack(spacing: 14) {
                    ForEach(data.apps) { app in
                        appRow(app, maximum: data.apps.first?.usageMs ?? 1)
                    }
                }
            }
        }
    }

    private func appRow(_ app: AppRank, maximum: Int64) -> some View {
        let identity = ApplicationIdentityCache.shared.identity(for: app.app)
        return HStack(spacing: 10) {
            Group {
                if let icon = identity.icon { Image(nsImage: icon).resizable() }
                else { Image(systemName: "app").resizable().foregroundStyle(TaskMenuStyle.secondary) }
            }
            .scaledToFit().frame(width: 24, height: 24)
            VStack(spacing: 4) {
                HStack(spacing: 8) {
                    Text(identity.name).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    Text(MenuActivitySnapshot.compactDuration(app.usageMs)).fixedSize()
                }
                .font(.system(size: 11, weight: .medium))
                HStack(spacing: 8) {
                    GeometryReader { geometry in
                        Capsule().fill(TaskMenuStyle.input)
                        Capsule().fill(TaskMenuStyle.accent)
                            .frame(width: geometry.size.width * min(1, Double(app.usageMs) / Double(max(1, maximum))))
                    }
                    .frame(height: 5)
                    Text(L10n.tr("\(app.keyCount.formatted(.number.locale(L10n.locale))) 次"))
                        .font(.system(size: 10)).foregroundStyle(TaskMenuStyle.secondary)
                        .fixedSize()
                }
            }
        }
        .help(L10n.tr("\(identity.name) · \(Formatters.duration(ms: app.usageMs)) · \(app.keyCount) 次按键"))
        .padding(.vertical, 2)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.system(size: 13, weight: .semibold))
    }

    private func reload() async {
        let period = period
        let events = refresher.liveEvents
        let connected = refresher.isConnected
        let now = Date()
        let result = await Task.detached(priority: .utility) {
            Result { try MenuActivitySnapshot.load(period: period, now: now,
                                                   liveEvents: events, liveConnected: connected) }
        }.value
        guard !Task.isCancelled else { return }
        switch result {
        // Keep the previous day's date and data together while loading; the
        // new snapshot changes contentKey once, without flashing a spinner.
        case .success(let value): snapshot = value; errorMessage = nil
        case .failure:
            snapshot = nil
            errorMessage = L10n.tr("暂时无法读取活动记录，请稍后重试。")
        }
    }
}
