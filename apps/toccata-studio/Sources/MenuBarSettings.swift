import Combine
import Foundation

enum MenuPanelPage: String, CaseIterable, Identifiable {
    case tasks, calendar, activity

    var id: String { rawValue }
    var workbenchSection: WorkspaceSection {
        switch self {
        case .tasks: return .tasks
        case .calendar: return .taskCalendar
        case .activity: return .activity
        }
    }

    var title: String {
        switch self {
        case .tasks: return L10n.tr("任务管理")
        case .calendar: return L10n.tr("任务日历")
        case .activity: return L10n.tr("活动速览")
        }
    }
}

enum MenuActivityTab: CaseIterable {
    case keyboard, apps
    var title: String {
        // “应用” also labels the Apply action in the date picker.
        self == .keyboard ? L10n.tr("键盘") : (L10n.language == .english ? "Apps" : "应用")
    }
}

@MainActor
final class MenuBarSettings: ObservableObject {
    static let shared = MenuBarSettings()
    static let defaultPageKey = "menuBarDefaultPage"

    @Published var defaultPage: MenuPanelPage {
        didSet {
            guard defaultPage != oldValue else { return }
            defaults.set(defaultPage.rawValue, forKey: Self.defaultPageKey)
        }
    }
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaultPage = defaults.string(forKey: Self.defaultPageKey).flatMap(MenuPanelPage.init(rawValue:)) ?? .tasks
    }
}
