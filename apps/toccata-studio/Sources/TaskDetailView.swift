import SwiftUI
import AppKit

struct TaskDetailFocusRequest: Equatable {
    enum Field { case details, child }
    let field: Field
    let token = UUID()
}

@MainActor
struct TaskDetailView: View {
    @EnvironmentObject private var store: TaskStore
    let task: TodoTask
    let onSelect: (String) -> Void
    let focusRequest: TaskDetailFocusRequest?

    @State private var draft: TaskDetailDraft
    @State private var baseline: TaskDetailDraft
    @State private var childTitle = ""
    @State private var confirmsDeletion = false
    @State private var saveFailed = false
    @State private var detailsFocused = false
    @FocusState private var focusedField: Field?

    private enum Field: Hashable { case title, child }

    init(task: TodoTask, onSelect: @escaping (String) -> Void,
         focusRequest: TaskDetailFocusRequest? = nil) {
        self.task = task
        self.onSelect = onSelect
        self.focusRequest = focusRequest
        _draft = State(initialValue: TaskDraftBuffer.shared.edits[task.id] ?? TaskDetailDraft(task: task))
        _baseline = State(initialValue: TaskDetailDraft(task: task))
    }

    private var children: [TodoTask] { store.children(of: task.id) }
    private var validTitle: Bool { !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var hasChanges: Bool {
        draft.title != baseline.title || draft.details != baseline.details || draft.optionalDate != baseline.optionalDate
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 25) {
                        taskHeading
                        planDateSection
                        detailsSection.id("task-details-editor")
                        subtasksSection.id("task-child-editor")
                        metadata
                    }
                    .padding(25)
                }
                .onAppear { scrollToRequestedEditor(focusRequest, using: proxy) }
                .onChange(of: focusRequest) { request in scrollToRequestedEditor(request, using: proxy) }
            }
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.45))
        .background(TaskScrollerStyle())
        .onAppear { applyFocusRequest(focusRequest) }
        .onChange(of: focusRequest) { request in applyFocusRequest(request) }
        .onChange(of: focusedField) { field in
            if field != nil { detailsFocused = false }
        }
        .task(id: draft) {
            do {
                try await Task.sleep(nanoseconds: 450_000_000)
                guard !Task.isCancelled else { return }
                saveDraft()
            } catch { /* The next edit replaces this pending save. */ }
        }
        .onChange(of: draft) { value in
            if hasChanges {
                TaskDraftBuffer.shared.edits[task.id] = value
            } else {
                TaskDraftBuffer.shared.edits.removeValue(forKey: task.id)
            }
        }
        .onChange(of: task) { updatedTask in
            synchronizeUneditedFields(from: updatedTask)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            // Application shutdown may happen before SwiftUI removes this view.
            saveDraft(preservingValidTitle: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in
            saveDraft(preservingValidTitle: true)
        }
        .onDisappear {
            // Selection changes must not lose a final keystroke before the debounce fires.
            if store.task(id: task.id) != nil {
                if hasChanges {
                    TaskDraftBuffer.shared.edits[task.id] = draft
                } else {
                    TaskDraftBuffer.shared.edits.removeValue(forKey: task.id)
                }
            } else {
                TaskDraftBuffer.shared.discard(task.id)
            }
            saveDraft(preservingValidTitle: true)
        }
        .alert("删除这个任务？", isPresented: $confirmsDeletion) {
            Button("取消", role: .cancel) {}
            Button("删除任务", role: .destructive) { _ = store.deleteTask(id: task.id) }
        } message: {
            Text(children.isEmpty ? "任务详情也会删除。此操作无法撤销。" : "任务、所有子任务及其详情都会删除。此操作无法撤销。")
        }
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            if let parentID = task.parentID, let parent = store.task(id: parentID) {
                Button {
                    saveDraft(preservingValidTitle: true)
                    onSelect(parentID)
                } label: {
                    Label(parent.title, systemImage: "chevron.left")
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("返回父任务")
            } else {
                Label("任务详情", systemImage: "text.alignleft")
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 5)
            Text(hasChanges ? (validTitle ? (saveFailed ? "保存失败，请重试" : "正在保存…") : "标题不能为空") : "已保存")
                .font(.system(size: 10))
                .foregroundStyle(validTitle && !saveFailed ? Color.secondary : Color.orange)
            Button {
                saveDraft()
            } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .help("保存修改（⌘S）；修改也会自动保存")
            .keyboardShortcut("s", modifiers: .command)
            .disabled(!hasChanges || !validTitle)
            Button(role: .destructive) { confirmsDeletion = true } label: {
                Image(systemName: "trash")
            }
            .help("删除任务")
        }
        .font(.system(size: 11))
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var taskHeading: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(spacing: 7) {
                Button {
                    saveDraft(preservingValidTitle: true)
                    _ = store.setCompleted(id: task.id, completed: !task.isCompleted)
                } label: {
                    Label(task.isCompleted ? "已完成 · 点击恢复待办" : "标记完成", systemImage: task.isCompleted ? "checkmark.circle.fill" : "circle")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(task.isCompleted ? Color.accentColor : Color.secondary)
                if let completedAt = task.completedAt {
                    Spacer(minLength: 0)
                    Text(completedAt.formatted(.dateTime.month().day().hour().minute()))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 11))

            TextField("任务名称", text: $draft.title, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 21, weight: .semibold))
                .lineLimit(1...5)
                .focused($focusedField, equals: .title)
                .accessibilityLabel("任务名称")
        }
    }

    private var planDateSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("计划日期", systemImage: "calendar")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Toggle("设置日期", isOn: $draft.hasDate)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
            }
            if draft.hasDate {
                DatePicker("计划在", selection: $draft.date, displayedComponents: .date)
                    .datePickerStyle(.field)
                    .font(.system(size: 12))
                    .accessibilityLabel("计划日期")
            } else {
                Text("暂不安排时间，继续留在收集箱。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(13)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.75), in: RoundedRectangle(cornerRadius: 10))
    }

    private var detailsSection: some View {
        VStack(alignment: .leading, spacing: 11) {
            sectionHeading("详情", symbol: "text.alignleft")
            MarkdownTextEditor(
                text: $draft.details,
                placeholder: "补充背景、链接，或写下你打算怎么做…",
                isFocused: Binding(
                    get: { detailsFocused },
                    set: { focused in
                        if focused { focusedField = nil }
                        detailsFocused = focused
                    }
                )
            )
            .frame(minHeight: 120)
            .accessibilityLabel("任务详情")
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.65), in: RoundedRectangle(cornerRadius: 9))
        }
    }

    private var subtasksSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionHeading("子任务", symbol: "checklist")
                Spacer()
                if !children.isEmpty {
                    Text("\(children.filter(\.isCompleted).count) / \(children.count)")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
            if !children.isEmpty {
                VStack(spacing: 0) {
                    ForEach(children) { child in
                        HStack(alignment: .top, spacing: 9) {
                            Button {
                                _ = store.setCompleted(id: child.id, completed: !child.isCompleted)
                            } label: {
                                Image(systemName: child.isCompleted ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 16))
                                    .foregroundStyle(child.isCompleted ? Color.accentColor : Color.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(child.isCompleted ? "恢复子任务\(child.title)" : "完成子任务\(child.title)")
                            Button {
                                saveDraft(preservingValidTitle: true)
                                onSelect(child.id)
                            } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(child.title)
                                        .strikethrough(child.isCompleted)
                                        .foregroundStyle(child.isCompleted ? .secondary : .primary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    if !child.details.isEmpty {
                                        Text(child.details)
                                            .foregroundStyle(.secondary)
                                            .font(.system(size: 10))
                                            .lineLimit(1)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("编辑子任务详情")
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }
                        .font(.system(size: 12))
                        .padding(.vertical, 10)
                        .padding(.horizontal, 11)
                        if child.id != children.last?.id { Divider().padding(.leading, 35) }
                    }
                }
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.65), in: RoundedRectangle(cornerRadius: 9))
            }

            // Only top-level tasks can create subtasks.
            if task.parentID == nil {
                HStack(spacing: 8) {
                    Image(systemName: "plus").foregroundStyle(.secondary)
                    TextField("添加子任务，按回车确认", text: $childTitle)
                        .textFieldStyle(.plain)
                        .focused($focusedField, equals: .child)
                        .onSubmit(addChild)
                    Button(action: addChild) { Image(systemName: "return") }
                        .buttonStyle(.plain)
                        .disabled(childTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .help("添加子任务")
                }
                .font(.system(size: 12))
                .padding(11)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.65), in: RoundedRectangle(cornerRadius: 9))
            } else if children.isEmpty {
                Text("这是一个子任务，可在这里独立编辑详情。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider().padding(.bottom, 7)
            Text("创建于 \(task.createdAt.formatted(.dateTime.year().month().day().hour().minute()))")
            if let completedAt = task.completedAt {
                Text("完成于 \(completedAt.formatted(.dateTime.year().month().day().hour().minute()))")
            }
        }
        .font(.system(size: 10))
        .foregroundStyle(.tertiary)
    }

    private func sectionHeading(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 12, weight: .semibold))
    }

    private func saveDraft(preservingValidTitle: Bool = false) {
        guard let existing = store.task(id: task.id), hasChanges else { return }
        guard validTitle || preservingValidTitle else { return }
        let saved = store.updateTask(
            id: task.id,
            title: validTitle && draft.title != baseline.title ? draft.title : existing.title,
            details: draft.details != baseline.details ? draft.details : existing.details,
            plannedDate: draft.optionalDate != baseline.optionalDate ? draft.optionalDate : existing.plannedDate
        )
        saveFailed = !saved
        if saved {
            if let current = store.task(id: task.id) {
                let savedDraft = TaskDetailDraft(task: current)
                if validTitle { draft.title = savedDraft.title }
                draft.details = savedDraft.details
                draft.hasDate = savedDraft.hasDate
                draft.date = savedDraft.date
                baseline = savedDraft
            }
            if hasChanges {
                // An empty title remains an unsaved draft; valid content is still safe.
                TaskDraftBuffer.shared.edits[task.id] = draft
            } else {
                TaskDraftBuffer.shared.edits.removeValue(forKey: task.id)
            }
        } else {
            // Keep failed writes available after the user moves to a different task or sidebar page.
            TaskDraftBuffer.shared.edits[task.id] = draft
        }
    }

    private func synchronizeUneditedFields(from updatedTask: TodoTask) {
        let remote = TaskDetailDraft(task: updatedTask)
        // Another window may edit this task. Only preserve fields edited here;
        // completion changes must never reset an in-flight draft.
        if draft.title == baseline.title { draft.title = remote.title }
        if draft.details == baseline.details { draft.details = remote.details }
        if draft.optionalDate == baseline.optionalDate {
            draft.hasDate = remote.hasDate
            draft.date = remote.date
        }
        baseline = remote
    }

    private func scrollToRequestedEditor(_ request: TaskDetailFocusRequest?, using proxy: ScrollViewProxy) {
        guard let focusRequest = request else { return }
        let target = focusRequest.field == .details ? "task-details-editor" : "task-child-editor"
        proxy.scrollTo(target, anchor: .top)
    }

    private func applyFocusRequest(_ request: TaskDetailFocusRequest?) {
        // The task list takes AppKit first-responder focus directly. SwiftUI may
        // still remember the previous editor as focused, so explicitly clear it
        // even when a nil request returns control to the selected task list.
        focusedField = nil
        detailsFocused = request?.field == .details
        guard let focusRequest = request else { return }
        if focusRequest.field == .details { return }
        if focusRequest.field == .child && task.parentID != nil { return }
        DispatchQueue.main.async {
            focusedField = .child
        }
    }

    private func addChild() {
        guard task.parentID == nil else { return }
        saveDraft(preservingValidTitle: true)
        guard store.addTask(title: childTitle, parentID: task.id) != nil else { return }
        childTitle = ""
        focusedField = .child
    }

}

private struct TaskDetailDraft: Equatable {
    var title: String
    var details: String
    var hasDate: Bool
    var date: Date

    var optionalDate: Date? { hasDate ? date : nil }

    init(task: TodoTask) {
        title = task.title
        details = task.details
        hasDate = task.plannedDate != nil
        date = task.plannedDate ?? Calendar.current.startOfDay(for: Date())
    }
}

/// Unsaved edits stay in memory while navigating, including when a database write fails.
/// Successfully saved content continues to live exclusively in TaskStore.
@MainActor
private final class TaskDraftBuffer {
    static let shared = TaskDraftBuffer()
    var edits: [String: TaskDetailDraft] = [:]

    func discard(_ taskID: String) {
        edits.removeValue(forKey: taskID)
    }
}
