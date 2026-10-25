import Foundation
import XCTest
@testable import toccata_studio

final class CalendarDateRangeTests: XCTestCase {
    private func calendar(_ timeZone: String = "Asia/Shanghai") -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZone)!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0,
                      calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    func testReversedDatesNormalizeToInclusiveLocalDays() {
        let calendar = calendar()
        let range = CalendarDateRange(start: date(2026, 10, 25, hour: 20, calendar: calendar),
                                      end: date(2026, 10, 19, hour: 14, calendar: calendar),
                                      calendar: calendar)
        XCTAssertEqual(range.start, date(2026, 10, 19, calendar: calendar))
        XCTAssertEqual(range.end, date(2026, 10, 25, calendar: calendar))
        XCTAssertEqual(range.interval(calendar: calendar).end, date(2026, 10, 26, calendar: calendar))
    }

    func testSingleDayIntervalDoesNotCollapseToZero() {
        let calendar = calendar()
        let day = date(2026, 10, 20, hour: 12, calendar: calendar)
        let interval = CalendarDateRange(start: day, end: day, calendar: calendar).interval(calendar: calendar)
        XCTAssertEqual(interval.start, date(2026, 10, 20, calendar: calendar))
        XCTAssertEqual(interval.end, date(2026, 10, 21, calendar: calendar))
    }

    func testMonthAndYearBoundariesUseTheNextCalendarDate() {
        let calendar = calendar()
        let yearRange = CalendarDateRange(start: date(2026, 12, 31, calendar: calendar),
                                          end: date(2027, 1, 2, calendar: calendar), calendar: calendar)
        XCTAssertEqual(yearRange.interval(calendar: calendar).end, date(2027, 1, 3, calendar: calendar))
        let leapRange = CalendarDateRange(start: date(2028, 1, 31, calendar: calendar),
                                          end: date(2028, 2, 29, calendar: calendar), calendar: calendar)
        XCTAssertEqual(leapRange.interval(calendar: calendar).end, date(2028, 3, 1, calendar: calendar))
    }

    func testDaylightSavingDaysKeepTheirActualDuration() {
        let calendar = calendar("America/Los_Angeles")
        for (month, day, hours) in [(3, 8, 23), (11, 1, 25)] {
            let selected = date(2026, month, day, hour: 12, calendar: calendar)
            let interval = CalendarDateRange(start: selected, end: selected, calendar: calendar)
                .interval(calendar: calendar)
            XCTAssertEqual(interval.duration, Double(hours * 60 * 60))
            XCTAssertEqual(interval.end, date(2026, month, day + 1, calendar: calendar))
        }
    }
}
