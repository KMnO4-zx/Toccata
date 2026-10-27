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
        .languageChangeTransition()
    }
}

@MainActor
private struct FloatingTaskEditorContent: View {
    @ObservedObject private var interfaceLanguage = LanguageSettings.shared
    @EnvironmentObject private var store: TaskStore
    @EnvironmentObject private var presentation: MenuTaskPresentation
    let task: TodoTask
    let focusRequest: MenuEditorFocusRequest?

    @State private var draft: FloatingEditorDraft
    @State private var baseline: FloatingEditorDraft
    @State private var childTitle = ""
    @State private var showsChildComposer = false
    @State private var isChoosingDate = false
    @State private var dateChoice: Date?
    @State private var dateReference = Date()
    @State private var confirmsDeletion = false
    @State private var saveFailed = false
    @State private var descriptionFocused = false
    @FocusState private var focusedField: Field?

    private enum Field: Hashable { case title, child }

    init(task: TodoTask, focusRequest: MenuEditorFocusRequest?) {
        self.task = task
        self.focusRequest = focusRequest
        _draft = State(initialValue: FloatingEditorDrafts.shared.restoredDraft(for: task) ?? FloatingEditorDraft(task: task))
        _baseline = State(initialValue: FloatingEditorDraft(task: task))
    }

    private var children: [TodoTask] { store.children(of: task.id) }
    private var hasChanges: Bool { draft != baseline }
    private var validTitle: Bool { !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        let _ = interfaceLanguage.language
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
        .onChange(of: focusedField) { field in
            if field != nil { descriptionFocused = false }
        }
        .onChange(of: draft) { value in
            if hasChanges { FloatingEditorDrafts.shared.remember(taskID: task.id, draft: value, baseline: baseline, store: store) }
            else { FloatingEditorDrafts.shared.discard(task.id) }
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
        .onReceive(NotificationCenter.default.publisher(for: .toccataSavePendingEdits)) { notification in
            saveDraft()
            if saveFailed { (notification.object as? PendingEditSaveRequest)?.failed = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in saveDraft() }
        .onDisappear { saveDraft() }
        .onExitCommand {
            if isChoosingDate { isChoosingDate = false }
            else { closeEditor() }
        }
        .alert(L10n.tr("删除这个任务？"), isPresented: $confirmsDeletion) {
            Button(L10n.tr("取消"), role: .cancel) {}
            Button(L10n.tr("删除任务"), role: .destructive) {
                if store.deleteTask(id: task.id) {
                    presentation.dismissEditor()
                    presentation.requestListFocus()
                }
            }
        } message: {
            Text(children.isEmpty ? L10n.tr("任务详情也会删除。此操作无法撤销。") : L10n.tr("任务、所有子任务及其详情都会删除。此操作无法撤销。"))
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            TaskMenuCheckbox(isCompleted: task.isCompleted, size: 14) {
                saveDraft()
                _ = store.setCompleted(id: task.id, completed: !task.isCompleted)
            }
            .accessibilityLabel(task.isCompleted ? L10n.tr("恢复任务") : L10n.tr("完成任务"))
            Rectangle().fill(TaskMenuStyle.muted).frame(width: 0.5, height: 16)
            Button {
                dateChoice = draft.plannedDate
                dateReference = Date()
                isChoosingDate.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "calendar").font(.system(size: 14))
                    Text(draft.plannedDate.map { $0.formatted(.dateTime.month().day().locale(L10n.locale)) } ?? L10n.tr("设置日期"))
                        .font(.system(size: 13))
                }
                .foregroundStyle(draft.plannedDate == nil ? TaskMenuStyle.secondary : TaskMenuStyle.accent)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.tr("设置计划日期"))
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
        .accessibilityLabel(L10n.tr("任务优先级"))
        .help(L10n.tr("设置任务优先级"))
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
        TaskPlannedDatePicker(
            initialDate: dateChoice,
            referenceDate: dateReference,
            onCancel: { isChoosingDate = false },
            onApply: { date in
                draft.plannedDate = date
                isChoosingDate = false
                saveDraft()
            },
            onClear: draft.plannedDate == nil ? nil : {
                draft.plannedDate = nil
                isChoosingDate = false
                saveDraft()
            }
        )
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
            .help(L10n.tr("返回父任务"))
        }
    }

