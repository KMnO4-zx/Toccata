import AppKit
import SwiftUI
import XCTest
@testable import toccata_studio

@MainActor
final class WorkspaceSidebarTests: XCTestCase {
    func testMouseClicksActivateEveryDestination() async throws {
        let fixture = SidebarFixture()
        defer { fixture.close() }

        for destination in WorkspaceSection.allCases {
            try await fixture.press(destination)
            XCTAssertEqual(fixture.model.selection, destination)
        }
    }

    func testArrowKeysCrossGroupsAfterPressingSidebarButton() async throws {
        let fixture = SidebarFixture()
        defer { fixture.close() }
        try await fixture.press(.review)
        XCTAssertEqual(fixture.model.selection, .review)

        fixture.send(keyCode: 125, characters: "\u{f701}")
        try await fixture.settle()
        XCTAssertEqual(fixture.model.selection, .activity)
        fixture.send(keyCode: 126, characters: "\u{f700}")
        try await fixture.settle()
        XCTAssertEqual(fixture.model.selection, .review)

        try await fixture.press(.ranking)
        fixture.send(keyCode: 125, characters: "\u{f701}")
        try await fixture.settle()
        XCTAssertEqual(fixture.model.selection, .generalSettings)
        fixture.send(keyCode: 125, characters: "\u{f701}")
        try await fixture.settle()
        XCTAssertEqual(fixture.model.selection, .generalSettings)
        fixture.send(keyCode: 126, characters: "\u{f700}")
        try await fixture.settle()
        XCTAssertEqual(fixture.model.selection, .ranking)
        try await fixture.press(.tasks)
        fixture.send(keyCode: 126, characters: "\u{f700}")
        try await fixture.settle()
        XCTAssertEqual(fixture.model.selection, .tasks)
    }

    func testProgrammaticNavigationPreservesEditorFocusAndArrowKeys() async throws {
        let fixture = SidebarFixture()
        defer { fixture.close() }
        // Start with real sidebar focus before moving into a text editor.
        try await fixture.press(.inbox)
        let field = NSTextField(string: "Focused editor")
        field.frame = CGRect(x: 250, y: 30, width: 220, height: 28)
        fixture.host.view.addSubview(field)
        XCTAssertTrue(fixture.window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.setSelectedRange(NSRange(location: 4, length: 0))

        for destination in [WorkspaceSection.activity, .tasks] {
            fixture.model.selection = destination
            try await fixture.settle()
            XCTAssertTrue(fixture.window.firstResponder === editor)
            let previousCaret = editor.selectedRange().location
            fixture.send(keyCode: 123, characters: "\u{f702}")
            XCTAssertEqual(editor.selectedRange().location, previousCaret - 1)
            fixture.send(keyCode: 125, characters: "\u{f701}")
            try await fixture.settle()
            XCTAssertEqual(fixture.model.selection, destination)
            XCTAssertTrue(fixture.window.firstResponder === editor)
        }
    }
}

@MainActor
private final class SidebarFixture {
    let model = SidebarFixtureModel()
    let window: NSWindow
    let host: NSHostingController<SidebarFixtureView>

    init() {
        _ = NSApplication.shared
        host = NSHostingController(rootView: SidebarFixtureView(model: model))
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 520, height: 420),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        window.title = "Toccata Sidebar Interaction Test"
        window.makeKeyAndOrderFront(nil)
    }

    func press(_ destination: WorkspaceSection) async throws {
        try await settle()
        // SwiftUI installs its hit regions during display, after layout.
        let bitmap = try XCTUnwrap(host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds))
        host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
        // Row centers in this fixed-size fixture, measured from its rendered layout.
        let rowCenters: [WorkspaceSection: CGFloat] = [
            .tasks: 37, .inbox: 69, .taskCalendar: 101, .review: 133,
            .activity: 198, .ranking: 230, .generalSettings: 295
        ]
        let fromTop = rowCenters[destination]!
        let point = NSPoint(x: 110, y: host.view.isFlipped ? fromTop : host.view.bounds.height - fromTop)
        let location = host.view.convert(point, to: nil)
        let timestamp = ProcessInfo.processInfo.systemUptime
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [],
                                      timestamp: timestamp, windowNumber: window.windowNumber, context: nil,
                                      eventNumber: 1, clickCount: 1, pressure: 1)!
        let up = NSEvent.mouseEvent(with: .leftMouseUp, location: location, modifierFlags: [],
                                    timestamp: timestamp + 0.01, windowNumber: window.windowNumber, context: nil,
                                    eventNumber: 2, clickCount: 1, pressure: 0)!
        window.sendEvent(down)
        window.sendEvent(up)
        try await settle()
    }

    func settle() async throws {
        for _ in 0..<5 {
            host.view.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func send(keyCode: UInt16, characters: String) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                                    characters: characters, charactersIgnoringModifiers: characters,
                                    isARepeat: false, keyCode: keyCode)!
        window.sendEvent(event)
    }

    func close() {
        window.makeFirstResponder(nil)
        window.contentViewController = nil
        window.close()
    }
}

@MainActor
private final class SidebarFixtureModel: ObservableObject {
    @Published var selection: WorkspaceSection? = .tasks
}

private struct SidebarFixtureView: View {
    @ObservedObject var model: SidebarFixtureModel

    var body: some View {
        HStack(spacing: 0) {
            WorkspaceSidebar(selection: $model.selection, openCount: 7)
                .frame(width: 220)
            Color.clear
        }
        .frame(width: 520, height: 420)
    }
}
