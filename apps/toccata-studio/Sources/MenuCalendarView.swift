import SwiftUI

@MainActor
struct MenuCalendarView: View {
    @ObservedObject private var interfaceLanguage = LanguageSettings.shared
    @EnvironmentObject private var tasks: TaskStore
    @EnvironmentObject private var presentation: MenuTaskPresentation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var displayedMonth = Calendar.current.startOfDay(for: Date())
    @State private var selectedDay = Calendar.current.startOfDay(for: Date())
    @State private var collapsedTaskIDs: Set<String> = []
    @AppStorage("tasks.listDisplayMode") private var displayMode: TaskListDisplayMode = .titles
    private let calendar = Calendar.current

    private var dayTasks: [TodoTask] {
        TaskCalendarModel.tasks(on: selectedDay, from: tasks.tasks, calendar: calendar)
    }

    var body: some View {
        let _ = interfaceLanguage.language
        let matchingTasks = dayTasks
        let snapshot = WorkspaceTaskListSnapshot(allTasks: tasks.tasks, scopedTasks: matchingTasks)
        let rows = WorkspaceTaskListSnapshot.rows(from: snapshot.pendingRoots + snapshot.completedRoots,
                                                  collapsedIDs: collapsedTaskIDs)
        return VStack(alignment: .leading, spacing: 0) {
            TaskMonthGrid(tasks: tasks.tasks, displayedMonth: $displayedMonth,
                          selectedDay: $selectedDay, compact: true)
                .padding(.horizontal, 17)
                .padding(.top, 10)

            HStack(alignment: .firstTextBaseline) {
                Text(dateLabel)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(TaskMenuStyle.primary)
                Spacer()
                Text(L10n.tr("\(matchingTasks.count) 项"))
                    .font(.system(size: 10))
                    .foregroundStyle(TaskMenuStyle.secondary)
            }
            .padding(.horizontal, 22)
            .padding(.top, 10)
            .padding(.bottom, 7)

            dayList(rows)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(reduceMotion ? nil : WorkspaceMotion.menuChange, value: selectedDay)
        }
        .background(TaskScrollerStyle())
        .onChange(of: selectedDay) { _ in
            collapsedTaskIDs.removeAll()
            presentation.selectedTaskID = nil
            presentation.dismissEditor()
        }
    }

