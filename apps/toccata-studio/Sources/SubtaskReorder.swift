import AppKit
import SwiftUI

/// Local row dragging avoids the system's file/icon drag preview. Only the grip
/// captures mouse events; the title and completion button keep their own actions.
struct SubtaskDragHandle: View {
    @ObservedObject private var interfaceLanguage = LanguageSettings.shared
    @EnvironmentObject private var store: TaskStore
    let task: TodoTask

    var body: some View {
        let _ = interfaceLanguage.language
        SubtaskGrip(taskID: task.id, store: store)
            .frame(width: 28, height: 28)
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            .help(task.parentID == nil
                  ? L10n.tr("按住拖动：主任务与子任务一起排序")
                  : L10n.tr("按住拖动：仅调整同一主任务下、同一完成状态的子任务顺序"))
    }
}

extension View {
    @ViewBuilder
    func subtaskReordering(task: TodoTask, enabled: Bool = true) -> some View {
        if enabled {
            modifier(SubtaskReorderModifier(task: task))
        } else {
            self
        }
    }
}

@MainActor
private struct SubtaskReorderModifier: ViewModifier {
    @EnvironmentObject private var store: TaskStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var session = SubtaskReorderSession.shared
    @State private var regionID = UUID()
    let task: TodoTask

    func body(content: Content) -> some View {
        let isDragging = session.drag?.movingRegionIDs.contains(regionID) == true
        let insertion = session.drag?.insertionRegionID == regionID ? session.drag?.placement : nil
        content
            .background {
                if isDragging {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: .windowBackgroundColor))
                        .shadow(color: .black.opacity(0.10), radius: 5, y: 2)
                        .padding(.horizontal, 6)
                }
            }
            .background(SubtaskRegion(id: regionID, taskID: task.id, store: store,
                                      reduceMotion: reduceMotion))
            .overlay(alignment: insertion == .after ? .bottom : .top) {
                if insertion != nil {
                    Capsule().fill(Color.accentColor).frame(height: 2)
                        .padding(.horizontal, 8)
                        .allowsHitTesting(false)
                }
            }
            .offset(y: isDragging ? session.drag?.offset ?? 0 : 0)
            .zIndex(isDragging ? 1 : 0)
            .accessibilityAction(named: L10n.tr("上移任务")) { moveByKeyboard(-1) }
            .accessibilityAction(named: L10n.tr("下移任务")) { moveByKeyboard(1) }
    }

    private func moveByKeyboard(_ offset: Int) {
        let sortOrder = task.parentID == nil ? TaskDragSortPreference.current : .manual
        let siblings = store.children(of: task.parentID)
            .filter { $0.id == task.id || TaskOrder.canMove(task, relativeTo: $0) }
            .sorted { TaskOrder.precedes($0, $1, sortOrder: sortOrder) }
        guard let index = siblings.firstIndex(where: { $0.id == task.id }),
              siblings.indices.contains(index + offset) else { return }
        withAnimation(reduceMotion ? nil : WorkspaceMotion.taskReorder) {
            if store.moveTask(id: task.id, relativeTo: siblings[index + offset].id,
                              placement: offset < 0 ? .before : .after, sortOrder: sortOrder),
               task.parentID == nil {
                TaskDragSortPreference.useManualOrder()
            }
        }
    }
}

private enum TaskDragSortPreference {
    static var current: TaskSortOrder {
        UserDefaults.standard.string(forKey: TaskSortOrder.storageKey)
            .flatMap(TaskSortOrder.init(rawValue:)) ?? .createdDescending
    }

    static func useManualOrder() {
        UserDefaults.standard.set(TaskSortOrder.manual.rawValue, forKey: TaskSortOrder.storageKey)
    }
}

@MainActor
private final class SubtaskReorderSession: ObservableObject {
    static let shared = SubtaskReorderSession()
    struct Drag {
        let sourceID: UUID
        let movingRegionIDs: Set<UUID>
        var offset: CGFloat = 0
        var insertionRegionID: UUID?
        var targetTaskID: String?
        var placement: SubtaskPlacement?
    }
    @Published private(set) var drag: Drag?
    let regions = NSHashTable<SubtaskRowRegion>.weakObjects()
    private weak var source: SubtaskRowRegion?
    private var sourceTask: TodoTask?
    private var startPoint = NSPoint.zero
    private var sourceFrame = NSRect.zero
    private var sortOrder: TaskSortOrder = .manual