    private var titleEditor: some View {
        HStack(alignment: .top, spacing: 8) {
            TextField(L10n.tr("任务名称"), text: $draft.title, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(TaskMenuStyle.primary)
                .lineLimit(1...4)
                .focused($focusedField, equals: .title)
                .accessibilityLabel(L10n.tr("任务名称"))
            if task.parentID == nil {
                Button(action: focusChild) {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 14))
                        .foregroundStyle(TaskMenuStyle.secondary)
                        .frame(width: 18, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L10n.tr("添加子任务"))
                .accessibilityLabel(L10n.tr("展开子任务输入"))
            }
        }
    }

    private func descriptionHeight(available: CGFloat) -> CGFloat {
        if children.isEmpty && !showsChildComposer {
            return max(70, available - (task.parentID == nil ? 76 : 98))
        }
        if draft.details.isEmpty { return descriptionFocused ? 58 : 26 }
        let lines = draft.details.split(separator: "\n", omittingEmptySubsequences: false).count
        return min(84, max(42, CGFloat(lines) * 18 + 12))
    }

    private func descriptionEditor(height: CGFloat) -> some View {
        MarkdownTextEditor(
            text: $draft.details,
            placeholder: L10n.tr("写下任务描述…"),
            isFocused: Binding(
                get: { descriptionFocused },
                set: { focused in
                    if focused { focusedField = nil }
                    descriptionFocused = focused
                }
            ),
            textColor: TaskMenuStyle.textColor
        )
        .frame(height: height)
        .accessibilityLabel(L10n.tr("任务描述"))
    }

