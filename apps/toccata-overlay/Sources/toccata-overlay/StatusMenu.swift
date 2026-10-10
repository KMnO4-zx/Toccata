import AppKit

final class StatusMenuController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var liveItem: NSMenuItem?
    private var heatItem: NSMenuItem?
    private var themeItems: [(item: NSMenuItem, entry: ThemeEntry)] = []

    var onSelectMode: ((KeyboardView.Mode) -> Void)?
    var onOpacityChanged: ((Double) -> Void)?
    var onSelectTheme: ((ThemeEntry) -> Void)?

    func setup(mode: KeyboardView.Mode, themeName: String, opacity: Double, themes: [ThemeEntry]) {
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "Toccata Overlay")
        }

        let menu = NSMenu()
        menu.autoenablesItems = false

        let live = NSMenuItem(title: "实时", action: #selector(selectLive), keyEquivalent: "")
        live.target = self
        let heat = NSMenuItem(title: "热力图", action: #selector(selectHeat), keyEquivalent: "")
        heat.target = self
        liveItem = live
        heatItem = heat
        menu.addItem(live)
        menu.addItem(heat)
        menu.addItem(.separator())

        let opacityItem = NSMenuItem()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 32))
        let title = NSTextField(labelWithString: "透明度")
        title.font = NSFont.menuFont(ofSize: 0)
        title.frame = NSRect(x: 16, y: 6, width: 56, height: 20)
        let slider = NSSlider(value: opacity, minValue: 0.2, maxValue: 1.0, target: self, action: #selector(opacityChanged(_:)))
        slider.isContinuous = true
        slider.frame = NSRect(x: 76, y: 5, width: 148, height: 22)
        container.addSubview(title)
        container.addSubview(slider)
        opacityItem.view = container
        menu.addItem(opacityItem)
        menu.addItem(.separator())

        let themeItem = NSMenuItem(title: "主题", action: nil, keyEquivalent: "")
        let themeMenu = NSMenu()
        themeMenu.autoenablesItems = false
        for entry in themes {
            let item = NSMenuItem(title: entry.name, action: #selector(selectTheme(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = entry
            themeMenu.addItem(item)
            themeItems.append((item, entry))
        }
        themeItem.submenu = themeMenu
        menu.addItem(themeItem)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "退出 Toccata Overlay", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
        updateStates(mode: mode, themeName: themeName)
    }

    func updateStates(mode: KeyboardView.Mode, themeName: String) {
        liveItem?.state = (mode == .live) ? .on : .off
        heatItem?.state = (mode == .heat) ? .on : .off
        for (item, entry) in themeItems {
            item.state = (entry.name == themeName) ? .on : .off
        }
    }

    @objc private func selectLive() { onSelectMode?(.live) }
    @objc private func selectHeat() { onSelectMode?(.heat) }

    @objc private func opacityChanged(_ sender: NSSlider) {
        onOpacityChanged?(sender.doubleValue)
    }

    @objc private func selectTheme(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? ThemeEntry else { return }
        onSelectTheme?(entry)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
