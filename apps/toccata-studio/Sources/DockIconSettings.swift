import AppKit
import Combine
import Foundation

/// Keep the menu bar available under both policies. A fresh installation shows
/// the Dock icon; changing this preference never changes the app's lifetime.
@MainActor
final class DockIconSettings: ObservableObject {
    static let defaultsKey = "hideDockIcon"

    @Published private(set) var isHidden: Bool
    @Published private(set) var errorMessage: String?
    private let defaults: UserDefaults
    private let apply: @MainActor (Bool) -> Bool

    init(defaults: UserDefaults = .standard, apply: (@MainActor (Bool) -> Bool)? = nil) {
        self.defaults = defaults
        self.apply = apply ?? { hidden in
            let app = NSApplication.shared
            let window = app.keyWindow
            let wasActive = app.isActive
            guard app.setActivationPolicy(hidden ? .accessory : .regular) else { return false }
            if wasActive, let window, window.isVisible {
                window.makeKeyAndOrderFront(nil)
                app.activate(ignoringOtherApps: true)
            }
            return true
        }
        isHidden = defaults.bool(forKey: Self.defaultsKey)
    }

    /// Apply after launch, once the status item exists, to keep a recovery entry
    /// point available even when the preference hides the Dock icon.
    func applySavedPreference() {
        errorMessage = apply(isHidden) ? nil : L10n.tr("无法更改 Dock 图标显示，请重试。")
    }

    func setHidden(_ hidden: Bool) {
        guard hidden != isHidden else { return }
        guard apply(hidden) else {
            errorMessage = L10n.tr("无法更改 Dock 图标显示，请重试。")
            return
        }
        isHidden = hidden
        defaults.set(hidden, forKey: Self.defaultsKey)
        errorMessage = nil
    }
}
