import SwiftUI
import AppKit

@main
@MainActor
struct ToccataStudioApp: App {
    @ObservedObject private var interfaceLanguage = LanguageSettings.shared
    @NSApplicationDelegateAdaptor(ToccataApplicationDelegate.self) private var application

    var body: some Scene {
        let _ = interfaceLanguage.language
        Settings {
            ApplicationSettingsView(loginItems: application.loginItems, appearance: application.appearance,
                                    openAbout: application.openAbout)
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button(L10n.tr("关于 Toccata")) { application.openAbout() }
            }
            CommandGroup(replacing: .newItem) {
                Button(L10n.tr("打开工作台")) {
                    application.openWorkbench()
                }
                .keyboardShortcut("1", modifiers: .command)
            }
        }
    }
}

private enum WorkspaceSection: String, CaseIterable, Identifiable {
    case tasks = "任务"
    case inbox = "收集箱"
    case taskCalendar = "任务日历"
    case review = "任务回顾"
    case activity = "键盘活跃"
    case ranking = "应用与趋势"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .tasks: return "checklist"
        case .inbox: return "tray"
        case .taskCalendar: return "calendar"
        case .review: return "checkmark.circle"
        case .activity: return "waveform.path"
        case .ranking: return "chart.bar.xaxis"
        }
    }
}

@MainActor
struct ContentView: View {
    @ObservedObject private var interfaceLanguage = LanguageSettings.shared
    @EnvironmentObject private var tasks: TaskStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selection: WorkspaceSection? = .tasks
    @State private var taskPeriod: TaskReviewPeriod = .thisWeek
    @State private var selectedTaskID: String?
    @State private var isOpeningTasks = false
    @State private var homeNavigationFailed = false
    @Binding var requestedSection: String?
    private let openAbout: () -> Void

    init(requestedSection: Binding<String?> = .constant(nil), openAbout: @escaping () -> Void) {
        _requestedSection = requestedSection
        self.openAbout = openAbout
    }

    private var section: WorkspaceSection { selection ?? .tasks }
    private var openCount: Int { tasks.tasks.filter { $0.parentID == nil && !$0.isCompleted }.count }
    private var showsTaskWorkspace: Bool {
        switch section {
        case .tasks, .inbox, .taskCalendar, .review: return true
        case .activity, .ranking: return false
        }
    }

