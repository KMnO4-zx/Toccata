import AppKit
import SwiftUI

enum MenuTaskListKey {
    case details
    case child
    case move(Int)
    case escape
}

/// Only the selected task list becomes first responder. Text fields and multiline
/// editors retain their own Tab / Return behavior.
struct MenuTaskListKeyboard: NSViewRepresentable {
    let focusRequest: Int
    let onKey: (MenuTaskListKey) -> Void

    func makeNSView(context: Context) -> MenuTaskListKeyView {
        MenuTaskListKeyView()
    }

    func updateNSView(_ view: MenuTaskListKeyView, context: Context) {
        view.onKey = onKey
        guard focusRequest > 0, view.focusRequest != focusRequest else { return }
        view.focusRequest = focusRequest
        view.requestListFocus()
    }
}

final class MenuTaskListKeyView: NSView {
    var onKey: ((MenuTaskListKey) -> Void)?
    var focusRequest = 0
    private var pendingFocus = false
    private var tabMonitor: Any?
    override var acceptsFirstResponder: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeTabMonitor()
        if window != nil {
            // AppKit may handle Tab as key-view traversal before keyDown reaches
            // an ordinary NSView. Intercept it only while this exact list view is
            // first responder, in this exact window. Editors remain untouched.
            tabMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window,
                      event.window === window, window.firstResponder === self,
                      event.keyCode == 48,
                      event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else {
                    return event
                }
                self.onKey?(.details)
                return nil
            }
        }
        if pendingFocus { requestListFocus() }
    }

    deinit { removeTabMonitor() }

    private func removeTabMonitor() {
        if let tabMonitor { NSEvent.removeMonitor(tabMonitor) }
        tabMonitor = nil
    }

    func requestListFocus() {
        pendingFocus = true
        DispatchQueue.main.async { [weak self] in
            guard let self, self.pendingFocus, let window = self.window else { return }
            self.pendingFocus = false
            window.makeFirstResponder(self)
        }
    }

    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else {
            super.keyDown(with: event)
            return
        }
        switch event.keyCode {
        case 48: onKey?(.details) // Tab
        case 36, 76: onKey?(.child) // Return / keypad Enter
        case 125: onKey?(.move(1))
        case 126: onKey?(.move(-1))
        case 53: onKey?(.escape)
        default: super.keyDown(with: event)
        }
    }
}
