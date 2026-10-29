import SwiftUI
import AppKit
import Combine

@MainActor
struct QuickCaptureView: View {
    @ObservedObject private var interfaceLanguage = LanguageSettings.shared
    @EnvironmentObject private var tasks: TaskStore
    @EnvironmentObject private var presentation: MenuTaskPresentation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var page: MenuPanelPage { presentation.page }
    @State private var scope: MenuTaskScope = .thisWeek
    @State private var sortOrder: MenuTaskSortOrder = .createdDescending
    @State private var title = ""
    @State private var taskToDelete: TodoTask?
    @State private var hoveredTaskID: String?
    @State private var referenceDate = Date()
    @State private var knownBranchIDs: Set<String> = []
    @FocusState private var captureFocused: Bool

    private var matchingTasks: [TodoTask] { tasks.menuTasks(for: scope, relativeTo: referenceDate) }
    private var treeRoots: [MenuTaskTreeNode] {
        MenuTaskTree.roots(allTasks: tasks.tasks, matchingTasks: matchingTasks,
                           includeAllDescendants: scope == .inbox)
    }
    private var pendingRoots: [MenuTaskTreeNode] { treeRoots.filter { !$0.task.isCompleted } }
    private var completedRoots: [MenuTaskTreeNode] { treeRoots.filter { $0.task.isCompleted } }
    private var visibleRows: [MenuTaskVisibleRow] { flatten(pendingRoots) + flatten(completedRoots) }

