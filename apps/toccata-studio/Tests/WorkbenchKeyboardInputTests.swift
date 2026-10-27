import AppKit
import SwiftUI
import XCTest
@testable import toccata_studio

/// Exercises AppKit dispatch through an unshown SwiftUI workbench. The final
/// responder records declined keys instead of letting the test emit alert sounds.
@MainActor
final class WorkbenchKeyboardInputTests: XCTestCase {
    func testActivitySilencesOnlyUnhandledTypingAfterTheHostingView() async throws {
        let fixture = KeyboardWindowFixture()
        defer { fixture.close() }
        try await fixture.waitForScope(active: true)
        XCTAssertTrue(fixture.window.makeFirstResponder(fixture.host.view))

        for key in [
            FixtureKey(0, "a"), FixtureKey(0, "A", modifiers: .shift),
            FixtureKey(0, "A", modifiers: .capsLock), FixtureKey(49, " "),
            FixtureKey(18, "1"), FixtureKey(0, "中"),
            FixtureKey(36, "\r"), FixtureKey(51, "\u{7f}"), FixtureKey(76, "\u{3}")
        ] {
            fixture.send(key)
        }
        XCTAssertTrue(fixture.fallback.keys.isEmpty)
        XCTAssertTrue(fixture.window.firstResponder === fixture.host.view)
        XCTAssertFalse(fixture.window.isVisible)

        // Prove this same dispatch path reaches the normal fallback off the page.
        fixture.model.isActive = false
        try await fixture.waitForScope(active: false)
        fixture.send(FixtureKey(0, "a"))
        XCTAssertEqual(fixture.fallback.keys.map(\.keyCode), [0])
    }

    func testShortcutsNavigationAndFunctionKeysContinueThroughTheResponderChain() async throws {
        let fixture = KeyboardWindowFixture()
        defer { fixture.close() }
        try await fixture.waitForScope(active: true)
        XCTAssertTrue(fixture.window.makeFirstResponder(fixture.host.view))
        let keys = [
            FixtureKey(0, "a", modifiers: .command),
            FixtureKey(0, "\u{1}", modifiers: .control),
            FixtureKey(0, "å", modifiers: .option),
            FixtureKey(0, "a", modifiers: .function),
            FixtureKey(123, "\u{f702}"), FixtureKey(124, "\u{f703}"),
            FixtureKey(125, "\u{f701}"), FixtureKey(126, "\u{f700}"),
            FixtureKey(115, "\u{f729}"), FixtureKey(119, "\u{f72b}"),
            FixtureKey(116, "\u{f72c}"), FixtureKey(121, "\u{f72d}"),
            FixtureKey(117, "\u{f728}"), FixtureKey(122, "\u{f704}"),
            FixtureKey(36, "\r", modifiers: .command)
        ]
        keys.forEach(fixture.send)

        XCTAssertEqual(fixture.fallback.keys.map(\.keyCode), keys.map(\.code))
        XCTAssertEqual(fixture.fallback.keys.map(\.modifierFlags), keys.map(\.modifiers))
    }

    func testAppKitHandlesTabAndEscapeTheSameWayOnAndOffActivityPage() async throws {
        let fixture = KeyboardWindowFixture()
        defer { fixture.close() }
        try await fixture.waitForScope(active: true)
        let keys = [FixtureKey(48, "\t"), FixtureKey(48, "\t", modifiers: .shift), FixtureKey(53, "\u{1b}")]
        for key in keys {
            XCTAssertTrue(fixture.window.makeFirstResponder(fixture.host.view))
            fixture.send(key)
        }
        let activeFallback = fixture.fallback.keys.map(\.keyCode)
        fixture.fallback.keys.removeAll()
        fixture.model.isActive = false
        try await fixture.waitForScope(active: false)
        for key in keys {
            XCTAssertTrue(fixture.window.makeFirstResponder(fixture.host.view))
            fixture.send(key)
        }
        XCTAssertEqual(fixture.fallback.keys.map(\.keyCode), activeFallback)
    }

