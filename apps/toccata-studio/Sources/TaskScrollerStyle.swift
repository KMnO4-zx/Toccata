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
        guard let window else { return }
        // SwiftUI can replace a List's native scroll view while retaining this
        // background anchor, for example when an empty task list gains a row.
        // Rediscovery is coalesced per window; unchanged scroll views need no work.
        var ancestor = superview
        while let view = ancestor {
            if let scrollView = view as? NSScrollView {
                TaskScrollerWindowConfiguration.schedule(in: window, scrollView: scrollView)
                return
            }
            ancestor = view.superview
        }
        TaskScrollerWindowConfiguration.schedule(in: window)
    }
}

/// A window can contain several SwiftUI background anchors. Coalesce discovery
/// after their updates, then leave unchanged scrolling/layout to AppKit.
@MainActor
private final class TaskScrollerWindowConfiguration {
    private static let configurations = NSMapTable<NSWindow, TaskScrollerWindowConfiguration>(
        keyOptions: .weakMemory, valueOptions: .strongMemory
    )

    private weak var window: NSWindow?
    private let pendingScrollViews = NSHashTable<NSScrollView>.weakObjects()
    private var needsWindowDiscovery = false
    private var isScheduled = false

    private init(window: NSWindow) { self.window = window }

    static func schedule(in window: NSWindow, scrollView: NSScrollView? = nil) {
        let configuration: TaskScrollerWindowConfiguration
        if let existing = configurations.object(forKey: window) {
            configuration = existing
        } else {
            configuration = TaskScrollerWindowConfiguration(window: window)
            configurations.setObject(configuration, forKey: window)
        }
        if let scrollView { configuration.pendingScrollViews.add(scrollView) }
        else { configuration.needsWindowDiscovery = true }
        guard !configuration.isScheduled else { return }
        configuration.isScheduled = true
        DispatchQueue.main.async { [weak configuration] in configuration?.configure() }
    }

    private func configure() {
        isScheduled = false
        guard let contentView = window?.contentView else { return }
        let scrollViews = needsWindowDiscovery ? Self.scrollViews(in: contentView) : pendingScrollViews.allObjects
        needsWindowDiscovery = false
        pendingScrollViews.removeAllObjects()
        for scrollView in scrollViews { Self.configure(scrollView) }
    }

    private static func configure(_ scrollView: NSScrollView) {
        var changed = false
        if scrollView.scrollerStyle != .legacy {
            scrollView.scrollerStyle = .legacy
            changed = true
        }
        if scrollView.autohidesScrollers {
            scrollView.autohidesScrollers = false
            changed = true
        }
        if scrollView.hasVerticalScroller, !(scrollView.verticalScroller is TaskScroller) {
            let scroller = TaskScroller()
            scroller.controlSize = .small
            scrollView.verticalScroller = scroller
            changed = true
        }
        if scrollView.hasHorizontalScroller, !(scrollView.horizontalScroller is TaskScroller) {
            let scroller = TaskScroller()
            scroller.controlSize = .small
            scrollView.horizontalScroller = scroller
            changed = true
        }
        guard changed else { return }
        scrollView.tile()
        if scrollView.hasVerticalScroller, let vertical = scrollView.verticalScroller as? TaskScroller {
            present(vertical, in: scrollView)
        }
        if scrollView.hasHorizontalScroller, let horizontal = scrollView.horizontalScroller as? TaskScroller {
            present(horizontal, in: scrollView)
        }
    }

    private static func present(_ scroller: TaskScroller, in scrollView: NSScrollView) {
        scrollView.addSubview(scroller, positioned: .above, relativeTo: scrollView.documentView)
        scroller.updateVisibility()
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

    override var knobProportion: CGFloat {
        didSet { updateVisibility() }
    }

    func updateVisibility() {
        let shouldHide = knobProportion >= 1
        if isHidden != shouldHide { isHidden = shouldHide }
    }

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
