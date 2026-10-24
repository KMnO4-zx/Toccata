import Foundation
import SQLite3
import XCTest
@testable import toccata_studio

@MainActor
final class TaskStoreTests: XCTestCase {
    private final class Clock {
        var date: Date
        init(_ date: Date) { self.date = date }
    }

    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        // A Sunday-first system preference must not change the Monday review boundary.
        value.firstWeekday = 1
        return value
    }

    private func date(_ day: Int, year: Int = 2026, month: Int = 10,
                      hour: Int = 12, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func fixture(at date: Date,
                         completionFeedback: @escaping () -> Void = {}) throws -> (TaskStore, Clock, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ToccataTasks-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("tasks.sqlite")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let clock = Clock(date)
        let store = TaskStore(databaseURL: url, calendar: calendar, now: { clock.date },
                              completionFeedback: completionFeedback)
        XCTAssertNil(store.errorMessage)
        return (store, clock, url)
    }

    func testNewTaskStaysUndatedAndPersistsInInbox() async throws {
        let (store, _, url) = try fixture(at: date(19))
        let id = try XCTUnwrap(store.addTask(title: "  想到再做的事情  "))
        let task = try XCTUnwrap(store.task(id: id))
        XCTAssertEqual(task.title, "想到再做的事情")
        XCTAssertNil(task.parentID)
        XCTAssertNil(task.plannedDate)
        XCTAssertNil(task.completedAt)
        XCTAssertEqual(store.children(of: nil).map(\.id), [id])
        let restored = TaskStore(databaseURL: url)
        XCTAssertEqual(restored.task(id: id), task)
    }

    func testPlannedDateIsOptionalAndCanBeRemovedWithoutChangingCreationTime() async throws {
        let (store, clock, _) = try fixture(at: date(19))
        let id = try XCTUnwrap(store.addTask(title: "周报", details: "整理实验", plannedDate: date(23)))
        clock.date = date(20)
        XCTAssertTrue(store.updateTask(id: id, title: "周报 v2", details: "不急，先记录", plannedDate: nil))
        let task = try XCTUnwrap(store.task(id: id))
        XCTAssertNil(task.plannedDate)
        XCTAssertEqual(task.createdAt, date(19))
        XCTAssertEqual(task.updatedAt, date(20))
        XCTAssertEqual(task.details, "不急，先记录")
    }

    func testCompletingParentCascadesAndPreservesEarlierChildCompletionTime() async throws {
        let (store, clock, url) = try fixture(at: date(15))
        let parent = try XCTUnwrap(store.addTask(title: "项目"))
        let child = try XCTUnwrap(store.addTask(title: "调研", parentID: parent))
        let grandchild = "legacy-grandchild"
        try insertLegacyTask(id: grandchild, parentID: child, title: "读论文", createdAt: date(15), at: url)
        XCTAssertTrue(store.reload())
        XCTAssertTrue(store.setCompleted(id: grandchild, completed: true))
        clock.date = date(19)
        XCTAssertTrue(store.setCompleted(id: parent, completed: true))
        XCTAssertEqual(store.task(id: parent)?.completedAt, date(19))
        XCTAssertEqual(store.task(id: child)?.completedAt, date(19))
        XCTAssertEqual(store.task(id: grandchild)?.completedAt, date(15))
        let restored = TaskStore(databaseURL: url)
        XCTAssertEqual(restored.tasks, store.tasks)
        clock.date = date(20)
        XCTAssertTrue(store.setCompleted(id: parent, completed: true))
        XCTAssertEqual(store.task(id: parent)?.completedAt, date(19), "Repeated completion must not move history")
    }

    func testReopeningDescendantClearsItsCompletionAndAllAncestors() async throws {
        let (store, clock, url) = try fixture(at: date(19))
        let parent = try XCTUnwrap(store.addTask(title: "父任务"))
        let child = try XCTUnwrap(store.addTask(title: "子任务", parentID: parent))
        let grandchild = "legacy-grandchild"
        try insertLegacyTask(id: grandchild, parentID: child, title: "孙任务", createdAt: date(19), at: url)
        XCTAssertTrue(store.reload())
        XCTAssertTrue(store.setCompleted(id: parent, completed: true))
        clock.date = date(20)
        XCTAssertTrue(store.setCompleted(id: child, completed: false))
        XCTAssertNil(store.task(id: parent)?.completedAt)
        XCTAssertNil(store.task(id: child)?.completedAt)
        XCTAssertEqual(store.task(id: grandchild)?.completedAt, date(19))
        XCTAssertTrue(store.setCompleted(id: child, completed: true))
        XCTAssertEqual(store.task(id: child)?.completedAt, date(20))
        XCTAssertNil(store.task(id: parent)?.completedAt, "Completing children does not silently complete their parent")
    }

    func testAddingUnfinishedChildReopensCompletedParent() async throws {
        let (store, _, _) = try fixture(at: date(19))
        let parent = try XCTUnwrap(store.addTask(title: "父任务"))
        let child = try XCTUnwrap(store.addTask(title: "子任务", parentID: parent))
        XCTAssertTrue(store.setCompleted(id: parent, completed: true))
        let newChild = try XCTUnwrap(store.addTask(title: "补充一个步骤", parentID: parent))
        XCTAssertNil(store.task(id: parent)?.completedAt)
        XCTAssertEqual(store.task(id: child)?.completedAt, date(19))
        XCTAssertEqual(store.task(id: newChild)?.parentID, parent)
    }

    func testSubtasksCannotHaveChildren() async throws {
        let (store, _, url) = try fixture(at: date(19))
        let parent = try XCTUnwrap(store.addTask(title: "父任务"))
        let child = try XCTUnwrap(store.addTask(title: "子任务", parentID: parent))
        let original = store.tasks

        XCTAssertNil(store.addTask(title: "不允许的孙任务", parentID: child))
        XCTAssertEqual(store.errorMessage, "子任务下不能再创建子任务。")
        XCTAssertEqual(store.tasks, original)
        XCTAssertEqual(TaskStore(databaseURL: url).tasks, original)
    }

    func testCompletionFeedbackPlaysOnlyForSuccessfulTransitionsToCompleted() async throws {
        var playCount = 0
        let (store, _, url) = try fixture(at: date(19), completionFeedback: { playCount += 1 })
        let parent = try XCTUnwrap(store.addTask(title: "父任务"))
        _ = try XCTUnwrap(store.addTask(title: "子任务", parentID: parent))

        XCTAssertTrue(store.setCompleted(id: parent, completed: true))
        XCTAssertEqual(playCount, 1, "Cascading completion plays only one sound")
        XCTAssertTrue(store.setCompleted(id: parent, completed: true))
        XCTAssertEqual(playCount, 1, "Repeated completion stays silent")
        XCTAssertTrue(store.setCompleted(id: parent, completed: false))
        XCTAssertEqual(playCount, 1, "Reopening stays silent")
        XCTAssertTrue(store.setCompleted(id: parent, completed: true))
        XCTAssertEqual(playCount, 2)
        XCTAssertTrue(store.setCompleted(id: parent, completed: false))
        XCTAssertFalse(store.setCompleted(id: "missing", completed: true))
        XCTAssertEqual(playCount, 2)

        try executeSQL("""
            CREATE TRIGGER reject_completion BEFORE UPDATE ON tasks
            WHEN NEW.completed_at IS NOT NULL
            BEGIN SELECT RAISE(ABORT, 'test completion failure'); END;
            """, at: url)
        XCTAssertFalse(store.setCompleted(id: parent, completed: true))
        XCTAssertEqual(playCount, 2, "A failed database write stays silent")
        XCTAssertFalse(store.task(id: parent)!.isCompleted)
    }

    func testDetailsAndTimestampedProgressPreserveSQLSensitiveTextAndPersist() async throws {
        let (store, clock, url) = try fixture(at: date(19, hour: 9))
        let title = "读 'paper'; DROP TABLE tasks; --"
        let details = "第一段\n第二段：先复现，再判断。"
        let id = try XCTUnwrap(store.addTask(title: title, details: details))
        XCTAssertTrue(store.addProgress(taskID: id, text: "  今天卡在 'tokenizer' 😅  "))
        clock.date = date(19, hour: 11)
        XCTAssertTrue(store.addProgress(taskID: id, text: "找到原因\n先记下来"))
        let restored = TaskStore(databaseURL: url)
        XCTAssertEqual(restored.task(id: id)?.title, title)
        XCTAssertEqual(restored.task(id: id)?.details, details)
        let entries = restored.progress(for: id)
        XCTAssertEqual(entries.map(\.text), ["找到原因\n先记下来", "今天卡在 'tokenizer' 😅"])
        XCTAssertEqual(entries.map(\.createdAt), [date(19, hour: 11), date(19, hour: 9)])
        XCTAssertTrue(restored.deleteProgress(id: entries[0].id))
        XCTAssertEqual(restored.progress(for: id).count, 1)
    }

    func testReviewUsesRealCompletionTimeIncludesSubtasksAndExcludesFutureDates() async throws {
        let reference = date(21, hour: 15) // Wednesday, week begins October 19.
        let (store, clock, _) = try fixture(at: date(1))
        let early = try XCTUnwrap(store.addTask(title: "早早创建但本周完成", plannedDate: date(1)))
        let parent = try XCTUnwrap(store.addTask(title: "还在做的父任务"))
        let child = try XCTUnwrap(store.addTask(title: "独立完成的子任务", parentID: parent))
        let lastWeek = try XCTUnwrap(store.addTask(title: "上周完成"))
        let tooOld = try XCTUnwrap(store.addTask(title: "七天前完成"))
        let future = try XCTUnwrap(store.addTask(title: "未来完成"))
        clock.date = date(14, hour: 23, minute: 59)
        XCTAssertTrue(store.setCompleted(id: tooOld, completed: true))
        clock.date = date(15, hour: 0)
        XCTAssertTrue(store.setCompleted(id: lastWeek, completed: true))
        clock.date = date(19, hour: 0)
        XCTAssertTrue(store.setCompleted(id: early, completed: true))
        clock.date = date(21, hour: 14)
        XCTAssertTrue(store.setCompleted(id: child, completed: true))
        clock.date = date(22)
        XCTAssertTrue(store.setCompleted(id: future, completed: true))
        XCTAssertEqual(store.completedTasks(in: .thisWeek, relativeTo: reference).map(\.id), [child, early])
        XCTAssertEqual(store.completedTasks(in: .lastSevenDays, relativeTo: reference).map(\.id), [child, early, lastWeek])
        XCTAssertFalse(store.task(id: parent)!.isCompleted)
        XCTAssertTrue(store.setCompleted(id: early, completed: false))
        XCTAssertEqual(store.completedTasks(in: .thisWeek, relativeTo: reference).map(\.id), [child])
    }

    func testReviewBoundariesUseMondayAndLocalMidnightAcrossDST() async throws {
        var losAngeles = calendar
        losAngeles.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let sunday = losAngeles.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 12))!
        let interval = TaskReviewPeriod.lastSevenDays.interval(relativeTo: sunday, calendar: losAngeles)
        let start = losAngeles.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 0))!
        XCTAssertEqual(interval.start, start)
        XCTAssertEqual(TaskReviewPeriod.thisWeek.interval(relativeTo: sunday, calendar: losAngeles).start, start)
        // DST ended this Sunday: six calendar days plus thirteen hours have elapsed.
        XCTAssertEqual(interval.duration, 157 * 3_600)
        let monday = date(19, hour: 0)
        XCTAssertEqual(TaskReviewPeriod.thisWeek.interval(relativeTo: monday, calendar: calendar).start, monday)
    }

    func testDeleteParentRemovesAllDescendantsAndProgressWithoutAffectingOtherTasks() async throws {
        let (store, _, url) = try fixture(at: date(19))
        let parent = try XCTUnwrap(store.addTask(title: "要删除的项目"))
        let child = try XCTUnwrap(store.addTask(title: "子任务", parentID: parent))
        let grandchild = "legacy-grandchild"
        try insertLegacyTask(id: grandchild, parentID: child, title: "孙任务", createdAt: date(19), at: url)
        XCTAssertTrue(store.reload())
        let other = try XCTUnwrap(store.addTask(title: "另一个想法"))
        XCTAssertTrue(store.addProgress(taskID: grandchild, text: "记录"))
        XCTAssertTrue(store.deleteTask(id: parent))
        XCTAssertEqual(store.tasks.map(\.id), [other])
        XCTAssertTrue(store.progressEntries.isEmpty)
        let restored = TaskStore(databaseURL: url)
        XCTAssertEqual(restored.tasks.map(\.id), [other])
        XCTAssertTrue(restored.progressEntries.isEmpty)
    }

    func testFailedInsertRollsBackAncestorReopeningAndPublishedState() async throws {
        let (store, _, url) = try fixture(at: date(19))
        let parent = try XCTUnwrap(store.addTask(title: "完成的项目"))
        XCTAssertTrue(store.setCompleted(id: parent, completed: true))
        let original = store.tasks
        try executeSQL("CREATE TRIGGER reject_child BEFORE INSERT ON tasks WHEN NEW.title = 'reject' BEGIN SELECT RAISE(ABORT, 'test disk write failure'); END;", at: url)
        XCTAssertNil(store.addTask(title: "reject", parentID: parent))
        XCTAssertNotNil(store.errorMessage)
        XCTAssertEqual(store.tasks, original)
        let restored = TaskStore(databaseURL: url)
        XCTAssertEqual(restored.tasks, original, "Ancestor updates must roll back when child insertion fails")
    }

    func testInvalidInputAndUnavailableDatabaseExposeErrorsWithoutPhantomTasks() async throws {
        let (store, _, url) = try fixture(at: date(19))
        XCTAssertNil(store.addTask(title: "  \n"))
        XCTAssertNotNil(store.errorMessage)
        XCTAssertNil(store.addTask(title: "孤立任务", parentID: "missing"))
        XCTAssertNotNil(store.errorMessage)
        XCTAssertFalse(store.addProgress(taskID: "missing", text: "进展"))
        XCTAssertTrue(store.tasks.isEmpty)
        XCTAssertTrue(store.progressEntries.isEmpty)
        // The database URL is a directory: opening must fail visibly, without touching real user data.
        let unavailable = TaskStore(databaseURL: url.deletingLastPathComponent())
        XCTAssertNotNil(unavailable.errorMessage)
        XCTAssertNil(unavailable.addTask(title: "保存失败"))
        XCTAssertTrue(unavailable.tasks.isEmpty)
    }

    private func insertLegacyTask(id: String, parentID: String, title: String,
                                  createdAt: Date, at url: URL) throws {
        let timestamp = createdAt.timeIntervalSince1970
        try executeSQL("""
            INSERT INTO tasks (id, parent_id, title, details, planned_at, created_at, updated_at)
            VALUES ('\(id)', '\(parentID)', '\(title)', '', NULL, \(timestamp), \(timestamp))
            """, at: url)
    }

    private func executeSQL(_ sql: String, at url: URL) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK, let handle else {
            throw NSError(domain: "TaskStoreTests", code: 1)
        }
        defer { sqlite3_close(handle) }
        let result = sqlite3_exec(handle, sql, nil, nil, nil)
        guard result == SQLITE_OK else {
            throw NSError(domain: "TaskStoreTests", code: Int(result), userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(handle))])
        }
    }
}
