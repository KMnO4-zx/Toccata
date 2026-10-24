import Foundation
import XCTest
@testable import toccata_studio

final class TaskCalendarTests: XCTestCase {
    private func calendar(_ zone: String = "Asia/Shanghai") -> Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: zone)!
        value.firstWeekday = 1
        return value
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12,
                      calendar: Calendar? = nil) -> Date {
        (calendar ?? self.calendar()).date(from: DateComponents(year: year, month: month,
                                                               day: day, hour: hour))!
    }

    private func task(_ id: String, created: Date, planned: Date? = nil, completed: Date? = nil,
                      parentID: String? = nil) -> TodoTask {
        TodoTask(id: id, parentID: parentID, title: id, details: "", plannedDate: planned,
                 createdAt: created, updatedAt: completed ?? created, completedAt: completed)
    }

    func testMonthGridStartsMondayAndPadsAcrossMonthBoundaries() {
        let cal = calendar()
        let cells = TaskCalendarModel.days(in: date(2026, 10, 19), calendar: cal)
        XCTAssertEqual(cells.count, 35)
        XCTAssertEqual(cells.first?.date, date(2026, 9, 28, hour: 0))
        XCTAssertEqual(cells.last?.date, date(2026, 11, 1, hour: 0))
        XCTAssertEqual(cal.component(.weekday, from: cells.first!.date), 2)
        XCTAssertEqual(cells.filter(\.isInDisplayedMonth).count, 31)
        XCTAssertEqual(Set(cells.map(\.id)).count, cells.count)
    }

    func testLeapYearAndSixWeekMonthsHaveEveryDayExactlyOnce() {
        let cal = calendar()
        let leap = TaskCalendarModel.days(in: date(2024, 2, 1), calendar: cal)
        XCTAssertEqual(leap.filter(\.isInDisplayedMonth).count, 29)
        XCTAssertTrue(leap.contains { $0.date == date(2024, 2, 29, hour: 0) && $0.isInDisplayedMonth })
        let sixWeeks = TaskCalendarModel.days(in: date(2026, 3, 1), calendar: cal)
        XCTAssertEqual(sixWeeks.count, 42)
        XCTAssertEqual(sixWeeks.first?.date, date(2026, 2, 23, hour: 0))
        XCTAssertEqual(sixWeeks.last?.date, date(2026, 4, 5, hour: 0))
        let fourWeeks = TaskCalendarModel.days(in: date(2021, 2, 1), calendar: cal)
        XCTAssertEqual(fourWeeks.count, 28)
    }

    func testMonthNavigationAvoidsEndOfMonthOverflowAndCrossesYear() {
        let cal = calendar()
        XCTAssertEqual(TaskCalendarModel.month(byAdding: 1, to: date(2024, 1, 31), calendar: cal),
                       date(2024, 2, 1, hour: 0))
        XCTAssertEqual(TaskCalendarModel.month(byAdding: 1, to: date(2026, 12, 31), calendar: cal),
                       date(2027, 1, 1, hour: 0))
        XCTAssertEqual(TaskCalendarModel.month(byAdding: -1, to: date(2027, 1, 31), calendar: cal),
                       date(2026, 12, 1, hour: 0))
    }

    func testDailyModesAndBadgesKeepCreationPlanningAndCompletionDistinct() {
        let cal = calendar()
        let selected = date(2026, 10, 19)
        let previous = date(2026, 10, 1)
        let tasks = [
            task("created", created: selected),
            task("planned", created: previous, planned: selected),
            task("completed", created: previous, completed: selected),
            task("all-three", created: selected, planned: selected, completed: selected),
            task("other", created: previous, planned: date(2026, 10, 20)),
            task("child", created: selected, parentID: "other")
        ]
        XCTAssertEqual(Set(TaskCalendarModel.tasks(on: selected, from: tasks, mode: .created, calendar: cal).map(\.id)),
                       Set(["created", "all-three", "child"]))
        XCTAssertEqual(Set(TaskCalendarModel.tasks(on: selected, from: tasks, mode: .planned, calendar: cal).map(\.id)),
                       Set(["planned", "all-three"]))
        XCTAssertEqual(Set(TaskCalendarModel.tasks(on: selected, from: tasks, mode: .completed, calendar: cal).map(\.id)),
                       Set(["completed", "all-three"]))
        let all = TaskCalendarModel.tasks(on: selected, from: tasks, mode: .all, calendar: cal)
        XCTAssertEqual(all.count, 5, "A task with three same-day events appears once")
        XCTAssertEqual(all.prefix(3).map(\.isCompleted), [false, false, false])
        XCTAssertEqual(TaskCalendarModel.eventCounts(on: selected, from: tasks, calendar: cal),
                       TaskCalendarEventCounts(created: 3, planned: 2, completed: 2))
    }

    func testUnscheduledTasksRemainUndatedIncludingCompletedItems() {
        let created = date(2026, 10, 1)
        let tasks = [task("open", created: created),
                     task("done", created: created, completed: date(2026, 10, 19)),
                     task("plan", created: created, planned: date(2026, 11, 1))]
        XCTAssertEqual(TaskCalendarModel.unscheduledTasks(from: tasks).map(\.id), ["open", "done"])
        XCTAssertTrue(TaskCalendarModel.unscheduledTasks(from: tasks).allSatisfy { $0.plannedDate == nil })
        XCTAssertTrue(TaskCalendarModel.tasks(on: date(2026, 10, 19), from: tasks, mode: .planned,
                                               calendar: calendar()).isEmpty)
    }

    func testLocalMidnightCanBelongToDifferentUTCDay() {
        let shanghai = calendar()
        let utc = calendar("UTC")
        let timestamp = date(2026, 10, 19, hour: 0)
        let tasks = [task("midnight", created: timestamp, planned: timestamp, completed: timestamp)]
        XCTAssertEqual(TaskCalendarModel.tasks(on: date(2026, 10, 19), from: tasks,
                                               mode: .all, calendar: shanghai).count, 1)
        XCTAssertEqual(TaskCalendarModel.tasks(on: date(2026, 10, 19, calendar: utc), from: tasks,
                                               mode: .all, calendar: utc).count, 0)
        XCTAssertEqual(TaskCalendarModel.tasks(on: date(2026, 10, 18, calendar: utc), from: tasks,
                                               mode: .all, calendar: utc).count, 1)
    }

    func testDaylightSavingGridUsesCalendarDaysAndKeepsMidnight() {
        let cal = calendar("America/Los_Angeles")
        let cells = TaskCalendarModel.days(in: date(2026, 3, 15, calendar: cal), calendar: cal)
        XCTAssertEqual(cells.filter(\.isInDisplayedMonth).count, 31)
        XCTAssertTrue(cells.allSatisfy { cal.component(.hour, from: $0.date) == 0 })
        for pair in zip(cells, cells.dropFirst()) {
            XCTAssertEqual(cal.dateComponents([.day], from: pair.0.date, to: pair.1.date).day, 1)
        }
        let before = date(2026, 3, 8, hour: 0, calendar: cal)
        let after = date(2026, 3, 9, hour: 0, calendar: cal)
        XCTAssertEqual(after.timeIntervalSince(before), 23 * 60 * 60)
        let event = task("late-night", created: date(2026, 3, 8, hour: 23, calendar: cal))
        XCTAssertEqual(TaskCalendarModel.tasks(on: before, from: [event], mode: .created, calendar: cal).count, 1)
        XCTAssertEqual(TaskCalendarModel.tasks(on: after, from: [event], mode: .created, calendar: cal).count, 0)
    }
}