    func begin(taskID: String, store: TaskStore, window: NSWindow?, at point: NSPoint) -> Bool {
        guard drag == nil, let task = store.task(id: taskID),
              let region = regions.allObjects.first(where: {
                  $0.taskID == taskID && $0.store === store && $0.window === window &&
                  $0.screenFrame.insetBy(dx: -4, dy: -4).contains(point)
              }) else { return false }
        source = region
        sourceTask = task
        sourceFrame = region.screenFrame
        startPoint = point
        sortOrder = task.parentID == nil ? TaskDragSortPreference.current : .manual
        // Only the visible copy in this list follows the dragged branch. A detail
        // pane or another window can display the same tasks at the same time.
        let moving = regions.allObjects.filter { candidate in
            candidate.belongsToSameList(as: region) &&
            belongsToBranch(candidate.taskID, rootID: task.id, tasks: store.tasks)
        }
        drag = Drag(sourceID: region.id, movingRegionIDs: Set(moving.map(\.id)))
        return true
    }

    func move(to point: NSPoint) {
        guard var value = drag, let source, let original = sourceTask,
              let store = source.store, let current = store.task(id: original.id),
              source.window != nil,
              current.parentID == original.parentID,
              current.isCompleted == original.isCompleted,
              current.isPinned == original.isPinned else { cancel(); return }
        value.offset = startPoint.y - point.y
        value.insertionRegionID = nil
        value.targetTaskID = nil
        value.placement = nil

        // Merge a root's visible descendants into its drop region. This accepts
        // drops over children and between rows, with generous horizontal slack.
        var grouped: [String: [(region: SubtaskRowRegion, frame: CGRect)]] = [:]
        for candidate in regions.allObjects {
            guard !value.movingRegionIDs.contains(candidate.id),
                  candidate.belongsToSameList(as: source),
                  let candidateTask = store.task(id: candidate.taskID),
                  let target = TaskOrder.target(for: candidateTask, moving: current, in: store.tasks) else { continue }
            let frame = candidate.visibleScreenFrame
            guard !frame.isEmpty else { continue }
            grouped[target.id, default: []].append((candidate, frame))
        }
        let groups = grouped.compactMap { taskID, rows -> TaskDragGeometry.Group? in
            guard let top = rows.max(by: { $0.frame.maxY < $1.frame.maxY }),
                  let bottom = rows.min(by: { $0.frame.minY < $1.frame.minY }) else { return nil }
            let frame = rows.reduce(CGRect.null) { $0.union($1.frame) }
            return TaskDragGeometry.Group(taskID: taskID, frame: frame,
                                          topRegionID: top.region.id, bottomRegionID: bottom.region.id)
        }
        if let insertion = TaskDragGeometry.insertion(at: point, groups: groups, lane: sourceFrame) {
            value.insertionRegionID = insertion.regionID
            value.targetTaskID = insertion.taskID
            value.placement = insertion.placement
        }
        // Pointer tracking must be immediate, independent of surrounding list animations.
        var transaction = Transaction(); transaction.disablesAnimations = true
        withTransaction(transaction) { drag = value }
    }

    func finish() {
        guard let value = drag else { return }
        let source = self.source
        let original = sourceTask
        let order = sortOrder
        withAnimation(source?.reduceMotion == true ? nil : WorkspaceMotion.taskReorder) {
            clear()
            guard let source, let original, let store = source.store,
                  let current = store.task(id: original.id),
                  current.parentID == original.parentID, current.isCompleted == original.isCompleted,
                  current.isPinned == original.isPinned,
                  let targetID = value.targetTaskID, let target = store.task(id: targetID),
                  TaskOrder.canMove(current, relativeTo: target),
                  let placement = value.placement else { return }
            if store.moveTask(id: original.id, relativeTo: targetID, placement: placement, sortOrder: order),
               original.parentID == nil {
                TaskDragSortPreference.useManualOrder()
            }
        }
    }

    func cancel() {
        guard drag != nil else { return }
        withAnimation(source?.reduceMotion == true ? nil : WorkspaceMotion.taskReorder) { clear() }
    }

    private func belongsToBranch(_ taskID: String, rootID: String, tasks: [TodoTask]) -> Bool {
        var cursor: String? = taskID
        var visited: Set<String> = []
        while let id = cursor, visited.insert(id).inserted {
            if id == rootID { return true }
            cursor = tasks.first(where: { $0.id == id })?.parentID
        }
        return false
    }

    private func clear() { drag = nil; source = nil; sourceTask = nil }
}

private struct SubtaskRegion: NSViewRepresentable {
    let id: UUID
    let taskID: String
    let store: TaskStore
    let reduceMotion: Bool

