import Foundation
import XCTest
@testable import toccata_studio

final class TaskDragGeometryTests: XCTestCase {
    private let lane = CGRect(x: 100, y: 0, width: 300, height: 32)
    private let top = UUID()
    private let bottom = UUID()

    private var group: TaskDragGeometry.Group {
        TaskDragGeometry.Group(taskID: "parent", frame: CGRect(x: 100, y: 100, width: 300, height: 96),
                               topRegionID: top, bottomRegionID: bottom)
    }

    func testDropOverDescendantsUsesWholeGroupAndMarksItsOuterEdges() {
        let before = TaskDragGeometry.insertion(at: CGPoint(x: 200, y: 180), groups: [group], lane: lane)
        XCTAssertEqual(before?.taskID, "parent")
        XCTAssertEqual(before?.placement, .before)
        XCTAssertEqual(before?.regionID, top)

        let after = TaskDragGeometry.insertion(at: CGPoint(x: 200, y: 115), groups: [group], lane: lane)
        XCTAssertEqual(after?.taskID, "parent")
        XCTAssertEqual(after?.placement, .after)
        XCTAssertEqual(after?.regionID, bottom)
    }

    func testHorizontalSlackAndRowGapsAcceptDrops() {
        let above = TaskDragGeometry.insertion(at: CGPoint(x: 65, y: 212), groups: [group], lane: lane)
        XCTAssertEqual(above?.placement, .before)
        let below = TaskDragGeometry.insertion(at: CGPoint(x: 435, y: 80), groups: [group], lane: lane)
        XCTAssertEqual(below?.placement, .after)
    }

    func testFarOutsideLaneOrListIsNotAnAccidentalDrop() {
        XCTAssertNil(TaskDragGeometry.insertion(at: CGPoint(x: 55, y: 150), groups: [group], lane: lane))
        XCTAssertNil(TaskDragGeometry.insertion(at: CGPoint(x: 445, y: 150), groups: [group], lane: lane))
        XCTAssertNil(TaskDragGeometry.insertion(at: CGPoint(x: 200, y: 230), groups: [group], lane: lane))
        XCTAssertNil(TaskDragGeometry.insertion(at: CGPoint(x: 200, y: 60), groups: [group], lane: lane))
    }

    func testGapUsesNearestGroupRegardlessOfRegistrationOrder() {
        let next = TaskDragGeometry.Group(taskID: "next", frame: CGRect(x: 100, y: 50, width: 300, height: 32),
                                         topRegionID: UUID(), bottomRegionID: UUID())
        let point = CGPoint(x: 200, y: 88)
        let first = TaskDragGeometry.insertion(at: point, groups: [group, next], lane: lane)
        let reversed = TaskDragGeometry.insertion(at: point, groups: [next, group], lane: lane)
        XCTAssertEqual(first, reversed)
        XCTAssertEqual(first?.taskID, "next")
        XCTAssertEqual(first?.placement, .before)
    }

    func testNoVisibleTargetsDoesNotProduceAnInsertion() {
        let empty = TaskDragGeometry.Group(taskID: "hidden", frame: .zero,
                                          topRegionID: UUID(), bottomRegionID: UUID())
        XCTAssertNil(TaskDragGeometry.insertion(at: CGPoint(x: 200, y: 150), groups: [], lane: lane))
        XCTAssertNil(TaskDragGeometry.insertion(at: CGPoint(x: 200, y: 150), groups: [empty], lane: lane))
    }
}
