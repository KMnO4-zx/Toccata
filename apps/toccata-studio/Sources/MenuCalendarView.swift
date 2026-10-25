import SwiftUI

@MainActor
struct MenuCalendarView: View {
    @EnvironmentObject private var tasks: TaskStore
    @EnvironmentObject private var presentation: MenuTaskPresentation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var displayedMonth = Calendar.current.startOfDay(for: Date())
    @State private var selectedDay = Calendar.current.startOfDay(for: Date())
    private let calendar = Calendar.current

    private var dayTasks: [TodoTask] {
        TaskCalendarModel.tasks(on: selectedDay, from: tasks.tasks, calendar: calendar)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TaskMonthGrid(tasks: tasks.tasks, displayedMonth: $displayedMonth,
                          selectedDay: $selectedDay, compact: true)
                .padding(.horizontal, 17)
                .padding(.top, 10)

            HStack(alignment: .firstTextBaseline) {
                Text(dateLabel)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(TaskMenuStyle.primary)
                Spacer()
                Text("\(dayTasks.count) 项")
                    .font(.system(size: 10))
                    .foregroundStyle(TaskMenuStyle.secondary)
            }
            .padding(.horizontal, 22)
            .padding(.top, 10)
            .padding(.bottom, 7)

            dayList
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(reduceMotion ? nil : WorkspaceMotion.menuChange, value: selectedDay)
        }
        .background(TaskScrollerStyle())
        .onChange(of: selectedDay) { _ in
            presentation.selectedTaskID = nil
            presentation.dismissEditor()
        }
    }

    @ViewBuilder
    private var dayList: some View {
        if dayTasks.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "calendar")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(TaskMenuStyle.muted)
                Text("这一天还没有任务记录")
                    .font(.system(size: 11))
                    .foregroundStyle(TaskMenuStyle.secondary)
                Text("创建、计划或完成的任务\n会按实际日期显示在这里。")
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
                LazyVStack(spacing: 3) {
                    ForEach(dayTasks) { task in
                        taskRow(task)
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.visible)
            .id(selectedDay)
            .transition(WorkspaceMotion.menuTransition)
        }
    }

    private func taskRow(_ task: TodoTask) -> some View {
        HStack(spacing: 7) {
            TaskMenuCheckbox(isCompleted: task.isCompleted, size: 12) {
                _ = tasks.setCompleted(id: task.id, completed: !task.isCompleted)
            }
            .frame(width: 12, height: 32)
            .accessibilityLabel("\(task.isCompleted ? "恢复为待办" : "完成")：\(task.title)")

            Button { presentation.toggleTask(task.id) } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(task.title)
                        .font(.system(size: 12))
                        .foregroundStyle(task.isCompleted ? TaskMenuStyle.secondary : TaskMenuStyle.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 5) {
                        if calendar.isDate(task.createdAt, inSameDayAs: selectedDay) {
                            eventLabel("创建", color: .blue)
                        }
                        if let plannedDate = task.plannedDate,
                           calendar.isDate(plannedDate, inSameDayAs: selectedDay) {
                            eventLabel("计划", color: .orange)
                        }
                        if let completedAt = task.completedAt,
                           calendar.isDate(completedAt, inSameDayAs: selectedDay) {
                            eventLabel("完成", color: .green)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: 34)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("编辑任务：\(task.title)")
            .accessibilityIdentifier("menu-calendar-task-\(task.id)")
        }
        .padding(.horizontal, 18)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(presentation.selectedTaskID == task.id ? TaskMenuStyle.hover : Color.clear)
                .padding(.horizontal, 6)
        }
    }

    private func eventLabel(_ title: String, color: Color) -> some View {
        Text(title)
            .font(.system(size: 8, weight: .medium))
            .foregroundStyle(color.opacity(0.85))
    }

    private var dateLabel: String {
        let weekdays = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
        let weekday = weekdays[calendar.component(.weekday, from: selectedDay) - 1]
        return "\(calendar.component(.month, from: selectedDay))月\(calendar.component(.day, from: selectedDay))日 · \(weekday)"
    }
}
