import XCTest
@testable import toccata_studio

@MainActor
final class DockIconSettingsTests: XCTestCase {
    func testFreshInstallShowsDockIconWithoutWritingPreference() throws {
        let defaults = try fixture()
        var applied: [Bool] = []
        let settings = DockIconSettings(defaults: defaults, apply: { applied.append($0); return true })
        XCTAssertFalse(settings.isHidden)
        XCTAssertTrue(applied.isEmpty, "Policy must be applied only after the menu bar is ready")
        settings.applySavedPreference()
        XCTAssertEqual(applied, [false])
        XCTAssertNil(defaults.object(forKey: DockIconSettings.defaultsKey))
    }

    func testBothChoicesApplyImmediatelyAndSurviveRelaunch() throws {
        let defaults = try fixture()
        var applied: [Bool] = []
        let settings = DockIconSettings(defaults: defaults, apply: { applied.append($0); return true })
        for hidden in [true, false] {
            settings.setHidden(hidden)
            XCTAssertEqual(settings.isHidden, hidden)
            XCTAssertEqual(defaults.bool(forKey: DockIconSettings.defaultsKey), hidden)
            var restored: [Bool] = []
            let nextLaunch = DockIconSettings(defaults: defaults, apply: { restored.append($0); return true })
            nextLaunch.applySavedPreference()
            XCTAssertEqual(nextLaunch.isHidden, hidden)
            XCTAssertEqual(restored, [hidden])
        }
        XCTAssertEqual(applied, [true, false])
    }

    func testFailedChangeKeepsPreviousChoiceAndCanBeRetried() throws {
        let defaults = try fixture()
        var succeeds = false
        let settings = DockIconSettings(defaults: defaults, apply: { _ in succeeds })
        settings.setHidden(true)
        XCTAssertFalse(settings.isHidden)
        XCTAssertNil(defaults.object(forKey: DockIconSettings.defaultsKey))
        XCTAssertNotNil(settings.errorMessage)
        succeeds = true
        settings.setHidden(true)
        XCTAssertTrue(settings.isHidden)
        XCTAssertTrue(defaults.bool(forKey: DockIconSettings.defaultsKey))
        XCTAssertNil(settings.errorMessage)
    }

    private func fixture() throws -> UserDefaults {
        let name = "ToccataDockIconTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }
}
