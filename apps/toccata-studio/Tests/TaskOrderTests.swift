import Foundation
import SQLite3
import XCTest
@testable import toccata_studio

@MainActor
final class TaskOrderTests: XCTestCase {
    private func fixture() throws -> (TaskStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ToccataRootOrder-\(UUID().uuidString)")
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

    private func add(_ title: String, to store: TaskStore, parent: String? = nil,
                     planned: TimeInterval? = nil, done: Bool = false, pinned: Bool = false) throws -> String {
        let id = try XCTUnwrap(store.addTask(title: title, details: "保留说明", plannedDate: planned.map(Date.init(timeIntervalSince1970:)), parentID: parent))
        if done { XCTAssertTrue(store.setCompleted(id: id, completed: true)) }
        if pinned { XCTAssertTrue(store.setPinned(id: id, pinned: true)) }
        return id
    }

    private func rootIDs(_ store: TaskStore, order: TaskSortOrder = .manual) -> [String] {
        store.tasks.filter { $0.parentID == nil }
            .sorted { TaskOrder.precedes($0, $1, sortOrder: order) }.map(\.id)
    }

    func testMovingRootFromTitleOrderPreservesOtherVisibleOrderAndWholeSubtree() async throws {
        let (store, url) = try fixture()
        let c = try add("C", to: store)
        let a = try add("A", to: store)
        let b = try add("B", to: store)
        let first = try add("子任务 A", to: store, parent: c)
        let second = try add("子任务 B", to: store, parent: c)
        XCTAssertTrue(store.moveSubtask(id: first, relativeTo: second, placement: .before))
        let before = store.tasks
        XCTAssertEqual(rootIDs(store, order: .title), [a, b, c])

        XCTAssertTrue(store.moveTask(id: c, relativeTo: a, placement: .before, sortOrder: .title))
        XCTAssertEqual(rootIDs(store), [c, a, b], "Switching to manual order must preserve the current title order of unmoved roots")
        XCTAssertEqual(store.children(of: c).map(\.id), [first, second])
        let snapshot = WorkspaceTaskListSnapshot(allTasks: store.tasks, scopedTasks: store.tasks, sortOrder: .manual)
        XCTAssertEqual(WorkspaceTaskListSnapshot.rows(from: snapshot.pendingRoots).map(\.id), [c, first, second, a, b])
        let restored = TaskStore(databaseURL: url, completionFeedback: {})
        XCTAssertEqual(restored.tasks, store.tasks)
        XCTAssertEqual(rootIDs(restored), [c, a, b])
        for original in before {
            let updated = try XCTUnwrap(store.task(id: original.id))
            XCTAssertEqual(updated.parentID, original.parentID)
            XCTAssertEqual(updated.title, original.title)
            XCTAssertEqual(updated.details, original.details)
            XCTAssertEqual(updated.plannedDate, original.plannedDate)
            XCTAssertEqual(updated.createdAt, original.createdAt)
            XCTAssertEqual(updated.updatedAt, original.updatedAt)
            XCTAssertEqual(updated.completedAt, original.completedAt)
            XCTAssertEqual(updated.isPinned, original.isPinned)
            if original.parentID != nil { XCTAssertEqual(updated, original) }
        }
    }

    func testSwitchingFromAutomaticToManualPreservesUntouchedPinAndCompletionGroups() async throws {
        for order in [TaskSortOrder.title, .plannedAscending, .createdAscending] {
            let (store, url) = try fixture()
            let pinnedZ = try add("Z pinned", to: store, planned: 300, pinned: true)
            let pinnedA = try add("A pinned", to: store, planned: 100, pinned: true)
            let z = try add("Z", to: store, planned: 300)
            let a = try add("A", to: store, planned: 100)
            let m = try add("M", to: store, planned: 200)
            let completedZ = try add("Z completed", to: store, planned: 300, done: true)
            let completedA = try add("A completed", to: store, planned: 100, done: true)
            let completedPinnedZ = try add("Z completed pin", to: store, planned: 300, done: true, pinned: true)
            let completedPinnedA = try add("A completed pin", to: store, planned: 100, done: true, pinned: true)
            // Seed manual ranks that conflict with the requested automatic order.
            XCTAssertTrue(store.moveTask(id: pinnedZ, relativeTo: pinnedA, placement: .before))
            XCTAssertTrue(store.moveTask(id: completedZ, relativeTo: completedA, placement: .before))
            XCTAssertTrue(store.moveTask(id: completedPinnedZ, relativeTo: completedPinnedA, placement: .before))
            let untouchedIDs = Set([pinnedZ, pinnedA, completedZ, completedA, completedPinnedZ, completedPinnedA])
            let originalOrder = rootIDs(store, order: order)
            let unchangedGroups = originalOrder.filter { untouchedIDs.contains($0) }
            let currentGroup = originalOrder.filter { [a, m, z].contains($0) }
            let moving = try XCTUnwrap(currentGroup.last)
            let target = try XCTUnwrap(currentGroup.first)
            XCTAssertTrue(store.moveTask(id: moving, relativeTo: target, placement: .before, sortOrder: order))
            XCTAssertEqual(rootIDs(store).filter { untouchedIDs.contains($0) }, unchangedGroups,
                           "Changing the global sort must not reshuffle untouched or hidden groups")
            XCTAssertEqual(rootIDs(store).filter { [a, m, z].contains($0) }, [moving] + currentGroup.dropLast())
            XCTAssertEqual(rootIDs(TaskStore(databaseURL: url, completionFeedback: {})), rootIDs(store))
        }
    }

    func testManualDropInSameGapDoesNotCreateRanksOrWriteToDatabase() async throws {
        let (store, url) = try fixture()
        let a = try add("A", to: store)
        let b = try add("B", to: store)
        let childA = try add("child A", to: store, parent: a)
        let childB = try add("child B", to: store, parent: a)
        let before = store.tasks
        XCTAssertTrue(before.allSatisfy { $0.subtaskOrder == nil })
        try executeSQL("""
            CREATE TRIGGER reject_noop_rank BEFORE UPDATE OF subtask_order ON tasks
            BEGIN SELECT RAISE(ABORT, 'unnecessary update'); END;
            """, at: url)
        XCTAssertTrue(store.moveTask(id: b, relativeTo: a, placement: .before))
        XCTAssertTrue(store.moveSubtask(id: childB, relativeTo: childA, placement: .before))
        XCTAssertEqual(store.tasks, before)
        XCTAssertEqual(TaskStore(databaseURL: url, completionFeedback: {}).tasks, before)
    }

    func testAutomaticDropInSameGapStillPersistsCurrentSortForManualMode() async throws {
        let (store, url) = try fixture()
        let a = try add("A", to: store)
        let b = try add("B", to: store)
        XCTAssertEqual(rootIDs(store, order: .title), [a, b])
        XCTAssertEqual(rootIDs(store), [b, a])
        XCTAssertTrue(store.moveTask(id: a, relativeTo: b, placement: .before, sortOrder: .title))
        XCTAssertEqual(rootIDs(store), [a, b])
        XCTAssertEqual(rootIDs(TaskStore(databaseURL: url, completionFeedback: {})), [a, b])
    }

    func testRootDropOnChildUsesItsParentAndKeepsHiddenRoots() async throws {
        let (store, _) = try fixture()
        let a = try add("A", to: store)
        let hidden = try add("B hidden", to: store)
        let c = try add("C", to: store)
        let d = try add("D", to: store)
        let child = try add("child", to: store, parent: c)
        let matches = store.tasks.filter { [a, c, child].contains($0.id) }
        XCTAssertTrue(store.moveTask(id: a, relativeTo: child, placement: .after, sortOrder: .title))
        XCTAssertEqual(rootIDs(store), [hidden, c, a, d])
        XCTAssertEqual(store.task(id: child)?.parentID, c)
        let currentMatches = matches.compactMap { store.task(id: $0.id) }
        let snapshot = WorkspaceTaskListSnapshot(allTasks: store.tasks, scopedTasks: currentMatches, sortOrder: .manual)
        XCTAssertEqual(snapshot.pendingRoots.map(\.id), [c, a])
        XCTAssertEqual(WorkspaceTaskListSnapshot.rows(from: snapshot.pendingRoots).map(\.id), [c, child, a])
    }

    func testRootMovesRespectPinAndCompletionGroupsWithoutReparenting() async throws {
        let (store, _) = try fixture()
        let pinnedA = try add("Pinned A", to: store, pinned: true)
        let pinnedB = try add("Pinned B", to: store, pinned: true)
        let a = try add("A", to: store)
        let b = try add("B", to: store)
        let doneA = try add("Done A", to: store, done: true)
        let doneB = try add("Done B", to: store, done: true)
        let child = try add("child", to: store, parent: a)
        XCTAssertTrue(store.moveTask(id: pinnedA, relativeTo: pinnedB, placement: .before))
        XCTAssertTrue(store.moveTask(id: a, relativeTo: b, placement: .before))
        XCTAssertTrue(store.moveTask(id: doneA, relativeTo: doneB, placement: .before))
        XCTAssertEqual(rootIDs(store), [pinnedA, pinnedB, a, b, doneA, doneB])
        let before = store.tasks
        for (source, target) in [(a, pinnedA), (pinnedA, b), (a, doneA), (doneA, a),
                                 (child, b), (a, child), (a, a), (a, "missing"), ("missing", a)] {
            XCTAssertFalse(store.moveTask(id: source, relativeTo: target, placement: .before))
            XCTAssertEqual(store.tasks, before)
        }
        XCTAssertTrue(store.setCompleted(id: a, completed: true))
        XCTAssertTrue(store.setCompleted(id: a, completed: false))
        XCTAssertEqual(rootIDs(store), [pinnedA, pinnedB, a, b, doneA, doneB])
    }

    func testPlannedSortKeepsPinsFirstAndUnscheduledLastWithStableTies() async throws {
        let (store, _) = try fixture()
        let later = try add("Later", to: store, planned: 200)
        let noDate = try add("No date", to: store)
        let earlyOlder = try add("Early older", to: store, planned: 100)
        let earlyNewer = try add("Early newer", to: store, planned: 100)
        let pinnedNoDate = try add("Pinned", to: store, pinned: true)
        let completed = try add("Completed pinned", to: store, planned: 50, done: true, pinned: true)
        let child = try add("Child with earlier plan", to: store, parent: later, planned: 1)
        XCTAssertEqual(rootIDs(store, order: .plannedAscending),
                       [pinnedNoDate, earlyNewer, earlyOlder, later, noDate, completed])
        let snapshot = WorkspaceTaskListSnapshot(allTasks: store.tasks, scopedTasks: store.tasks,
                                                 sortOrder: .plannedAscending)
        XCTAssertEqual(snapshot.pendingRoots.map(\.id), [pinnedNoDate, earlyNewer, earlyOlder, later, noDate])
        XCTAssertEqual(snapshot.completedRoots.map(\.id), [completed])
        XCTAssertEqual(snapshot.pendingRoots.first { $0.id == later }?.children.map(\.id), [child])
        for order in TaskSortOrder.allCases {
            XCTAssertEqual(rootIDs(store, order: order).first, pinnedNoDate)
            XCTAssertEqual(rootIDs(store, order: order).last, completed)
        }
        XCTAssertTrue(store.setPinned(id: pinnedNoDate, pinned: false))
        XCTAssertEqual(rootIDs(store, order: .plannedAscending),
                       [earlyNewer, earlyOlder, later, pinnedNoDate, noDate, completed])
    }

    func testSortTiesUseStableIDAndSharedTreeOrdering() {
        let date = Date(timeIntervalSince1970: 100)
        func task(_ id: String) -> TodoTask {
            TodoTask(id: id, parentID: nil, title: "Same", details: "", plannedDate: date,
                     createdAt: date, updatedAt: date, completedAt: nil)
        }
        let all = [task("b"), task("a")]
        for order in TaskSortOrder.allCases {
            let roots = MenuTaskTree.roots(allTasks: all, matchingTasks: all)
            XCTAssertEqual(TaskOrder.sortedRoots(roots, sortOrder: order).map(\.id), ["a", "b"])
            let workspace = WorkspaceTaskListSnapshot(allTasks: all, scopedTasks: all, sortOrder: order)
            XCTAssertEqual(workspace.pendingRoots.map(\.id), ["a", "b"])
        }
    }

    func testFailedRootReorderRollsBackAllRanksAndPreservesChildren() async throws {
        let (store, url) = try fixture()
        let a = try add("A", to: store)
        _ = try add("B", to: store)
        let c = try add("C", to: store)
        _ = try add("child", to: store, parent: a)
        let before = store.tasks
        try executeSQL("""
            CREATE TRIGGER reject_root_order BEFORE UPDATE OF subtask_order ON tasks
            WHEN NEW.parent_id IS NULL AND NEW.subtask_order = 1
            BEGIN SELECT RAISE(ABORT, 'fixture failure'); END;
            """, at: url)
        XCTAssertFalse(store.moveTask(id: a, relativeTo: c, placement: .before))
        XCTAssertNotNil(store.errorMessage)
        XCTAssertEqual(store.tasks, before)
        XCTAssertEqual(TaskStore(databaseURL: url, completionFeedback: {}).tasks, before)
    }

    private func executeSQL(_ sql: String, at url: URL) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK, let handle else {
            throw NSError(domain: "TaskOrderTests", code: 1)
        }
        defer { sqlite3_close(handle) }
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "TaskOrderTests", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(handle))])
        }
    }
}
