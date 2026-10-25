import SwiftUI
import AppKit

enum TaskViewMode: String, Hashable {
    case inbox
    case lastSevenDays
    case thisWeek
    case review

    var scope: MenuTaskScope? {
        switch self {
        case .inbox: return .inbox
        case .lastSevenDays: return .lastSevenDays
        case .thisWeek: return .thisWeek
        case .review: return nil
        }
    }

    var title: String {
        switch self {
        case .inbox: return "收集箱"
        case .lastSevenDays: return "最近 7 天"
        case .thisWeek: return "本周任务"
        case .review: return "完成回顾"
        }
    }

    var explanation: String {
        switch self {
        case .inbox: return "想到就记下。什么时候做，由你决定。"
        case .lastSevenDays: return "最近 7 天创建的任务，待办与完成记录都保留。"
        case .thisWeek: return "本周新建、之前留下的待办，以及本周完成的事。"
        case .review: return "按实际完成时间，找回这一段的进展。"
        }
    }
}

/// The inbox keeps tasks until the user completes them. A missing plan date has no special meaning.
@MainActor
struct TasksView: View {
    @EnvironmentObject private var store: TaskStore
    let mode: TaskViewMode

    @State private var title = ""
    @State private var query = ""
    @Binding private var selection: String?
    @State private var reviewPeriod: TaskReviewPeriod = .thisWeek
    @State private var showsCompleted = true
    @State private var copied = false
    @State private var referenceDate = Date()
    @FocusState private var addingTask: Bool

    init(mode: TaskViewMode, selection: Binding<String?> = .constant(nil)) {
        self.mode = mode
        _selection = selection
    }

    private var scopedTasks: [TodoTask] {
        guard let scope = mode.scope else { return [] }
        return store.menuTasks(for: scope, relativeTo: referenceDate)
    }
    private var pendingTasks: [TodoTask] { scopedTasks.filter { !$0.isCompleted && matches($0) } }
    private var completedTasks: [TodoTask] {
        scopedTasks.filter { $0.isCompleted && matches($0) }
            .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
    }
    private var reviewTasks: [TodoTask] {
        store.completedTasks(in: reviewPeriod).filter(matches)
    }
    private var reviewDays: [Date] {
        Array(Set(reviewTasks.compactMap { $0.completedAt.map { Calendar.current.startOfDay(for: $0) } }))
            .sorted(by: >)
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
        .onReceive(store.$tasks.dropFirst()) { _ in referenceDate = Date() }
        .onChange(of: mode) { _ in
            query = ""
            selection = nil
        }
        .onChange(of: store.tasks.map(\.id)) { ids in
            if let selection, !ids.contains(selection) { self.selection = nil }
        }
    }

    private var taskList: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(mode.title)
                            .font(.system(size: 25, weight: .bold, design: .rounded))
                        Text(mode.explanation)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    if mode == .review {
                        Button(action: copyReview) {
                            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        }
                        .help(copied ? "已复制回顾" : "复制当前回顾（含任务详情）")
                        .disabled(reviewTasks.isEmpty)
                    }
                }

                if mode != .review {
                    quickAdd
                } else {
                    Picker("回顾范围", selection: $reviewPeriod) {
                        ForEach(TaskReviewPeriod.allCases) { period in
                            Text(period.rawValue).tag(period)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: reviewPeriod) { _ in selection = nil; copied = false }

                    HStack {
                        Text(reviewDateLabel)
                        Spacer()
                        Text("\(reviewTasks.count) 项完成")
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

            if mode != .review {
                inboxList
            } else {
                reviewList
            }

            Divider()
            HStack(spacing: 5) {
                Image(systemName: mode.scope?.symbol ?? "checkmark.circle")
                Text(mode == .review ? "包含子任务；撤销完成会移出回顾" : "视图按时间组织任务，不会自动设置计划日期")
                Spacer(minLength: 0)
                if copied { Text("已复制").foregroundStyle(Color.accentColor) }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
        }
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
            TaskPlaceholder(symbol: mode.scope?.symbol ?? "tray", title: mode == .inbox ? "先收集，再安排" : "这个视图还没有任务", message: mode == .inbox ? "把想到的事情放进来。\n没有计划日期，也可以安心待在这里。" : "添加一个新任务，或切换视图查看其他记录。")
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
    private var reviewList: some View {
        if reviewTasks.isEmpty {
            TaskPlaceholder(
                symbol: query.isEmpty ? "checkmark.circle" : "magnifyingglass",
                title: query.isEmpty ? "这段时间还没有完成记录" : "没有匹配的任务",
                message: query.isEmpty ? "完成任务后，它会按完成日期出现在这里。\n创建时间和计划日期不会影响归档。" : "试试其他关键词。"
            )
        } else {
            List(selection: $selection) {
                ForEach(reviewDays, id: \.self) { day in
                    Section {
                        ForEach(reviewTasks.filter { task in
                            task.completedAt.map { Calendar.current.isDate($0, inSameDayAs: day) } ?? false
                        }) { task in
                            taskRow(task, showsParent: true).tag(task.id)
                        }
                    } header: {
                        Text(day.formatted(.dateTime.month().day().weekday(.wide)))
                    }
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
        // A child match must remain discoverable from the inbox's parent row.
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

    private var reviewDateLabel: String {
        let bounds = reviewBounds
        return "\(bounds.0.formatted(.dateTime.month().day())) — \(bounds.1.formatted(.dateTime.month().day()))"
    }

    private var reviewBounds: (Date, Date) {
        let interval = reviewPeriod.interval(relativeTo: Date())
        return (interval.start, interval.end)
    }

    private func copyReview() {
        var lines = ["\(reviewPeriod.rawValue)完成回顾（\(reviewDateLabel)）", "完成 \(reviewTasks.count) 项（含子任务）", ""]
        for task in reviewTasks.reversed() {
            let parent = task.parentID.flatMap { store.task(id: $0)?.title }
            let name = parent.map { "\($0) / \(task.title)" } ?? task.title
            let time = task.completedAt?.formatted(.dateTime.month().day().hour().minute()) ?? ""
            lines.append("- [x] \(name)（\(time)）")
            if !task.details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lines.append("  详情：\(task.details.replacingOccurrences(of: "\n", with: "\n  "))")
            }
            lines.append("")
        }
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string) {
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
