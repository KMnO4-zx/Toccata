import AppKit
import SwiftUI

/// A compact companion card; the task list keeps its own anchored window.
@MainActor
struct FloatingTaskEditor: View {
    @EnvironmentObject private var store: TaskStore
    @EnvironmentObject private var presentation: MenuTaskPresentation

    var body: some View {
        Group {
            if let id = presentation.selectedTaskID, let task = store.task(id: id) {
                FloatingTaskEditorContent(task: task, focusRequest: presentation.focusRequest)
                    .id(task.id)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TaskMenuStyle.background)
    }
}

@MainActor
private struct FloatingTaskEditorContent: View {
    @EnvironmentObject private var store: TaskStore
    @EnvironmentObject private var presentation: MenuTaskPresentation
    let task: TodoTask
    let focusRequest: MenuEditorFocusRequest?

    @State private var draft: FloatingEditorDraft
    @State private var baseline: FloatingEditorDraft
    @State private var childTitle = ""
    @State private var showsChildComposer = false
    @State private var isChoosingDate = false
    @State private var dateChoice = Date()
    @State private var showsProgress = false
    @State private var progressText = ""
    @State private var confirmsDeletion = false
    @State private var saveFailed = false
    @FocusState private var focusedField: Field?

    private enum Field: Hashable { case title, description, child, progress }

    init(task: TodoTask, focusRequest: MenuEditorFocusRequest?) {
        self.task = task
        self.focusRequest = focusRequest
        _draft = State(initialValue: FloatingEditorDrafts.shared.values[task.id] ?? FloatingEditorDraft(task: task))
        _baseline = State(initialValue: FloatingEditorDraft(task: task))
        _progressText = State(initialValue: FloatingEditorDrafts.shared.progress[task.id] ?? "")
    }

