import Combine
import Foundation
import ServiceManagement

/// Only this adapter talks to macOS. Tests inject a service that has no system side effects.
@MainActor
protocol LoginItemServicing: AnyObject {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
    func openSystemSettings()
}

@MainActor
final class SystemLoginItemService: LoginItemServicing {
    var status: SMAppService.Status { SMAppService.mainApp.status }

    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}

/// The system status is the source of truth; no local preference can silently
/// re-enable a login item that the user has disabled in System Settings.
@MainActor
final class LoginItemController: ObservableObject {
    @Published private(set) var status: SMAppService.Status
    @Published var errorMessage: String?

    private let service: LoginItemServicing

    init(service: LoginItemServicing? = nil) {
        let service = service ?? SystemLoginItemService()
        self.service = service
        status = service.status
        // Reading status is intentional. Registration only follows setEnabled(true).
    }

    var enabled: Bool { status == .enabled }
    var requiresApproval: Bool { status == .requiresApproval }

    var statusText: String {
        switch status {
        case .notRegistered:
            return "未开启，登录时不会自动启动"
        case .enabled:
            return "已开启，登录后会在菜单栏运行"
        case .requiresApproval:
            return "需要在系统设置中允许 Toccata 登录启动"
        case .notFound:
            return "系统未找到此应用的登录项"
        @unknown default:
            return "登录启动状态暂不可用"
        }
    }

    func refresh() {
        status = service.status
    }

    func setEnabled(_ requested: Bool) {
        errorMessage = nil
        refresh()
        defer { refresh() }

        do {
            if requested {
                // A registered item awaiting consent must be approved by the user
                // in System Settings. Re-registering cannot provide that consent.
                guard status != .enabled, status != .requiresApproval else { return }
                try service.register()
            } else {
                guard status != .notRegistered, status != .notFound else { return }
                try service.unregister()
            }
        } catch {
            let action = requested ? "开启" : "关闭"
            errorMessage = "无法\(action)登录启动：\(error.localizedDescription)"
        }
    }

    func openSystemSettings() {
        service.openSystemSettings()
    }
}
