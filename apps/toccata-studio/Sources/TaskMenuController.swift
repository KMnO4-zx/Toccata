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
    private var loginItems: LoginItemController?
    private var appearance: AppearanceSettings?
    private var openWorkbenchAction: (() -> Void)?
    private var clickMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var storeSubscription: AnyCancellable?
    private var isDismissing = false
    private var isEditorRevealing = false
    private var editorRevealGeneration = UUID()

    func configure(store: TaskStore, loginItems: LoginItemController, appearance: AppearanceSettings,
                   openWorkbench: @escaping () -> Void) {
        openWorkbenchAction = openWorkbench
        guard statusItem == nil else { return }
        self.store = store
        self.loginItems = loginItems
        self.appearance = appearance
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "square.stack.3d.up.fill", accessibilityDescription: "Toccata 任务")
            button.image?.isTemplate = true
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
        guard let store, let loginItems, let appearance,
              let button = statusItem?.button, let statusWindow = button.window else { return }
        loginItems.refresh()
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
                    .environmentObject(loginItems)
                    .environmentObject(appearance)
                    .tint(TaskMenuStyle.accent)
                    .background(TaskMenuStyle.background)
                    .clipShape(RoundedRectangle(cornerRadius: TaskMenuStyle.cornerRadius))
            )
            listPanel = panel
        }
        guard let panel = listPanel else { return }
        let wasVisible = panel.isVisible
        hideEditor()
        presentation.selectedTaskID = nil
        presentation.focusRequest = nil
        presentation.rowFrames = [:]
        presentation.openGeneration = UUID()

        let shouldAnimate = !wasVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.setFrame(shouldAnimate ? MenuPanelLayout.revealFrame(for: frame) : frame, display: true)
        panel.alphaValue = shouldAnimate ? 0 : 1
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        guard shouldAnimate else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = WorkspaceMotion.panelRevealDuration
            panel.animator().alphaValue = 1
            panel.animator().setFrame(frame, display: true, animate: true)
        }
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
            MenuEditorHostingView.install(in: editorPanel, rootView:
                FloatingTaskEditor()
                    .environmentObject(store)
                    .environmentObject(presentation)
                    .tint(TaskMenuStyle.accent)
                    .background(TaskMenuStyle.background)
                    .clipShape(RoundedRectangle(cornerRadius: TaskMenuStyle.cornerRadius))
            ) { [weak self] in
                self?.presentation.dismissEditor()
                self?.presentation.requestListFocus()
            }
        }
        if focus == nil {
            // A row click only previews the task. Explicit Tab / Return requests
            // below still activate the editor and focus their requested field.
            editorPanel.makeFirstResponder(editorPanel.contentView)
        }
        let targetFrame = isEditorRevealing ? nil : positionEditor()
        let shouldAnimate = !editorPanel.isVisible && targetFrame != nil
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if shouldAnimate, let targetFrame {
            editorRevealGeneration = UUID()
            isEditorRevealing = true
            editorPanel.alphaValue = 0
            editorPanel.setFrame(MenuPanelLayout.revealFrame(for: targetFrame), display: true)
        } else if !isEditorRevealing {
            editorPanel.alphaValue = 1
        }
        if editorPanel.parent !== listPanel { listPanel.addChildWindow(editorPanel, ordered: .above) }
        editorPanel.orderFront(nil)
        if focus != nil { editorPanel.makeKeyAndOrderFront(nil) }
        guard shouldAnimate, let targetFrame else { return }
        let generation = editorRevealGeneration
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = WorkspaceMotion.panelRevealDuration
            editorPanel.animator().alphaValue = 1
            editorPanel.animator().setFrame(targetFrame, display: true, animate: true)
        }, completionHandler: {
            Task { @MainActor [weak self] in
                guard let self, self.editorRevealGeneration == generation else { return }
                self.isEditorRevealing = false
                self.positionEditor()
            }
        })
    }

    private func hideEditor() {
        presentation.editorDidHide()
        editorRevealGeneration = UUID()
        isEditorRevealing = false
        guard let editorPanel else { return }
        if let parent = editorPanel.parent { parent.removeChildWindow(editorPanel) }
        editorPanel.makeFirstResponder(nil)
        editorPanel.initialFirstResponder = nil
        // Releasing the hosted editor flushes its final draft through onDisappear.
        editorPanel.contentView = nil
        editorPanel.orderOut(nil)
    }

    @discardableResult
    private func positionEditor() -> CGRect? {
        guard !isEditorRevealing, let listPanel, let editorPanel, let id = presentation.selectedTaskID else { return nil }
        let screen = listPanel.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let frame = MenuPanelLayout.editorFrame(list: listPanel.frame,
                                                row: presentation.rowFrames[id], screen: screen.visibleFrame)
        editorPanel.setFrame(frame, display: true)
        return frame
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
