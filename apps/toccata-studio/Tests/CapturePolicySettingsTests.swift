import XCTest
@testable import toccata_studio

@MainActor
final class CapturePolicySettingsTests: XCTestCase {
    func testFreshInstallRecordsWithoutCreatingAFile() throws {
        let url = try fixture()
        let settings = CapturePolicySettings(url: url)
        XCTAssertFalse(settings.isPaused)
        XCTAssertNil(settings.pauseStatusText)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testFileMatchesTheContractReadByTheService() throws {
        let url = try fixture()
        let now = Date(timeIntervalSince1970: 1_000)
        let settings = CapturePolicySettings(url: url, now: { now })
        settings.setMode(.redact, for: "com.apple.Terminal")
        settings.pause(.fifteenMinutes)

        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(saved["version"] as? Int, 1)
        XCTAssertEqual((saved["paused_until_ms"] as? NSNumber)?.int64Value, 1_900_000)
        XCTAssertEqual(saved["apps"] as? [String: String], ["com.apple.Terminal": "redact"])
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }

    func testPauseExpiresAndResumeClearsTheDeadline() throws {
        let url = try fixture()
        var now = Date(timeIntervalSince1970: 1_000)
        let settings = CapturePolicySettings(url: url, now: { now })
        settings.pause(.oneHour)
        XCTAssertTrue(settings.isPaused)
        XCTAssertNotNil(settings.pauseStatusText)
        now = now.addingTimeInterval(3_600)
        XCTAssertFalse(settings.isPaused)

        settings.pause(.untilResumed)
        now = now.addingTimeInterval(86_400 * 365)
        XCTAssertTrue(settings.isPaused)
        settings.resume()
        XCTAssertFalse(settings.isPaused)
        XCTAssertNil(CapturePolicySettings(url: url).document.pausedUntilMs)
    }

    func testChangesNotifyTheServiceAndSurviveRelaunch() throws {
        let url = try fixture()
        let settings = CapturePolicySettings(url: url)
        var notifications = 0
        settings.onChange = { notifications += 1 }
        settings.setMode(.ignore, for: "b.app")
        settings.setMode(.redact, for: "a.app")
        XCTAssertEqual(notifications, 2)

        let restored = CapturePolicySettings(url: url)
        XCTAssertEqual(restored.appRules.map(\.app), ["a.app", "b.app"])
        XCTAssertEqual(restored.appRules.map(\.mode), [.redact, .ignore])
        restored.removeRule(for: "a.app")
        XCTAssertEqual(CapturePolicySettings(url: url).appRules.map(\.app), ["b.app"])
    }

    func testUnreadableFileShowsPausedUntilResumeRebuildsIt() throws {
        let url = try fixture()
        for content in ["{broken", #"{"version":2}"#, #"{"version":1,"apps":{"a":"maybe"}}"#] {
            try Data(content.utf8).write(to: url)
            let settings = CapturePolicySettings(url: url)
            XCTAssertTrue(settings.isFileInvalid, content)
            XCTAssertTrue(settings.isPaused, content)
        }
        let settings = CapturePolicySettings(url: url)
        settings.resume()
        XCTAssertFalse(settings.isPaused)
        XCTAssertFalse(CapturePolicySettings(url: url).isFileInvalid)
    }

    func testFailedSaveKeepsThePreviousStateAndReportsIt() throws {
        let directory = try fixture().deletingLastPathComponent()
        let blocker = directory.appendingPathComponent("not-a-directory")
        try Data().write(to: blocker)
        let settings = CapturePolicySettings(url: blocker.appendingPathComponent("capture-policy.json"))
        var notifications = 0
        settings.onChange = { notifications += 1 }

        settings.pause(.oneHour)

        XCTAssertFalse(settings.isPaused, "A pause that was not saved must not appear active")
        XCTAssertNotNil(settings.errorMessage)
        XCTAssertEqual(notifications, 0)
    }

    func testRedactedKeysCountInTotalsButNotPerKey() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let start = ActivityCalculator.milliseconds(now) - 60_000
        let events = [
            ActivityKeyEvent(timestampMs: start, keycode: CapturePolicyDocument.redactedKeycode, kind: 0),
            ActivityKeyEvent(timestampMs: start + 1_000, keycode: 13, kind: 0)
        ]
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let snapshot = ActivityCalculator.snapshot(events: events, range: .today, now: now, calendar: calendar)
        XCTAssertEqual(snapshot.keyCount, 2)
        XCTAssertEqual(snapshot.keyCounts, [13: 1])
        XCTAssertEqual(snapshot.activeMs, 6_000)
    }

    private func fixture() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("capture-policy.json")
    }
}
