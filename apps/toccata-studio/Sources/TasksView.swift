import SwiftUI
import AppKit

enum TaskViewMode: String, Hashable {
    case tasks
    case inbox
    case review

    var title: String {
        switch self {
        case .tasks: return L10n.tr("任务")
        case .inbox: return L10n.tr("收集箱")
        case .review: return L10n.tr("任务回顾")
        }
    }
}

/// Lists and reports share task records; changing the range never changes a task's dates.
@MainActor
struct TasksView: View {
    @ObservedObject private var interfaceLanguage = LanguageSettings.shared
    @EnvironmentObject private var store: TaskStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let mode: TaskViewMode

    @State private var title = ""
    @State private var query = ""
    @Binding private var selection: String?
    @Binding private var taskPeriod: TaskReviewPeriod
    @State private var reviewRange: TaskReviewRange = .preset(.thisWeek)
    @State private var showsCustomReviewRange = false
    @State private var showsCompleted = true
    @State private var copied = false
    @State private var referenceDate = Date()
    @State private var collapsedTaskIDs: Set<String> = []
    @State private var hoveredTaskID: String?
    @AppStorage("tasks.listDisplayMode") private var displayMode: TaskListDisplayMode = .titles
    @FocusState private var addingTask: Bool
    @FocusState private var taskListFocused: Bool

    init(mode: TaskViewMode, selection: Binding<String?> = .constant(nil),
         taskPeriod: Binding<TaskReviewPeriod> = .constant(.thisWeek)) {
        self.mode = mode
        _selection = selection
        _taskPeriod = taskPeriod
    }

    private var taskScope: MenuTaskScope {
        mode == .inbox ? .inbox : (taskPeriod == .thisWeek ? .thisWeek : .lastSevenDays)
    }
    private var explanation: String {
        switch mode {
        case .inbox: return L10n.tr("想到就记下。什么时候做，由你决定。")
        case .tasks: return taskScope.titleExplanation
        case .review: return L10n.tr("回看这段时间完成的事，也带上还没做完的任务。")
        }
    }
    private var scopedTasks: [TodoTask] {
        store.menuTasks(for: taskScope, relativeTo: referenceDate)
    }
    private var reviewSnapshot: TaskReviewSnapshot {
        TaskReviewSnapshot(tasks: store.tasks, range: reviewRange, referenceDate: referenceDate, query: query)
    }