    private var childList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(children) { child in
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    TaskMenuCheckbox(isCompleted: child.isCompleted, size: 12) {
                        _ = store.setCompleted(id: child.id, completed: !child.isCompleted)
                    }
                    .accessibilityLabel(child.isCompleted ? L10n.tr("恢复子任务：\(child.title)") : L10n.tr("完成子任务：\(child.title)"))
                    Button {
                        saveDraft()
                        presentation.selectTask(child.id)
                    } label: {
                        Text(child.title)
                            .font(.system(size: 12))
                            .foregroundStyle(child.isCompleted ? TaskMenuStyle.secondary : TaskMenuStyle.text)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.tr("编辑子任务：\(child.title)"))
                    if !child.details.isEmpty {
                        Image(systemName: "text.alignleft")
                            .font(.system(size: 10))
                            .foregroundStyle(TaskMenuStyle.muted)
                    }
                    SubtaskDragHandle(task: child)
                }
                .padding(.vertical, 7)
                .padding(.leading, 8)
                .taskContextMenu(task: child) {
                    saveDraft()
                    presentation.selectTask(child.id)
                }
                .subtaskReordering(task: child)
            }
            if showsChildComposer {
                HStack(spacing: 9) {
                    Image(systemName: "plus")
                        .font(.system(size: 12))
                        .foregroundStyle(TaskMenuStyle.secondary)
                    TextField(L10n.tr("添加子任务"), text: $childTitle)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(TaskMenuStyle.text)
                        .focused($focusedField, equals: .child)
                        .onSubmit(addChild)
                        .accessibilityLabel(L10n.tr("添加子任务"))
                }
                .padding(.leading, 8)
                .padding(.vertical, 8)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 13) {
            Label(L10n.tr("收集箱"), systemImage: "tray.and.arrow.forward")
                .font(.system(size: 13))
                .foregroundStyle(TaskMenuStyle.primary)
            Spacer(minLength: 4)
            if !validTitle {
                Text(L10n.tr("名称不能为空")).font(.system(size: 10)).foregroundStyle(.orange)
            } else if saveFailed {
                Button(L10n.tr("保存失败，重试"), action: saveDraft)
                    .font(.system(size: 10))
                    .buttonStyle(.plain)
                    .foregroundStyle(.orange)
            }
            Button(action: focusDescription) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 16))
                    .frame(width: 17, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.tr("编辑任务描述"))
            .help(L10n.tr("编辑任务描述"))
            moreMenu
        }
        .foregroundStyle(TaskMenuStyle.primary)
        .padding(.horizontal, 24)
        .frame(height: 44)
    }

    private var moreMenu: some View {
        Menu {
            Button(L10n.tr("编辑描述"), action: focusDescription)
            if task.parentID == nil {
                Button(L10n.tr("添加子任务"), action: focusChild)
            }
            Divider()
            Button(L10n.tr("关闭详情"), action: closeEditor)
            Button(L10n.tr("删除任务…"), role: .destructive) { confirmsDeletion = true }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 16))
                .frame(width: 18, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(L10n.tr("更多任务操作"))
    }

    private func applyFocusRequest(_ request: MenuEditorFocusRequest?) {
        focusedField = nil
        descriptionFocused = request?.field == .description
        guard let request else { return }
        if request.field == .description {
            focusDescription()
            return
        }
        guard task.parentID == nil else { return }
        showsChildComposer = true
        DispatchQueue.main.async { focusedField = .child }
    }

    private func scrollToRequest(_ request: MenuEditorFocusRequest?, using proxy: ScrollViewProxy) {
        guard let request else { return }
        let target = request.field == .description ? "floating-description" : "floating-children"
        DispatchQueue.main.async { proxy.scrollTo(target, anchor: .top) }
    }

    private func focusDescription() {
        focusedField = nil
        descriptionFocused = true
    }

    private func focusChild() {
        guard task.parentID == nil else { return }
        showsChildComposer = true
        focusedField = nil
        descriptionFocused = false
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
            FloatingEditorDrafts.shared.discard(task.id)
            saveFailed = false
            return
        }
        guard hasChanges else {
            FloatingEditorDrafts.shared.discard(task.id)
            saveFailed = false
            return
        }
        let editedTitle = draft.title != baseline.title && validTitle
        let title = editedTitle ? draft.title : current.title
        let details = draft.details != baseline.details ? draft.details : current.details
        let plannedDate = draft.plannedDate != baseline.plannedDate ? draft.plannedDate : current.plannedDate
        // Empty in-progress titles must not block a valid description or date save.
        if title == current.title && details == current.details && plannedDate == current.plannedDate {
            saveFailed = false
            return
        }
        let saved = store.updateTask(id: task.id, title: title, details: details, plannedDate: plannedDate)
        saveFailed = !saved
        if saved, let updated = store.task(id: task.id) {
            if editedTitle { draft.title = updated.title }
            baseline = FloatingEditorDraft(task: updated)
            if hasChanges { FloatingEditorDrafts.shared.remember(taskID: task.id, draft: draft, baseline: baseline, store: store) }
            else { FloatingEditorDrafts.shared.discard(task.id) }
        } else {
            FloatingEditorDrafts.shared.remember(taskID: task.id, draft: draft, baseline: baseline, store: store)
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
private final class FloatingEditorDrafts: PendingDraftSaving {
    static let shared = FloatingEditorDrafts()

    private final class Entry {
        var draft: FloatingEditorDraft
        var baseline: FloatingEditorDraft
        weak var store: TaskStore?

        init(draft: FloatingEditorDraft, baseline: FloatingEditorDraft, store: TaskStore) {
            self.draft = draft
            self.baseline = baseline
            self.store = store
        }
    }

    private var entries: [String: Entry] = [:]

    private init() { PendingEdits.shared.registerDraftBuffer(self) }

    func remember(taskID: String, draft: FloatingEditorDraft, baseline: FloatingEditorDraft, store: TaskStore) {
        entries[taskID] = Entry(draft: draft, baseline: baseline, store: store)
    }

    func restoredDraft(for task: TodoTask) -> FloatingEditorDraft? {
        guard let entry = entries[task.id] else { return nil }
        let current = FloatingEditorDraft(task: task)
        if entry.draft.title == entry.baseline.title { entry.draft.title = current.title }
        if entry.draft.details == entry.baseline.details { entry.draft.details = current.details }
        if entry.draft.plannedDate == entry.baseline.plannedDate { entry.draft.plannedDate = current.plannedDate }
        entry.baseline = current
        return entry.draft
    }

    func discard(_ taskID: String) { entries.removeValue(forKey: taskID) }

    func savePendingDrafts() -> Bool {
        var succeeded = true
        for (taskID, entry) in Array(entries) {
            guard let store = entry.store else {
                succeeded = false
                continue
            }
            guard let current = store.task(id: taskID) else {
                discard(taskID)
                continue
            }
            let validTitle = !entry.draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let title = validTitle && entry.draft.title != entry.baseline.title ? entry.draft.title : current.title
            let details = entry.draft.details != entry.baseline.details ? entry.draft.details : current.details
            let plannedDate = entry.draft.plannedDate != entry.baseline.plannedDate
                ? entry.draft.plannedDate : current.plannedDate
            let needsWrite = title != current.title || details != current.details || plannedDate != current.plannedDate
            if needsWrite && !store.updateTask(id: taskID, title: title, details: details, plannedDate: plannedDate) {
                succeeded = false
                continue
            }
            discard(taskID)
        }
        return succeeded
    }
}
