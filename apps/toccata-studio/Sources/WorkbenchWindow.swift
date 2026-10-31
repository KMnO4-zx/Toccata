import AppKit
import SwiftUI

/// Requests are consumed by the existing workbench, including while its window is hidden.
@MainActor
final class WorkbenchNavigation: ObservableObject {
    @Published var requestedSection: String?
}

struct WorkbenchRootView: View {
    @ObservedObject var navigation: WorkbenchNavigation
    let openAbout: () -> Void

    var body: some View {
        ContentView(requestedSection: $navigation.requestedSection, openAbout: openAbout)
    }
}

@MainActor
final class WorkbenchWindow: NSWindow {
    weak var activityKeyboardInputScope: ActivityKeyboardInputAnchorView?

    // NavigationSplitView may restore the native title while updating its toolbar.
    override var titleVisibility: NSWindow.TitleVisibility {
        get { super.titleVisibility }
        set { super.titleVisibility = .hidden }
    }

    override func keyDown(with event: NSEvent) {
        // Only keys already declined by the focused control reach this fallback.
        // The listen-only keyboard collector still receives the original event.
        if let scope = activityKeyboardInputScope,
           scope.isActive, scope.window === self, !scope.isHiddenOrHasHiddenAncestor,
           event.window === self, attachedSheet == nil,
           isKeyboardPreviewInput(event) {
            return
        }
        super.keyDown(with: event)
    }

    private func isKeyboardPreviewInput(_ event: NSEvent) -> Bool {
        // Keep shortcuts, input-source commands, function keys and accessibility
        // chords on the normal responder chain. Shift/Caps Lock still allow typing.
        guard event.modifierFlags.intersection([.command, .control, .option, .function]).isEmpty else {
            return false
        }
        switch event.keyCode {
        case 36, 51, 76: return true // Unhandled Return, Backspace, keypad Enter.
        default:
            guard let text = event.charactersIgnoringModifiers, !text.isEmpty else { return false }
            return text.unicodeScalars.allSatisfy {
                !CharacterSet.controlCharacters.contains($0) && !(0xF700...0xF8FF).contains($0.value)
            }
        }
    }
}

/// Track the selected page without taking focus or installing an event monitor.
/// The stable workbench root updates this even while the outgoing page animates.
struct ActivityKeyboardInputScope: NSViewRepresentable {
    let isActive: Bool

    func makeNSView(context: Context) -> ActivityKeyboardInputAnchorView {
        let view = ActivityKeyboardInputAnchorView()
        view.isActive = isActive
        return view
    }

    func updateNSView(_ view: ActivityKeyboardInputAnchorView, context: Context) {
        view.isActive = isActive
    }

    static func dismantleNSView(_ view: ActivityKeyboardInputAnchorView, coordinator: ()) {
        view.uninstall()
    }
}

final class ActivityKeyboardInputAnchorView: NSView {
    var isActive = false
    private weak var registeredWindow: WorkbenchWindow?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        uninstall()
        guard let window = window as? WorkbenchWindow else { return }
        registeredWindow = window
        window.activityKeyboardInputScope = self
    }

    func uninstall() {
        if registeredWindow?.activityKeyboardInputScope === self {
            registeredWindow?.activityKeyboardInputScope = nil
        }
        registeredWindow = nil
    }
}
