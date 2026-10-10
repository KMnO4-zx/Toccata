import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: OverlayWindow?
    private var keyboardView: KeyboardView?
    private var statusMenu: StatusMenuController?
    private let daemonClient = DaemonClient()
    private let heatmapStore = HeatmapStore()
    private let layout = KeyboardLayout.load()
    private var theme: Theme
    private var mode: KeyboardView.Mode = .live
    private var pressedCodes: Set<UInt16> = []

    override init() {
        theme = ThemeCatalog.availableThemes().first?.load() ?? .fallback
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let width: CGFloat = 720
        let height = layout.contentHeightPoints > 0 && layout.contentWidthPoints > 0
            ? width * CGFloat(layout.contentHeightPoints / layout.contentWidthPoints)
            : width / 3
        let window = OverlayWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height))
        let keyboardView = KeyboardView(layout: layout, theme: theme)
        window.contentView = keyboardView
        self.window = window
        self.keyboardView = keyboardView
        positionWindowAtBottomRight(window)
        window.orderFrontRegardless()

        let menu = StatusMenuController()
        menu.onSelectMode = { [weak self] newMode in self?.setMode(newMode) }
        menu.onOpacityChanged = { [weak self] value in self?.window?.alphaValue = CGFloat(value) }
        menu.onSelectTheme = { [weak self] entry in self?.applyTheme(entry) }
        menu.setup(mode: mode, themeName: theme.name, opacity: Double(window.alphaValue),
                   themes: ThemeCatalog.availableThemes())
        statusMenu = menu

        daemonClient.onKeyEvent = { [weak self] code, isDown in
            DispatchQueue.main.async {
                self?.handleKeyEvent(code: code, isDown: isDown)
            }
        }
        daemonClient.start()

        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self = self, self.mode == .heat else { return }
            self.refreshHeat()
        }
    }

    private func positionWindowAtBottomRight(_ window: NSWindow) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        window.setFrameOrigin(NSPoint(
            x: visible.maxX - window.frame.width - 24,
            y: visible.minY + 24
        ))
    }

    private func handleKeyEvent(code: UInt16, isDown: Bool) {
        if isDown {
            pressedCodes.insert(code)
        } else {
            pressedCodes.remove(code)
        }
        if mode == .live {
            keyboardView?.pressed = pressedCodes
        }
    }

    private func setMode(_ newMode: KeyboardView.Mode) {
        mode = newMode
        keyboardView?.mode = newMode
        if newMode == .live {
            keyboardView?.pressed = pressedCodes
        } else {
            refreshHeat()
        }
        statusMenu?.updateStates(mode: mode, themeName: theme.name)
    }

    private func refreshHeat() {
        let data = heatmapStore.load()
        guard let keyboardView = keyboardView else { return }
        keyboardView.heatCounts = data.counts
        keyboardView.heatMax = data.maxCount
        keyboardView.heatAvailable = data.available
        keyboardView.needsDisplay = true
    }

    private func applyTheme(_ entry: ThemeEntry) {
        theme = entry.load()
        keyboardView?.theme = theme
        statusMenu?.updateStates(mode: mode, themeName: theme.name)
    }
}