    func testTextFieldEditingReceivesTypingAndDeletionBeforeTheQuietFallback() async throws {
        let fixture = KeyboardWindowFixture()
        defer { fixture.close() }
        try await fixture.waitForScope(active: true)
        let field = NSTextField(string: "task")
        field.frame = CGRect(x: 20, y: 20, width: 200, height: 28)
        fixture.host.view.addSubview(field)
        XCTAssertTrue(fixture.window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.setSelectedRange(NSRange(location: editor.string.count, length: 0))

        fixture.send(FixtureKey(0, "a"))
        XCTAssertEqual(editor.string, "taska")
        fixture.send(FixtureKey(51, "\u{7f}"))
        XCTAssertEqual(editor.string, "task")
        XCTAssertTrue(fixture.window.firstResponder === editor)
        XCTAssertTrue(fixture.fallback.keys.isEmpty)
    }

    func testNativeButtonKeyEquivalentsStillInvokeTheirAction() async throws {
        let fixture = KeyboardWindowFixture()
        defer { fixture.close() }
        try await fixture.waitForScope(active: true)
        let target = KeyboardButtonTarget()
        let button = NSButton(title: "Share", target: target, action: #selector(KeyboardButtonTarget.activate(_:)))
        button.frame = CGRect(x: 20, y: 20, width: 120, height: 28)
        button.keyEquivalent = "j"
        button.keyEquivalentModifierMask = .command
        fixture.host.view.addSubview(button)

        // AppKit resolves key equivalents before its ordinary keyDown fallback.
        XCTAssertTrue(fixture.window.performKeyEquivalent(with: fixture.event(FixtureKey(38, "j", modifiers: .command))))
        button.keyEquivalent = " "
        button.keyEquivalentModifierMask = []
        XCTAssertTrue(fixture.window.performKeyEquivalent(with: fixture.event(FixtureKey(49, " "))))
        XCTAssertEqual(target.activationCount, 2)
        XCTAssertTrue(fixture.fallback.keys.isEmpty)
    }

    func testChangingSelectedPageDoesNotTakeFocusAndImmediatelyRestoresFallback() async throws {
        let fixture = KeyboardWindowFixture()
        defer { fixture.close() }
        try await fixture.waitForScope(active: true)
        let field = NSTextField(string: "focused")
        field.frame = CGRect(x: 20, y: 20, width: 200, height: 28)
        fixture.host.view.addSubview(field)
        XCTAssertTrue(fixture.window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor())

        fixture.model.isActive = false
        try await fixture.waitForScope(active: false)
        XCTAssertTrue(fixture.window.firstResponder === editor)
        fixture.model.isActive = true
        try await fixture.waitForScope(active: true)
        XCTAssertTrue(fixture.window.firstResponder === editor)

        XCTAssertTrue(fixture.window.makeFirstResponder(fixture.host.view))
        fixture.send(FixtureKey(0, "a"))
        XCTAssertTrue(fixture.fallback.keys.isEmpty)
        fixture.model.isActive = false
        try await fixture.waitForScope(active: false)
        fixture.send(FixtureKey(0, "a"))
        XCTAssertEqual(fixture.fallback.keys.map(\.keyCode), [0])
    }

    func testRemovingScopeRestoresOrdinaryWindowBehavior() async throws {
        let fixture = KeyboardWindowFixture()
        defer { fixture.close() }
        try await fixture.waitForScope(active: true)
        XCTAssertTrue(fixture.window.makeFirstResponder(fixture.host.view))
        fixture.model.hasScope = false
        try await fixture.waitForScope(active: nil)
        fixture.send(FixtureKey(0, "a"))
        XCTAssertEqual(fixture.fallback.keys.map(\.keyCode), [0])

        fixture.model.hasScope = true
        try await fixture.waitForScope(active: true)
        fixture.send(FixtureKey(0, "a"))
        XCTAssertEqual(fixture.fallback.keys.map(\.keyCode), [0])
    }

    func testInactiveAndOtherWindowsKeepTheirOwnInputBehavior() async throws {
        let activity = KeyboardWindowFixture()
        let other = KeyboardWindowFixture(isActive: false)
        defer { activity.close(); other.close() }
        try await activity.waitForScope(active: true)
        try await other.waitForScope(active: false)
        XCTAssertTrue(activity.window.makeFirstResponder(activity.host.view))
        XCTAssertTrue(other.window.makeFirstResponder(other.host.view))
        activity.send(FixtureKey(0, "a"))
        other.send(FixtureKey(0, "a"))
        XCTAssertTrue(activity.fallback.keys.isEmpty)
        XCTAssertEqual(other.fallback.keys.map(\.keyCode), [0])

        // Even a directly forwarded event must belong to the scoped window.
        activity.window.keyDown(with: other.event(FixtureKey(0, "a")))
        XCTAssertEqual(activity.fallback.keys.map(\.keyCode), [0])
    }

    func testHiddenScopeDoesNotSilenceTheWindow() async throws {
        let fixture = KeyboardWindowFixture()
        defer { fixture.close() }
        try await fixture.waitForScope(active: true)
        XCTAssertTrue(fixture.window.makeFirstResponder(fixture.host.view))
        let scope = try XCTUnwrap(fixture.window.activityKeyboardInputScope)
        scope.isHidden = true
        fixture.send(FixtureKey(0, "a"))
        XCTAssertEqual(fixture.fallback.keys.map(\.keyCode), [0])
        scope.isHidden = false
        fixture.send(FixtureKey(0, "a"))
        XCTAssertEqual(fixture.fallback.keys.map(\.keyCode), [0])
    }
}

private struct FixtureKey {
    let code: UInt16
    let characters: String
    let modifiers: NSEvent.ModifierFlags

    init(_ code: UInt16, _ characters: String, modifiers: NSEvent.ModifierFlags = []) {
        self.code = code
        self.characters = characters
        self.modifiers = modifiers
    }
}

@MainActor
private final class KeyboardWindowFixture {
    let window: WorkbenchWindow
    let model: KeyboardScopeModel
    let host: NSHostingController<KeyboardScopeFixtureView>
    let fallback = KeyboardFallbackRecorder()

    init(isActive: Bool = true) {
        _ = NSApplication.shared
        model = KeyboardScopeModel(isActive: isActive)
        host = NSHostingController(rootView: KeyboardScopeFixtureView(model: model))
        window = WorkbenchWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: 300),
                                 styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        window.nextResponder = fallback
    }

    func event(_ key: FixtureKey) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: key.modifiers,
                        timestamp: 0, windowNumber: window.windowNumber, context: nil,
                        characters: key.characters, charactersIgnoringModifiers: key.characters,
                        isARepeat: false, keyCode: key.code)!
    }

    func send(_ key: FixtureKey) { window.sendEvent(event(key)) }

    func waitForScope(active: Bool?) async throws {
        for _ in 0..<25 {
            host.view.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 20_000_000)
            if let active {
                if let scope = window.activityKeyboardInputScope, scope.isActive == active { return }
            } else if window.activityKeyboardInputScope == nil { return }
        }
        XCTFail("SwiftUI did not install/update/remove the keyboard activity scope")
        throw FixtureError.scopeNotUpdated
    }

    func close() {
        window.makeFirstResponder(nil)
        window.contentViewController = nil
        window.nextResponder = nil
        window.close()
    }

    private enum FixtureError: Error { case scopeNotUpdated }
}

@MainActor
private final class KeyboardScopeModel: ObservableObject {
    @Published var isActive: Bool
    @Published var hasScope = true
    init(isActive: Bool) { self.isActive = isActive }
}

private struct KeyboardScopeFixtureView: View {
    @ObservedObject var model: KeyboardScopeModel
    var body: some View {
        Text("Keyboard activity")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                if model.hasScope { ActivityKeyboardInputScope(isActive: model.isActive) }
            }
    }
}

@MainActor
private final class KeyboardFallbackRecorder: NSResponder {
    var keys: [NSEvent] = []
    override func keyDown(with event: NSEvent) { keys.append(event) }
}

@MainActor
private final class KeyboardButtonTarget: NSObject {
    var activationCount = 0
    @objc func activate(_ sender: Any?) { activationCount += 1 }
}
