import AppKit
import SwiftUI

/// Owns the only workbench window. Closing it never owns the application's lifetime.
@MainActor
final class ToccataApplicationDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let appearance = AppearanceSettings()
    let loginItems = LoginItemController()
    let dockIcon = DockIconSettings()
    let hydrationReminders = HydrationReminderController()
    private let taskStore = TaskStore()
    private let taskMenu = TaskMenuController()
    private let coreProcess = CoreProcessController()
    private let refresher = LiveRefresher()
    // SwiftUI owns NSApp.delegate and forwards to this adapted delegate.
    // Pass the real lifecycle owner explicitly instead of casting that proxy.
    private lazy var aboutWindow = AboutWindowController(install: { [weak self] prepared, failed in
        guard let self else { failed(UpdateInstallFailure.installer); return }
        self.installUpdate(start: {
            try await prepared.startInstaller()
        }, failed: failed)
    })
    private let hydrationWindow = HydrationReminderWindowController()
    private let workbenchNavigation = WorkbenchNavigation()
    private var workbench: NSWindow?
    private var healthTimer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var isQuitting = false
    private var didStart = false
    private var isClosingWorkbench = false
    private var allowsWorkbenchClose = false
    private var pendingSave: Task<Bool, Never>?
    private var updateInstallation: (start: () async throws -> Void, failed: (Error) -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !didStart else { return }
        didStart = true
        PreparedAppUpdate.cleanUpSuccessfulInstallation()
        let launchedAtLogin = ApplicationLaunchContext.currentIsLoginItemLaunch
        taskMenu.configure(store: taskStore, loginItems: loginItems, appearance: appearance,
                           refresher: refresher, openHydrationSettings: { [weak self] in
            self?.openHydrationSettings()
        }, openAbout: { [weak self] in
            self?.openAbout()
        }) { [weak self] section in
            self?.openWorkbench(section: section)
        }
        dockIcon.applySavedPreference()
        refresher.start()
        hydrationReminders.start(refresher: refresher)
        coreProcess.start(requestPermission: false)
        healthTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.ensureCaptureIsRunning() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.ensureCaptureIsRunning() }
        }
        if !launchedAtLogin { openWorkbench() }
        if CommandLine.arguments.contains("--update-failed") { openAbout() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openWorkbench()
        return false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        loginItems.refresh()
        Task { await hydrationReminders.refreshAuthorization() }
    }

    func openHydrationSettings() {
        taskMenu.dismiss()
        hydrationWindow.show(reminders: hydrationReminders)
    }

    func openAbout() {
        taskMenu.dismiss()
        aboutWindow.show()
    }

    func openWorkbench(section: WorkspaceSection? = nil) {
        guard !isQuitting else { return }
        if let section { workbenchNavigation.requestedSection = section.rawValue }
        if workbench == nil {
            let content = WorkbenchRootView(navigation: workbenchNavigation,
                                            openAbout: { [weak self] in self?.openAbout() })
                .environmentObject(refresher)
                .environmentObject(taskStore)
                .environmentObject(appearance)
                .environmentObject(loginItems)
                .environmentObject(dockIcon)
                .environmentObject(hydrationReminders)
                .frame(minWidth: 1040, minHeight: 650)
            let window = WorkbenchWindow(contentViewController: NSHostingController(rootView: content))
            window.title = "Toccata"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.toolbarStyle = .unified
            window.setContentSize(NSSize(width: 1240, height: 780))
            window.contentMinSize = NSSize(width: 1040, height: 650)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            window.setFrameAutosaveName("ToccataWorkbench")
            workbench = window
        }
        workbench?.deminiaturize(nil)
        workbench?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        coreProcess.requestInputMonitoringPermission()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if allowsWorkbenchClose { return true }
        guard !isClosingWorkbench, !isQuitting else { return false }
        isClosingWorkbench = true
        Task { @MainActor in
            defer { isClosingWorkbench = false }
            let saved = await savePendingEdits()
            guard !isQuitting else { return }
            if saved {
                allowsWorkbenchClose = true
                sender.performClose(nil)
                allowsWorkbenchClose = false
            } else {
                showSaveFailure()
            }
        }
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isQuitting else { return .terminateLater }
        isQuitting = true
        Task { @MainActor in
            guard await savePendingEdits() else {
                isQuitting = false
                failUpdate(UpdateInstallFailure.save)
                sender.reply(toApplicationShouldTerminate: false)
                showSaveFailure()
                return
            }
            taskMenu.dismiss()
            let stopped = await coreProcess.stop()
            if stopped {
                do {
                    try await updateInstallation?.start()
                    updateInstallation = nil
                } catch {
                    isQuitting = false
                    failUpdate(error)
                    coreProcess.start(requestPermission: false)
                    sender.reply(toApplicationShouldTerminate: false)
                    return
                }
                healthTimer?.invalidate()
                hydrationReminders.stop()
                refresher.stop()
                sender.reply(toApplicationShouldTerminate: true)
            } else {
                isQuitting = false
                failUpdate(UpdateInstallFailure.save)
                sender.reply(toApplicationShouldTerminate: false)
                let alert = NSAlert()
                alert.messageText = L10n.tr("后台记录仍在保存")
                alert.informativeText = L10n.tr("Toccata 暂时保留运行。请稍后再次退出，确保最后的记录已保存。")
                alert.addButton(withTitle: L10n.tr("好"))
                alert.runModal()
            }
        }
        return .terminateLater
    }

    func installUpdate(start: @escaping () async throws -> Void, failed: @escaping (Error) -> Void) {
        guard !isQuitting, updateInstallation == nil else { failed(UpdateInstallFailure.save); return }
        updateInstallation = (start, failed)
        NSApp.terminate(nil)
    }

    private func failUpdate(_ error: Error) {
        let failed = updateInstallation?.failed
        updateInstallation = nil
        failed?(error)
    }

    func applicationWillTerminate(_ notification: Notification) {
        healthTimer?.invalidate()
        hydrationReminders.stop()
        refresher.stop()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    }

    private func ensureCaptureIsRunning() {
        guard !isQuitting else { return }
        coreProcess.start(requestPermission: false)
    }

    private func savePendingEdits() async -> Bool {
        if let pendingSave { return await pendingSave.value }
        for window in NSApp.windows { window.makeFirstResponder(nil) }
        let save = Task { @MainActor in await PendingEdits.shared.flushAll() }
        pendingSave = save
        let saved = await save.value
        pendingSave = nil
        return saved
    }

    private func showSaveFailure() {
        let alert = NSAlert()
        alert.messageText = L10n.tr("任务修改尚未保存")
        alert.informativeText = taskStore.errorMessage ?? L10n.tr("请重试保存，再关闭窗口或退出 Toccata。")
        alert.addButton(withTitle: L10n.tr("返回任务"))
        alert.runModal()
    }
}
