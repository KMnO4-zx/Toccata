import Foundation
import SQLite3
import XCTest
@testable import toccata_studio

@MainActor
final class TaskPriorityTests: XCTestCase {
    private func databaseURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ToccataPriority-\(UUID().uuidString)", isDirectory: true)
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
        XCTAssertEqual(original.priority, TaskPriority.none)
        XCTAssertEqual(original.title, "原有任务")
        XCTAssertEqual(original.details, "保留详情")
        XCTAssertEqual(original.plannedDate, Date(timeIntervalSince1970: 1_792_425_600))
        XCTAssertEqual(original.createdAt, Date(timeIntervalSince1970: 1_792_339_200))
        XCTAssertEqual(original.updatedAt, Date(timeIntervalSince1970: 1_792_429_200))
        XCTAssertEqual(original.completedAt, Date(timeIntervalSince1970: 1_792_432_800))
        XCTAssertEqual(store.task(id: "legacy-child")?.parentID, original.id)
        XCTAssertNil(store.task(id: "legacy-child")?.plannedDate)
        XCTAssertEqual(store.progress(for: original.id).map(\.text), ["原有进展"])

        let reopened = TaskStore(databaseURL: url)
        XCTAssertNil(reopened.errorMessage)
        XCTAssertEqual(reopened.tasks, store.tasks)
        XCTAssertEqual(reopened.progressEntries, store.progressEntries)
        XCTAssertTrue(reopened.setPriority(id: original.id, priority: .high))
        let reopenedAgain = TaskStore(databaseURL: url)
        XCTAssertNil(reopenedAgain.errorMessage)
        XCTAssertEqual(reopenedAgain.task(id: original.id)?.priority, .high)
        XCTAssertEqual(reopenedAgain.task(id: original.id)?.completedAt, original.completedAt)
        XCTAssertEqual(reopenedAgain.task(id: original.id)?.createdAt, original.createdAt)
        XCTAssertEqual(reopenedAgain.task(id: original.id)?.plannedDate, original.plannedDate)
    }

    func testPriorityPersistsAndEditingOtherFieldsDoesNotClearIt() async throws {
        let url = try databaseURL()
        var now = Date(timeIntervalSince1970: 1_792_339_200)
        let store = TaskStore(databaseURL: url, now: { now }, completionFeedback: {})
        let id = try XCTUnwrap(store.addTask(title: "记录新想法"))
        XCTAssertEqual(store.task(id: id)?.priority, TaskPriority.none)
        let createdAt = try XCTUnwrap(store.task(id: id)?.createdAt)

        now.addTimeInterval(60)
        XCTAssertTrue(store.setPriority(id: id, priority: .high))
        XCTAssertEqual(store.task(id: id)?.updatedAt, now)
        XCTAssertEqual(store.task(id: id)?.createdAt, createdAt)
        XCTAssertNil(store.task(id: id)?.completedAt)
        now.addTimeInterval(60)
        let plan = now.addingTimeInterval(86_400)
        XCTAssertTrue(store.updateTask(id: id, title: "修改名称", details: "写下任务详情", plannedDate: plan))
        XCTAssertEqual(store.task(id: id)?.priority, .high)
        XCTAssertTrue(store.setCompleted(id: id, completed: true))

        let restored = TaskStore(databaseURL: url)
        XCTAssertEqual(restored.task(id: id)?.priority, .high)
        XCTAssertEqual(restored.task(id: id)?.title, "修改名称")
        XCTAssertEqual(restored.task(id: id)?.details, "写下任务详情")
        XCTAssertEqual(restored.task(id: id)?.plannedDate, plan)
        XCTAssertEqual(restored.task(id: id)?.completedAt, now)
        XCTAssertEqual(restored.task(id: id)?.createdAt, createdAt)
        for priority in [TaskPriority.medium, .low, .none] {
            XCTAssertTrue(restored.setPriority(id: id, priority: priority))
            XCTAssertEqual(TaskStore(databaseURL: url).task(id: id)?.priority, priority)
        }
        XCTAssertFalse(restored.setPriority(id: "missing", priority: .high))
        XCTAssertNotNil(restored.errorMessage)
        XCTAssertEqual(restored.task(id: id)?.priority, TaskPriority.none)
    }

    private func executeSQL(_ sql: String, at url: URL) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK, let handle else {
            throw NSError(domain: "TaskPriorityTests", code: 1)
        }
        defer { sqlite3_close(handle) }
        let result = sqlite3_exec(handle, sql, nil, nil, nil)
        guard result == SQLITE_OK else {
            throw NSError(domain: "TaskPriorityTests", code: Int(result),
                          userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(handle))])
        }
    }
}
