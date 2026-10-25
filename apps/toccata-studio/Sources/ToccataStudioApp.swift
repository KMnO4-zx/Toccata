import SwiftUI
import AppKit

@main
@MainActor
struct ToccataStudioApp: App {
    @NSApplicationDelegateAdaptor(ToccataApplicationDelegate.self) private var application

    var body: some Scene {
        Settings {
            ApplicationSettingsView(loginItems: application.loginItems, appearance: application.appearance)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("打开工作台") {
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
    case activityCalendar = "活跃日历"
    case ranking = "应用与趋势"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .tasks: return "checklist"
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
    @State private var selection: WorkspaceSection? = .tasks
    @State private var taskPeriod: TaskReviewPeriod = .thisWeek
    @State private var selectedTaskID: String?
    @Binding var requestedSection: String?

    init(requestedSection: Binding<String?> = .constant(nil)) {
        _requestedSection = requestedSection
    }

    private var section: WorkspaceSection { selection ?? .tasks }
    private var openCount: Int { tasks.tasks.filter { $0.parentID == nil && !$0.isCompleted }.count }
    private var showsTaskWorkspace: Bool {
        switch section {
        case .tasks, .inbox, .taskCalendar, .review: return true
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
                        sidebarRow(.tasks)
                        sidebarRow(.inbox, count: openCount)
                        sidebarRow(.taskCalendar)
                        sidebarRow(.review)
                    }
                    Section("时间与活动") {
                        sidebarRow(.activity)
                        sidebarRow(.ranking)
                    }
                }
                .listStyle(.sidebar)

                VStack(alignment: .leading, spacing: 7) {
                    CaptureStatusView()
                        .font(.caption)
                    Text("任务随时可用 · 数据保存在本机")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding(16)
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
        .onAppear(perform: openRequestedSection)
        .onChange(of: requestedSection) { _ in openRequestedSection() }
        .onChange(of: tasks.tasks.map(\.id)) { ids in
            if let selectedTaskID, !ids.contains(selectedTaskID) { self.selectedTaskID = nil }
        }
    }

    @ViewBuilder
    private var workspacePage: some View {
        switch section {
        case .tasks: TasksView(mode: .tasks, selection: $selectedTaskID, taskPeriod: $taskPeriod)
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
        case .activityCalendar, .ranking: RankingView().navigationTitle("应用与趋势")
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