    var body: some View {
        let _ = interfaceLanguage.language
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 0) {
                Button(action: openTasks) {
                    HStack(spacing: 10) {
                        Image(systemName: "square.stack.3d.up.fill")
                            .font(.title2)
                            .foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Toccata").font(.title3.weight(.semibold))
                            Text(L10n.tr("记下想法，看见投入")).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(20)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L10n.tr("回到任务"))
                .accessibilityLabel(L10n.tr("Toccata，回到任务"))

                List(selection: $selection) {
                    Section(L10n.tr("任务")) {
                        sidebarRow(.tasks)
                        sidebarRow(.inbox, count: openCount)
                        sidebarRow(.taskCalendar)
                        sidebarRow(.review)
                    }
                    Section(L10n.tr("时间与活动")) {
                        sidebarRow(.activity)
                        sidebarRow(.ranking)
                    }
                }
                .listStyle(.sidebar)

                SidebarFooterView(openAbout: openAbout)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 205, max: 240)
        } detail: {
            // Keep a concrete host for both activity pages while their identities
            // change, so NavigationSplitView can render the outgoing transition.
            ZStack(alignment: .topLeading) {
                if showsTaskWorkspace {
                    WorkspaceSplitView {
                        workspacePage
                            .id(section)
                            .transition(WorkspaceMotion.pageTransition)
                    } detail: {
                        workspaceDetail
                            .id(section)
                            .transition(WorkspaceMotion.pageTransition)
                    }
                    .transition(WorkspaceMotion.pageTransition)
                } else {
                    activityPage
                        .id(section)
                        .transition(WorkspaceMotion.pageTransition)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .animation(reduceMotion ? nil : WorkspaceMotion.pageChange, value: section)
        }
        .font(.system(size: 13))
        .tint(.indigo)
        .background(TaskScrollerStyle())
        .languageChangeTransition()
        .onAppear(perform: openRequestedSection)
        .onChange(of: requestedSection) { _ in openRequestedSection() }
        .onChange(of: tasks.tasks.map(\.id)) { ids in
            if let selectedTaskID, !ids.contains(selectedTaskID) { self.selectedTaskID = nil }
        }
        .alert(L10n.tr("任务修改尚未保存"), isPresented: $homeNavigationFailed) {
            Button(L10n.tr("好"), role: .cancel) {}
        } message: {
            Text(L10n.tr("请先重试保存，再返回任务页面。"))
        }
    }

    @ViewBuilder
    private var workspacePage: some View {
        switch section {
        case .tasks: TasksView(mode: .tasks, selection: $selectedTaskID, taskPeriod: $taskPeriod)
        case .inbox: TasksView(mode: .inbox, selection: $selectedTaskID)
        case .taskCalendar: TaskCalendarView(selection: $selectedTaskID)
        case .review: TasksView(mode: .review, selection: $selectedTaskID)
        case .activity, .ranking: EmptyView()
        }
    }

    private var workspaceDetail: some View {
        ZStack(alignment: .topLeading) {
            workspaceDetailContent
                .id(selectedTaskID)
                .transition(reduceMotion ? .identity : WorkspaceMotion.detailTransition)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Scope the animation to task selection, not draft edits or completion.
        .animation(reduceMotion ? nil : WorkspaceMotion.detailChange, value: selectedTaskID)
    }

    @ViewBuilder
    private var workspaceDetailContent: some View {
        if let selectedTaskID, let task = tasks.task(id: selectedTaskID) {
            TaskDetailView(task: task, onSelect: { self.selectedTaskID = $0 })
        } else if section == .taskCalendar {
            TaskPlaceholder(
                symbol: "calendar.badge.clock",
                title: L10n.tr("把任务放回时间里"),
                message: L10n.tr("选择日期查看当天的记录，\n点击任务即可编辑详情与子任务。")
            )
        } else {
            TaskPlaceholder(
                symbol: "text.alignleft",
                title: L10n.tr("留一点空间给思路"),
                message: L10n.tr("选择任务，补充详情、拆分子任务，\n或用 Markdown 整理背景与想法。")
            )
        }
    }

    @ViewBuilder
    private var activityPage: some View {
        switch section {
        case .activity: ActivityView()
        case .ranking: RankingView()
        case .tasks, .inbox, .taskCalendar, .review: EmptyView()
        }
    }

    private func openRequestedSection() {
        guard let name = requestedSection else { return }
        // Keep earlier navigation requests working after consolidating the pages.
        let destination: WorkspaceSection?
        switch name {
        case "本周任务", "本周":
            taskPeriod = .thisWeek
            destination = .tasks
        case "最近 7 天", "最近7天":
            taskPeriod = .lastSevenDays
            destination = .tasks
        case "完成回顾":
            destination = .review
        case "按键与应用", "键盘与应用", "活跃日历":
            destination = .ranking
        default:
            destination = WorkspaceSection(rawValue: name)
        }
        guard let destination else { return }
        selection = destination
        requestedSection = nil
    }

    private func openTasks() {
        guard section != .tasks, !isOpeningTasks else { return }
        let originalSection = section
        isOpeningTasks = true
        NSApp.keyWindow?.makeFirstResponder(nil)
        Task { @MainActor in
            defer { isOpeningTasks = false }
            guard await PendingEdits.shared.flushAll() else {
                homeNavigationFailed = true
                return
            }
            // A later sidebar choice takes precedence over an in-flight save.
            guard section == originalSection else { return }
            withAnimation(reduceMotion ? nil : WorkspaceMotion.pageChange) {
                selection = .tasks
            }
        }
    }

    private func sidebarRow(_ item: WorkspaceSection, count: Int? = nil) -> some View {
        HStack {
            Label(L10n.key(item.rawValue), systemImage: item.symbol)
            Spacer()
            if let count, count > 0 {
                Text("\(count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .tag(item)
        .padding(.vertical, 3)
    }
}

extension View {
    @ViewBuilder
    func onValueChange<V: Equatable>(of value: V, perform action: @escaping () -> Void) -> some View {
        if #available(macOS 14.0, *) {
            onChange(of: value, action)
        } else {
            onChange(of: value) { _ in action() }
        }
    }
}