    @ViewBuilder
    private func dayList(_ rows: [WorkspaceTaskListRow]) -> some View {
        if rows.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "calendar")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(TaskMenuStyle.muted)
                Text(L10n.tr("这一天还没有任务记录"))
                    .font(.system(size: 11))
                    .foregroundStyle(TaskMenuStyle.secondary)
                Text(L10n.tr("创建、计划或完成的任务\n会按实际日期显示在这里。"))
                    .font(.system(size: 10))
                    .foregroundStyle(TaskMenuStyle.muted)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.bottom, 16)
            .transition(WorkspaceMotion.menuTransition)
        } else {
            ScrollView {
                // Match the workbench: animated branches with native drag grips
                // must have concrete row heights throughout the transition.
                VStack(spacing: 3) {
                    ForEach(rows) { row in
                        taskRow(row)
                            .transition(reduceMotion ? .identity : WorkspaceMotion.branchTransition)
                    }
                }
                .animation(reduceMotion ? nil : WorkspaceMotion.branchChange, value: collapsedTaskIDs)
                .padding(.vertical, 2)
            }
            .scrollIndicators(.visible)
            .id(selectedDay)
            .transition(WorkspaceMotion.menuTransition)
            .animation(reduceMotion ? nil : WorkspaceMotion.menuChange, value: displayMode)
        }
    }

    private func taskRow(_ row: WorkspaceTaskListRow) -> some View {
        let task = row.task
        let indentation = CGFloat(min(row.depth, 5)) * 18
        let isCollapsed = collapsedTaskIDs.contains(task.id)
        return HStack(alignment: .top, spacing: 7) {
            TaskMenuCheckbox(isCompleted: task.isCompleted, size: 12) {
                _ = tasks.setCompleted(id: task.id, completed: !task.isCompleted)
            }
            .frame(width: 12, height: 32)
            .accessibilityLabel("\(task.isCompleted ? L10n.tr("恢复为待办") : L10n.tr("完成"))：\(task.title)")

            Button { presentation.toggleTask(task.id) } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(task.title)
                        .font(.system(size: 12))
                        .strikethrough(task.isCompleted)
                        .foregroundStyle(task.isCompleted ? TaskMenuStyle.secondary : TaskMenuStyle.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if displayMode.showsDescriptions {
                        if !task.details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text(task.details)
                                .font(.system(size: 10))
                                .foregroundStyle(TaskMenuStyle.secondary)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if !row.node.isContextOnly {
                            HStack(spacing: 5) {
                                if calendar.isDate(task.createdAt, inSameDayAs: selectedDay) {
                                    eventLabel(L10n.tr("创建"), color: .blue)
                                }
                                if let plannedDate = task.plannedDate,
                                   calendar.isDate(plannedDate, inSameDayAs: selectedDay) {
                                    eventLabel(L10n.tr("计划"), color: .orange)
                                }
                                if let completedAt = task.completedAt,
                                   calendar.isDate(completedAt, inSameDayAs: selectedDay) {
                                    eventLabel(L10n.tr("完成"), color: .green)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: 32)
                .padding(.vertical, displayMode.showsDescriptions ? 3 : 0)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.tr("编辑任务：\(task.title)"))
            .accessibilityValue(row.node.isContextOnly ? L10n.tr("父任务上下文") : "")
            .accessibilityIdentifier("menu-calendar-task-\(task.id)")
            .help(taskHelp(row))
            SubtaskDragHandle(task: task)
        }
        .padding(.leading, 23 + indentation)
        .padding(.trailing, 18)
        .overlay(alignment: .topLeading) {
            if !row.node.children.isEmpty {
                Button {
                    withAnimation(reduceMotion ? nil : WorkspaceMotion.branchChange) {
                        if isCollapsed { collapsedTaskIDs.remove(task.id) }
                        else { collapsedTaskIDs.insert(task.id) }
                    }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .medium))
                        .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                        .foregroundStyle(TaskMenuStyle.secondary)
                        .frame(width: 12, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.leading, 7 + indentation)
                .accessibilityLabel(isCollapsed ? L10n.tr("展开\(task.title)的子任务") : L10n.tr("收起\(task.title)的子任务"))
                .accessibilityValue(isCollapsed ? L10n.tr("已收起") : L10n.tr("已展开"))
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(presentation.selectedTaskID == task.id ? TaskMenuStyle.hover : Color.clear)
                .padding(.horizontal, 6)
        }
        .background(GeometryReader { proxy in
            Color.clear.preference(key: MenuTaskRowFrameKey.self,
                                   value: [task.id: proxy.frame(in: .named("taskMenu"))])
        })
        .taskContextMenu(task: task) { presentation.selectTask(task.id) }
        .subtaskReordering(task: task)
    }

    private func taskHelp(_ row: WorkspaceTaskListRow) -> String {
        let task = row.task
        if row.node.isContextOnly { return L10n.tr("\(task.title) · 父任务上下文") }
        var events: [String] = []
        if calendar.isDate(task.createdAt, inSameDayAs: selectedDay) { events.append(L10n.tr("创建")) }
        if let date = task.plannedDate, calendar.isDate(date, inSameDayAs: selectedDay) { events.append(L10n.tr("计划")) }
        if let date = task.completedAt, calendar.isDate(date, inSameDayAs: selectedDay) { events.append(L10n.tr("完成")) }
        return "\(task.title) · \(events.joined(separator: "、"))"
    }

    private func eventLabel(_ title: String, color: Color) -> some View {
        Text(title)
            .font(.system(size: 8, weight: .medium))
            .foregroundStyle(color.opacity(0.85))
    }

    private var dateLabel: String {
        let weekdays = [L10n.tr("周日"), L10n.tr("周一"), L10n.tr("周二"), L10n.tr("周三"), L10n.tr("周四"), L10n.tr("周五"), L10n.tr("周六")]
        let weekday = weekdays[calendar.component(.weekday, from: selectedDay) - 1]
        return L10n.tr("\(calendar.component(.month, from: selectedDay))月\(calendar.component(.day, from: selectedDay))日 · \(weekday)")
    }
}
