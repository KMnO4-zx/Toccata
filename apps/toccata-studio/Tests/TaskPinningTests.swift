import Foundation
import SQLite3
import XCTest
@testable import toccata_studio

@MainActor
final class TaskPinningTests: XCTestCase {
    private func databaseURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ToccataPinning-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("tasks.sqlite")
    }

    func testLegacySchemaMigrationPreservesExistingTaskDataAndIsIdempotent() async throws {
        let url = try databaseURL()
        try executeSQL("""
            CREATE TABLE tasks (
                id TEXT PRIMARY KEY NOT NULL,
                parent_id TEXT REFERENCES tasks(id) ON DELETE CASCADE,
                title TEXT NOT NULL,
                details TEXT NOT NULL DEFAULT '',
                planned_at REAL,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                completed_at REAL
            );
            CREATE TABLE task_progress (
                id TEXT PRIMARY KEY NOT NULL,
                task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
                text TEXT NOT NULL,
                created_at REAL NOT NULL
            );
            INSERT INTO tasks VALUES ('legacy-parent', NULL, '原有任务', '保留详情', 1792425600, 1792339200, 1792429200, 1792432800);
            INSERT INTO tasks VALUES ('legacy-child', 'legacy-parent', '原有子任务', '', NULL, 1792342800, 1792429200, NULL);
            INSERT INTO task_progress VALUES ('legacy-note', 'legacy-parent', '原有进展', 1792429200);
            """, at: url)

        let store = TaskStore(databaseURL: url)
        XCTAssertNil(store.errorMessage)
        let original = try XCTUnwrap(store.task(id: "legacy-parent"))
        XCTAssertFalse(original.isPinned)
        XCTAssertEqual(original.title, "原有任务")
        XCTAssertEqual(original.details, "保留详情")
        XCTAssertEqual(original.plannedDate, Date(timeIntervalSince1970: 1_792_425_600))
        XCTAssertEqual(original.createdAt, Date(timeIntervalSince1970: 1_792_339_200))
        XCTAssertEqual(original.updatedAt, Date(timeIntervalSince1970: 1_792_429_200))
        XCTAssertEqual(original.completedAt, Date(timeIntervalSince1970: 1_792_432_800))
        XCTAssertEqual(store.task(id: "legacy-child")?.parentID, original.id)
        XCTAssertNil(store.task(id: "legacy-child")?.plannedDate)
        XCTAssertEqual(try legacyProgressText(at: url), ["原有进展"])

        let reopened = TaskStore(databaseURL: url)
        XCTAssertNil(reopened.errorMessage)
        XCTAssertEqual(reopened.tasks, store.tasks)
        XCTAssertEqual(try legacyProgressText(at: url), ["原有进展"])
        XCTAssertTrue(reopened.setPinned(id: original.id, pinned: true))
        let reopenedAgain = TaskStore(databaseURL: url)
        XCTAssertNil(reopenedAgain.errorMessage)
        XCTAssertEqual(reopenedAgain.task(id: original.id)?.isPinned, true)
        XCTAssertEqual(reopenedAgain.task(id: original.id)?.completedAt, original.completedAt)
        XCTAssertEqual(reopenedAgain.task(id: original.id)?.createdAt, original.createdAt)
        XCTAssertEqual(reopenedAgain.task(id: original.id)?.plannedDate, original.plannedDate)
    }

    func testPinPersistsAndEditingOtherFieldsDoesNotClearIt() async throws {
        let url = try databaseURL()
        var now = Date(timeIntervalSince1970: 1_792_339_200)
        let store = TaskStore(databaseURL: url, now: { now }, completionFeedback: {})
        let id = try XCTUnwrap(store.addTask(title: "记录新想法"))
        XCTAssertEqual(store.task(id: id)?.isPinned, false)
        let createdAt = try XCTUnwrap(store.task(id: id)?.createdAt)

        now.addTimeInterval(60)
        XCTAssertTrue(store.setPinned(id: id, pinned: true))
        XCTAssertEqual(store.task(id: id)?.updatedAt, now)
        XCTAssertEqual(store.task(id: id)?.createdAt, createdAt)
        XCTAssertNil(store.task(id: id)?.completedAt)
        now.addTimeInterval(60)
        let plan = now.addingTimeInterval(86_400)
        XCTAssertTrue(store.updateTask(id: id, title: "修改名称", details: "写下任务详情", plannedDate: plan))
        XCTAssertEqual(store.task(id: id)?.isPinned, true)
        XCTAssertTrue(store.setCompleted(id: id, completed: true))

        let restored = TaskStore(databaseURL: url)
        XCTAssertEqual(restored.task(id: id)?.isPinned, true)
        XCTAssertEqual(restored.task(id: id)?.title, "修改名称")
        XCTAssertEqual(restored.task(id: id)?.details, "写下任务详情")
        XCTAssertEqual(restored.task(id: id)?.plannedDate, plan)
        XCTAssertEqual(restored.task(id: id)?.completedAt, now)
        XCTAssertEqual(restored.task(id: id)?.createdAt, createdAt)
        for pinned in [false, true, false] {
            XCTAssertTrue(restored.setPinned(id: id, pinned: pinned))
            XCTAssertEqual(TaskStore(databaseURL: url).task(id: id)?.isPinned, pinned)
        }
        XCTAssertFalse(restored.setPinned(id: "missing", pinned: true))
        XCTAssertNotNil(restored.errorMessage)
        XCTAssertEqual(restored.task(id: id)?.isPinned, false)
    }

    func testExistingPriorityValuesDoNotBecomePinsDuringMigration() async throws {
        let url = try databaseURL()
        try executeSQL("""
            CREATE TABLE tasks (
                id TEXT PRIMARY KEY NOT NULL, parent_id TEXT REFERENCES tasks(id), title TEXT NOT NULL,
                details TEXT NOT NULL DEFAULT '', planned_at REAL, created_at REAL NOT NULL,
                updated_at REAL NOT NULL, completed_at REAL, priority INTEGER NOT NULL DEFAULT 0,
                subtask_order INTEGER
            );
            INSERT INTO tasks VALUES ('high', NULL, '旧高优先级', '保留内容', 100, 1, 2, NULL, 3, 1);
            INSERT INTO tasks VALUES ('medium', NULL, '旧中优先级', '', NULL, 2, 3, NULL, 2, 0);
            INSERT INTO tasks VALUES ('low', 'high', '旧低优先级', '', NULL, 3, 4, NULL, 1, 0);
            """, at: url)
        let store = TaskStore(databaseURL: url, completionFeedback: {})
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.tasks.count, 3)
        XCTAssertTrue(store.tasks.allSatisfy { !$0.isPinned })
        XCTAssertEqual(store.task(id: "high")?.details, "保留内容")
        XCTAssertEqual(store.task(id: "high")?.subtaskOrder, 1)
        XCTAssertEqual(store.task(id: "medium")?.subtaskOrder, 0)
        XCTAssertEqual(store.task(id: "low")?.parentID, "high")
        XCTAssertTrue(store.setPinned(id: "high", pinned: true))
        for _ in 0..<2 {
            let restored = TaskStore(databaseURL: url, completionFeedback: {})
            XCTAssertNil(restored.errorMessage)
            XCTAssertEqual(restored.tasks, store.tasks)
            XCTAssertTrue(restored.isPinned(id: "high"))
            XCTAssertFalse(restored.isPinned(id: "medium"))
        }
    }

    func testPinningThroughChildAffectsItsWholeGroupAndNewChildrenInheritIt() async throws {
        let url = try databaseURL()
        let store = TaskStore(databaseURL: url, completionFeedback: {})
        let parent = try XCTUnwrap(store.addTask(title: "主任务"))
        let child = try XCTUnwrap(store.addTask(title: "子任务", parentID: parent))
        let other = try XCTUnwrap(store.addTask(title: "其他任务"))
        let beforeChild = try XCTUnwrap(store.task(id: child))
        XCTAssertTrue(store.setPinned(id: child, pinned: true))
        XCTAssertTrue(store.isPinned(id: parent))
        XCTAssertTrue(store.isPinned(id: child))
        XCTAssertFalse(store.isPinned(id: other))
        XCTAssertEqual(store.task(id: child), beforeChild, "Inherited pinning must not rewrite child records")
        let newChild = try XCTUnwrap(store.addTask(title: "后来添加的子任务", parentID: parent))
        XCTAssertTrue(store.isPinned(id: newChild))

        let restored = TaskStore(databaseURL: url, completionFeedback: {})
        XCTAssertTrue(restored.isPinned(id: child))
        XCTAssertTrue(restored.isPinned(id: newChild))
        XCTAssertTrue(restored.setPinned(id: newChild, pinned: false))
        XCTAssertFalse(restored.isPinned(id: parent))
        XCTAssertFalse(restored.isPinned(id: child))
        XCTAssertFalse(restored.isPinned(id: newChild))
        XCTAssertFalse(restored.isPinned(id: "missing"))
    }

    func testFailedPinLeavesPublishedAndPersistedGroupUnchanged() async throws {
        let url = try databaseURL()
        let store = TaskStore(databaseURL: url, completionFeedback: {})
        let parent = try XCTUnwrap(store.addTask(title: "主任务"))
        let child = try XCTUnwrap(store.addTask(title: "子任务", parentID: parent))
        let before = store.tasks
        try executeSQL("""
            CREATE TRIGGER reject_pin BEFORE UPDATE OF is_pinned ON tasks
            BEGIN SELECT RAISE(ABORT, 'fixture failure'); END;
            """, at: url)
        XCTAssertFalse(store.setPinned(id: child, pinned: true))
        XCTAssertNotNil(store.errorMessage)
        XCTAssertEqual(store.tasks, before)
        XCTAssertEqual(TaskStore(databaseURL: url, completionFeedback: {}).tasks, before)
    }

    private func legacyProgressText(at url: URL) throws -> [String] {
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK, let handle else {
            throw NSError(domain: "TaskPinningTests", code: 1)
        }
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT text FROM task_progress ORDER BY created_at", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw NSError(domain: "TaskPinningTests", code: 2)
        }
        defer { sqlite3_finalize(statement) }
        var values: [String] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return values }
            guard result == SQLITE_ROW else { throw NSError(domain: "TaskPinningTests", code: Int(result)) }
            if let text = sqlite3_column_text(statement, 0) {
                values.append(String(cString: text))
            }
        }
    }

    private func executeSQL(_ sql: String, at url: URL) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK, let handle else {
            throw NSError(domain: "TaskPinningTests", code: 1)
        }
        defer { sqlite3_close(handle) }
        let result = sqlite3_exec(handle, sql, nil, nil, nil)
        guard result == SQLITE_OK else {
            throw NSError(domain: "TaskPinningTests", code: Int(result),
                          userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(handle))])
        }
    }
}
