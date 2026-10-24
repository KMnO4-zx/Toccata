import AppKit
import SwiftUI

/// Observes a popover's actual host window without participating in hit testing.
@MainActor
struct MenuCompanionWindow: NSViewRepresentable {
    let presentation: MenuTaskPresentation

    func makeNSView(context: Context) -> WindowObserver {
        WindowObserver(presentation: presentation)
    }

    func updateNSView(_ view: WindowObserver, context: Context) {
        view.setPresentation(presentation)
    }

    static func dismantleNSView(_ view: WindowObserver, coordinator: ()) {
        view.setPresentation(nil)
    }

    final class WindowObserver: NSView {
        private weak var presentation: MenuTaskPresentation?
        private weak var registeredWindow: NSWindow?

        init(presentation: MenuTaskPresentation) {
            self.presentation = presentation
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { return nil }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            updateRegistration()
        }

        func setPresentation(_ newPresentation: MenuTaskPresentation?) {
            if presentation !== newPresentation {
                unregisterWindow()
                presentation = newPresentation
            }
            updateRegistration()
        }

        private func updateRegistration() {
            guard presentation != nil else { return }
            guard registeredWindow !== window else { return }
            unregisterWindow()
            if let window {
                presentation?.companionWindows.add(window)
                registeredWindow = window
            }
        }

        private func unregisterWindow() {
            if let registeredWindow {
                presentation?.companionWindows.remove(registeredWindow)
            }
            registeredWindow = nil
        }
    }
}
