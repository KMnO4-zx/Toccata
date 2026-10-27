import AppKit
import SwiftUI

struct WorkspaceSplitLayout {
    static let minimumPrimaryWidth: CGFloat = 360
    static let minimumDetailWidth: CGFloat = 330
    static let dividerWidth: CGFloat = 12

    static func columns(totalWidth: CGFloat, fraction: CGFloat) -> (primary: CGFloat, detail: CGFloat) {
        let available = max(0, totalWidth - dividerWidth)
        guard available >= minimumPrimaryWidth + minimumDetailWidth else {
            let primary = available / 2
            return (primary, available - primary)
        }
        let primary = min(max(available * fraction, minimumPrimaryWidth), available - minimumDetailWidth)
        return (primary, available - primary)
    }

    static func fraction(totalWidth: CGFloat, fraction: CGFloat) -> Double {
        let available = max(1, totalWidth - dividerWidth)
        return Double(columns(totalWidth: totalWidth, fraction: fraction).primary / available)
    }
}

struct WorkspaceSplitView<Primary: View, Detail: View>: View {
    @AppStorage("workspacePrimaryColumnFraction") private var fraction = 0.48
    private let primary: Primary
    private let detail: Detail

    init(@ViewBuilder primary: () -> Primary, @ViewBuilder detail: () -> Detail) {
        self.primary = primary()
        self.detail = detail()
    }

    var body: some View {
        GeometryReader { proxy in
            let columns = WorkspaceSplitLayout.columns(totalWidth: proxy.size.width, fraction: fraction)
            HStack(spacing: 0) {
                primary
                    .frame(width: columns.primary, height: proxy.size.height)
                    .clipped()
                WorkspaceDivider(fraction: fraction, totalWidth: proxy.size.width) {
                    fraction = $0
                }
                .frame(width: WorkspaceSplitLayout.dividerWidth, height: proxy.size.height)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(L10n.tr("调整任务与详情宽度"))
                .accessibilityValue(String(format: "%.0f%%", WorkspaceSplitLayout.fraction(
                    totalWidth: proxy.size.width, fraction: fraction) * 100))
                .accessibilityAdjustableAction { direction in
                    let current = WorkspaceSplitLayout.fraction(totalWidth: proxy.size.width, fraction: fraction)
                    switch direction {
                    case .increment: fraction = Swift.min(Swift.max(current + 0.04, 0), 1)
                    case .decrement: fraction = Swift.min(Swift.max(current - 0.04, 0), 1)
                    @unknown default: break
                    }
                }
                detail
                    .frame(width: columns.detail, height: proxy.size.height)
                    .clipped()
            }
        }
    }
}

private struct WorkspaceDivider: NSViewRepresentable {
    let fraction: Double
    let totalWidth: CGFloat
    let onChange: (Double) -> Void

    func makeNSView(context: Context) -> WorkspaceDividerView {
        let view = WorkspaceDividerView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: WorkspaceDividerView, context: Context) {
        view.fraction = fraction
        view.totalWidth = totalWidth
        view.onChange = onChange
    }
}

private final class WorkspaceDividerView: NSView {
    var fraction = 0.48 {
        didSet { needsDisplay = true }
    }
    var totalWidth: CGFloat = 0
    var onChange: (Double) -> Void = { _ in }
    private var dragStart: (x: CGFloat, fraction: Double)?
    private var tracking: NSTrackingArea?

    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSBezierPath(rect: NSRect(x: bounds.midX - 0.5, y: 0, width: 1, height: bounds.height)).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = (event.locationInWindow.x, effectiveFraction)
        window?.makeFirstResponder(self)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStart else { return }
        adjust(by: event.locationInWindow.x - dragStart.x, from: dragStart.fraction)
    }

    override func mouseUp(with event: NSEvent) {
        dragStart = nil
    }

    override func mouseEntered(with event: NSEvent) {
        NSCursor.resizeLeftRight.set()
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .slider }
    override func accessibilityLabel() -> String? { L10n.tr("调整任务与详情宽度") }
    override func accessibilityValue() -> Any? {
        String(format: "%.0f%%", effectiveFraction * 100)
    }

    override func accessibilityPerformIncrement() -> Bool {
        adjust(by: 0.04)
        return true
    }

    override func accessibilityPerformDecrement() -> Bool {
        adjust(by: -0.04)
        return true
    }

    private var effectiveFraction: Double {
        let available = max(1, totalWidth - WorkspaceSplitLayout.dividerWidth)
        let columns = WorkspaceSplitLayout.columns(totalWidth: totalWidth, fraction: fraction)
        return Double(columns.primary / available)
    }

    private func adjust(by delta: Double, from start: Double? = nil) {
        let available = max(1, totalWidth - WorkspaceSplitLayout.dividerWidth)
        let next = (start ?? effectiveFraction) + delta / available
        onChange(Swift.min(Swift.max(next, 0), 1))
    }
}
