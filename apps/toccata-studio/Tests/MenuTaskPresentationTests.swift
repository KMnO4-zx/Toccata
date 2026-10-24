import Foundation
import XCTest
@testable import toccata_studio

@MainActor
final class MenuTaskPresentationTests: XCTestCase {
    private enum EditorEvent: Equatable {
        case show(String, MenuEditorField?)
        case hide
    }

    private final class EventLog {
        var events: [EditorEvent] = []
    }

    private func fixture() -> (MenuTaskPresentation, EventLog) {
        let presentation = MenuTaskPresentation()
        let log = EventLog()
        presentation.onShowEditor = { id, focus in log.events.append(.show(id, focus)) }
        presentation.onDismissEditor = { log.events.append(.hide) }
        return (presentation, log)
    }

    func testRepeatedClickOpensClosesAndReopensSameTask() async {
        let (presentation, log) = fixture()
        XCTAssertFalse(presentation.isEditorVisible)
        XCTAssertNil(presentation.selectedTaskID)

        presentation.toggleTask("A")
        XCTAssertTrue(presentation.isEditorVisible)
        XCTAssertEqual(presentation.selectedTaskID, "A")
        XCTAssertNil(presentation.focusRequest)

        presentation.toggleTask("A")
        XCTAssertFalse(presentation.isEditorVisible)
        XCTAssertEqual(presentation.selectedTaskID, "A")
        XCTAssertNil(presentation.focusRequest)

        presentation.toggleTask("A")
        XCTAssertTrue(presentation.isEditorVisible)
        XCTAssertEqual(presentation.selectedTaskID, "A")
        XCTAssertEqual(log.events, [.show("A", nil), .hide, .show("A", nil)])
    }

    func testClickingDifferentTaskSwitchesEditorWithoutClosing() async {
        let (presentation, log) = fixture()
        presentation.toggleTask("A")
        presentation.toggleTask("B")

        XCTAssertTrue(presentation.isEditorVisible)
        XCTAssertEqual(presentation.selectedTaskID, "B")
        XCTAssertNil(presentation.focusRequest)
        XCTAssertEqual(log.events, [.show("A", nil), .show("B", nil)])
    }

    func testDismissPreservesSelectionAndNextClickReopensTask() async {
        let (presentation, log) = fixture()
        presentation.selectTask("A", focus: .description)
        presentation.dismissEditor()

        XCTAssertFalse(presentation.isEditorVisible)
        XCTAssertEqual(presentation.selectedTaskID, "A")
        XCTAssertNil(presentation.focusRequest)

        presentation.toggleTask("A")
        XCTAssertTrue(presentation.isEditorVisible)
        XCTAssertEqual(presentation.selectedTaskID, "A")
        XCTAssertEqual(log.events, [.show("A", .description), .hide, .show("A", nil)])
    }

    func testRepeatedKeyboardRequestsAlwaysOpenAndIssueFreshFocus() async throws {
        let (presentation, log) = fixture()
        let fields: [MenuEditorField] = [.description, .description, .child, .child]
        var tokens = Set<UUID>()

        for field in fields {
            presentation.selectTask("A", focus: field)
            XCTAssertTrue(presentation.isEditorVisible)
            XCTAssertEqual(presentation.selectedTaskID, "A")
            let request = try XCTUnwrap(presentation.focusRequest)
            XCTAssertEqual(request.field, field)
            XCTAssertTrue(tokens.insert(request.token).inserted,
                          "Repeated Tab or Enter must request focus again, never toggle the editor off")
        }

        XCTAssertEqual(log.events, fields.map { .show("A", $0) })
    }

    func testControllerHideClearsVisibilityWithoutAnotherHideCallback() async {
        let (presentation, log) = fixture()
        presentation.selectTask("A", focus: .child)

        presentation.editorDidHide()
        presentation.editorDidHide()
        XCTAssertFalse(presentation.isEditorVisible)
        XCTAssertEqual(presentation.selectedTaskID, "A")
        XCTAssertNil(presentation.focusRequest)
        XCTAssertEqual(log.events, [.show("A", .child)])

        presentation.toggleTask("A")
        XCTAssertTrue(presentation.isEditorVisible)
        XCTAssertEqual(presentation.selectedTaskID, "A")
        XCTAssertEqual(log.events, [.show("A", .child), .show("A", nil)])
    }
}
