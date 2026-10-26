import Foundation
import SQLite3
import XCTest
@testable import toccata_studio

@MainActor
final class SubtaskOrderTests: XCTestCase {
    private func fixture() throws -> (TaskStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ToccataOrder-\(UUID().uuidString)")
        let url = directory.appendingPathComponent("tasks.sqlite")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        var timestamp: TimeInterval = 1_800_000_000
        let store = TaskStore(databaseURL: url, now: {
            timestamp += 1
            return Date(timeIntervalSince1970: timestamp)
        }, completionFeedback: {})
        XCTAssertNil(store.errorMessage)
        return (store, url)
    }

    private func add(_ title: String, to store: TaskStore, parent: String? = nil, done: Bool = false) throws -> String {
        let id = try XCTUnwrap(store.addTask(title: title, details: "说明\n", parentID: parent))
        if done { XCTAssertTrue(store.setCompleted(id: id, completed: true)) }
        return id
    }

    private func ids(_ store: TaskStore, _ parent: String) -> [String] {
        store.children(of: parent).map(\.id)
    }

    func testManualOrderPersistsAndDoesNotChangeTaskContentDatesOrOtherGroup() async throws {
        let (store, url) = try fixture()
        let parent = try add("主任务", to: store)
        let a = try add("A", to: store, parent: parent)
        let b = try add("B", to: store, parent: parent)
        let c = try add("C", to: store, parent: parent)
        let done = try add("已完成", to: store, parent: parent, done: true)
        let before = store.tasks
        XCTAssertEqual(ids(store, parent), [c, b, a, done])

        XCTAssertTrue(store.moveSubtask(id: a, relativeTo: c, placement: .before))
        XCTAssertEqual(ids(store, parent), [a, c, b, done])
        XCTAssertTrue(store.moveSubtask(id: a, relativeTo: b, placement: .after))
        XCTAssertEqual(ids(store, parent), [c, b, a, done])
        XCTAssertTrue(store.moveSubtask(id: b, relativeTo: c, placement: .before))
        XCTAssertEqual(ids(store, parent), [b, c, a, done])

        let reopened = TaskStore(databaseURL: url, completionFeedback: {})
        XCTAssertEqual(reopened.tasks, store.tasks)
        XCTAssertEqual(ids(reopened, parent), [b, c, a, done])
        for original in before {
            let updated = try XCTUnwrap(store.task(id: original.id))
            XCTAssertEqual(updated.title, original.title)
            XCTAssertEqual(updated.details, original.details)
            XCTAssertEqual(updated.parentID, original.parentID)
            XCTAssertEqual(updated.createdAt, original.createdAt)
            XCTAssertEqual(updated.updatedAt, original.updatedAt)
            XCTAssertEqual(updated.completedAt, original.completedAt)
            XCTAssertEqual(updated.plannedDate, original.plannedDate)
            XCTAssertEqual(updated.priority, original.priority)
        }
        XCTAssertEqual(store.task(id: done), before.first { $0.id == done })
        XCTAssertEqual(store.task(id: parent), before.first { $0.id == parent })
    }

    func testCompletedChildrenCanReorderButCannotCrossStatusOrParentBoundaries() async throws {
        let (store, _) = try fixture()
        let parent = try add("主任务", to: store)
        let other = try add("其他主任务", to: store)
        let pending = try add("待办", to: store, parent: parent)
        let a = try add("已完成 A", to: store, parent: parent, done: true)
        let b = try add("已完成 B", to: store, parent: parent, done: true)
        let outsider = try add("其他子任务", to: store, parent: other, done: true)
        XCTAssertTrue(store.moveSubtask(id: a, relativeTo: b, placement: .before))
        XCTAssertEqual(ids(store, parent), [pending, a, b])
        let original = store.tasks
        for (source, target) in [(a, pending), (pending, b), (a, outsider), (parent, other),
                                 (pending, parent), (a, a), (a, "deleted"), ("deleted", a)] {
            XCTAssertFalse(store.moveSubtask(id: source, relativeTo: target, placement: .before))
            XCTAssertEqual(store.tasks, original)
        }
        XCTAssertTrue(store.moveSubtask(id: a, relativeTo: b, placement: .before))
        XCTAssertEqual(store.tasks, original, "Dropping into the same gap is a no-op")
    }

