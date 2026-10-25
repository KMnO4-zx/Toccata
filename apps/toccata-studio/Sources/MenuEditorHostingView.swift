import AppKit
import SwiftUI

/// Browsing a task must not start editing its first text field. Establish a
/// neutral native responder before SwiftUI installs the title and description.
@MainActor
final class MenuEditorHostingView: NSView {
    private var onCancel: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }

    static func install<Content: View>(in panel: NSPanel, rootView: Content,
                                      onCancel: @escaping () -> Void) {
        let container = MenuEditorHostingView(frame: panel.contentView?.bounds ?? .zero)
        container.onCancel = onCancel
        panel.contentView = container
        panel.initialFirstResponder = container
        panel.makeFirstResponder(container)

        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = container.bounds
        hostingView.autoresizingMask = [.width, .height]
        container.addSubview(hostingView)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53,
           event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
            cancelOperation(nil)
        } else {
            super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) { onCancel?() }
}