    func makeNSView(context: Context) -> SubtaskRowRegion {
        let view = SubtaskRowRegion()
        view.id = id
        SubtaskReorderSession.shared.regions.add(view)
        return view
    }
    func updateNSView(_ view: SubtaskRowRegion, context: Context) {
        view.taskID = taskID; view.store = store; view.reduceMotion = reduceMotion
    }
    static func dismantleNSView(_ view: SubtaskRowRegion, coordinator: ()) {
        if SubtaskReorderSession.shared.drag?.sourceID == view.id { SubtaskReorderSession.shared.cancel() }
        SubtaskReorderSession.shared.regions.remove(view)
    }
}

private final class SubtaskRowRegion: NSView {
    var id = UUID()
    var taskID = ""
    weak var store: TaskStore?
    var reduceMotion = false
    var screenFrame: NSRect { window?.convertToScreen(convert(bounds, to: nil)) ?? .zero }
    var visibleScreenFrame: NSRect { window?.convertToScreen(convert(bounds.intersection(visibleRect), to: nil)) ?? .zero }
    func belongsToSameList(as other: SubtaskRowRegion) -> Bool {
        guard window != nil, window === other.window, store === other.store else { return false }
        if let scrollView = enclosingScrollView, let otherScrollView = other.enclosingScrollView {
            guard scrollView === otherScrollView else { return false }
        } else if enclosingScrollView != nil || other.enclosingScrollView != nil {
            return false
        }
        // A scroll view may itself contain multiple columns. Compare their row
        // lanes as well as scroll-view identity, independently of drop tolerance.
        return abs(screenFrame.minX - other.screenFrame.minX) <= 24 &&
            abs(screenFrame.maxX - other.screenFrame.maxX) <= 24
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private struct SubtaskGrip: NSViewRepresentable {
    @ObservedObject private var interfaceLanguage = LanguageSettings.shared
    let taskID: String
    let store: TaskStore
    func makeNSView(context: Context) -> SubtaskGripView { SubtaskGripView() }
    func updateNSView(_ view: SubtaskGripView, context: Context) {
        view.taskID = taskID; view.store = store
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.button)
        view.setAccessibilityLabel(L10n.tr("拖动排序：\(store.task(id: taskID)?.title ?? L10n.tr("任务"))"))
        view.setAccessibilityIdentifier("subtask-drag-\(taskID)")
    }
    static func dismantleNSView(_ view: SubtaskGripView, coordinator: ()) { view.cancelTracking() }
}

private final class SubtaskGripView: NSView {
    var taskID = ""
    weak var store: TaskStore?
    private var mouseStart: NSPoint?
    private var isDragging = false
    private var keyMonitor: Any?
    private var windowObserver: NSObjectProtocol?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func draw(_ dirtyRect: NSRect) {
        let image = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))?
            .withSymbolConfiguration(.init(paletteColors: [.secondaryLabelColor]))
        if let image {
            image.draw(in: NSRect(x: (bounds.width - image.size.width) / 2,
                                  y: (bounds.height - image.size.height) / 2,
                                  width: image.size.width, height: image.size.height))
        }
    }
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        mouseStart = window.convertPoint(toScreen: event.locationInWindow)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, self?.mouseStart != nil else { return event }
            self?.cancelTracking()
            return nil
        }
        windowObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
                                                                object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancelTracking() }
        }
    }
    override func mouseDragged(with event: NSEvent) {
        guard let window, let mouseStart, let store else { return }
        let point = window.convertPoint(toScreen: event.locationInWindow)
        if !isDragging {
            guard hypot(point.x - mouseStart.x, point.y - mouseStart.y) >= 3 else { return }
            guard SubtaskReorderSession.shared.begin(taskID: taskID, store: store, window: window,
                                                    at: mouseStart) else { return }
            isDragging = true
            NSCursor.closedHand.push()
        }
        SubtaskReorderSession.shared.move(to: point)
    }
    override func mouseUp(with event: NSEvent) {
        if isDragging {
            if let window { SubtaskReorderSession.shared.move(to: window.convertPoint(toScreen: event.locationInWindow)) }
            SubtaskReorderSession.shared.finish()
        }
        endTracking()
    }
    func cancelTracking() {
        if isDragging { SubtaskReorderSession.shared.cancel() }
        endTracking()
    }
    private func endTracking() {
        if isDragging { NSCursor.pop() }
        isDragging = false; mouseStart = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }
        keyMonitor = nil; windowObserver = nil
    }
}
