import Foundation
import XCTest
@testable import toccata_studio

final class MenuPanelLayoutTests: XCTestCase {
    func testEditorAppearsLeftOfListAlignedWithSelectedRow() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 875)
        let list = CGRect(x: 1030, y: 200, width: 380, height: 660)
        let row = CGRect(x: 20, y: 150, width: 340, height: 45)
        let editor = MenuPanelLayout.editorFrame(list: list, row: row, screen: screen)
        XCTAssertEqual(editor.maxX, list.minX)
        XCTAssertEqual(editor.maxY, list.maxY - row.minY)
        XCTAssertTrue(screen.contains(editor))
    }

    func testLowerRowKeepsEditorInsideScreenWithoutChangingList() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 875)
        let list = CGRect(x: 1030, y: 200, width: 380, height: 660)
        let editor = MenuPanelLayout.editorFrame(list: list,
            row: CGRect(x: 0, y: 600, width: 340, height: 40), screen: screen)
        XCTAssertEqual(editor.minY, 8)
        XCTAssertEqual(editor.maxX, list.minX)
        XCTAssertTrue(screen.contains(editor))
    }

    func testLeftEdgeUsesAvailableRightSide() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 875)
        let list = CGRect(x: 8, y: 200, width: 380, height: 660)
        let editor = MenuPanelLayout.editorFrame(list: list, row: nil, screen: screen)
        XCTAssertEqual(editor.minX, list.maxX)
        XCTAssertTrue(screen.contains(editor))
    }

    func testExternalDisplayWithNegativeOriginUsesItsOwnBounds() {
        let screen = CGRect(x: -1920, y: 40, width: 1920, height: 1040)
        let list = MenuPanelLayout.listFrame(anchor: CGRect(x: -100, y: 1080, width: 24, height: 24), screen: screen)
        let editor = MenuPanelLayout.editorFrame(list: list,
            row: CGRect(x: 0, y: 300, width: 340, height: 40), screen: screen)
        XCTAssertTrue(screen.contains(list))
        XCTAssertTrue(screen.contains(editor))
        XCTAssertEqual(editor.maxX, list.minX)
    }

    func testShortScreenClampsBothPanels() {
        let screen = CGRect(x: 0, y: 0, width: 1024, height: 600)
        let list = MenuPanelLayout.listFrame(anchor: CGRect(x: 1000, y: 600, width: 24, height: 24), screen: screen)
        let editor = MenuPanelLayout.editorFrame(list: list, row: nil, screen: screen)
        XCTAssertTrue(screen.contains(list))
        XCTAssertTrue(screen.contains(editor))
        XCTAssertLessThanOrEqual(list.height, screen.height - 24)
    }

    func testPanelRevealKeepsItsSizeAndHorizontalAnchor() {
        let frame = CGRect(x: 700, y: 300, width: 312, height: 554)
        let reveal = MenuPanelLayout.revealFrame(for: frame)
        XCTAssertEqual(reveal.size, frame.size)
        XCTAssertEqual(reveal.minX, frame.minX)
        XCTAssertEqual(reveal.maxY, frame.maxY - 6)
        XCTAssertEqual(reveal.offsetBy(dx: 0, dy: 6), frame)
    }
}
