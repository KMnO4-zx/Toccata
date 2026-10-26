import Foundation
import XCTest
@testable import toccata_studio

final class WorkspaceTaskListSnapshotTests: XCTestCase {
    private func task(_ id: String, parent: String? = nil, title: String? = nil,
                      details: String = "", created: TimeInterval = 0,
                      completed: Bool = false) -> TodoTask {
        let date = Date(timeIntervalSince1970: created)
        return TodoTask(id: id, parentID: parent, title: title ?? id, details: details,
                        plannedDate: nil, createdAt: date, updatedAt: date,
                        completedAt: completed ? date : nil)
    }

    func testParentsPrecedeTheirOwnChildrenWithoutDuplicates() {
        let first = task("first", created: 100)
        let second = task("second", created: 200)
        let firstOlder = task("first-older", parent: first.id, created: 110)
        let firstNewer = task("first-newer", parent: first.id, created: 120)
        let secondOlder = task("second-older", parent: second.id, created: 210)
        let secondNewer = task("second-newer", parent: second.id, created: 220)
        let all = [firstOlder, second, secondNewer, first, secondOlder, firstNewer]
        let snapshot = WorkspaceTaskListSnapshot(allTasks: all, scopedTasks: all + [first])

        let rows = WorkspaceTaskListSnapshot.rows(from: snapshot.pendingRoots)

        XCTAssertEqual(snapshot.pendingRoots.map(\.id), [second.id, first.id])
        XCTAssertEqual(rows.map(\.id), [second.id, secondNewer.id, secondOlder.id,
                                       first.id, firstNewer.id, firstOlder.id])
        XCTAssertEqual(rows.map(\.depth), [0, 1, 1, 0, 1, 1])
        XCTAssertEqual(Set(rows.map(\.id)).count, all.count)
        XCTAssertTrue(snapshot.completedRoots.isEmpty)
    }

    func testRecentChildRestoresOlderParentWithoutUnrelatedSibling() {
        let parent = task("older-parent", created: 1)
        let recent = task("recent-child", parent: parent.id, created: 100)
        let sibling = task("older-sibling", parent: parent.id, created: 2)
        let unrelated = task("unrelated-root", created: 3)
        let snapshot = WorkspaceTaskListSnapshot(allTasks: [parent, recent, sibling, unrelated],
                                                 scopedTasks: [recent])

        let rows = WorkspaceTaskListSnapshot.rows(from: snapshot.pendingRoots)

        XCTAssertEqual(rows.map(\.id), [parent.id, recent.id])
        XCTAssertTrue(rows[0].node.isContextOnly)
        XCTAssertFalse(rows[1].node.isContextOnly)
    }

    func testInboxIncludesCompletedChildrenOfMatchingParent() {
        let parent = task("parent")
        let pending = task("pending", parent: parent.id, created: 1)
        let completed = task("completed", parent: parent.id, created: 2, completed: true)
        let snapshot = WorkspaceTaskListSnapshot(allTasks: [parent, pending, completed],
                                                 scopedTasks: [parent], includeAllDescendants: true)

        XCTAssertEqual(WorkspaceTaskListSnapshot.rows(from: snapshot.pendingRoots).map(\.id),
                       [parent.id, pending.id, completed.id])
        XCTAssertTrue(snapshot.completedRoots.isEmpty)
    }

    func testParentSearchKeepsItsScopedChildren() {
        let parent = task("parent", title: "PyTrio 科研 PPT")
        let child = task("child", parent: parent.id, title: "整理叙事")
        let excludedChild = task("excluded", parent: parent.id, title: "旧资料")
        let other = task("other", title: "其他任务")
        let snapshot = WorkspaceTaskListSnapshot(allTasks: [parent, child, excludedChild, other],
                                                 scopedTasks: [parent, child, other], query: "  pytrio  ")

        XCTAssertEqual(WorkspaceTaskListSnapshot.rows(from: snapshot.pendingRoots).map(\.id),
                       [parent.id, child.id])
    }

    func testChildDescriptionSearchRetainsAncestorAndExcludesUnmatchedSibling() {
        let parent = task("parent", title: "制作 PPT")
        let matchingChild = task("matching", parent: parent.id, title: "整理资料", details: "梳理叙事逻辑")
        let sibling = task("sibling", parent: parent.id, title: "配图")
        let all = [parent, matchingChild, sibling]
        let snapshot = WorkspaceTaskListSnapshot(allTasks: all, scopedTasks: all, query: "叙事")

        XCTAssertEqual(WorkspaceTaskListSnapshot.rows(from: snapshot.pendingRoots).map(\.id),
                       [parent.id, matchingChild.id])
    }

    func testCompletedChildStaysUnderPendingParentWhileCompletedRootFormsOwnGroup() {
        let parent = task("pending-parent", created: 10)
        let pendingChild = task("pending-child", parent: parent.id, created: 11)
        let doneChild = task("done-child", parent: parent.id, created: 12, completed: true)
        let doneParent = task("done-parent", created: 20, completed: true)
        let doneParentChild = task("done-parent-child", parent: doneParent.id, created: 21, completed: true)
        let all = [doneChild, doneParent, parent, doneParentChild, pendingChild]
        let snapshot = WorkspaceTaskListSnapshot(allTasks: all, scopedTasks: all)

        XCTAssertEqual(WorkspaceTaskListSnapshot.rows(from: snapshot.pendingRoots).map(\.id),
                       [parent.id, pendingChild.id, doneChild.id])
        XCTAssertEqual(WorkspaceTaskListSnapshot.rows(from: snapshot.completedRoots).map(\.id),
                       [doneParent.id, doneParentChild.id])
    }

    func testCollapsingOneParentHidesOnlyItsDescendants() {
        let first = task("first", created: 100)
        let second = task("second", created: 200)
        let firstChild = task("first-child", parent: first.id)
        let secondChild = task("second-child", parent: second.id)
        let all = [first, second, firstChild, secondChild]
        let snapshot = WorkspaceTaskListSnapshot(allTasks: all, scopedTasks: all)

        let collapsed = WorkspaceTaskListSnapshot.rows(from: snapshot.pendingRoots,
                                                       collapsedIDs: [first.id])
        XCTAssertEqual(collapsed.map(\.id), [second.id, secondChild.id, first.id])
        XCTAssertEqual(WorkspaceTaskListSnapshot.rows(from: snapshot.pendingRoots).map(\.id),
                       [second.id, secondChild.id, first.id, firstChild.id])
    }
}
