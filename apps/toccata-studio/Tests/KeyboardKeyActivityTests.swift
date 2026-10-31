import XCTest
@testable import toccata_studio

final class KeyboardKeyActivityTests: XCTestCase {
    override func setUp() {
        super.setUp()
        let original = L10n.language
        L10n.language = .simplifiedChinese
        addTeardownBlock { L10n.language = original }
    }

    func testTooltipUsesSelectedPeriodTotalAndKeepsCount() {
        let today = KeyboardKeyActivity(count: 9, totalCount: 485, periodDescription: "今天")
        XCTAssertEqual(today.countDescription, "今天按下 9 次")
        XCTAssertEqual(today.percentageDescription, "占总按键 1.9%")
        XCTAssertEqual(today.accessibilityDescription, "今天按下 9 次 · 占总按键 1.9%")
        XCTAssertNil(today.holdDescription)

        let yesterday = KeyboardKeyActivity(count: 9, totalCount: 90, periodDescription: "昨天")
        XCTAssertEqual(yesterday.accessibilityDescription, "昨天按下 9 次 · 占总按键 10%")
        let custom = KeyboardKeyActivity(count: 9, totalCount: 900, periodDescription: "所选时段")
        XCTAssertEqual(custom.accessibilityDescription, "所选时段按下 9 次 · 占总按键 1%")
    }

    func testFnKeepsHoldTimeAlongsideCountAndShare() {
        let fn = KeyboardKeyActivity(count: 2, totalCount: 10, periodDescription: "今天", fnMs: 1_500)
        XCTAssertEqual(fn.accessibilityDescription, "今天按下 2 次 · 占总按键 20% · 今天按住 1.5秒")
    }

    func testEnglishTooltipAndShareLabels() {
        L10n.language = .english
        let activity = KeyboardKeyActivity(count: 1, totalCount: 4, periodDescription: "Yesterday", fnMs: 1_500)
        XCTAssertEqual(activity.accessibilityDescription, "1 presses · Yesterday · 25% of all key presses · Held for 1.5s · Yesterday")
        XCTAssertEqual(L10n.tr("占 \("25%")"), "25% of total")
        XCTAssertEqual(L10n.tr("悬停查看次数与占比 · Fn 同时显示按住时长"),
                       "Hover for counts and shares · Fn also shows hold time")
    }
}