    var body: some View {
        let _ = interfaceLanguage.language
        VStack(spacing: 0) {
            if page != .activity { header }
            if page == .tasks { captureField }
            if page != .activity, let error = tasks.errorMessage {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
            }
            Group {
                if page == .tasks {
                    taskList.padding(.top, 8)
                } else if page == .calendar {
                    MenuCalendarView()
                } else {
                    MenuActivityOverview()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .id(page)
            .transition(WorkspaceMotion.menuTransition)
            .animation(reduceMotion ? nil : WorkspaceMotion.menuChange, value: page)
            bottomBar
        }
        .frame(width: presentation.panelSize.width, height: presentation.panelSize.height)
        .background(TaskMenuStyle.background)
        .clipShape(RoundedRectangle(cornerRadius: TaskMenuStyle.cornerRadius))
        .languageChangeTransition()
        .coordinateSpace(name: "taskMenu")
        .onPreferenceChange(MenuTaskRowFrameKey.self) { frames in presentation.rowFrames = frames }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { referenceDate = $0 }
        .onAppear {
            updateExpandedBranches(reset: knownBranchIDs.isEmpty)
            captureFocused = page == .tasks
        }
        .onExitCommand {
            if page != .tasks { presentation.dismissMenu() }
        }
        .onChange(of: presentation.openGeneration) { _ in resetForOpening() }
        .onChange(of: presentation.listFocusRequest) { _ in captureFocused = false }
        .onChange(of: page) { newPage in
            presentation.selectedTaskID = nil
            presentation.dismissEditor()
            captureFocused = false
            if newPage == .tasks {
                DispatchQueue.main.async {
                    if page == .tasks { captureFocused = true }
                }
            }
        }
        .onChange(of: scope) { _ in
            presentation.selectedTaskID = nil
            presentation.dismissEditor()
            updateExpandedBranches(reset: false)
        }
        .onChange(of: tasks.tasks) { updatedTasks in
            referenceDate = Date()
            updateExpandedBranches(reset: false)
            if let selectedID = presentation.selectedTaskID,
               !updatedTasks.contains(where: { $0.id == selectedID }) {
                presentation.selectedTaskID = nil
                presentation.dismissEditor()
            }
        }
        .alert(L10n.tr("删除这个任务？"), isPresented: Binding(
            get: { taskToDelete != nil },
            set: { if !$0 { taskToDelete = nil } }
        )) {
            Button(L10n.tr("取消"), role: .cancel) { taskToDelete = nil }
            Button(L10n.tr("删除任务"), role: .destructive) {
                if let task = taskToDelete { _ = tasks.deleteTask(id: task.id) }
                taskToDelete = nil
            }
        } message: {
            if let task = taskToDelete, !tasks.children(of: task.id).isEmpty {
                Text(L10n.tr("任务、所有子任务及其详情都会删除。此操作无法撤销。"))
            } else {
                Text(L10n.tr("任务的详情也会删除。此操作无法撤销。"))
            }
        }
    }

    private var header: some View {
        HStack {
            if page == .calendar {
                Text(L10n.tr("任务日历"))
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(TaskMenuStyle.primary)
            } else {
                Menu {
                    Picker(L10n.tr("任务视图"), selection: $scope) {
                        ForEach(MenuTaskScope.allCases) { item in Text(item.title).tag(item) }
                    }
                    .pickerStyle(.inline)
                    .id(interfaceLanguage.language)
                } label: {
                    HStack(spacing: 8) {
                        Text(scope.title)
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(TaskMenuStyle.primary)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(TaskMenuStyle.secondary)
                    }
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel(L10n.tr("切换任务视图，当前：\(scope.title)"))
            }

            Spacer()
            if page == .tasks {
                Menu {
                    Picker(L10n.tr("排序"), selection: $sortOrder) {
                        ForEach(MenuTaskSortOrder.allCases) { order in Text(L10n.key(order.rawValue)).tag(order) }
                    }
                    .pickerStyle(.inline)
                    .id(interfaceLanguage.language)
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 14))
                        .foregroundStyle(TaskMenuStyle.primary)
                        .frame(width: 18, height: 28)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel(L10n.tr("任务排序"))
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
    }

    private var canAddTask: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var captureField: some View {
        HStack(spacing: 5) {
            Button(action: addTask) {
                Image(systemName: "plus")
                    .font(.system(size: 16))
                    .foregroundStyle(canAddTask ? TaskMenuStyle.accent : TaskMenuStyle.muted)
                    .frame(width: 20, height: 25)
                    .contentShape(Rectangle())
            }
            .buttonStyle(EditActionButtonStyle())
            .disabled(!canAddTask)
            .accessibilityLabel(L10n.tr("添加任务，不设置计划日期"))
            TextField("", text: $title, prompt: Text(L10n.tr("添加任务")).foregroundColor(TaskMenuStyle.muted))
                .font(.system(size: 13))
                .foregroundStyle(TaskMenuStyle.text)
                .textFieldStyle(.plain)
                .focused($captureFocused)
                .onSubmit(addTask)
                .accessibilityLabel(L10n.tr("快速添加任务"))
        }
        .padding(.horizontal, 9)
        .frame(height: 35)
        .editableSurface(isFocused: captureFocused, cornerRadius: 10,
                         accent: TaskMenuStyle.accent, fill: TaskMenuStyle.input)
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private var taskList: some View {
        if treeRoots.isEmpty {
            Text(L10n.tr("暂无任务"))
                .font(.system(size: 13))
                .foregroundStyle(TaskMenuStyle.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        taskRows(pendingRoots)
                        if !completedRoots.isEmpty {
                            Text(L10n.tr("已完成"))
                                .font(.system(size: 10))
                                .foregroundStyle(TaskMenuStyle.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.leading, 22)
                                .padding(.top, 12)
                                .padding(.bottom, 4)
                            taskRows(completedRoots)
                        }
                    }
                    .animation(reduceMotion ? nil : WorkspaceMotion.branchChange,
                               value: presentation.expandedTaskIDs)
                    .animation(reduceMotion ? nil : WorkspaceMotion.taskReorder, value: sortOrder)
                }
                .scrollIndicators(.visible)
                .background(TaskScrollerStyle())
                .onChange(of: presentation.selectedTaskID) { id in
                    if let id { proxy.scrollTo(id) }
                }
            }
            .background(MenuTaskListKeyboard(focusRequest: presentation.listFocusRequest, onKey: handleListKey))
        }
    }

    private func taskRows(_ roots: [MenuTaskTreeNode]) -> some View {
        ForEach(flatten(roots)) { row in
            taskRow(row)
                .id(row.id)
                .transition(reduceMotion ? .identity : WorkspaceMotion.branchTransition)
        }
    }

    private func taskRow(_ row: MenuTaskVisibleRow) -> some View {
        let task = row.node.task
        let indentation = CGFloat(min(row.depth, 6)) * 21
        let isExpanded = presentation.expandedTaskIDs.contains(task.id)
        let isHighlighted = presentation.selectedTaskID == task.id || hoveredTaskID == task.id
        return HStack(spacing: 7) {
            TaskMenuCheckbox(isCompleted: task.isCompleted, size: 12) {
                _ = tasks.setCompleted(id: task.id, completed: !task.isCompleted)
            }
            .frame(width: 12, height: 32)
            .accessibilityLabel("\(task.isCompleted ? L10n.tr("恢复为待办") : L10n.tr("完成"))：\(task.title)")

            Button { toggleTask(task.id) } label: {
                HStack(spacing: 6) {
                    Text(task.title)
                        .font(.system(size: 13))
                        .foregroundStyle(task.isCompleted ? TaskMenuStyle.secondary : TaskMenuStyle.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    taskMetadata(task)
                }
                .frame(height: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.tr("编辑任务：\(task.title)"))
            .accessibilityIdentifier("menu-task-\(task.id)")
            SubtaskDragHandle(task: task)
        }
        .padding(.leading, 23 + indentation)
        .padding(.trailing, 18)
        .frame(height: 32)
        .overlay(alignment: .leading) {
            if !row.node.children.isEmpty {
                Button { toggleExpanded(task.id) } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .medium))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .animation(reduceMotion ? nil : WorkspaceMotion.branchChange, value: isExpanded)
                        .foregroundStyle(TaskMenuStyle.secondary)
                        .frame(width: 12, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.leading, 7 + indentation)
                .accessibilityLabel(L10n.tr("\(isExpanded ? L10n.tr("收起") : L10n.tr("展开"))子任务：\(task.title)"))
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 10)
                .fill(isHighlighted ? TaskMenuStyle.hover : Color.clear)
                .padding(.horizontal, 6)
        }
        .onHover { hovering in
            if hovering { hoveredTaskID = task.id }
            else if hoveredTaskID == task.id { hoveredTaskID = nil }
        }
        .background(GeometryReader { proxy in
            Color.clear.preference(key: MenuTaskRowFrameKey.self,
                                   value: [task.id: proxy.frame(in: .named("taskMenu"))])
        })
        .contextMenu { taskActions(task) }
        .subtaskReordering(task: task)
    }

    @ViewBuilder
    private func taskMetadata(_ task: TodoTask) -> some View {
        if let date = task.plannedDate {
            HStack(spacing: 3) {
                Image(systemName: "calendar").font(.system(size: 9))
                Text(date.formatted(.dateTime.month().day().locale(L10n.locale)))
                    .font(.system(size: 10))
                    .fixedSize()
            }
            .foregroundStyle(TaskMenuStyle.muted)
        } else if !task.details.isEmpty {
            Image(systemName: "doc.text")
                .font(.system(size: 10))
                .foregroundStyle(TaskMenuStyle.muted)
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 0) {
            navigationButton(.tasks, title: L10n.tr("任务"),
                             symbol: page == .tasks ? "checkmark.circle.fill" : "checkmark.circle")
            navigationButton(.calendar, title: L10n.tr("日历"), symbol: "calendar")
            navigationButton(.activity, title: L10n.tr("活动"), symbol: "waveform.path")
            Button { presentation.openWorkbench() } label: {
                navigationLabel(L10n.tr("工作台"), symbol: "macwindow", selected: false)
            }
            .buttonStyle(.plain)
            .help(L10n.tr("打开工作台"))
            .accessibilityLabel(L10n.tr("打开工作台"))
        }
        .frame(height: 52)
        .overlay(alignment: .top) { Rectangle().fill(TaskMenuStyle.divider).frame(height: 0.5) }
    }

    private func navigationButton(_ destination: MenuPanelPage, title: String, symbol: String) -> some View {
        Button {
            presentation.page = destination
            captureFocused = destination == .tasks
        } label: {
            navigationLabel(title, symbol: symbol, selected: page == destination)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(destination.title)
        .accessibilityIdentifier("menu-page-\(destination.rawValue)")
        .accessibilityAddTraits(page == destination ? .isSelected : [])
    }

    private func navigationLabel(_ title: String, symbol: String, selected: Bool) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 18, weight: .medium))
            Text(title).font(.system(size: 9))
        }
        .foregroundStyle(selected ? TaskMenuStyle.accent : TaskMenuStyle.muted)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func taskActions(_ task: TodoTask) -> some View {
        Button { selectTask(task.id, focus: .description) } label: {
            Label(L10n.tr("编辑描述"), systemImage: "text.alignleft")
        }
        if task.parentID == nil {
            Button { selectTask(task.id, focus: .child) } label: {
                Label(L10n.tr("添加子任务"), systemImage: "plus")
            }
        }
        Button { _ = tasks.setCompleted(id: task.id, completed: !task.isCompleted) } label: {
            Label(task.isCompleted ? L10n.tr("恢复为待办") : L10n.tr("标记完成"),
                  systemImage: task.isCompleted ? "arrow.uturn.backward" : "checkmark.circle")
        }
        Divider()
        Button(role: .destructive) { taskToDelete = task } label: {
            Label(L10n.tr("删除任务…"), systemImage: "trash")
        }
    }

    private func selectTask(_ id: String, focus: MenuEditorField? = nil) {
        captureFocused = false
        presentation.selectTask(id, focus: focus)
        if focus == nil { presentation.requestListFocus() }
    }

    private func toggleTask(_ id: String) {
        captureFocused = false
        presentation.toggleTask(id)
        presentation.requestListFocus()
    }

    private func handleListKey(_ key: MenuTaskListKey) {
        switch key {
        case .details:
            if let id = presentation.selectedTaskID { selectTask(id, focus: .description) }
        case .child:
            if let id = presentation.selectedTaskID, tasks.task(id: id)?.parentID == nil {
                selectTask(id, focus: .child)
            }
        case .move(let offset):
            let rows = visibleRows
            guard !rows.isEmpty else { return }
            let oldIndex = rows.firstIndex { $0.id == presentation.selectedTaskID } ?? (offset > 0 ? -1 : rows.count)
            let index = min(max(oldIndex + offset, 0), rows.count - 1)
            selectTask(rows[index].id)
        case .escape:
            presentation.dismissEditor()
            presentation.requestListFocus()
        }
    }

    private func toggleExpanded(_ id: String) {
        withAnimation(reduceMotion ? nil : WorkspaceMotion.branchChange) {
            if presentation.expandedTaskIDs.contains(id) { presentation.expandedTaskIDs.remove(id) }
            else { presentation.expandedTaskIDs.insert(id) }
        }
    }

    private func sorted(_ nodes: [MenuTaskTreeNode]) -> [MenuTaskTreeNode] {
        nodes.sorted { lhs, rhs in
            if lhs.task.isCompleted != rhs.task.isCompleted { return !lhs.task.isCompleted }
            switch sortOrder {
            case .createdDescending:
                if lhs.task.createdAt != rhs.task.createdAt { return lhs.task.createdAt > rhs.task.createdAt }
            case .createdAscending:
                if lhs.task.createdAt != rhs.task.createdAt { return lhs.task.createdAt < rhs.task.createdAt }
            case .title:
                let comparison = lhs.task.title.localizedStandardCompare(rhs.task.title)
                if comparison != .orderedSame { return comparison == .orderedAscending }
            }
            return lhs.id < rhs.id
        }
    }

    private func flatten(_ roots: [MenuTaskTreeNode], depth: Int = 0) -> [MenuTaskVisibleRow] {
        // Header sorting affects roots only; children keep their saved sibling order.
        (depth == 0 ? sorted(roots) : roots).flatMap { node in
            let row = MenuTaskVisibleRow(node: node, depth: depth)
            return [row] + (presentation.expandedTaskIDs.contains(node.task.id)
                ? flatten(node.children, depth: depth + 1) : [])
        }
    }

    private func branchIDs(in nodes: [MenuTaskTreeNode]) -> Set<String> {
        nodes.reduce(into: Set<String>()) { ids, node in
            if !node.children.isEmpty { ids.insert(node.task.id) }
            ids.formUnion(branchIDs(in: node.children))
        }
    }

    private func updateExpandedBranches(reset: Bool) {
        let branches = branchIDs(in: treeRoots)
        if reset {
            presentation.expandedTaskIDs = branches
            knownBranchIDs = branches
        } else {
            presentation.expandedTaskIDs.formUnion(branches.subtracting(knownBranchIDs))
            knownBranchIDs.formUnion(branches)
        }
    }

    private func resetForOpening() {
        scope = .thisWeek
        presentation.selectedTaskID = nil
        presentation.dismissEditor()
        referenceDate = Date()
        updateExpandedBranches(reset: true)
        captureFocused = false
        let opening = presentation.openGeneration
        DispatchQueue.main.async {
            if presentation.openGeneration == opening, page == .tasks { captureFocused = true }
        }
    }

    private func addTask() {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if tasks.addTask(title: title) != nil {
            referenceDate = Date()
            title = ""
            captureFocused = true
        }
    }
}

private enum MenuTaskSortOrder: String, CaseIterable, Identifiable {
    case createdDescending = "创建时间：从新到旧"
    case createdAscending = "创建时间：从旧到新"
    case title = "任务名称"
    var id: String { rawValue }
}

private struct MenuTaskVisibleRow: Identifiable {
    let node: MenuTaskTreeNode
    let depth: Int
    var id: String { node.task.id }
}

struct MenuTaskRowFrameKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, newest in newest })
    }
}
