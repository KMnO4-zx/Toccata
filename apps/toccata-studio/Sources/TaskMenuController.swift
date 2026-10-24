import AppKit
import Combine
import SwiftUI

/// The task list and editor are a single dismissible pair. A separate native
/// panel keeps the status-item anchor stable while the editor gains keyboard focus.
@MainActor
final class TaskMenuController: NSObject, ObservableObject {
    let presentation = MenuTaskPresentation()
    private(set) var listPanel: NSPanel?
    private(set) var editorPanel: NSPanel?
    private var statusItem: NSStatusItem?
    private var store: TaskStore?
    private var openWorkbenchAction: (() -> Void)?
    private var openCalendarAction: (() -> Void)?
    private var clickMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var storeSubscription: AnyCancellable?
    private var isDismissing = false

    func configure(store: TaskStore, openWorkbench: @escaping () -> Void, openCalendar: (() -> Void)? = nil) {
        openWorkbenchAction = openWorkbench
        openCalendarAction = openCalendar ?? openWorkbench
        guard statusItem == nil else { return }
        self.store = store
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: "Toccata 任务")
            button.imagePosition = .imageLeading
            button.font = .systemFont(ofSize: 13)
            button.toolTip = "Toccata 任务"
            button.target = self
            button.action = #selector(toggleMenu)
            button.setAccessibilityLabel("Toccata 任务")
        }
        statusItem = item
        presentation.onShowEditor = { [weak self] _, focus in self?.showEditor(focus: focus) }
        presentation.onDismissEditor = { [weak self] in self?.hideEditor() }
        presentation.onFocusList = { [weak self] in self?.listPanel?.makeKeyAndOrderFront(nil) }
        presentation.onOpenWorkbench = { [weak self] in
            self?.dismiss()
            self?.openWorkbenchAction?()
            NSApp.activate(ignoringOtherApps: true)
        }
        presentation.onOpenCalendar = { [weak self] in
            self?.dismiss()
            self?.openCalendarAction?()
            NSApp.activate(ignoringOtherApps: true)
        }
        presentation.onAnchorsChanged = { [weak self] in self?.positionEditor() }
        storeSubscription = store.$tasks.receive(on: RunLoop.main).sink { [weak self] updated in
            guard let self else { return }
            let count = updated.filter { $0.parentID == nil && !$0.isCompleted }.count
            self.statusItem?.button?.title = count == 0 ? "" : " \(count)"
            guard let id = self.presentation.selectedTaskID,
                  !updated.contains(where: { $0.id == id }) else { return }
            self.hideEditor()
            self.presentation.selectedTaskID = nil
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        })
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, self.listPanel?.isVisible == true else { return }
                if event.window === self.statusItem?.button?.window { return }
                if self.belongsToMenu(event.window) { return }
                // A context menu has its own NSWindow. Let AppKit finish that
                // interaction instead of dismissing its task panel underneath it.
                if event.window?.level.rawValue ?? 0 >= NSWindow.Level.popUpMenu.rawValue { return }
                self.dismiss()
            }
            return event
        }
    }

    @objc func toggleMenu() {
        if listPanel?.isVisible == true { dismiss() } else { showMenu() }
    }

    func showMenu() {
        guard let store, let button = statusItem?.button, let statusWindow = button.window else { return }
        let anchor = statusWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = statusWindow.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let frame = MenuPanelLayout.listFrame(anchor: anchor, screen: screen.visibleFrame)
        presentation.panelSize = frame.size
        if listPanel == nil {
            let panel = makePanel(title: "Toccata 任务列表")
            panel.contentView = NSHostingView(rootView:
                QuickCaptureView()
                    .environmentObject(store)
                    .environmentObject(presentation)
                    .tint(TaskMenuStyle.accent)
                    .environment(\.colorScheme, .light)
                    .background(TaskMenuStyle.background)
                    .clipShape(RoundedRectangle(cornerRadius: TaskMenuStyle.cornerRadius))
            )
            listPanel = panel
        }
        hideEditor()
        presentation.selectedTaskID = nil
        presentation.focusRequest = nil
        presentation.rowFrames = [:]
        presentation.openGeneration = UUID()
        listPanel?.setFrame(frame, display: true)
        NSApp.activate(ignoringOtherApps: true)
        listPanel?.makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        guard !isDismissing else { return }
        isDismissing = true
        hideEditor()
        listPanel?.orderOut(nil)
        isDismissing = false
    }

    private func showEditor(focus: MenuEditorField?) {
        guard let store, let id = presentation.selectedTaskID,
              store.task(id: id) != nil, let listPanel, listPanel.isVisible else {
            presentation.editorDidHide()
            return
        }
        if editorPanel == nil {
            let panel = makePanel(title: "Toccata 任务详情")
            panel.contentView = nil
            editorPanel = panel
        }
        guard let editorPanel else { return }
        if editorPanel.contentView == nil {
            editorPanel.contentView = NSHostingView(rootView:
                FloatingTaskEditor()
                    .environmentObject(store)
                    .environmentObject(presentation)
                    .tint(TaskMenuStyle.accent)
                    .environment(\.colorScheme, .light)
                    .background(TaskMenuStyle.background)
                    .clipShape(RoundedRectangle(cornerRadius: TaskMenuStyle.cornerRadius))
            )
        }
        positionEditor()
        if editorPanel.parent !== listPanel { listPanel.addChildWindow(editorPanel, ordered: .above) }
        editorPanel.orderFront(nil)
        if focus != nil { editorPanel.makeKeyAndOrderFront(nil) }
    }

    private func hideEditor() {
        presentation.editorDidHide()
        guard let editorPanel else { return }
        if let parent = editorPanel.parent { parent.removeChildWindow(editorPanel) }
        // Releasing the hosted editor flushes its final draft through onDisappear.
        editorPanel.contentView = nil
        editorPanel.orderOut(nil)
    }

    private func positionEditor() {
        guard let listPanel, let editorPanel, let id = presentation.selectedTaskID else { return }
        let screen = listPanel.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let frame = MenuPanelLayout.editorFrame(list: listPanel.frame,
                                                row: presentation.rowFrames[id], screen: screen.visibleFrame)
        editorPanel.setFrame(frame, display: true)
    }

    private func belongsToMenu(_ window: NSWindow?) -> Bool {
        var candidate = window
        while let current = candidate {
            if presentation.companionWindows.contains(current) { return true }
            if current === listPanel || current === editorPanel { return true }
            candidate = current.sheetParent ?? current.parent
        }
        return false
    }

    private func makePanel(title: String) -> NSPanel {
        let panel = TaskMenuPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.title = title
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.transient, .moveToActiveSpace, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.appearance = NSAppearance(named: .aqua)
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false
        return panel
    }
}

private final class TaskMenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

struct TaskMenuSetup: View {
    @Environment(\.openWindow) private var openWindow
    let controller: TaskMenuController
    let store: TaskStore
    @Binding var requestedSection: String?

    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .onAppear {
                controller.configure(store: store, openWorkbench: { openWindow(id: "main") }, openCalendar: {
                    requestedSection = "任务日历"
                    openWindow(id: "main")
                })
            }
    }
}
