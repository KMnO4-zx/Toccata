import Foundation
import ServiceManagement
import XCTest
@testable import toccata_studio

@MainActor
final class LoginItemControllerTests: XCTestCase {
    override func setUp() {
        super.setUp()
        let original = L10n.language
        L10n.language = .simplifiedChinese
        addTeardownBlock { L10n.language = original }
    }

    private final class FakeService: LoginItemServicing {
        var status: SMAppService.Status
        var registeredStatus: SMAppService.Status?
        var unregisteredStatus: SMAppService.Status?
        var registerError: Error?
        var unregisterError: Error?
        private(set) var registerCount = 0
        private(set) var unregisterCount = 0
        private(set) var settingsCount = 0

        init(status: SMAppService.Status = .notRegistered) { self.status = status }

        func register() throws {
            registerCount += 1
            if let registeredStatus { status = registeredStatus }
            if let registerError { throw registerError }
        }

        func unregister() throws {
            unregisterCount += 1
            if let unregisteredStatus { status = unregisteredStatus }
            if let unregisterError { throw unregisterError }
        }

        func openSystemSettings() { settingsCount += 1 }
    }

    private var denied: Error {
        NSError(domain: "LoginItemTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "用户未授权"])
    }

    func testInitialStatusNeverRegistersOrOpensSettings() async {
        for status in [SMAppService.Status.notRegistered, .enabled, .requiresApproval, .notFound] {
            let service = FakeService(status: status)
            let controller = LoginItemController(service: service)
            XCTAssertEqual(controller.status, status)
            XCTAssertEqual(controller.enabled, status == .enabled)
            XCTAssertEqual(controller.requiresApproval, status == .requiresApproval)
            XCTAssertFalse(controller.statusText.isEmpty)
            XCTAssertNil(controller.errorMessage)
            XCTAssertEqual(service.registerCount, 0)
            XCTAssertEqual(service.unregisterCount, 0)
            XCTAssertEqual(service.settingsCount, 0)
        }
    }

    func testExplicitEnableRegistersAndReadsResultingSystemStatus() async {
        let service = FakeService()
        service.registeredStatus = .enabled
        let controller = LoginItemController(service: service)
        controller.setEnabled(true)
        XCTAssertEqual(service.registerCount, 1)
        XCTAssertTrue(controller.enabled)
        XCTAssertFalse(controller.requiresApproval)
        XCTAssertNil(controller.errorMessage)
    }

    func testSuccessfulRegisterDoesNotInventEnabledStatus() async {
        let service = FakeService()
        let controller = LoginItemController(service: service)
        controller.setEnabled(true)
        XCTAssertEqual(service.registerCount, 1)
        XCTAssertFalse(controller.enabled)
        XCTAssertEqual(controller.status, .notRegistered)
    }

    func testApprovalRequiredIsDistinctFromEnabledAndDoesNotReregister() async {
        let service = FakeService()
        service.registeredStatus = .requiresApproval
        let controller = LoginItemController(service: service)
        controller.setEnabled(true)
        XCTAssertFalse(controller.enabled)
        XCTAssertTrue(controller.requiresApproval)
        XCTAssertTrue(controller.statusText.contains("系统设置"))
        controller.setEnabled(true)
        XCTAssertEqual(service.registerCount, 1)
        XCTAssertEqual(service.settingsCount, 0)
    }

    func testDisableRemovesEnabledOrApprovalPendingRegistration() async {
        for status in [SMAppService.Status.enabled, .requiresApproval] {
            let service = FakeService(status: status)
            service.unregisteredStatus = .notRegistered
            let controller = LoginItemController(service: service)
            controller.setEnabled(false)
            XCTAssertEqual(service.unregisterCount, 1)
            XCTAssertEqual(controller.status, .notRegistered)
            XCTAssertFalse(controller.enabled)
            XCTAssertFalse(controller.requiresApproval)
        }
    }

    func testAlreadyRequestedStateDoesNotCallRegistrationAPI() async {
        let enabledService = FakeService(status: .enabled)
        let enabledController = LoginItemController(service: enabledService)
        enabledController.setEnabled(true)
        XCTAssertEqual(enabledService.registerCount, 0)
        let disabledService = FakeService(status: .notRegistered)
        let disabledController = LoginItemController(service: disabledService)
        disabledController.setEnabled(false)
        XCTAssertEqual(disabledService.unregisterCount, 0)
    }

    func testRefreshAndSetEnabledReadExternalChangesWithoutRestoringLocalPreference() async {
        let service = FakeService(status: .enabled)
        let controller = LoginItemController(service: service)
        service.status = .requiresApproval
        controller.refresh()
        XCTAssertFalse(controller.enabled)
        XCTAssertTrue(controller.requiresApproval)
        XCTAssertEqual(service.registerCount, 0)
        service.status = .enabled
        controller.setEnabled(true)
        XCTAssertTrue(controller.enabled)
        XCTAssertEqual(service.registerCount, 0)
    }

    func testRegistrationFailureShowsErrorAndStillRefreshesSystemStatus() async {
        let service = FakeService()
        service.registerError = denied
        service.registeredStatus = .requiresApproval
        let controller = LoginItemController(service: service)
        controller.setEnabled(true)
        XCTAssertFalse(controller.enabled)
        XCTAssertTrue(controller.requiresApproval)
        XCTAssertEqual(controller.errorMessage, "无法开启登录启动：用户未授权")
        controller.errorMessage = nil
        XCTAssertNil(controller.errorMessage)
    }

    func testUnregisterFailureKeepsActualEnabledStateAndCanBeRetried() async {
        let service = FakeService(status: .enabled)
        service.unregisterError = denied
        let controller = LoginItemController(service: service)
        controller.setEnabled(false)
        XCTAssertTrue(controller.enabled)
        XCTAssertEqual(controller.errorMessage, "无法关闭登录启动：用户未授权")
        service.unregisterError = nil
        service.unregisteredStatus = .notRegistered
        controller.setEnabled(false)
        XCTAssertFalse(controller.enabled)
        XCTAssertNil(controller.errorMessage)
        XCTAssertEqual(service.unregisterCount, 2)
    }

    func testOpenSettingsIsExplicitAndDoesNotRegister() async {
        let service = FakeService(status: .requiresApproval)
        let controller = LoginItemController(service: service)
        controller.openSystemSettings()
        XCTAssertEqual(service.settingsCount, 1)
        XCTAssertEqual(service.registerCount, 0)
        XCTAssertEqual(service.unregisterCount, 0)
    }
}