    func testCompletionAndReopeningKeepPendingAboveCompletedAndPreserveSiblingOrder() async throws {
        let (store, _) = try fixture()
        let parent = try add("主任务", to: store)
        let a = try add("A", to: store, parent: parent)
        let b = try add("B", to: store, parent: parent)
        let c = try add("C", to: store, parent: parent)
        let d = try add("Done", to: store, parent: parent, done: true)
        XCTAssertTrue(store.moveSubtask(id: a, relativeTo: c, placement: .before))
        XCTAssertTrue(store.setCompleted(id: a, completed: true))
        XCTAssertEqual(store.children(of: parent).filter { !$0.isCompleted }.map(\.id), [c, b])
        XCTAssertEqual(Set(store.children(of: parent).suffix(2).map(\.id)), Set([a, d]))
        XCTAssertFalse(store.moveSubtask(id: a, relativeTo: b, placement: .before))
        XCTAssertTrue(store.setCompleted(id: a, completed: false))
        XCTAssertEqual(ids(store, parent), [a, c, b, d])
    }

    func testFilteredViewsPreserveHiddenSiblingsAndUseTheSameOrderAsDetails() async throws {
        let (store, _) = try fixture()
        let parent = try add("主任务", to: store)
        let a = try add("A", to: store, parent: parent)
        let hidden = try add("隐藏项", to: store, parent: parent)
        let b = try add("B", to: store, parent: parent)
        let c = try add("C", to: store, parent: parent)
        XCTAssertTrue(store.moveSubtask(id: a, relativeTo: c, placement: .before))
        XCTAssertEqual(ids(store, parent), [a, c, b, hidden])
        let matches = store.tasks.filter { [a, c].contains($0.id) }
        let filtered = MenuTaskTree.roots(allTasks: store.tasks, matchingTasks: matches)
        XCTAssertEqual(filtered.first?.children.map(\.id), [a, c])
        let full = MenuTaskTree.roots(allTasks: store.tasks, matchingTasks: store.tasks)
        XCTAssertEqual(full.first?.children.map(\.id), ids(store, parent))
        let workspace = WorkspaceTaskListSnapshot(allTasks: store.tasks, scopedTasks: store.tasks)
        XCTAssertEqual(workspace.pendingRoots.first?.children.map(\.id), ids(store, parent))
    }

    func testFailedReorderRollsBackEveryRank() async throws {
        let (store, url) = try fixture()
        let parent = try add("主任务", to: store)
        let a = try add("A", to: store, parent: parent)
        let b = try add("B", to: store, parent: parent)
        let c = try add("C", to: store, parent: parent)
        let original = store.tasks
        try sql("""
            CREATE TRIGGER reject_middle_rank BEFORE UPDATE OF subtask_order ON tasks
            WHEN NEW.subtask_order = 1 BEGIN SELECT RAISE(ABORT, 'fixture failure'); END;
            """, at: url)
        XCTAssertFalse(store.moveSubtask(id: a, relativeTo: c, placement: .before))
        XCTAssertEqual(store.tasks, original)
        XCTAssertEqual(TaskStore(databaseURL: url, completionFeedback: {}).tasks, original)
        XCTAssertEqual(ids(store, parent), [c, b, a])
    }

    func testLegacyDatabaseMigratesWithoutLosingTasksAndCanBeOpenedRepeatedly() async throws {
        let (_, url) = try fixture()
        // Recreate the pre-priority/pre-order table at a separate path.
        let legacy = url.deletingLastPathComponent().appendingPathComponent("legacy.sqlite")
        try sql("""
            CREATE TABLE tasks (
              id TEXT PRIMARY KEY NOT NULL, parent_id TEXT REFERENCES tasks(id), title TEXT NOT NULL,
              details TEXT NOT NULL DEFAULT '', planned_at REAL, created_at REAL NOT NULL,
              updated_at REAL NOT NULL, completed_at REAL
            );
            INSERT INTO tasks VALUES ('parent', NULL, '旧主任务', '保留详情', NULL, 1, 1, NULL);
            INSERT INTO tasks VALUES ('a', 'parent', '旧 A', '', NULL, 2, 2, NULL);
            INSERT INTO tasks VALUES ('b', 'parent', '旧 B', '', NULL, 3, 3, NULL);
            """, at: legacy)
        let store = TaskStore(databaseURL: legacy, completionFeedback: {})
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(ids(store, "parent"), ["b", "a"])
        XCTAssertTrue(store.tasks.allSatisfy { $0.subtaskOrder == nil })
        XCTAssertEqual(store.task(id: "parent")?.details, "保留详情")
        XCTAssertTrue(store.moveSubtask(id: "a", relativeTo: "b", placement: .before))
        for _ in 0..<2 {
            let reopened = TaskStore(databaseURL: legacy, completionFeedback: {})
            XCTAssertNil(reopened.errorMessage)
            XCTAssertEqual(ids(reopened, "parent"), ["a", "b"])
            XCTAssertEqual(reopened.tasks.count, 3)
        }
    }

    private func sql(_ sql: String, at url: URL) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK, let handle else {
            XCTFail("Cannot open fixture database")
            return
        }
        defer { sqlite3_close(handle) }
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "SQLite", code: 1, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(handle))])
        }
    }
}
