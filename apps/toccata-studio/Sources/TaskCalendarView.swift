import SwiftUI

/// A calendar follows a task's actual dates. An absent plan date never becomes today's plan.
@MainActor
struct TaskCalendarView: View {
    @EnvironmentObject private var store: TaskStore

    @State private var displayedMonth = Calendar.current.startOfDay(for: Date())
    @State private var selectedDay = Calendar.current.startOfDay(for: Date())
    @State private var mode: TaskCalendarMode = .all
    @Binding private var selection: String?
    @State private var newTitle = ""
    @State private var showsUnscheduled = false
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
    private var pendingUnscheduledCount: Int { unscheduledTasks.filter { !$0.isCompleted }.count }

    var body: some View {
        VStack(spacing: 0) {
            if let error = store.errorMessage {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(error).textSelection(.enabled)
                    Spacer()
                    Button { store.errorMessage = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
                        .help("关闭错误提示")
                }
                .font(.system(size: 12))
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
            ScrollView {
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
            Text("任务日历")
                .font(.system(size: 25, weight: .bold, design: .rounded))
            Text("创建、安排、完成，各自保留真实日期。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private var daySection: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .firstTextBaseline) {
                Text(dateLabel(selectedDay, includesWeekday: true))
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Text("\(dayTasks.count) 项任务")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Picker("按哪种日期查看", selection: Binding(
                get: { mode },
                set: { mode = $0; selection = nil }
            )) {
                ForEach(TaskCalendarMode.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)

            if dayTasks.isEmpty {
                VStack(spacing: 7) {
                    Text(emptyDayTitle)
                        .font(.system(size: 12, weight: .medium))
                    Text("没有指定计划日期的任务，会留在下方“未安排日期”。")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 22)
            } else {
                LazyVStack(spacing: 4) {
                    ForEach(dayTasks) { task in
                        taskRow(task, showsDayEvents: true)
                    }
                }
            }

            plannedTaskComposer
        }
    }

    private var plannedTaskComposer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "calendar.badge.plus")
                    .foregroundStyle(Color.accentColor)
                TextField("在选中日期安排一项任务", text: $newTitle)
                    .textFieldStyle(.plain)
                    .focused($addingTask)
                    .onSubmit(addPlannedTask)
                    .accessibilityLabel("新建带计划日期的任务")
            }
            HStack {
                Text("会明确设置计划日期")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 2)
                Button("安排到 \(dateLabel(selectedDay))", action: addPlannedTask)
                    .controlSize(.small)
                    .disabled(newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .font(.system(size: 12))
        .padding(12)
        .background(Color.accentColor.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
    }

    private var unscheduledSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            DisclosureGroup(isExpanded: $showsUnscheduled) {
                LazyVStack(alignment: .leading, spacing: 7) {
                    Text("这些任务未设计划日期，不会自动安排到今天。点击任务可设置日期；已完成记录仍保留。")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 6)
                    if unscheduledTasks.isEmpty {
                        Text("当前没有未安排日期的任务。")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 8)
                    } else {
                        ForEach(unscheduledTasks) { task in
                            taskRow(task, showsDayEvents: false)
                        }
                    }
                }
            } label: {
                HStack(spacing: 7) {
                    Label("未安排日期", systemImage: "tray")
                        .font(.system(size: 12, weight: .medium))
                    Spacer(minLength: 0)
                    Text("\(pendingUnscheduledCount) 项待办 · \(unscheduledTasks.count) 项共计")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func taskRow(_ task: TodoTask, showsDayEvents: Bool) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Button {
                _ = store.setCompleted(id: task.id, completed: !task.isCompleted)
            } label: {
                Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 17))
                    .foregroundStyle(task.isCompleted ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
            .accessibilityLabel(task.isCompleted ? "将\(task.title)恢复待办" : "完成\(task.title)")

            Button {
                selection = task.id
                addingTask = false
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(task.title)
                        .font(.system(size: 12, weight: .medium))
                        .strikethrough(task.isCompleted)
                        .foregroundStyle(task.isCompleted ? .secondary : .primary)
                        .lineLimit(2)
                    if let parentID = task.parentID, let parent = store.task(id: parentID) {
                        Label(parent.title, systemImage: "arrow.turn.down.right")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if showsDayEvents {
                        HStack(spacing: 6) {
                            if calendar.isDate(task.createdAt, inSameDayAs: selectedDay) {
                                eventBadge("创建", color: .blue)
                            }
                            if let plannedDate = task.plannedDate, calendar.isDate(plannedDate, inSameDayAs: selectedDay) {
                                eventBadge("计划", color: .orange)
                            }
                            if let completedAt = task.completedAt, calendar.isDate(completedAt, inSameDayAs: selectedDay) {
                                eventBadge("完成", color: .green)
                            }
                            Spacer(minLength: 0)
                        }
                    } else {
                        Text(task.isCompleted ? "已完成 · 未设置计划日期" : "待办 · 未设置计划日期")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("编辑任务详情")
            Image(systemName: "chevron.right")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .padding(.top, 5)
                .allowsHitTesting(false)
        }
        .padding(10)
        .background(selection == task.id ? Color.accentColor.opacity(0.1) : Color(nsColor: .controlBackgroundColor).opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selection == task.id ? Color.accentColor.opacity(0.2) : Color.clear))
        .taskContextMenu(task: task) {
            selection = task.id
            addingTask = false
        }
    }

    private func eventBadge(_ title: String, color: Color) -> some View {
        Text(title)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 4))
    }

    private var emptyDayTitle: String {
        switch mode {
        case .all: return "当天还没有创建、计划或完成记录"
        case .created: return "当天没有创建任务"
        case .planned: return "当天没有安排任务"
        case .completed: return "当天没有完成记录"
        }
    }

    private func dateLabel(_ date: Date, includesWeekday: Bool = false) -> String {
        let day = "\(calendar.component(.month, from: date))月\(calendar.component(.day, from: date))日"
        guard includesWeekday else { return day }
        let weekdays = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
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
