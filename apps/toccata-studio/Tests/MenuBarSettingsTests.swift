import XCTest
@testable import toccata_studio

@MainActor
final class MenuBarSettingsTests: XCTestCase {
    func testFreshAndInvalidPreferencesDefaultToTasks() throws {
        let defaults = try fixture()
        XCTAssertEqual(MenuBarSettings(defaults: defaults).defaultPage, .tasks)
        XCTAssertNil(defaults.object(forKey: MenuBarSettings.defaultPageKey))
        defaults.set("removed-page", forKey: MenuBarSettings.defaultPageKey)
        XCTAssertEqual(MenuBarSettings(defaults: defaults).defaultPage, .tasks)
    }

    func testEveryChoiceSurvivesRelaunchAndDeterminesInitialPage() throws {
        let defaults = try fixture()
        let settings = MenuBarSettings(defaults: defaults)
        for page in MenuPanelPage.allCases {
            settings.defaultPage = page
            let restored = MenuBarSettings(defaults: defaults)
            XCTAssertEqual(restored.defaultPage, page)
            XCTAssertEqual(MenuTaskPresentation(settings: restored).page, page)
        }
    }

    func testEveryOpeningUsesConfiguredPageInsteadOfLastVisitedPage() throws {
        let defaults = try fixture()
        let settings = MenuBarSettings(defaults: defaults)
        let presentation = MenuTaskPresentation(settings: settings)
        for configured in MenuPanelPage.allCases {
            settings.defaultPage = configured
            presentation.prepareForOpening()
            XCTAssertEqual(presentation.page, configured)
            XCTAssertTrue(presentation.isMenuVisible)
            presentation.page = configured == .tasks ? .activity : .tasks
            XCTAssertEqual(settings.defaultPage, configured)
            presentation.selectTask("draft", focus: .description)
            presentation.menuDidHide()
            XCTAssertFalse(presentation.isMenuVisible)
            let previousOpening = presentation.openGeneration
            presentation.prepareForOpening()
            XCTAssertNotEqual(presentation.openGeneration, previousOpening)
            XCTAssertEqual(presentation.page, configured)
            XCTAssertNil(presentation.selectedTaskID)
            XCTAssertNil(presentation.focusRequest)
            XCTAssertFalse(presentation.isEditorVisible)
        }
    }

    private func fixture() throws -> UserDefaults {
        let name = "ToccataMenuBarTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }
}
