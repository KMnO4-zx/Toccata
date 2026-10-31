import SwiftUI

/// A calendar follows a task's actual dates. An absent plan date never becomes today's plan.
@MainActor
struct TaskCalendarView: View {
    @ObservedObject private var interfaceLanguage = LanguageSettings.shared
    @EnvironmentObject private var store: TaskStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("tasks.listDisplayMode") private var displayMode: TaskListDisplayMode = .titles

    @State private var displayedMonth = Calendar.current.startOfDay(for: Date())
    @State private var selectedDay = Calendar.current.startOfDay(for: Date())
    @State private var mode: TaskCalendarMode = .all
    @Binding private var selection: String?
    @State private var newTitle = ""
    @State private var showsUnscheduled = false
    @State private var collapsedTaskIDs: Set<String> = []
    @FocusState private var addingTask: Bool

    private let calendar = Calendar.current

    init(selection: Binding<String?> = .constant(nil)) {
        _selection = selection
    }

    private var dayTasks: [TodoTask] {
        TaskCalendarModel.tasks(on: selectedDay, from: store.tasks, mode: mode, calendar: calendar)
    }
    private var unscheduledTasks: [TodoTask] {
        TaskCalendarModel.unscheduledTasks(from: store.tasks).sorted {
            if $0.isCompleted != $1.isCompleted { return !$0.isCompleted }
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.id < $1.id
        }
    }
    var body: some View {
        let _ = interfaceLanguage.language
        VStack(spacing: 0) {
            if let error = store.errorMessage {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(error).textSelection(.enabled)
                    Spacer()
                    Button { store.errorMessage = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
                        .help(L10n.tr("关闭错误提示"))
                }
                .font(.system(size: 13))
                .padding(12)
                .background(Color.orange.opacity(0.09))
            }

            calendarPane
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .background(TaskScrollerStyle())
        .onChange(of: store.tasks.map(\.id)) { ids in
            if let selection, !ids.contains(selection) { self.selection = nil }
        }
    }

    private var calendarPane: some View {
        ScrollViewReader { proxy in
            // Keep the calendar columns fixed as the selected day's task list
            // gains or loses the legacy scrollbar gutter.
            StableWidthScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    heading
                    TaskMonthGrid(tasks: store.tasks, displayedMonth: $displayedMonth,
                                  selectedDay: $selectedDay)
                    daySection
                        .id("selected-day")
                    unscheduledSection
                }
                .padding(22)
            }
            .onChange(of: selectedDay) { _ in
                selection = nil
                collapsedTaskIDs.removeAll()
            }
            .onChange(of: addingTask) { focused in
                if focused {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        proxy.scrollTo("selected-day", anchor: .top)
                    }
                }
            }
        }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.tr("任务日历"))
                .font(.system(size: 25, weight: .bold, design: .rounded))
            Text(L10n.tr("创建、安排、完成，各自保留真实日期。"))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
    }

    private var daySection: some View {
        let matchingTasks = dayTasks
        let snapshot = WorkspaceTaskListSnapshot(allTasks: store.tasks, scopedTasks: matchingTasks)
        let rows = WorkspaceTaskListSnapshot.rows(from: snapshot.pendingRoots + snapshot.completedRoots,
                                                  collapsedIDs: collapsedTaskIDs)
        return VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .firstTextBaseline) {
                Text(dateLabel(selectedDay, includesWeekday: true))
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Text(L10n.tr("\(matchingTasks.count) 项任务"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                filterRow(L10n.tr("查看记录")) {
                    WorkspaceSegmentedControl(
                        title: L10n.tr("按哪种日期查看"),
                        selection: Binding(
                            get: { mode },
                            set: { mode = $0; selection = nil; collapsedTaskIDs.removeAll() }
                        ),
                        options: TaskCalendarMode.allCases,
                        optionTitle: { $0.title }
                    )
                }
                filterRow(L10n.tr("显示方式")) {
                    WorkspaceSegmentedControl(
                        title: L10n.tr("任务显示方式"), selection: $displayMode,
                        options: TaskListDisplayMode.allCases, optionTitle: { $0.title }
                    )
                }
            }

            // Keep the calendar and composer in place while the selected record
            // category fades between its results, including empty states.
            ZStack(alignment: .topLeading) {
                // A concrete container keeps the transition on the result set;
                // Group can leave native-backed rows hidden after later updates.
                VStack(alignment: .leading, spacing: 0) {
                    if matchingTasks.isEmpty {
                        VStack(spacing: 7) {
                            Text(emptyDayTitle)
                                .font(.system(size: 13, weight: .medium))
                            Text(L10n.tr("没有指定计划日期的任务，会留在下方“未安排日期”。"))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 22)
                    } else {
                        // Branch animations change both row count and height. Resolve
                        // their native-backed rows eagerly, as in the main task list.
                        VStack(spacing: 4) {
                            ForEach(rows) { row in
                                taskRow(row, showsDayEvents: true)
                                    .transition(reduceMotion ? .identity : WorkspaceMotion.branchTransition)
                            }
                        }
                        .animation(reduceMotion ? nil : WorkspaceMotion.branchChange, value: collapsedTaskIDs)
                        .animation(reduceMotion ? nil : WorkspaceMotion.pageChange, value: displayMode)
                    }
                }
                .id(mode)
                .transition(.opacity)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(reduceMotion ? WorkspaceMotion.sidebarSelectionFade : WorkspaceMotion.pageChange, value: mode)

            plannedTaskComposer
        }
    }

    private func filterRow<Control: View>(_ title: String, @ViewBuilder control: () -> Control) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                filterLabel(title)
                control()
            }
            VStack(alignment: .leading, spacing: 6) {
                filterLabel(title)
                control()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func filterLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize()
    }

    private var plannedTaskComposer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "calendar.badge.plus")
                    .foregroundStyle(Color.accentColor)
                TextField(L10n.tr("在选中日期安排一项任务"), text: $newTitle)
                    .textFieldStyle(.plain)
                    .focused($addingTask)
                    .onSubmit(addPlannedTask)
                    .accessibilityLabel(L10n.tr("新建带计划日期的任务"))
            }
            HStack {
                Text(L10n.tr("会明确设置计划日期"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 2)
                Button(L10n.tr("安排到 \(dateLabel(selectedDay))"), action: addPlannedTask)
                    .controlSize(.small)
                    .disabled(newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .font(.system(size: 13))
        .padding(12)
        .background(Color.accentColor.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
    }

    private var unscheduledSection: some View {
        let matchingTasks = unscheduledTasks
        let snapshot = WorkspaceTaskListSnapshot(allTasks: store.tasks, scopedTasks: matchingTasks)
        let rows = WorkspaceTaskListSnapshot.rows(from: snapshot.pendingRoots + snapshot.completedRoots,
                                                  collapsedIDs: collapsedTaskIDs)
        return VStack(alignment: .leading, spacing: 10) {
            Divider()
            DisclosureGroup(isExpanded: $showsUnscheduled) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(L10n.tr("这些任务未设计划日期，不会自动安排到今天。点击任务可设置日期；已完成记录仍保留。"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 6)
                    if matchingTasks.isEmpty {
                        Text(L10n.tr("当前没有未安排日期的任务。"))
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 8)
                    } else {
                        ForEach(rows) { row in
                            taskRow(row, showsDayEvents: false)
                                .transition(reduceMotion ? .identity : WorkspaceMotion.branchTransition)
                        }
                    }
                }
                .animation(reduceMotion ? nil : WorkspaceMotion.branchChange, value: collapsedTaskIDs)
                .animation(reduceMotion ? nil : WorkspaceMotion.pageChange, value: displayMode)
            } label: {
                HStack(spacing: 7) {
                    Label(L10n.tr("未安排日期"), systemImage: "tray")
                        .font(.system(size: 13, weight: .medium))
                    Spacer(minLength: 0)
                    Text(L10n.tr("\(matchingTasks.filter { !$0.isCompleted }.count) 项待办 · \(matchingTasks.count) 项共计"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func taskRow(_ row: WorkspaceTaskListRow, showsDayEvents: Bool) -> some View {
        let task = row.task
        return HStack(alignment: .top, spacing: 7) {
            if row.node.children.isEmpty {
                Color.clear.frame(width: 12, height: 22)
                    .accessibilityHidden(true)
            } else {
                Button {
                    withAnimation(reduceMotion ? nil : WorkspaceMotion.branchChange) {
                        if collapsedTaskIDs.contains(task.id) { collapsedTaskIDs.remove(task.id) }
                        else { collapsedTaskIDs.insert(task.id) }
                    }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(collapsedTaskIDs.contains(task.id) ? 0 : 90))
                        .foregroundStyle(.secondary)
                        .frame(width: 12, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(collapsedTaskIDs.contains(task.id) ? L10n.tr("展开\(task.title)的子任务") : L10n.tr("收起\(task.title)的子任务"))
                .accessibilityValue(collapsedTaskIDs.contains(task.id) ? L10n.tr("已收起") : L10n.tr("已展开"))
            }

            Button {
                _ = store.setCompleted(id: task.id, completed: !task.isCompleted)
            } label: {
                Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 17))
                    .foregroundStyle(task.isCompleted ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
            .accessibilityLabel(task.isCompleted ? L10n.tr("将\(task.title)恢复待办") : L10n.tr("完成\(task.title)"))

            Button {
                selection = task.id
                addingTask = false
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(task.title)
                        .font(.system(size: 13, weight: .medium))
                        .strikethrough(task.isCompleted)
                        .foregroundStyle(task.isCompleted ? .secondary : .primary)
                        .lineLimit(2)
                    if displayMode.showsDescriptions, !task.details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(task.details)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .transition(.opacity)
                    }
                    if showsDayEvents, !row.node.isContextOnly, displayMode.showsDescriptions {
                        HStack(spacing: 6) {
                            if calendar.isDate(task.createdAt, inSameDayAs: selectedDay) {
                                eventBadge(L10n.tr("创建"), color: .blue)
                            }
                            if let plannedDate = task.plannedDate, calendar.isDate(plannedDate, inSameDayAs: selectedDay) {
                                eventBadge(L10n.tr("计划"), color: .orange)
                            }
                            if let completedAt = task.completedAt, calendar.isDate(completedAt, inSameDayAs: selectedDay) {
                                eventBadge(L10n.tr("完成"), color: .green)
                            }
                            Spacer(minLength: 0)
                        }
                        .transition(.opacity)
                    } else if !showsDayEvents, !row.node.isContextOnly, displayMode.showsDescriptions {
                        Text(task.isCompleted ? L10n.tr("已完成 · 未设置计划日期") : L10n.tr("待办 · 未设置计划日期"))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.tr("编辑任务详情"))
            if task.parentID != nil {
                SubtaskDragHandle(task: task)
            } else {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 5)
                    .allowsHitTesting(false)
            }
        }
        .padding(10)
        .background(selection == task.id ? Color.accentColor.opacity(0.1) : Color(nsColor: .controlBackgroundColor).opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selection == task.id ? Color.accentColor.opacity(0.2) : Color.clear))
        .taskContextMenu(task: task) {
            selection = task.id
            addingTask = false
        }
        .padding(.leading, CGFloat(row.depth) * 22)
        .subtaskReordering(task: task)
    }

    private func eventBadge(_ title: String, color: Color) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 4))
    }

    private var emptyDayTitle: String {
        switch mode {
        case .all: return L10n.tr("当天还没有创建、计划或完成记录")
        case .created: return L10n.tr("当天没有创建任务")
        case .planned: return L10n.tr("当天没有安排任务")
        case .completed: return L10n.tr("当天没有完成记录")
        }
    }

    private func dateLabel(_ date: Date, includesWeekday: Bool = false) -> String {
        let day = L10n.tr("\(calendar.component(.month, from: date))月\(calendar.component(.day, from: date))日")
        guard includesWeekday else { return day }
        let weekdays = [L10n.tr("周日"), L10n.tr("周一"), L10n.tr("周二"), L10n.tr("周三"), L10n.tr("周四"), L10n.tr("周五"), L10n.tr("周六")]
        return "\(day) · \(weekdays[calendar.component(.weekday, from: date) - 1])"
    }

    private func addPlannedTask() {
        guard let id = store.addTask(title: newTitle, plannedDate: selectedDay) else { return }
        newTitle = ""
        if mode != .all { mode = .planned }
        selection = id
        addingTask = false
    }
}
