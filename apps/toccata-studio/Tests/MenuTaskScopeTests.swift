import Foundation
import XCTest
@testable import toccata_studio

@MainActor
final class MenuTaskScopeTests: XCTestCase {
    private final class Clock {
        var date: Date
        init(_ date: Date) { self.date = date }
    }

    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        value.firstWeekday = 1
        return value
    }

    private func date(_ day: Int, hour: Int = 12, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day,
                                           hour: hour, minute: minute))!
    }

    private func fixture(at date: Date) throws -> (TaskStore, Clock) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ToccataMenuScope-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let clock = Clock(date)
        let store = TaskStore(databaseURL: directory.appendingPathComponent("tasks.sqlite"),
                              calendar: calendar, now: { clock.date }, completionFeedback: {})
        XCTAssertNil(store.errorMessage)
        return (store, clock)
    }

    private func visible(_ scope: MenuTaskScope, store: TaskStore, at date: Date) -> [TodoTask] {
        store.menuTasks(for: scope, relativeTo: date, calendar: calendar)
    }

    func testInboxRetainsUndatedPlannedAndCompletedParents() async throws {
        let (store, clock) = try fixture(at: date(1))
        let undated = try XCTUnwrap(store.addTask(title: "以后有空再做"))
        clock.date = date(2)
        let pastPlan = try XCTUnwrap(store.addTask(title: "计划日期已过", plannedDate: date(3)))
        clock.date = date(3)
        let futurePlan = try XCTUnwrap(store.addTask(title: "未来计划", plannedDate: date(30)))
        clock.date = date(4)
        let todayPlan = try XCTUnwrap(store.addTask(title: "今天计划", plannedDate: date(19)))
        clock.date = date(5)
        _ = try XCTUnwrap(store.addTask(title: "未完成子任务", parentID: undated))
        clock.date = date(6)
        let completed = try XCTUnwrap(store.addTask(title: "已经完成"))
        XCTAssertTrue(store.setCompleted(id: completed, completed: true))

        let inbox = visible(.inbox, store: store, at: date(19))
        XCTAssertEqual(inbox.map(\.id), [todayPlan, futurePlan, pastPlan, undated, completed])
        XCTAssertTrue(inbox.allSatisfy { $0.parentID == nil })
        XCTAssertNil(store.task(id: undated)?.plannedDate)
    }

    func testLastSevenDaysUsesLocalCreationDateIncludingCompletedTasks() async throws {
        let reference = date(19)
        let (store, clock) = try fixture(at: date(12, hour: 23, minute: 59))
        let olderButFinishedToday = try XCTUnwrap(store.addTask(title: "窗口之前创建"))
        clock.date = date(13, hour: 0)
        let atStart = try XCTUnwrap(store.addTask(title: "七天起点创建"))
        clock.date = date(18)
        let completed = try XCTUnwrap(store.addTask(title: "最近创建且已完成"))
        XCTAssertTrue(store.setCompleted(id: completed, completed: true))
        clock.date = reference
        let atEnd = try XCTUnwrap(store.addTask(title: "当前时刻创建"))
        XCTAssertTrue(store.setCompleted(id: olderButFinishedToday, completed: true))
        clock.date = date(19, hour: 12, minute: 1)
        _ = try XCTUnwrap(store.addTask(title: "未来创建不能出现在窗口"))

        XCTAssertEqual(visible(.lastSevenDays, store: store, at: reference).map(\.id),
                       [atEnd, atStart, completed])
        XCTAssertEqual(store.completedTasks(in: .lastSevenDays, relativeTo: reference).map(\.id),
                       [olderButFinishedToday, completed],
                       "Completion review keeps its independent completion-time semantics")
    }

    func testThisWeekIncludesCarryoverNewAndActuallyCompletedTasks() async throws {
        let reference = date(22)
        let (store, clock) = try fixture(at: date(1))
        let carryover = try XCTUnwrap(store.addTask(title: "长期未安排"))
        let plannedLater = try XCTUnwrap(store.addTask(title: "之前创建未来计划", plannedDate: date(30)))
        let oldDone = try XCTUnwrap(store.addTask(title: "之前已完成"))
        let finishedThisWeek = try XCTUnwrap(store.addTask(title: "旧任务本周完成"))
        let futureCompletion = try XCTUnwrap(store.addTask(title: "未来完成时间不能当本周完成"))
        clock.date = date(18, hour: 23, minute: 59)
        XCTAssertTrue(store.setCompleted(id: oldDone, completed: true))
        clock.date = date(19, hour: 0)
        XCTAssertTrue(store.setCompleted(id: finishedThisWeek, completed: true))
        let mondayCreated = try XCTUnwrap(store.addTask(title: "周一创建"))
        clock.date = date(21)
        let newCompleted = try XCTUnwrap(store.addTask(title: "本周创建并完成"))
        XCTAssertTrue(store.setCompleted(id: newCompleted, completed: true))
        clock.date = date(22, hour: 12, minute: 1)
        _ = try XCTUnwrap(store.addTask(title: "未来创建"))
        XCTAssertTrue(store.setCompleted(id: futureCompletion, completed: true))

        let result = visible(.thisWeek, store: store, at: reference)
        XCTAssertEqual(Set(result.map(\.id)), Set([carryover, plannedLater, finishedThisWeek,
                                                 mondayCreated, newCompleted]))
        XCTAssertEqual(result.prefix(3).map(\.isCompleted), [false, false, false])
        XCTAssertNil(store.task(id: carryover)?.plannedDate)
    }

    func testTimeViewsIncludeMatchingChildrenAndParentContextRemainsAvailable() async throws {
        let (store, clock) = try fixture(at: date(1))
        let parent = try XCTUnwrap(store.addTask(title: "之前创建的项目"))
        let oldChild = try XCTUnwrap(store.addTask(title: "之前创建本周完成的步骤", parentID: parent))
        clock.date = date(19, hour: 10)
        XCTAssertTrue(store.setCompleted(id: oldChild, completed: true))
        clock.date = date(19, hour: 11)
        let recentChild = try XCTUnwrap(store.addTask(title: "新建未完成步骤", parentID: parent))

        XCTAssertEqual(visible(.lastSevenDays, store: store, at: date(19)).map(\.id), [recentChild])
        XCTAssertEqual(visible(.thisWeek, store: store, at: date(19)).map(\.id),
                       [recentChild, parent, oldChild])
        XCTAssertEqual(store.task(id: recentChild)?.parentID, parent)
        XCTAssertEqual(visible(.inbox, store: store, at: date(19)).map(\.id), [parent])
    }

    func testMondayStartsNewWeekButRetainsOldUnfinishedTasks() async throws {
        let (store, clock) = try fixture(at: date(18, hour: 23, minute: 59))
        let unfinished = try XCTUnwrap(store.addTask(title: "周日创建未完成"))
        let doneOnSunday = try XCTUnwrap(store.addTask(title: "周日完成"))
        XCTAssertTrue(store.setCompleted(id: doneOnSunday, completed: true))
        clock.date = date(19, hour: 0)
        let monday = try XCTUnwrap(store.addTask(title: "周一零点创建"))

        XCTAssertEqual(visible(.thisWeek, store: store, at: clock.date).map(\.id), [monday, unfinished])
        XCTAssertEqual(Set(visible(.lastSevenDays, store: store, at: clock.date).map(\.id)),
                       Set([monday, unfinished, doneOnSunday]))
    }

    func testEditingAndCompletingNeverMovesCreationDateOrAssignsPlanDate() async throws {
        let (store, clock) = try fixture(at: date(1))
        let id = try XCTUnwrap(store.addTask(title: "最初想法"))
        clock.date = date(19)
        XCTAssertTrue(store.updateTask(id: id, title: "补充后的任务", details: "写进度", plannedDate: nil))
        XCTAssertTrue(store.setCompleted(id: id, completed: true))
        _ = visible(.thisWeek, store: store, at: clock.date)
        _ = visible(.lastSevenDays, store: store, at: clock.date)
        XCTAssertTrue(store.reload())
        XCTAssertEqual(store.task(id: id)?.createdAt, date(1))
        XCTAssertNil(store.task(id: id)?.plannedDate)
        XCTAssertEqual(visible(.lastSevenDays, store: store, at: clock.date), [])
        XCTAssertEqual(visible(.thisWeek, store: store, at: clock.date).map(\.id), [id])
    }

    func testCreationWindowUsesSuppliedTimeZoneInsteadOfUTCDate() async throws {
        let created = date(13, hour: 0)
        let task = TodoTask(id: "boundary", parentID: nil, title: "本地零点", details: "",
                            plannedDate: nil, createdAt: created, updatedAt: created, completedAt: nil)
        XCTAssertEqual(MenuTaskScope.lastSevenDays.tasks(from: [task], relativeTo: date(19),
                                                         calendar: calendar).map(\.id), ["boundary"])
        var utc = calendar
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        XCTAssertEqual(MenuTaskScope.lastSevenDays.tasks(from: [task], relativeTo: date(19), calendar: utc), [])
    }
}
