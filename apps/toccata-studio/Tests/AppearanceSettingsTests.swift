import AppKit
import XCTest
@testable import toccata_studio

@MainActor
final class AppearanceSettingsTests: XCTestCase {
    override func setUp() {
        super.setUp()
        let original = L10n.language
        L10n.language = .simplifiedChinese
        addTeardownBlock { L10n.language = original }
    }

    func testMissingPreferenceDefaultsToSystemAndAppliesWithoutWriting() throws {
        let defaults = try fixture()
        var applied: [AppearanceMode] = []
        let settings = AppearanceSettings(defaults: defaults, apply: { applied.append($0) })

        XCTAssertEqual(settings.mode, .system)
        XCTAssertEqual(applied, [.system])
        XCTAssertNil(defaults.object(forKey: AppearanceSettings.defaultsKey))
    }

    func testRestoresAndAppliesEachPersistedChoiceAtInitialization() throws {
        let defaults = try fixture()
        for choice in AppearanceMode.allCases {
            defaults.set(choice.rawValue, forKey: AppearanceSettings.defaultsKey)
            var applied: [AppearanceMode] = []
            let settings = AppearanceSettings(defaults: defaults, apply: { applied.append($0) })

            XCTAssertEqual(settings.mode, choice)
            XCTAssertEqual(applied, [choice])
        }
    }

    func testInvalidPreferencesFallBackToSystem() throws {
        let defaults = try fixture()
        let invalidValues: [Any] = ["unknown-mode", "", 42]
        for value in invalidValues {
            defaults.set(value, forKey: AppearanceSettings.defaultsKey)
            var applied: [AppearanceMode] = []
            let settings = AppearanceSettings(defaults: defaults, apply: { applied.append($0) })

            XCTAssertEqual(settings.mode, .system)
            XCTAssertEqual(applied, [.system])
        }
    }

    func testBindingStyleAssignmentPersistsAndAppliesEveryChange() throws {
        let defaults = try fixture()
        var applied: [AppearanceMode] = []
        let settings = AppearanceSettings(defaults: defaults, apply: { applied.append($0) })

        for choice in [AppearanceMode.light, .dark, .system] {
            settings.mode = choice
            XCTAssertEqual(defaults.string(forKey: AppearanceSettings.defaultsKey), choice.rawValue)
        }
        XCTAssertEqual(applied, [.system, .light, .dark, .system])
    }

    func testSetModePersistsChoiceForNextLaunch() throws {
        let defaults = try fixture()
        let settings = AppearanceSettings(defaults: defaults, apply: { _ in })
        settings.setMode(.dark)

        var restored: [AppearanceMode] = []
        let nextLaunch = AppearanceSettings(defaults: defaults, apply: { restored.append($0) })
        XCTAssertEqual(nextLaunch.mode, .dark)
        XCTAssertEqual(restored, [.dark])
    }

    func testSelectingCurrentModeDoesNotApplyAgain() throws {
        let defaults = try fixture()
        var applied: [AppearanceMode] = []
        let settings = AppearanceSettings(defaults: defaults, apply: { applied.append($0) })
        settings.setMode(.system)
        settings.setMode(.light)
        settings.mode = .light

        XCTAssertEqual(applied, [.system, .light])
    }

    func testNamesAndNativeOverridesMatchTheThreeChoices() {
        XCTAssertEqual(AppearanceMode.allCases, [.light, .dark, .system])
        XCTAssertEqual(AppearanceMode.light.title, "月之亮面")
        XCTAssertEqual(AppearanceMode.dark.title, "月之暗面")
        XCTAssertEqual(AppearanceMode.system.title, "跟随系统")
        XCTAssertEqual(AppearanceMode.light.appearanceName, .aqua)
        XCTAssertEqual(AppearanceMode.dark.appearanceName, .darkAqua)
        XCTAssertNil(AppearanceMode.system.appearanceName,
                     "Following the system must remove the app override, not snapshot the current theme")
    }

    private func fixture() throws -> UserDefaults {
        let suiteName = "ToccataAppearanceTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }
}
