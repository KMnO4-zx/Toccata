import Foundation
import XCTest
@testable import toccata_studio

final class WorkspaceSplitLayoutTests: XCTestCase {
    func testSharedFractionUsesAllAvailableWidth() {
        let columns = WorkspaceSplitLayout.columns(totalWidth: 1000, fraction: 0.48)
        XCTAssertEqual(columns.primary, 474.24, accuracy: 0.001)
        XCTAssertEqual(columns.detail, 513.76, accuracy: 0.001)
        XCTAssertEqual(columns.primary + columns.detail + WorkspaceSplitLayout.dividerWidth, 1000)
    }

    func testDividerCannotHideEitherColumn() {
        let leading = WorkspaceSplitLayout.columns(totalWidth: 1000, fraction: 0)
        let trailing = WorkspaceSplitLayout.columns(totalWidth: 1000, fraction: 1)
        XCTAssertEqual(leading.primary, WorkspaceSplitLayout.minimumPrimaryWidth)
        XCTAssertEqual(trailing.detail, WorkspaceSplitLayout.minimumDetailWidth)
    }

    func testTinyWindowKeepsBothColumnsNonnegative() {
        let columns = WorkspaceSplitLayout.columns(totalWidth: 400, fraction: 0.9)
        XCTAssertEqual(columns.primary, 194)
        XCTAssertEqual(columns.detail, 194)
        XCTAssertGreaterThanOrEqual(columns.primary, 0)
        XCTAssertGreaterThanOrEqual(columns.detail, 0)
    }
}
