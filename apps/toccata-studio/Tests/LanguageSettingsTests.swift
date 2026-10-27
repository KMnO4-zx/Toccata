import XCTest
@testable import toccata_studio

final class LanguageSettingsTests: XCTestCase {
    @MainActor
    func testAnimatedSelectionPublishesAfterFadeOutAndRestoresVisibility() async throws {
        let original = L10n.language
        let name = "Toccata.LanguageTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name); L10n.language = original }
        let settings = LanguageSettings(defaults: defaults, preferredLanguages: ["zh-Hans"])

        settings.select(.english, reduceMotion: false)
        XCTAssertEqual(settings.language, .simplifiedChinese)
        XCTAssertNil(defaults.string(forKey: LanguageSettings.defaultsKey))
        XCTAssertEqual(settings.contentOpacity, 0)

        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(settings.language, .english)
        XCTAssertEqual(defaults.string(forKey: LanguageSettings.defaultsKey), "en")
        XCTAssertEqual(settings.contentOpacity, 1)
    }

    @MainActor
    func testNewSelectionCancelsPendingLanguageChange() async throws {
        let original = L10n.language
        let name = "Toccata.LanguageTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name); L10n.language = original }
        let settings = LanguageSettings(defaults: defaults, preferredLanguages: ["zh-Hans"])

        settings.select(.english, reduceMotion: false)
        settings.select(.simplifiedChinese, reduceMotion: false)
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(settings.language, .simplifiedChinese)
        XCTAssertEqual(settings.contentOpacity, 1)
        XCTAssertNil(defaults.string(forKey: LanguageSettings.defaultsKey))
    }

    @MainActor
    func testReducedMotionSwitchesImmediatelyAndCancelsPendingTransition() async throws {
        let original = L10n.language
        let name = "Toccata.LanguageTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name); L10n.language = original }
        let settings = LanguageSettings(defaults: defaults, preferredLanguages: ["zh-Hans"])

        settings.select(.english, reduceMotion: true)
        XCTAssertEqual(settings.language, .english)
        XCTAssertEqual(settings.contentOpacity, 1)
        settings.select(.simplifiedChinese, reduceMotion: false)
        settings.select(.english, reduceMotion: true)
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(settings.language, .english)
        XCTAssertEqual(settings.contentOpacity, 1)
        XCTAssertEqual(defaults.string(forKey: LanguageSettings.defaultsKey), "en")
    }

    func testFirstLaunchUsesSystemLanguageAndSavedChoiceWins() {
        XCTAssertEqual(AppLanguage.resolve(saved: nil, preferredLanguages: ["zh-Hant-TW", "en"]), .simplifiedChinese)
        XCTAssertEqual(AppLanguage.resolve(saved: nil, preferredLanguages: ["en-GB", "zh-Hans"]), .english)
        XCTAssertEqual(AppLanguage.resolve(saved: nil, preferredLanguages: ["fr-FR"]), .english)
        XCTAssertEqual(AppLanguage.resolve(saved: "zh-Hans", preferredLanguages: ["en"]), .simplifiedChinese)
        XCTAssertEqual(AppLanguage.resolve(saved: "removed-value", preferredLanguages: ["zh-Hans"]), .simplifiedChinese)
    }

    func testPreferencePersistsAndPublishesWithoutChangingOtherPreferences() {
        let original = L10n.language
        let name = "Toccata.LanguageTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name); L10n.language = original }
        defaults.set("dark", forKey: "appearanceMode")
        let settings = LanguageSettings(defaults: defaults, preferredLanguages: ["zh-Hans"])
        let notification = expectation(forNotification: LanguageSettings.didChange, object: nil)
        settings.language = .english
        wait(for: [notification], timeout: 1)
        XCTAssertEqual(L10n.language, .english)
        XCTAssertEqual(defaults.string(forKey: LanguageSettings.defaultsKey), "en")
        XCTAssertEqual(defaults.string(forKey: "appearanceMode"), "dark")
        XCTAssertEqual(LanguageSettings(defaults: defaults, preferredLanguages: ["zh-Hans"]).language, .english)
    }

    func testCatalogPlaceholdersMatchAndTranslationsAreNotEmpty() throws {
        XCTAssertGreaterThan(L10n.english.count, 450, "The translation resource must be bundled")
        let regex = try NSRegularExpression(pattern: #"\{[0-9]+\}"#)
        func placeholders(_ text: String) -> [String] {
            let ns = text as NSString
            return regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
                .map { ns.substring(with: $0.range) }.sorted()
        }
        for (source, translated) in L10n.english {
            XCTAssertFalse(translated.isEmpty, source)
            XCTAssertEqual(placeholders(source), placeholders(translated), source)
        }
    }

    func testInterpolationPreservesUserTextAndSupportsReorderedArguments() {
        let userText = "任务 {0} {1} 100% 🌓\nDetails"
        XCTAssertEqual(L10n.render(key: "完成{0}", arguments: [userText], language: .english), "Complete: " + userText)
        XCTAssertEqual(L10n.render(key: "{0}按住 {1}", arguments: ["Today", "12s"], language: .english), "Held for 12s · Today")
        XCTAssertEqual(L10n.render(key: "完成{0}", arguments: [userText], language: .simplifiedChinese), "完成" + userText)
    }

    func testSwitchingLocalizesModelsAndDurationsWithoutChangingRangeIdentity() {
        let original = L10n.language
        defer { L10n.language = original }
        let range = ActivityRange.lastSevenDays
        let now = Date(timeIntervalSince1970: 1_793_000_000)
        let interval = range.interval(now: now, calendar: .current)
        L10n.language = .english
        XCTAssertEqual(range.rawValue, "Last 7 days")
        XCTAssertEqual(Formatters.duration(ms: 362_700), "362.7s")
        XCTAssertEqual(Formatters.duration(ms: 636_000), "10m 36s")
        XCTAssertEqual(Formatters.duration(ms: 5_772_000), "1h 36m 12s")
        XCTAssertEqual(KeyboardLayout.magicKeyboard.keys.first { $0.code == 49 }?.readableLabel, "Space")
        XCTAssertEqual(MenuTaskScope.thisWeek.title, "This week's tasks")
        L10n.language = .simplifiedChinese
        XCTAssertEqual(range.rawValue, "最近 7 天")
        XCTAssertEqual(Formatters.duration(ms: 636_000), "10分36秒")
        XCTAssertEqual(interval, range.interval(now: now, calendar: .current))
        XCTAssertEqual(TaskReviewPeriod.thisWeek.rawValue, "本周")
    }

    func testReviewExportChangesLanguageButKeepsTaskContent() {
        let original = L10n.language
        defer { L10n.language = original }
        L10n.language = .simplifiedChinese
        let date = Date()
        let task = TodoTask(id: "localized-content", parentID: nil, title: "任务", details: "Keep 原文\n\n",
                            plannedDate: nil, createdAt: date, updatedAt: date, completedAt: nil)
        let snapshot = TaskReviewSnapshot(tasks: [task], period: .thisWeek, referenceDate: date)
        XCTAssertTrue(snapshot.markdown.contains("本周任务回顾"))
        L10n.language = .english
        XCTAssertTrue(snapshot.markdown.contains("Weekly task review"))
        XCTAssertFalse(snapshot.markdown.contains("本周任务回顾"))
        XCTAssertTrue(snapshot.markdown.contains("- [ ] 任务"))
        XCTAssertTrue(snapshot.markdown.contains("Keep 原文"))
    }
}
