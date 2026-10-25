import Foundation
import XCTest
@testable import toccata_studio

final class CalendarDateRangeDraftTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    private func date(_ day: Int, month: Int = 10, year: Int = 2026, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func range(_ start: Date, _ end: Date) -> CalendarDateRange {
        CalendarDateRange(start: start, end: end, calendar: calendar)
    }

    func testRangeCannotBeAppliedUntilTheSecondClickAndCanSelectOneDay() {
        var draft = CalendarDateRangeDraft(initialRange: range(date(19), date(25)),
                                          referenceDate: date(26), calendar: calendar)
        XCTAssertNotNil(draft.selectedRange(calendar: calendar))
        XCTAssertTrue(draft.select(date(20, hour: 18), through: date(26), calendar: calendar))
        XCTAssertEqual(draft.start, date(20, hour: 0))
        XCTAssertNil(draft.end)
        XCTAssertNil(draft.selectedRange(calendar: calendar))

        XCTAssertTrue(draft.select(date(20), through: date(26), calendar: calendar))
        XCTAssertEqual(draft.selectedRange(calendar: calendar), range(date(20), date(20)))

        draft.select(date(22), through: date(26), calendar: calendar)
        XCTAssertEqual(draft.start, date(22, hour: 0))
        XCTAssertNil(draft.end, "A new click after a complete range starts a fresh selection")
    }

    func testEarlierSecondClickNormalizesRangeAcrossMonthAndYear() {
        let reference = date(20, month: 1, year: 2027)
        var draft = CalendarDateRangeDraft(initialRange: range(reference, reference),
                                          referenceDate: reference, calendar: calendar)
        draft.select(date(5, month: 1, year: 2027), through: reference, calendar: calendar)
        draft.select(date(28, month: 12), through: reference, calendar: calendar)
        XCTAssertEqual(draft.selectedRange(calendar: calendar),
                       range(date(28, month: 12), date(5, month: 1, year: 2027)))
    }

    func testSingleDayIsImmediatelyCompleteAfterEachClick() {
        var draft = CalendarDateRangeDraft(initialRange: range(date(19), date(25)),
                                          referenceDate: date(26), selectionMode: .singleDay, calendar: calendar)
        XCTAssertEqual(draft.selectedRange(calendar: calendar), range(date(25), date(25)))
        draft.select(date(15), through: date(26), calendar: calendar)
        XCTAssertEqual(draft.selectedRange(calendar: calendar), range(date(15), date(15)))
        draft.select(date(26, hour: 23), through: date(26), calendar: calendar)
        XCTAssertEqual(draft.selectedRange(calendar: calendar), range(date(26), date(26)))
    }

    func testFutureDayLeavesCompleteAndPartialSelectionsUnchanged() {
        for mode in [CalendarDateSelectionMode.range, .singleDay] {
            var draft = CalendarDateRangeDraft(initialRange: range(date(19), date(25)),
                                              referenceDate: date(26), selectionMode: mode, calendar: calendar)
            let complete = draft
            XCTAssertFalse(draft.select(date(27), through: date(26), calendar: calendar))
            XCTAssertEqual(draft, complete)

            draft.select(date(20), through: date(26), calendar: calendar)
            let selected = draft
            XCTAssertFalse(draft.select(date(27), through: date(26), calendar: calendar))
            XCTAssertEqual(draft, selected)
        }
    }

    func testInitialRangeClampsFutureEndpointsToTheCurrentLocalDay() {
        let reference = date(26, hour: 1)
        let partlyFuture = CalendarDateRangeDraft(initialRange: range(date(20), date(30)),
                                                 referenceDate: reference, calendar: calendar)
        XCTAssertEqual(partlyFuture.selectedRange(calendar: calendar), range(date(20), date(26)))
        let entirelyFuture = CalendarDateRangeDraft(initialRange: range(date(29), date(30)),
                                                   referenceDate: reference, calendar: calendar)
        XCTAssertEqual(entirelyFuture.selectedRange(calendar: calendar), range(date(26), date(26)))
    }

    func testFreshDraftRestoresCommittedRangeAfterAnAbandonedSelection() {
        let committed = range(date(19), date(25))
        var abandoned = CalendarDateRangeDraft(initialRange: committed,
                                              referenceDate: date(26), calendar: calendar)
        abandoned.select(date(3), through: date(26), calendar: calendar)
        XCTAssertNil(abandoned.selectedRange(calendar: calendar))
        let reopened = CalendarDateRangeDraft(initialRange: committed,
                                             referenceDate: date(26), calendar: calendar)
        XCTAssertEqual(reopened.selectedRange(calendar: calendar), committed)
    }
}
