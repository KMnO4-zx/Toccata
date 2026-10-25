import AppKit
import SwiftUI

struct TaskScrollerStyle: NSViewRepresentable {
    func makeNSView(context: Context) -> TaskScrollerAnchorView {
        TaskScrollerAnchorView()
    }

    func updateNSView(_ view: TaskScrollerAnchorView, context: Context) {
        view.configureScrollViews()
    }
}

final class TaskScrollerAnchorView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureScrollViews()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        configureScrollViews()
    }

    func configureScrollViews() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let contentView = self.window?.contentView else { return }
            for scrollView in Self.scrollViews(in: contentView) {
                scrollView.scrollerStyle = .legacy
                scrollView.autohidesScrollers = false
                if scrollView.hasVerticalScroller, !(scrollView.verticalScroller is TaskScroller) {
                    let scroller = TaskScroller()
                    scroller.controlSize = .small
                    scrollView.verticalScroller = scroller
                }
                if scrollView.hasHorizontalScroller, !(scrollView.horizontalScroller is TaskScroller) {
                    let scroller = TaskScroller()
                    scroller.controlSize = .small
                    scrollView.horizontalScroller = scroller
                }
                scrollView.tile()
                if scrollView.hasVerticalScroller, let vertical = scrollView.verticalScroller {
                    Self.present(vertical, in: scrollView)
                }
                if scrollView.hasHorizontalScroller, let horizontal = scrollView.horizontalScroller {
                    Self.present(horizontal, in: scrollView)
                }
            }
        }
    }

    private static func present(_ scroller: NSScroller, in scrollView: NSScrollView) {
        scrollView.addSubview(scroller, positioned: .above, relativeTo: scrollView.documentView)
        scroller.isHidden = scroller.knobProportion >= 1
        scroller.needsDisplay = true
    }

    private static func scrollViews(in view: NSView) -> [NSScrollView] {
        if let scrollView = view as? NSScrollView { return [scrollView] }
        return view.subviews.flatMap(scrollViews(in:))
    }
}

private final class TaskScroller: NSScroller {
    private static let thumbColor = NSColor(name: "Toccata.Scrollbar.thumb") { appearance in
        let white: CGFloat = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? 0.50 : 0.58
        return NSColor(srgbRed: white, green: white, blue: white, alpha: 1)
    }

    override class var isCompatibleWithOverlayScrollers: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override class func scrollerWidth(for controlSize: NSControl.ControlSize,
                                      scrollerStyle: NSScroller.Style) -> CGFloat {
        8
    }

    override func drawKnob() {
        let isVertical = bounds.height >= bounds.width
        let knob = rect(for: .knob).insetBy(dx: isVertical ? 0 : 2, dy: isVertical ? 2 : 0)
        guard knob.width > 0, knob.height > 0 else { return }
        let indicator = isVertical
            ? CGRect(x: bounds.midX - 2, y: knob.minY, width: 4, height: knob.height)
            : CGRect(x: knob.minX, y: bounds.midY - 2, width: knob.width, height: 4)
        Self.thumbColor.setFill()
        NSBezierPath(roundedRect: indicator, xRadius: 2, yRadius: 2).fill()
    }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}
}