    private var children: [TodoTask] { store.children(of: task.id) }
    private var hasChanges: Bool { draft != baseline }
    private var validTitle: Bool { !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Rectangle().fill(TaskMenuStyle.input).frame(height: 0.5)
            GeometryReader { geometry in
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            parentLink
                            titleEditor
                            descriptionEditor(height: descriptionHeight(available: geometry.size.height))
                                .id("floating-description")
                            if !children.isEmpty || showsChildComposer {
                                childList.id("floating-children")
                            }
                        }
                        .padding(.horizontal, 24)
                        .padding(.top, 20)
                        .padding(.bottom, 8)
                        .frame(minHeight: geometry.size.height, alignment: .top)
                    }
                    .onAppear { scrollToRequest(focusRequest, using: proxy) }
                    .onChange(of: focusRequest) { request in scrollToRequest(request, using: proxy) }
                    .onChange(of: showsChildComposer) { isShown in
                        if isShown {
                            DispatchQueue.main.async { proxy.scrollTo("floating-children", anchor: .bottom) }
                        }
                    }
                }
            }
            footer
        }
        .background(TaskMenuStyle.background)
        .onAppear { applyFocusRequest(focusRequest) }
        .onChange(of: focusRequest) { request in applyFocusRequest(request) }
        .onChange(of: draft) { value in
            if hasChanges { FloatingEditorDrafts.shared.values[task.id] = value }
            else { FloatingEditorDrafts.shared.values.removeValue(forKey: task.id) }
        }
        .onChange(of: progressText) { value in
            FloatingEditorDrafts.shared.progress[task.id] = value
        }
        .onChange(of: task) { latest in synchronizeUneditedFields(from: latest) }
        .task(id: draft) {
            do {
                try await Task.sleep(nanoseconds: 350_000_000)
                guard !Task.isCancelled else { return }
                saveDraft()
            } catch { /* The following edit owns the next save. */ }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in saveDraft() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in saveDraft() }
        .onDisappear { saveDraft() }
        .onExitCommand(perform: closeEditor)
        .alert("删除这个任务？", isPresented: $confirmsDeletion) {
            Button("取消", role: .cancel) {}
            Button("删除任务", role: .destructive) {
                if store.deleteTask(id: task.id) {
                    FloatingEditorDrafts.shared.progress.removeValue(forKey: task.id)
                    presentation.dismissEditor()
                    presentation.requestListFocus()
                }
            }
        } message: {
            Text(children.isEmpty ? "任务详情和过程记录也会删除。此操作无法撤销。" : "任务、所有子任务及其过程记录都会删除。此操作无法撤销。")
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            TaskMenuCheckbox(isCompleted: task.isCompleted, size: 14) {
                saveDraft()
                _ = store.setCompleted(id: task.id, completed: !task.isCompleted)
            }
            .accessibilityLabel(task.isCompleted ? "恢复任务" : "完成任务")
            Rectangle().fill(TaskMenuStyle.muted).frame(width: 0.5, height: 16)
            Button {
                dateChoice = draft.plannedDate ?? Date()
                isChoosingDate.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "calendar").font(.system(size: 14))
                    Text(draft.plannedDate.map { $0.formatted(.dateTime.month().day()) } ?? "设置日期")
                        .font(.system(size: 13))
                }
                .foregroundStyle(draft.plannedDate == nil ? TaskMenuStyle.secondary : TaskMenuStyle.accent)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("设置计划日期")
            .popover(isPresented: $isChoosingDate, arrowEdge: .bottom) {
                dateChooser.background(MenuCompanionWindow(presentation: presentation))
            }
            Spacer(minLength: 0)
            priorityMenu
        }
        .padding(.horizontal, 24)
        .frame(height: 48)
    }

    private var priorityMenu: some View {
        Menu {
            ForEach([TaskPriority.none, .low, .medium, .high], id: \.self) { priority in
                Button {
                    _ = store.setPriority(id: task.id, priority: priority)
                } label: {
                    if task.priority == priority {
                        Label(priority.title, systemImage: "checkmark")
                    } else {
                        Text(priority.title)
                    }
                }
            }
        } label: {
            Image(systemName: task.priority == .none ? "flag" : "flag.fill")
                .font(.system(size: 14))
                .foregroundStyle(priorityColor)
                .frame(width: 18, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("任务优先级")
        .help("设置任务优先级")
    }

    private var priorityColor: Color {
        switch task.priority {
        case .none: return TaskMenuStyle.secondary
        case .low: return TaskMenuStyle.accent
        case .medium: return .orange
        case .high: return .red
        }
    }

    private var dateChooser: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("计划日期").font(.system(size: 12, weight: .medium))
            DatePicker("计划日期", selection: $dateChoice, displayedComponents: .date)
                .labelsHidden()
                .datePickerStyle(.field)
                .accessibilityLabel("计划日期")
            HStack {
                if draft.plannedDate != nil {
                    Button("清除日期") {
                        draft.plannedDate = nil
                        isChoosingDate = false
                        saveDraft()
                    }
                    .buttonStyle(.borderless)
                }
                Spacer()
                Button("设置日期") {
                    draft.plannedDate = Calendar.current.startOfDay(for: dateChoice)
                    isChoosingDate = false
                    saveDraft()
                }
            }
        }
        .font(.system(size: 12))
        .padding(16)
        .frame(width: 250)
    }

    @ViewBuilder
    private var parentLink: some View {
        if let parentID = task.parentID, let parent = store.task(id: parentID) {
            Button {
                saveDraft()
                presentation.selectTask(parentID)
            } label: {
                Label(parent.title, systemImage: "chevron.left")
                    .font(.system(size: 11))
                    .foregroundStyle(TaskMenuStyle.secondary)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .help("返回父任务")
        }
    }

    private var titleEditor: some View {
        HStack(alignment: .top, spacing: 8) {
            TextField("任务名称", text: $draft.title, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(TaskMenuStyle.primary)
                .lineLimit(1...4)
                .focused($focusedField, equals: .title)
                .accessibilityLabel("任务名称")
            if task.parentID == nil {
                Button(action: focusChild) {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 14))
                        .foregroundStyle(TaskMenuStyle.secondary)
                        .frame(width: 18, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("添加子任务")
                .accessibilityLabel("展开子任务输入")
            }
        }
    }

    private func descriptionHeight(available: CGFloat) -> CGFloat {
        if children.isEmpty && !showsChildComposer {
            return max(70, available - (task.parentID == nil ? 76 : 98))
        }
        if draft.details.isEmpty { return focusedField == .description ? 58 : 26 }
        let lines = draft.details.split(separator: "\n", omittingEmptySubsequences: false).count
        return min(84, max(42, CGFloat(lines) * 18 + 12))
    }

    private func descriptionEditor(height: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $draft.details)
                .font(.system(size: 12))
                .foregroundStyle(TaskMenuStyle.text)
                .scrollContentBackground(.hidden)
                .focused($focusedField, equals: .description)
                .accessibilityLabel("任务描述")
                .frame(height: height)
            if draft.details.isEmpty && focusedField == .description {
                Text("写下任务描述…")
                    .font(.system(size: 12))
                    .foregroundStyle(TaskMenuStyle.muted)
                    .padding(.leading, 5)
                    .padding(.top, 8)
                    .allowsHitTesting(false)
            }
        }
    }

    private var childList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(children) { child in
                HStack(alignment: .top, spacing: 9) {
                    TaskMenuCheckbox(isCompleted: child.isCompleted, size: 12) {
                        _ = store.setCompleted(id: child.id, completed: !child.isCompleted)
                    }
                    .padding(.top, 1)
                    .accessibilityLabel(child.isCompleted ? "恢复子任务：\(child.title)" : "完成子任务：\(child.title)")
                    Button {
                        saveDraft()
                        presentation.selectTask(child.id)
                    } label: {
                        Text(child.title)
                            .font(.system(size: 12))
                            .foregroundStyle(child.isCompleted ? TaskMenuStyle.secondary : TaskMenuStyle.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("编辑子任务：\(child.title)")
                    if !child.details.isEmpty {
                        Image(systemName: "text.alignleft")
                            .font(.system(size: 10))
                            .foregroundStyle(TaskMenuStyle.muted)
                    }
                }
                .padding(.vertical, 7)
                .padding(.leading, 8)
                .taskContextMenu(task: child) {
                    saveDraft()
                    presentation.selectTask(child.id)
                }
            }
            if showsChildComposer {
                HStack(spacing: 9) {
                    Image(systemName: "plus")
                        .font(.system(size: 12))
                        .foregroundStyle(TaskMenuStyle.secondary)
                    TextField("添加子任务", text: $childTitle)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(TaskMenuStyle.text)
                        .focused($focusedField, equals: .child)
                        .onSubmit(addChild)
                        .accessibilityLabel("添加子任务")
                }
                .padding(.leading, 8)
                .padding(.vertical, 8)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 13) {
            Label("收集箱", systemImage: "tray.and.arrow.forward")
                .font(.system(size: 13))
                .foregroundStyle(TaskMenuStyle.primary)
            Spacer(minLength: 4)
            if !validTitle {
                Text("名称不能为空").font(.system(size: 10)).foregroundStyle(.orange)
            } else if saveFailed {
                Button("保存失败，重试", action: saveDraft)
                    .font(.system(size: 10))
                    .buttonStyle(.plain)
                    .foregroundStyle(.orange)
            }
            Button(action: focusDescription) {
                Image(systemName: "underline")
                    .font(.system(size: 16))
                    .frame(width: 17, height: 22)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("编辑任务描述")
            .help("编辑任务描述")
            Button { showsProgress.toggle() } label: {
                Image(systemName: "text.bubble")
                    .font(.system(size: 16))
                    .frame(width: 18, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("过程与感受")
            .help("查看和添加过程记录")
            .popover(isPresented: $showsProgress, arrowEdge: .bottom) {
                progressPopover.background(MenuCompanionWindow(presentation: presentation))
            }
            moreMenu
        }
        .foregroundStyle(TaskMenuStyle.primary)
        .padding(.horizontal, 24)
        .frame(height: 44)
    }

    private var moreMenu: some View {
        Menu {
            Button("编辑描述", action: focusDescription)
            if task.parentID == nil {
                Button("添加子任务", action: focusChild)
            }
            Divider()
            Button("关闭详情", action: closeEditor)
            Button("删除任务…", role: .destructive) { confirmsDeletion = true }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 16))
                .frame(width: 18, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("更多任务操作")
    }

    private var progressPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("过程与感受").font(.system(size: 13, weight: .semibold))
            if !store.progress(for: task.id).isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 13) {
                        ForEach(store.progress(for: task.id)) { entry in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(entry.text).font(.system(size: 12)).textSelection(.enabled)
                                Text(entry.createdAt.formatted(.dateTime.month().day().hour().minute()))
                                    .font(.system(size: 10))
                                    .foregroundStyle(TaskMenuStyle.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxHeight: 150)
            }
            TextEditor(text: $progressText)
                .font(.system(size: 12))
                .focused($focusedField, equals: .progress)
                .accessibilityLabel("新的过程记录")
                .frame(height: 70)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(TaskMenuStyle.muted, lineWidth: 0.5))
            HStack {
                Text("记录进展或新的想法")
                    .font(.system(size: 10))
                    .foregroundStyle(TaskMenuStyle.secondary)
                Spacer()
                Button("添加记录") {
                    guard store.addProgress(taskID: task.id, text: progressText) else { return }
                    progressText = ""
                    FloatingEditorDrafts.shared.progress.removeValue(forKey: task.id)
                }
                .disabled(progressText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    private func applyFocusRequest(_ request: MenuEditorFocusRequest?) {
        focusedField = nil
        guard let request else { return }
        if request.field == .child && task.parentID != nil { return }
        if request.field == .child { showsChildComposer = true }
        let destination: Field = request.field == .description ? .description : .child
        DispatchQueue.main.async { focusedField = destination }
    }

    private func scrollToRequest(_ request: MenuEditorFocusRequest?, using proxy: ScrollViewProxy) {
        guard let request else { return }
        let target = request.field == .description ? "floating-description" : "floating-children"
        DispatchQueue.main.async { proxy.scrollTo(target, anchor: .top) }
    }

    private func focusDescription() {
        focusedField = nil
        DispatchQueue.main.async { focusedField = .description }
    }

    private func focusChild() {
        guard task.parentID == nil else { return }
        showsChildComposer = true
        focusedField = nil
        DispatchQueue.main.async { focusedField = .child }
    }

    private func closeEditor() {
        saveDraft()
        presentation.dismissEditor()
        presentation.requestListFocus()
    }

    private func addChild() {
        let title = childTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard task.parentID == nil, !title.isEmpty else { return }
        saveDraft()
        guard store.addTask(title: title, parentID: task.id) != nil else { return }
        presentation.expandedTaskIDs.insert(task.id)
        childTitle = ""
        focusedField = .child
    }

    private func synchronizeUneditedFields(from task: TodoTask) {
        let latest = FloatingEditorDraft(task: task)
        if draft.title == baseline.title { draft.title = latest.title }
        if draft.details == baseline.details { draft.details = latest.details }
        if draft.plannedDate == baseline.plannedDate { draft.plannedDate = latest.plannedDate }
        baseline = latest
    }

    private func saveDraft() {
        guard let current = store.task(id: task.id) else {
            FloatingEditorDrafts.shared.values.removeValue(forKey: task.id)
            return
        }
        guard hasChanges else { return }
        let editedTitle = draft.title != baseline.title && validTitle
        let title = editedTitle ? draft.title : current.title
        let details = draft.details != baseline.details ? draft.details : current.details
        let plannedDate = draft.plannedDate != baseline.plannedDate ? draft.plannedDate : current.plannedDate
        // Empty in-progress titles must not block a valid description or date save.
        if title == current.title && details == current.details && plannedDate == current.plannedDate { return }
        let saved = store.updateTask(id: task.id, title: title, details: details, plannedDate: plannedDate)
        saveFailed = !saved
        if saved, let updated = store.task(id: task.id) {
            if editedTitle { draft.title = updated.title }
            baseline = FloatingEditorDraft(task: updated)
            if hasChanges { FloatingEditorDrafts.shared.values[task.id] = draft }
            else { FloatingEditorDrafts.shared.values.removeValue(forKey: task.id) }
        } else {
            FloatingEditorDrafts.shared.values[task.id] = draft
        }
    }
}

private struct FloatingEditorDraft: Equatable {
    var title: String
    var details: String
    var plannedDate: Date?

    init(task: TodoTask) {
        title = task.title
        details = task.details
        plannedDate = task.plannedDate
    }
}

@MainActor
private final class FloatingEditorDrafts {
    static let shared = FloatingEditorDrafts()
    var values: [String: FloatingEditorDraft] = [:]
    var progress: [String: String] = [:]
}
