import AppKit
import SwiftUI
import XCTest
@testable import toccata_studio

/// Exercises native responder behavior with a real SwiftUI title field in an
/// unshown panel. This does not substitute for clicking a visible menu panel.
@MainActor
final class MenuEditorHostingViewTests: XCTestCase {
    func testInstallingEditorDoesNotBeginEditingItsTitle() async throws {
        let model = TitleFixtureModel()
        let panel = makePanel()
        defer { close(panel) }
        MenuEditorHostingView.install(in: panel, rootView: TitleFixture(model: model), onCancel: {})

        let title = try await waitForTitle("第一个任务", in: panel)
        XCTAssertNil(title.currentEditor(), "Merely browsing a task must not create a selected title field editor")
        XCTAssertFalse(panel.firstResponder is NSTextView)
        XCTAssertFalse(panel.isVisible)
        XCTAssertFalse(panel.isKeyWindow)
    }

    func testSwitchingTaskIdentityDoesNotSelectTheNewTitle() async throws {
        let model = TitleFixtureModel()
        let panel = makePanel()
        defer { close(panel) }
        MenuEditorHostingView.install(in: panel, rootView: TitleFixture(model: model), onCancel: {})
        _ = try await waitForTitle("第一个任务", in: panel)

        model.title = "另一个任务"
        model.id = UUID()
        let nextTitle = try await waitForTitle("另一个任务", in: panel)

        XCTAssertNil(nextTitle.currentEditor())
        XCTAssertFalse(panel.firstResponder is NSTextView)
        XCTAssertFalse(panel.isVisible)
        XCTAssertFalse(panel.isKeyWindow)
    }

    func testExplicitTitleEditingStillAcceptsTypingAndKeepsItsCaret() async throws {
        let model = TitleFixtureModel()
        let panel = makePanel()
        defer { close(panel) }
        MenuEditorHostingView.install(in: panel, rootView: TitleFixture(model: model), onCancel: {})
        let title = try await waitForTitle("第一个任务", in: panel)

        XCTAssertTrue(panel.makeFirstResponder(title))
        let editor = try XCTUnwrap(title.currentEditor() as? NSTextView)
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        editor.insertText("补充", replacementRange: NSRange(location: NSNotFound, length: 0))
        let updatedTitle = try await waitForTitle("第一个任务补充", in: panel)
        // Give the SwiftUI binding/focus update another turn to expose any
        // automatic focus reset scheduled by installing the neutral host.
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertTrue(updatedTitle.currentEditor() === editor)
        XCTAssertTrue(panel.firstResponder === editor)
        XCTAssertEqual(editor.string, "第一个任务补充")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: (editor.string as NSString).length, length: 0))
        XCTAssertFalse(panel.isVisible)
    }

    func testEscapeFromNeutralResponderClosesThroughTheCallback() async throws {
        let panel = makePanel()
        defer { close(panel) }
        var cancellationCount = 0
        MenuEditorHostingView.install(in: panel, rootView: Text("任务详情")) { cancellationCount += 1 }
        let responder = try XCTUnwrap(panel.firstResponder as? NSView)
        let escape = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53
        ))

        responder.keyDown(with: escape)

        XCTAssertEqual(cancellationCount, 1)
        XCTAssertFalse(panel.isVisible)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        return panel
    }

    private func close(_ panel: NSPanel) {
        panel.makeFirstResponder(nil)
        panel.initialFirstResponder = nil
        panel.contentView = nil
        panel.close()
    }

    private func waitForTitle(_ expected: String, in panel: NSPanel) async throws -> NSTextField {
        for _ in 0..<25 {
            panel.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 20_000_000)
            if let content = panel.contentView,
               let title = textFields(in: content).first(where: { $0.stringValue == expected }) {
                return title
            }
        }
        XCTFail("The unshown SwiftUI host did not render the expected native title field")
        throw FixtureError.titleNotRendered
    }

    private func textFields(in view: NSView) -> [NSTextField] {
        ((view as? NSTextField).map { [$0] } ?? []) + view.subviews.flatMap { textFields(in: $0) }
    }

    private enum FixtureError: Error { case titleNotRendered }
}

@MainActor
private final class TitleFixtureModel: ObservableObject {
    @Published var id = UUID()
    @Published var title = "第一个任务"
}

private struct TitleFixture: View {
    @ObservedObject var model: TitleFixtureModel

    var body: some View {
        TitleFixtureField(title: model.title)
            .id(model.id)
            .padding(24)
            .frame(width: 400, height: 300, alignment: .topLeading)
    }
}

private struct TitleFixtureField: View {
    @State var title: String
    @FocusState private var focused: Bool

    var body: some View {
        TextField("任务名称", text: $title, axis: .vertical)
            .textFieldStyle(.plain)
            .lineLimit(1...4)
            .focused($focused)
            .onAppear { focused = false }
    }
}
