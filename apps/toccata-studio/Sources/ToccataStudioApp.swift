import SwiftUI
import AppKit

@main
@MainActor
struct ToccataStudioApp: App {
    @StateObject private var refresher = LiveRefresher()
    @StateObject private var taskStore = TaskStore()
    @StateObject private var taskMenu = TaskMenuController()
    @StateObject private var coreProcess = CoreProcessController()
    @State private var requestedSection: String?

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        Window("Toccata", id: "main") {
            ContentView(requestedSection: $requestedSection)
                .environmentObject(refresher)
                .environmentObject(taskStore)
                .frame(minWidth: 1040, minHeight: 650)
                .background(TaskMenuSetup(controller: taskMenu, store: taskStore))
                .onAppear {
                    coreProcess.start()
                    refresher.start()
                }
        }
        .defaultSize(width: 1240, height: 780)

    }
}

private enum WorkspaceSection: String, CaseIterable, Identifiable {
    case thisWeek = "本周任务"
    case lastSevenDays = "最近 7 天"
    case inbox = "收集箱"
    case taskCalendar = "任务日历"
    case review = "完成回顾"
    case activity = "键盘活跃"
    case activityCalendar = "活跃日历"
    case ranking = "按键与应用"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .thisWeek: return "calendar.badge.clock"
        case .lastSevenDays: return "clock.arrow.circlepath"
        case .inbox: return "tray"
        case .taskCalendar: return "calendar"
        case .review: return "checkmark.circle"
        case .activity: return "waveform.path"
        case .activityCalendar: return "square.grid.3x3"
        case .ranking: return "chart.bar.xaxis"
        }
    }
}

@MainActor
struct ContentView: View {
    @EnvironmentObject private var tasks: TaskStore
    @EnvironmentObject private var refresher: LiveRefresher
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selection: WorkspaceSection? = .thisWeek
    @State private var selectedTaskID: String?
    @Binding var requestedSection: String?

    init(requestedSection: Binding<String?> = .constant(nil)) {
        _requestedSection = requestedSection
    }

    private var section: WorkspaceSection { selection ?? .thisWeek }
    private var openCount: Int { tasks.tasks.filter { $0.parentID == nil && !$0.isCompleted }.count }
    private var showsTaskWorkspace: Bool {
        switch section {
        case .thisWeek, .lastSevenDays, .inbox, .taskCalendar, .review: return true
        case .activity, .activityCalendar, .ranking: return false
        }
    }

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.title2)
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Toccata").font(.title3.weight(.semibold))
                        Text("记下想法，看见投入").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(20)

                List(selection: $selection) {
                    Section("任务") {
                        sidebarRow(.thisWeek)
                        sidebarRow(.lastSevenDays)
                        sidebarRow(.inbox, count: openCount)
                        sidebarRow(.taskCalendar)
                        sidebarRow(.review)
                    }
                    Section("时间与活动") {
                        sidebarRow(.activity)
                        sidebarRow(.activityCalendar)
                        sidebarRow(.ranking)
                    }
                }
                .listStyle(.sidebar)

                VStack(alignment: .leading, spacing: 7) {
                    Label(refresher.isConnected ? "键盘记录已连接" : "键盘记录未连接",
                          systemImage: refresher.isConnected ? "circle.fill" : "circle")
                        .font(.caption)
                        .foregroundStyle(refresher.isConnected ? Color.green : Color.secondary)
                    Text("任务随时可用 · 数据保存在本机")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding(16)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 205, max: 240)
        } detail: {
            Group {
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
                        .transition(WorkspaceMotion.pageTransition)
                }
            }
            .animation(reduceMotion ? nil : WorkspaceMotion.pageChange, value: section)
        }
        .font(.system(size: 13))
        .tint(.indigo)
        .background(TaskScrollerStyle())
        .onAppear(perform: openRequestedSection)
        .onChange(of: requestedSection) { _ in openRequestedSection() }
        .onChange(of: tasks.tasks.map(\.id)) { ids in
            if let selectedTaskID, !ids.contains(selectedTaskID) { self.selectedTaskID = nil }
        }
    }

    @ViewBuilder
    private var workspacePage: some View {
        switch section {
        case .thisWeek: TasksView(mode: .thisWeek, selection: $selectedTaskID)
        case .lastSevenDays: TasksView(mode: .lastSevenDays, selection: $selectedTaskID)
        case .inbox: TasksView(mode: .inbox, selection: $selectedTaskID)
        case .taskCalendar: TaskCalendarView(selection: $selectedTaskID)
        case .review: TasksView(mode: .review, selection: $selectedTaskID)
        case .activity, .activityCalendar, .ranking: EmptyView()
        }
    }

    @ViewBuilder
    private var workspaceDetail: some View {
        if let selectedTaskID, let task = tasks.task(id: selectedTaskID) {
            TaskDetailView(task: task, onSelect: { self.selectedTaskID = $0 })
                .id(task.id)
        } else if section == .taskCalendar {
            TaskPlaceholder(
                symbol: "calendar.badge.clock",
                title: "把任务放回时间里",
                message: "选择日期查看当天的记录，\n点击任务即可编辑详情与子任务。"
            )
        } else {
            TaskPlaceholder(
                symbol: "text.alignleft",
                title: "留一点空间给思路",
                message: "选择任务，补充详情、拆分子任务，\n或用 Markdown 整理背景与想法。"
            )
        }
    }

    @ViewBuilder
    private var activityPage: some View {
        switch section {
        case .activity: ActivityView()
        case .activityCalendar: CalendarHeatmapView().navigationTitle("活跃日历")
        case .ranking: RankingView().navigationTitle("按键与应用")
        case .thisWeek, .lastSevenDays, .inbox, .taskCalendar, .review: EmptyView()
        }
    }

    private func openRequestedSection() {
        guard let name = requestedSection, let destination = WorkspaceSection(rawValue: name) else { return }
        selection = destination
        requestedSection = nil
    }

    private func sidebarRow(_ item: WorkspaceSection, count: Int? = nil) -> some View {
        HStack {
            Label(item.rawValue, systemImage: item.symbol)
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
