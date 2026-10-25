import SwiftUI
import AppKit

enum TaskViewMode: String, Hashable {
    case tasks
    case inbox
    case review

    var title: String {
        switch self {
        case .tasks: return "任务"
        case .inbox: return "收集箱"
        case .review: return "任务回顾"
        }
    }
}

/// Lists and reports share task records; changing the range never changes a task's dates.
@MainActor
struct TasksView: View {
    @EnvironmentObject private var store: TaskStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let mode: TaskViewMode

    @State private var title = ""
    @State private var query = ""
    @Binding private var selection: String?
    @Binding private var taskPeriod: TaskReviewPeriod
    @State private var reviewPeriod: TaskReviewPeriod = .thisWeek
    @State private var showsCompleted = true
    @State private var copied = false
    @State private var referenceDate = Date()
    @FocusState private var addingTask: Bool

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
        case .inbox: return "想到就记下。什么时候做，由你决定。"
        case .tasks: return taskScope.titleExplanation
        case .review: return "回看这段时间完成的事，也带上还没做完的任务。"
        }
    }
    private var scopedTasks: [TodoTask] {
        store.menuTasks(for: taskScope, relativeTo: referenceDate)
    }
    private var pendingTasks: [TodoTask] { scopedTasks.filter { !$0.isCompleted && matches($0) } }
    private var completedTasks: [TodoTask] {
        scopedTasks.filter { $0.isCompleted && matches($0) }
            .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
    }
    private var reviewSnapshot: TaskReviewSnapshot {
        TaskReviewSnapshot(tasks: store.tasks, period: reviewPeriod, referenceDate: referenceDate, query: query)
    }

    var body: some View {
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
        }
        .onChange(of: taskPeriod) { _ in selection = nil }
        .onChange(of: reviewPeriod) { _ in selection = nil; copied = false }
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
                            Label(copied ? "已复制" : "复制回顾", systemImage: copied ? "checkmark" : "doc.on.doc")
                                .fixedSize()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("复制当前范围和搜索结果，包含完成状态、任务详情与子任务")
                        .disabled(review.tasks.isEmpty)
                    }
                }

                if mode == .tasks {
                    periodPicker("任务范围", selection: $taskPeriod)
                    quickAdd
                } else if mode == .inbox {
                    quickAdd
                } else if let review {
                    periodPicker("回顾范围", selection: $reviewPeriod)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(review.dateLabel)
                        Text("已完成 \(review.completed.count) 项 · 未完成 \(review.pending.count) 项")
                            .monospacedDigit()
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                }

                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索任务名称与详情", text: $query)
                        .textFieldStyle(.plain)
                    if !query.isEmpty {
                        Button { query = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("清除搜索")
                    }
                }
                .font(.system(size: 13))
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            }
            .padding(22)
            .padding(.bottom, -5)

            ZStack {
                if let review {
                    reviewList(review)
                        .id(reviewPeriod)
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
            .animation(reduceMotion ? nil : WorkspaceMotion.pageChange, value: reviewPeriod)

            Divider()
            HStack(spacing: 5) {
                Image(systemName: mode == .review ? "doc.text" : taskScope.symbol)
                Text(mode == .review ? "含子任务与遗留待办；复制保留详情和完成状态" : "视图按时间组织任务，不会自动设置计划日期")
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
                Text(period == .thisWeek ? "本周" : "最近 7 天").tag(period)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
    }

    private var quickAdd: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 19))
                .foregroundStyle(Color.accentColor)
            TextField("添加任务，按回车收进来", text: $title)
                .textFieldStyle(.plain)
                .focused($addingTask)
                .onSubmit(addTask)
            Button(action: addTask) {
                Image(systemName: "return")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .help("添加任务，不预设日期")
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor.opacity(0.12)))
    }

    @ViewBuilder
    private var inboxList: some View {
        if scopedTasks.isEmpty && query.isEmpty {
            TaskPlaceholder(symbol: taskScope.symbol, title: mode == .inbox ? "先收集，再安排" : "这个视图还没有任务", message: mode == .inbox ? "把想到的事情放进来。\n没有计划日期，也可以安心待在这里。" : "添加一个新任务，或切换范围查看其他记录。")
        } else if pendingTasks.isEmpty && completedTasks.isEmpty {
            TaskPlaceholder(symbol: "magnifyingglass", title: "没有匹配的任务", message: "试试其他关键词。")
        } else {
            List(selection: $selection) {
                Section {
                    ForEach(pendingTasks) { task in
                        taskRow(task, showsParent: mode != .inbox).tag(task.id)
                    }
                } header: {
                    Text("待办 · \(pendingTasks.count)")
                }
                Section {
                    if showsCompleted {
                        ForEach(completedTasks) { task in
                            taskRow(task, showsParent: mode != .inbox).tag(task.id)
                        }
                    }
                } header: {
                    Button {
                        showsCompleted.toggle()
                    } label: {
                        HStack {
                            Text("已完成 · \(completedTasks.count)")
                            Spacer()
                            Image(systemName: showsCompleted ? "chevron.down" : "chevron.right")
                        }
                    }
                    .buttonStyle(.plain)
                    .help(showsCompleted ? "收起已完成任务" : "展开已完成任务")
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        }
    }

    @ViewBuilder
    private func reviewList(_ review: TaskReviewSnapshot) -> some View {
        if review.tasks.isEmpty {
            TaskPlaceholder(
                symbol: query.isEmpty ? "doc.text" : "magnifyingglass",
                title: query.isEmpty ? "这段时间还没有任务可回顾" : "没有匹配的任务",
                message: query.isEmpty ? "本期完成的任务和当前未完成的事项\n都会出现在这里，方便整理周报。" : "试试其他关键词。"
            )
        } else {
            List(selection: $selection) {
                Section {
                    ForEach(review.completed) { task in
                        taskRow(task, showsParent: true).tag(task.id)
                    }
                } header: {
                    Text("已完成 · \(review.completed.count)")
                }
                Section {
                    ForEach(review.pending) { task in
                        taskRow(task, showsParent: true).tag(task.id)
                    }
                } header: {
                    Text("未完成 · \(review.pending.count)")
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        }
    }

    private func taskRow(_ task: TodoTask, showsParent: Bool = false) -> some View {
        TaskListRow(
            task: task,
            children: store.children(of: task.id),
            parentTitle: showsParent ? task.parentID.flatMap { store.task(id: $0)?.title } : nil,
            onToggle: { _ = store.setCompleted(id: task.id, completed: !task.isCompleted) }
        )
        .taskContextMenu(task: task) { selection = task.id }
    }

    private func matches(_ task: TodoTask) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        if [task.title, task.details].contains(where: { $0.localizedCaseInsensitiveContains(needle) }) { return true }
        return store.children(of: task.id).contains { child in
            [child.title, child.details].contains { $0.localizedCaseInsensitiveContains(needle) }
        }
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
            store.errorMessage = "复制失败，请重试。"
        }
    }
}

private struct TaskListRow: View {
    let task: TodoTask
    let children: [TodoTask]
    let parentTitle: String?
    let onToggle: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: onToggle) {
                Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 19, weight: .regular))
                    .foregroundStyle(task.isCompleted ? Color.accentColor : Color.secondary.opacity(0.65))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(task.isCompleted ? "将\(task.title)恢复为待办" : "完成\(task.title)")

            VStack(alignment: .leading, spacing: 6) {
                Text(task.title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(task.isCompleted ? .secondary : .primary)
                    .strikethrough(task.isCompleted, color: .secondary.opacity(0.5))
                    .lineLimit(2)
                if let parentTitle {
                    Label(parentTitle, systemImage: "arrow.turn.down.right")
                        .lineLimit(1)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                if !children.isEmpty || task.plannedDate != nil || !task.details.isEmpty {
                    HStack(spacing: 9) {
                        if !children.isEmpty {
                            Label("\(children.filter(\.isCompleted).count)/\(children.count)", systemImage: "checklist")
                        }
                        if let date = task.plannedDate {
                            Label(date.formatted(.dateTime.month().day()), systemImage: "calendar")
                        }
                        if !task.details.isEmpty { Image(systemName: "text.alignleft") }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }
                Text("创建于 \(task.createdAt.formatted(.dateTime.month().day()))\(task.completedAt.map { " · 完成于 \($0.formatted(.dateTime.month().day()))" } ?? "")")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 9)
        .contentShape(Rectangle())
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
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).textSelection(.enabled)
            Spacer()
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .help("关闭错误提示")
        }
        .font(.system(size: 13))
        .padding(12)
        .background(Color.orange.opacity(0.09))
    }
}
