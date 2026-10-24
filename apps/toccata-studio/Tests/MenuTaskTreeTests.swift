import Foundation
import XCTest
@testable import toccata_studio

final class MenuTaskTreeTests: XCTestCase {
    private func task(_ id: String, parent: String? = nil, created: TimeInterval = 0,
                      completed: Bool = false) -> TodoTask {
        let date = Date(timeIntervalSince1970: created)
        return TodoTask(id: id, parentID: parent, title: id, details: "", plannedDate: nil,
                        createdAt: date, updatedAt: date, completedAt: completed ? date : nil)
    }

    private func flatten(_ nodes: [MenuTaskTreeNode]) -> [MenuTaskTreeNode] {
        nodes.flatMap { [$0] + flatten($0.children) }
    }

    func testTimeViewRestoresAncestorsWithoutDuplicatingMatchesOrIncludingSiblings() {
        let root = task("root")
        let parent = task("parent", parent: root.id)
        let recent = task("recent", parent: parent.id, created: 100)
        let olderSibling = task("older", parent: parent.id)
        let result = MenuTaskTree.roots(allTasks: [root, parent, recent, olderSibling],
                                        matchingTasks: [recent, recent])

        XCTAssertEqual(result.map(\.id), [root.id])
        XCTAssertTrue(result[0].isContextOnly)
        XCTAssertEqual(result[0].children.map(\.id), [parent.id])
        XCTAssertTrue(result[0].children[0].isContextOnly)
        XCTAssertEqual(result[0].children[0].children.map(\.id), [recent.id])
        XCTAssertFalse(result[0].children[0].children[0].isContextOnly)
        XCTAssertEqual(flatten(result).count, 3)
    }

    func testMatchingParentAndChildStayInOneTree() {
        let parent = task("parent")
        let child = task("child", parent: parent.id)
        let result = MenuTaskTree.roots(allTasks: [parent, child], matchingTasks: [child, parent])

        XCTAssertEqual(result.map(\.id), [parent.id])
        XCTAssertEqual(result[0].children.map(\.id), [child.id])
        XCTAssertTrue(flatten(result).allSatisfy { !$0.isContextOnly })
    }

    func testInboxIncludesAllDescendantsIncludingCompletedSteps() {
        let parent = task("parent")
        let child = task("child", parent: parent.id, completed: true)
        let grandchild = task("grandchild", parent: child.id, completed: true)
        let other = task("unmatched-root")
        let result = MenuTaskTree.roots(allTasks: [parent, child, grandchild, other],
                                        matchingTasks: [parent], includeAllDescendants: true)

        XCTAssertEqual(flatten(result).map(\.id), [parent.id, child.id, grandchild.id])
        XCTAssertTrue(flatten(result).allSatisfy { !$0.isContextOnly })
    }

    func testCompletedChildrenRemainUnderTheirCompletedParent() {
        let parent = task("parent", completed: true)
        let child = task("child", parent: parent.id, completed: true)
        let result = MenuTaskTree.roots(allTasks: [parent, child], matchingTasks: [parent, child])

        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(result[0].task.isCompleted)
        XCTAssertTrue(result[0].children[0].task.isCompleted)
    }

    func testSiblingOrderUsesCompletionCreationAndStableID() {
        let parent = task("parent")
        let children = [task("done", parent: parent.id, created: 500, completed: true),
                        task("older", parent: parent.id, created: 100),
                        task("b", parent: parent.id, created: 200),
                        task("a", parent: parent.id, created: 200)]
        let result = MenuTaskTree.roots(allTasks: [parent] + children,
                                        matchingTasks: [parent], includeAllDescendants: true)

        XCTAssertEqual(result[0].children.map(\.id), ["a", "b", "older", "done"])
    }

    func testOrphanIsVisibleAsRootAndRetainsItsChildren() {
        let orphan = task("orphan", parent: "missing")
        let child = task("child", parent: orphan.id)
        let result = MenuTaskTree.roots(allTasks: [orphan, child], matchingTasks: [child])

        XCTAssertEqual(result.map(\.id), [orphan.id])
        XCTAssertEqual(result[0].children.map(\.id), [child.id])
    }

    func testDamagedCycleAndSelfParentProduceFiniteUniqueTrees() {
        let a = task("a", parent: "b")
        let b = task("b", parent: "c")
        let c = task("c", parent: "a")
        let child = task("child", parent: "b")
        let selfParent = task("self", parent: "self")
        let all = [c, child, selfParent, b, a]
        let result = MenuTaskTree.roots(allTasks: all, matchingTasks: all)

        XCTAssertEqual(result.map(\.id), ["a", "self"])
        XCTAssertEqual(flatten(result).count, all.count)
        XCTAssertEqual(Set(flatten(result).map(\.id)), Set(all.map(\.id)))
        XCTAssertEqual(MenuTaskTree.roots(allTasks: all.reversed(), matchingTasks: all.reversed()), result)
    }

    func testMatchMissingFromSnapshotStillAppearsAndEmptyMatchesStayEmpty() {
        let parent = task("parent")
        let recent = task("recent", parent: parent.id)
        let result = MenuTaskTree.roots(allTasks: [parent], matchingTasks: [recent])

        XCTAssertEqual(flatten(result).map(\.id), [parent.id, recent.id])
        XCTAssertTrue(MenuTaskTree.roots(allTasks: [parent], matchingTasks: []).isEmpty)
    }
}
