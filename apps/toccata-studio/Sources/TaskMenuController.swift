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
    private var openAboutAction: (() -> Void)?
    private var clickMonitor: Any?
    private var globalClickMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var storeSubscription: AnyCancellable?
    private var isDismissing = false
    private var isEditorRevealing = false
    private var editorRevealGeneration = UUID()

    func configure(store: TaskStore, loginItems: LoginItemController, appearance: AppearanceSettings,
                   openAbout: @escaping () -> Void,
                   openWorkbench: @escaping () -> Void) {
        openAboutAction = openAbout
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
            button.toolTip = "Toccata 任务 · 右键打开设置"
            button.target = self
            button.action = #selector(toggleMenu)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel("Toccata 任务")
        }
        statusItem = item
        presentation.onShowEditor = { [weak self] _, focus in self?.showEditor(focus: focus) }
        presentation.onDismissEditor = { [weak self] in self?.hideEditor() }
        presentation.onFocusList = { [weak self] in self?.listPanel?.makeKeyAndOrderFront(nil) }
        presentation.onOpenWorkbench = { [weak self] in
            self?.dismiss()
            self?.openWorkbenchAction?()
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
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  application.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            MainActor.assumeIsolated { self?.dismiss() }
        })
    }

    @objc func toggleMenu() {
        if let event = NSApp.currentEvent, event.type == .rightMouseUp {
            showSettingsMenu(with: event)
            return
        }
        if listPanel?.isVisible == true { dismiss() } else { showMenu() }
    }

    func showMenu() {
        guard let store,
              let button = statusItem?.button, let statusWindow = button.window else { return }
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
        panel.makeKeyAndOrderFront(nil)
        monitorOutsideClicks()
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
        if let globalClickMonitor {
            NSEvent.removeMonitor(globalClickMonitor)
            self.globalClickMonitor = nil
        }
        hideEditor()
        listPanel?.orderOut(nil)
        isDismissing = false
    }

    private func monitorOutsideClicks() {
        guard globalClickMonitor == nil else { return }
        // Nonactivating panels leave the previous app active. Those clicks do
        // not reach the local monitor or trigger this app's resign notification.
        // Observe them only while a task panel is actually on screen.
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
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
        // The nonactivating style must be set at construction time. It lets the
        // list/editor take keyboard focus without raising the workbench window.
        let panel = TaskMenuPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = title
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.transient, .moveToActiveSpace, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false
        return panel
    }

    private func showSettingsMenu(with event: NSEvent) {
        guard let button = statusItem?.button, let appearance, let loginItems else { return }
        dismiss()
        loginItems.refresh()
        let menu = NSMenu()
        menu.addItem(settingsItem("打开工作台", action: #selector(openWorkbenchFromSettings)))

        let appearanceItem = NSMenuItem(title: "外观", action: nil, keyEquivalent: "")
        let appearanceMenu = NSMenu()
        for mode in AppearanceMode.allCases {
            let item = settingsItem(mode.title, action: #selector(selectAppearance(_:)))
            item.representedObject = mode.rawValue
            item.state = appearance.mode == mode ? .on : .off
            appearanceMenu.addItem(item)
        }
        appearanceItem.submenu = appearanceMenu
        menu.addItem(appearanceItem)
        menu.addItem(.separator())

        let loginItem = settingsItem("登录时启动", action: #selector(toggleLoginItem))
        loginItem.state = loginItems.enabled ? .on : .off
        menu.addItem(loginItem)
        if loginItems.requiresApproval {
            menu.addItem(settingsItem("前往系统设置允许启动", action: #selector(openLoginSettings)))
            menu.addItem(settingsItem("取消登录启动申请", action: #selector(disableLoginItem)))
        }
        if let error = loginItems.errorMessage {
            let item = NSMenuItem(title: error, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())

        let shortcutsItem = NSMenuItem(title: "快捷键", action: nil, keyEquivalent: "")
        let shortcutsMenu = NSMenu()
        for title in ["Tab：编辑所选任务的描述", "Enter：为顶层任务添加子任务", "↑ / ↓：选择任务", "Esc：收起编辑浮窗"] {
            shortcutsMenu.addItem(NSMenuItem(title: title, action: nil, keyEquivalent: ""))
        }
        shortcutsItem.submenu = shortcutsMenu
        menu.addItem(shortcutsItem)
        menu.addItem(.separator())
        menu.addItem(settingsItem("关于 Toccata", action: #selector(openAboutFromSettings)))
        menu.addItem(settingsItem("退出 Toccata", action: #selector(quitFromSettings)))
        NSMenu.popUpContextMenu(menu, with: event, for: button)
    }

    private func settingsItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func openWorkbenchFromSettings() { presentation.openWorkbench() }
    @objc private func openAboutFromSettings() { openAboutAction?() }

    @objc private func selectAppearance(_ item: NSMenuItem) {
        guard let value = item.representedObject as? String, let mode = AppearanceMode(rawValue: value) else { return }
        appearance?.setMode(mode)
    }

    @objc private func toggleLoginItem() {
        guard let loginItems else { return }
        loginItems.setEnabled(!loginItems.enabled)
    }

    @objc private func disableLoginItem() { loginItems?.setEnabled(false) }
    @objc private func openLoginSettings() { loginItems?.openSystemSettings() }
    @objc private func quitFromSettings() { NSApp.terminate(nil) }
}

private final class TaskMenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
