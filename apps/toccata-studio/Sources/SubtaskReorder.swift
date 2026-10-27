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
        if task.parentID != nil {
            SubtaskGrip(taskID: task.id, store: store)
                .frame(width: 22, height: 22)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                .help(L10n.tr("按住拖动：仅调整同一主任务下、同一完成状态的子任务顺序"))
        }
    }
}

extension View {
    func subtaskReordering(task: TodoTask) -> some View {
        modifier(SubtaskReorderModifier(task: task))
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
        if task.parentID != nil {
            let isDragging = session.drag?.sourceID == regionID
            let insertion = session.drag?.targetID == regionID ? session.drag?.placement : nil
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
                .accessibilityAction(named: L10n.tr("上移子任务")) { moveByKeyboard(-1) }
                .accessibilityAction(named: L10n.tr("下移子任务")) { moveByKeyboard(1) }
        } else {
            content
        }
    }

    private func moveByKeyboard(_ offset: Int) {
        let siblings = store.children(of: task.parentID).filter { $0.isCompleted == task.isCompleted }
        guard let index = siblings.firstIndex(where: { $0.id == task.id }),
              siblings.indices.contains(index + offset) else { return }
        withAnimation(reduceMotion ? nil : WorkspaceMotion.taskReorder) {
            _ = store.moveSubtask(id: task.id, relativeTo: siblings[index + offset].id,
                                 placement: offset < 0 ? .before : .after)
        }
    }
}

@MainActor
private final class SubtaskReorderSession: ObservableObject {
    static let shared = SubtaskReorderSession()
    struct Drag {
        let sourceID: UUID
        var offset: CGFloat = 0
        var targetID: UUID?
        var placement: SubtaskPlacement?
    }
    @Published private(set) var drag: Drag?
    let regions = NSHashTable<SubtaskRowRegion>.weakObjects()
    private weak var source: SubtaskRowRegion?
    private var sourceTask: TodoTask?
    private var startPoint = NSPoint.zero
    private var sourceFrame = NSRect.zero

    func begin(taskID: String, store: TaskStore, window: NSWindow?, at point: NSPoint) -> Bool {
        guard drag == nil, let task = store.task(id: taskID), task.parentID != nil,
              let region = regions.allObjects.first(where: {
                  $0.taskID == taskID && $0.store === store && $0.window === window &&
                  $0.screenFrame.contains(point)
              }) else { return false }
        source = region
        sourceTask = task
        sourceFrame = region.screenFrame
        startPoint = point
        drag = Drag(sourceID: region.id)
        return true
    }

    func move(to point: NSPoint) {
        guard var value = drag, let source, let original = sourceTask,
              let current = source.store?.task(id: original.id),
              current.parentID == original.parentID,
              current.isCompleted == original.isCompleted else { cancel(); return }
        value.offset = startPoint.y - point.y
        value.targetID = nil
        value.placement = nil
        // Stay in this list/column, even when the same tasks appear in a detail pane.
        if point.x >= sourceFrame.minX && point.x <= sourceFrame.maxX,
           let target = regions.allObjects.first(where: { candidate in
               guard candidate !== source, candidate.window === source.window,
                     candidate.store === source.store,
                     candidate.visibleScreenFrame.contains(point),
                     let task = candidate.store?.task(id: candidate.taskID) else { return false }
               return SubtaskOrder.canMove(current, relativeTo: task)
           }) {
            value.targetID = target.id
            value.placement = point.y >= target.screenFrame.midY ? .before : .after
        }
        // Pointer tracking must be immediate, independent of surrounding list animations.
        var transaction = Transaction(); transaction.disablesAnimations = true
        withTransaction(transaction) { drag = value }
    }

    func finish() {
        guard let value = drag else { return }
        let source = self.source
        let original = sourceTask
        let target = regions.allObjects.first { $0.id == value.targetID }
        withAnimation(source?.reduceMotion == true ? nil : WorkspaceMotion.taskReorder) {
            clear()
            guard let source, let original, let store = source.store,
                  let current = store.task(id: original.id),
                  current.parentID == original.parentID, current.isCompleted == original.isCompleted,
                  let target, let placement = value.placement else { return }
            _ = store.moveSubtask(id: original.id, relativeTo: target.taskID, placement: placement)
        }
    }

    func cancel() {
        guard drag != nil else { return }
        withAnimation(source?.reduceMotion == true ? nil : WorkspaceMotion.taskReorder) { clear() }
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
        view.setAccessibilityLabel(L10n.tr("拖动排序：\(store.task(id: taskID)?.title ?? L10n.tr("子任务"))"))
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