    var body: some View {
        let _ = interfaceLanguage.language
        VStack(spacing: 0) {
            if let error = store.errorMessage {
                TaskErrorBanner(message: error) { store.errorMessage = nil }
            }
            taskList
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .background(TaskScrollerStyle())
        .onAppear { referenceDate = Date() }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { referenceDate = $0 }
        .onReceive(store.$tasks.dropFirst()) { _ in
            referenceDate = Date()
            copied = false
        }
        .onChange(of: mode) { _ in
            query = ""
            selection = nil
            copied = false
            showsCustomReviewRange = false
            collapsedTaskIDs.removeAll()
        }
        .onChange(of: taskPeriod) { _ in selection = nil }
        .onChange(of: reviewRange) { _ in selection = nil; copied = false }
        .onChange(of: query) { _ in copied = false }
        .onChange(of: store.tasks.map(\.id)) { ids in
            if let selection, !ids.contains(selection) { self.selection = nil }
        }
    }

    private var taskList: some View {
        let review = mode == .review ? reviewSnapshot : nil
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(mode.title)
                            .font(.system(size: 25, weight: .bold, design: .rounded))
                        Text(explanation)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    if let review {
                        Button(action: copyReview) {
                            Label(copied ? L10n.tr("已复制") : L10n.tr("复制回顾"), systemImage: copied ? "checkmark" : "doc.on.doc")
                                .fixedSize()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help(L10n.tr("复制当前范围和搜索结果，包含完成状态、任务详情与子任务"))
                        .disabled(review.tasks.isEmpty)
                    }
                }

                if mode == .tasks {
                    periodPicker(L10n.tr("任务范围"), selection: $taskPeriod)
                    quickAdd
                } else if mode == .inbox {
                    quickAdd
                } else if let review {
                    reviewRangeControl
                    VStack(alignment: .leading, spacing: 5) {
                        Text(review.dateLabel)
                        Text(L10n.tr("已完成 \(review.completed.count) 项 · 未完成 \(review.pending.count) 项"))
                            .monospacedDigit()
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    searchField
                    TaskListDisplayModePicker(selection: $displayMode)
                }
            }
            .padding(22)
            .padding(.bottom, -5)

            ZStack {
                if let review {
                    reviewList(review)
                        .id(reviewRange)
                        .transition(WorkspaceMotion.pageTransition)
                } else {
                    inboxList
                        .id(taskScope)
                        .transition(WorkspaceMotion.pageTransition)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .animation(reduceMotion ? nil : WorkspaceMotion.pageChange, value: taskPeriod)
            .animation(reduceMotion ? nil : WorkspaceMotion.pageChange, value: reviewRange)

            Divider()
            HStack(spacing: 5) {
                Image(systemName: mode == .review ? "doc.text" : taskScope.symbol)
                Text(mode == .review ? L10n.tr("按主任务归组；已完成子任务保留在所属任务下") : L10n.tr("视图按时间组织任务，不会自动设置计划日期"))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
        }
    }

    private func periodPicker(_ title: String, selection: Binding<TaskReviewPeriod>) -> some View {
        Picker(title, selection: selection) {
            ForEach(TaskReviewPeriod.allCases) { period in
                Text(period == .thisWeek ? L10n.tr("本周") : L10n.tr("最近 7 天")).tag(period)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        // Rebuild only the native control: AppKit caches segment titles. The binding stays intact.
        .id(interfaceLanguage.language)
    }

    private var reviewRangeControl: some View {
        HStack(spacing: 2) {
            ForEach(TaskReviewPeriod.allCases) { period in
                Button {
                    reviewRange = .preset(period)
                } label: {
                    reviewRangeLabel(period == .thisWeek ? L10n.tr("本周") : L10n.tr("最近 7 天"),
                                     selected: reviewRange == .preset(period))
                }
                .accessibilityValue(reviewRange == .preset(period) ? L10n.tr("已选择") : L10n.tr("未选择"))
            }
            Button {
                referenceDate = Date()
                showsCustomReviewRange = true
            } label: {
                reviewRangeLabel(L10n.tr("自定义时段"), selected: isCustomReviewRange, symbol: "calendar")
            }
            .accessibilityValue(isCustomReviewRange ? L10n.tr("已选择") : L10n.tr("未选择"))
            .help(L10n.tr("在日历中选择开始和结束日期"))
            .popover(isPresented: $showsCustomReviewRange, arrowEdge: .bottom) {
                CalendarDateRangePicker(
                    initialRange: reviewRange.dateRange(relativeTo: referenceDate),
                    referenceDate: referenceDate,
                    onCancel: { showsCustomReviewRange = false },
                    onApply: { selected in
                        reviewRange = .custom(selected)
                        showsCustomReviewRange = false
                    }
                )
            }
        }
        .buttonStyle(.plain)
        .padding(3)
        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.tr("回顾范围"))
    }

    private var isCustomReviewRange: Bool {
        if case .custom = reviewRange { return true }
        return false
    }

    private func reviewRangeLabel(_ title: String, selected: Bool, symbol: String? = nil) -> some View {
        HStack(spacing: 5) {
            if let symbol { Image(systemName: symbol) }
            Text(title)
        }
        .font(.system(size: 12, weight: selected ? .semibold : .medium))
        .padding(.horizontal, 10)
        .frame(height: 26)
        .foregroundStyle(selected ? Color.white : Color.primary)
        .background(selected ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
    }

    private var canAddTask: Bool { !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var quickAdd: some View {
        HStack(spacing: 10) {
            Button(action: addTask) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 19))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(EditActionButtonStyle())
            .disabled(!canAddTask)
            .help(L10n.tr("添加任务，不预设日期"))
            .accessibilityLabel(L10n.tr("添加任务，不预设日期"))
            .accessibilityIdentifier("workspace-add-task")
            TextField(L10n.tr("添加任务，按回车收进来"), text: $title)
                .textFieldStyle(.plain)
                .focused($addingTask)
                .onSubmit(addTask)
                .accessibilityIdentifier("workspace-task-title")
            Button(action: addTask) {
                Image(systemName: "return")
            }
            .buttonStyle(EditActionButtonStyle())
            .foregroundStyle(canAddTask ? Color.accentColor : .secondary)
            .disabled(!canAddTask)
            .help(L10n.tr("添加任务，不预设日期"))
        }
        .padding(12)
        .editableSurface(isFocused: addingTask, cornerRadius: 10,
                         fill: Color.accentColor.opacity(0.07), idleBorderOpacity: 0.12)
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(L10n.tr("搜索任务名称与详情"), text: $query)
                .textFieldStyle(.plain)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(L10n.tr("清除搜索"))
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var inboxList: some View {
        let scoped = scopedTasks
        let snapshot = WorkspaceTaskListSnapshot(allTasks: store.tasks, scopedTasks: scoped,
            includeAllDescendants: mode == .inbox, query: query)
        // Search always reveals matching descendants, even inside a folded branch.
        let collapsed = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? collapsedTaskIDs : []
        let pendingRows = WorkspaceTaskListSnapshot.rows(from: snapshot.pendingRoots, collapsedIDs: collapsed)
        let completedRows = WorkspaceTaskListSnapshot.rows(from: snapshot.completedRoots, collapsedIDs: collapsed)
        if scoped.isEmpty && query.isEmpty {
            TaskPlaceholder(symbol: taskScope.symbol, title: mode == .inbox ? L10n.tr("先收集，再安排") : L10n.tr("这个视图还没有任务"), message: mode == .inbox ? L10n.tr("把想到的事情放进来。\n没有计划日期，也可以安心待在这里。") : L10n.tr("添加一个新任务，或切换范围查看其他记录。"))
        } else if pendingRows.isEmpty && completedRows.isEmpty {
            TaskPlaceholder(symbol: "magnifyingglass", title: L10n.tr("没有匹配的任务"), message: L10n.tr("试试其他关键词。"))
        } else {
            hierarchyList(
                firstTitle: L10n.tr("待办 · \(snapshot.pendingRoots.count) 项主任务"), firstRows: pendingRows,
                secondTitle: L10n.tr("已完成 · \(snapshot.completedRoots.count) 项主任务"), secondRows: completedRows,
                collapsed: collapsed, collapsesSecondSection: true
            )
        }
    }

    private func hierarchyRow(_ row: WorkspaceTaskListRow, collapsed: Set<String>) -> some View {
        WorkspaceTaskRow(
            task: row.task,
            displayMode: displayMode,
            depth: row.depth,
            childCount: row.node.children.count,
            isExpanded: !collapsed.contains(row.id),
            onToggle: { _ = store.setCompleted(id: row.id, completed: !row.task.isCompleted) },
            onToggleExpanded: {
                withAnimation(reduceMotion ? nil : WorkspaceMotion.branchChange) {
                    if collapsedTaskIDs.contains(row.id) { collapsedTaskIDs.remove(row.id) }
                    else { collapsedTaskIDs.insert(row.id) }
                }
            }
        )
        .taskContextMenu(task: row.task) { selection = row.id }
        .subtaskReordering(task: row.task)
    }

    @ViewBuilder
    private func reviewList(_ review: TaskReviewSnapshot) -> some View {
        let collapsed = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? collapsedTaskIDs : []
        let completedRows = WorkspaceTaskListSnapshot.rows(from: review.completedRoots, collapsedIDs: collapsed)
        let pendingRows = WorkspaceTaskListSnapshot.rows(from: review.pendingRoots, collapsedIDs: collapsed)
        if review.tasks.isEmpty {
            TaskPlaceholder(
                symbol: query.isEmpty ? "doc.text" : "magnifyingglass",
                title: query.isEmpty ? L10n.tr("这段时间还没有任务可回顾") : L10n.tr("没有匹配的任务"),
                message: query.isEmpty ? L10n.tr("本期完成的任务和当前未完成的事项\n都会出现在这里，方便整理周报。") : L10n.tr("试试其他关键词。")
            )
        } else {
            hierarchyList(
                firstTitle: L10n.tr("已完成主任务 · \(review.completedRoots.count) 组"), firstRows: completedRows,
                secondTitle: L10n.tr("待推进主任务 · \(review.pendingRoots.count) 组"), secondRows: pendingRows,
                collapsed: collapsed
            )
        }
    }

    private enum HierarchyListItem: Identifiable {
        case firstHeader
        case secondHeader
        case task(WorkspaceTaskListRow)

        enum ID: Hashable {
            case firstHeader
            case secondHeader
            case task(String)
        }

        var id: ID {
            switch self {
            case .firstHeader: return .firstHeader
            case .secondHeader: return .secondHeader
            case .task(let row): return .task(row.id)
            }
        }
    }

    /// SwiftUI owns the row layout so insertion/removal animates its height as
    /// well as opacity; AppKit-backed List reloads used to snap collapsed rows.
    private func hierarchyList(firstTitle: String, firstRows: [WorkspaceTaskListRow],
                               secondTitle: String, secondRows: [WorkspaceTaskListRow],
                               collapsed: Set<String>, collapsesSecondSection: Bool = false) -> some View {
        let secondVisible = !collapsesSecondSection || showsCompleted
        let visibleRows = firstRows + (secondVisible ? secondRows : [])
        let items: [HierarchyListItem] = [.firstHeader] + firstRows.map(HierarchyListItem.task)
            + [.secondHeader] + (secondVisible ? secondRows.map(HierarchyListItem.task) : [])
        return ScrollViewReader { proxy in
            ScrollView {
                // Expanded branches change row count and height together. Eager
                // layout avoids the lazy stack repeatedly estimating animated
                // native-backed rows during expansion (a main-thread hang).
                VStack(alignment: .leading, spacing: 0) {
                    // A task keeps one ForEach identity when completion moves it
                    // across the section header. Separate ForEach containers with
                    // the same explicit row ID can reuse a stale pending view.
                    ForEach(items) { item in
                        switch item {
                        case .firstHeader:
                            listSectionHeader(firstTitle)
                        case .secondHeader:
                            if collapsesSecondSection {
                                Button {
                                    withAnimation(reduceMotion ? nil : WorkspaceMotion.branchChange) {
                                        showsCompleted.toggle()
                                    }
                                } label: {
                                    HStack {
                                        Text(secondTitle)
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .rotationEffect(.degrees(showsCompleted ? 90 : 0))
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 12)
                                .padding(.top, 20)
                                .padding(.bottom, 9)
                                .help(showsCompleted ? L10n.tr("收起已完成任务") : L10n.tr("展开已完成任务"))
                            } else {
                                listSectionHeader(secondTitle)
                            }
                        case .task(let row):
                            selectableRow(row, collapsed: collapsed)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 18)
                .animation(reduceMotion ? nil : WorkspaceMotion.branchChange, value: collapsedTaskIDs)
                .animation(reduceMotion ? nil : WorkspaceMotion.branchChange, value: showsCompleted)
                .animation(reduceMotion ? nil : WorkspaceMotion.pageChange, value: displayMode)
            }
            .focusable()
            .focused($taskListFocused)
            .modifier(TaskListFocusAppearance())
            .onMoveCommand { direction in
                guard !visibleRows.isEmpty, direction == .up || direction == .down else { return }
                let offset = direction == .up ? -1 : 1
                let current = visibleRows.firstIndex { $0.id == selection } ?? (offset > 0 ? -1 : visibleRows.count)
                let next = visibleRows[min(max(current + offset, 0), visibleRows.count - 1)].id
                selection = next
                proxy.scrollTo(HierarchyListItem.ID.task(next))
            }
        }
    }

    private func listSectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.top, 16)
            .padding(.bottom, 9)
    }

    private func selectableRow(_ row: WorkspaceTaskListRow, collapsed: Set<String>) -> some View {
        VStack(spacing: 0) {
            hierarchyRow(row, collapsed: collapsed)
                .padding(.horizontal, 12)
                .background {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(selection == row.id ? Color.accentColor.opacity(0.1) :
                              (hoveredTaskID == row.id ? Color.primary.opacity(0.035) : Color.clear))
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    selection = row.id
                    addingTask = false
                    taskListFocused = true
                }
                .onHover { inside in
                    if inside { hoveredTaskID = row.id }
                    else if hoveredTaskID == row.id { hoveredTaskID = nil }
                }
                .accessibilityAddTraits(selection == row.id ? .isSelected : [])
            Divider()
                .opacity(0.45)
                .padding(.leading, 44 + CGFloat(row.depth) * 26)
                .padding(.trailing, 12)
        }
        .transition(reduceMotion ? .identity : WorkspaceMotion.branchTransition)
    }

    private func addTask() {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard let id = store.addTask(title: title) else { return }
        title = ""
        selection = id
        addingTask = true
    }

    private func copyReview() {
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString(reviewSnapshot.markdown, forType: .string) {
            copied = true
        } else {
            store.errorMessage = L10n.tr("复制失败，请重试。")
        }
    }
}

/// Keep arrow-key navigation without drawing a focus halo around the full list.
private struct TaskListFocusAppearance: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.focusEffectDisabled()
        } else {
            content
        }
    }
}

struct TaskPlaceholder: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(Color.accentColor.opacity(0.65))
                .padding(.bottom, 3)
            Text(title).font(.system(size: 16, weight: .semibold))
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(5)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct TaskErrorBanner: View {
    @ObservedObject private var interfaceLanguage = LanguageSettings.shared
    let message: String
    let dismiss: () -> Void

    var body: some View {
        let _ = interfaceLanguage.language
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).textSelection(.enabled)
            Spacer()
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .help(L10n.tr("关闭错误提示"))
        }
        .font(.system(size: 13))
        .padding(12)
        .background(Color.orange.opacity(0.09))
    }
}
