import AppKit
import Combine
import Foundation

enum AppearanceMode: String, CaseIterable, Identifiable {
    case light
    case dark
    case system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "月之亮面"
        case .dark: return "月之暗面"
        }
    }

    var appearanceName: NSAppearance.Name? {
        switch self {
        case .system: return nil
        case .light: return .aqua
        case .dark: return .darkAqua
        }
    }
}

/// Overrides only this application's appearance. Windows and panels without
/// their own override inherit it; nil continues following system changes live.
@MainActor
final class AppearanceSettings: ObservableObject {
    static let defaultsKey = "appearanceMode"

    @Published var mode: AppearanceMode {
        didSet {
            guard mode != oldValue else { return }
            defaults.set(mode.rawValue, forKey: Self.defaultsKey)
            applyAppearance(mode)
        }
    }

    private let defaults: UserDefaults
    private let applyAppearance: @MainActor (AppearanceMode) -> Void

    init(defaults: UserDefaults = .standard,
         apply: (@MainActor (AppearanceMode) -> Void)? = nil) {
        self.defaults = defaults
        applyAppearance = apply ?? { mode in
            NSApplication.shared.appearance = mode.appearanceName.flatMap { NSAppearance(named: $0) }
        }
        mode = defaults.string(forKey: Self.defaultsKey).flatMap(AppearanceMode.init(rawValue:)) ?? .system
        applyAppearance(mode)
    }

    func setMode(_ mode: AppearanceMode) {
        self.mode = mode
    }
}
