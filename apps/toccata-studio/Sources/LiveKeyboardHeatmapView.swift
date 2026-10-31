import AppKit
import Combine
import SwiftUI

/// The exported heatmap stays static. This wrapper adds live, ephemeral feedback
/// only while the workbench keyboard is actually on screen (also when not key).
struct LiveKeyboardHeatmapView: View {
    @EnvironmentObject private var refresher: LiveRefresher
    @StateObject private var feedback = LiveKeyboardFeedback()
    @State private var isVisible = false
    let counts: [Int: Int]
    let totalCount: Int
    let fnMs: Int64
    let periodDescription: String

    var body: some View {
        KeyboardHeatmapView(counts: counts, totalCount: totalCount, fnMs: fnMs, periodDescription: periodDescription,
                            pressedKeys: feedback.state.pressedKeys)
            .overlay {
                KeyboardFeedbackBubbles(state: feedback.state)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .background(KeyboardFeedbackVisibility { visible in isVisible = visible })
            .onChange(of: isVisible) { visible in
                if visible { feedback.connect(to: refresher.keyboardUpdates.eraseToAnyPublisher()) }
                else { feedback.disconnect() }
            }
            .onAppear {
                if isVisible { feedback.connect(to: refresher.keyboardUpdates.eraseToAnyPublisher()) }
            }
            .onDisappear {
                isVisible = false
                feedback.disconnect()
            }
    }
}

private struct KeyboardFeedbackBubbles: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    let state: LiveKeyboardState

    var body: some View {
        // Only this lightweight overlay ticks. Neither statistics queries nor the
        // keyboard's static keycaps are driven by the animation clock.
        TimelineView(.animation(minimumInterval: reduceMotion ? 0.1 : 1.0 / 60,
                                paused: !state.hasEffects)) { _ in
            let now = ProcessInfo.processInfo.systemUptime
            GeometryReader { proxy in
                let layout = KeyboardLayout.magicKeyboard.scaled(toWidth: proxy.size.width)
                ZStack(alignment: .topLeading) {
                    ForEach(state.visibleBubbles(at: now)) { bubble in
                        if let key = layout.keys.first(where: { $0.key.code == bubble.keycode }) {
                            let age = max(0, now - bubble.startedAt)
                            let progress = min(1, age / LiveKeyboardState.bubbleLifetime)
                            let drift = reduceMotion ? 0 : 18 * progress + bubble.displacement(at: now)
                            badge("+1", holding: false)
                                .scaleEffect(reduceMotion ? 1 : min(1, 0.82 + age * 3))
                                .opacity(min(1, (1 - progress) / 0.6))
                                .position(x: key.frame.midX, y: key.frame.minY - 7 - drift)
                        }
                    }
                    ForEach(state.presses.keys.sorted(), id: \.self) { code in
                        if let press = state.presses[code], now - press.startedAt >= LiveKeyboardState.holdThreshold,
                           let key = layout.keys.first(where: { $0.key.code == code }) {
                            let seconds = max(0, now - press.startedAt)
                            RoundedRectangle(cornerRadius: min(7, key.frame.height * 0.18), style: .continuous)
                                .stroke(Color.accentColor.opacity(reduceMotion ? 0.3 : 0.3 + sin(seconds * 3) * 0.12), lineWidth: 2)
                                .frame(width: key.frame.width, height: key.frame.height)
                                .scaleEffect(reduceMotion ? 1 : 0.95)
                                .position(x: key.frame.midX, y: key.frame.midY + (reduceMotion ? 0 : 1.5))
                            badge(String(format: "+%.1f s", locale: Locale(identifier: "en_US_POSIX"), seconds), holding: true)
                                .position(x: min(max(key.frame.midX, 34), max(34, layout.size.width - 34)),
                                          y: key.frame.minY - 9)
                        }
                    }
                }
                .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
            }
        }
    }

    private func badge(_ text: String, holding: Bool) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(holding ? Color.white : Color.accentColor)
            .padding(.horizontal, holding ? 8 : 7)
            .padding(.vertical, 4)
            .background {
                Capsule().fill(holding ? Color.accentColor :
                    (colorScheme == .dark ? Color(nsColor: .controlBackgroundColor) : Color.white))
            }
            .overlay(Capsule().strokeBorder(Color.accentColor.opacity(holding ? 0 : 0.18), lineWidth: 0.7))
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.22 : 0.12), radius: 3, x: 0, y: 2)
            .fixedSize()
    }
}

private struct KeyboardFeedbackVisibility: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> KeyboardFeedbackVisibilityView {
        let view = KeyboardFeedbackVisibilityView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: KeyboardFeedbackVisibilityView, context: Context) {
        view.onChange = onChange
        view.scheduleCheck()
    }

    static func dismantleNSView(_ view: KeyboardFeedbackVisibilityView, coordinator: ()) {
        view.stopObserving()
    }
}

private final class KeyboardFeedbackVisibilityView: NSView {
    var onChange: ((Bool) -> Void)?
    private var observers: [NSObjectProtocol] = []
    private var lastVisible = false
    private var checkScheduled = false

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopObserving()
        let center = NotificationCenter.default
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification,
                     NSApplication.didHideNotification, NSApplication.didUnhideNotification,
                     NSView.boundsDidChangeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.scheduleCheck()
            })
        }
        scheduleCheck()
    }

    override func layout() {
        super.layout()
        scheduleCheck()
    }

    func scheduleCheck() {
        guard !checkScheduled else { return }
        checkScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.checkScheduled = false
            let visible = self.window.map {
                $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible)
            } ?? false
            let next = visible && !NSApp.isHidden && !self.isHiddenOrHasHiddenAncestor && !self.visibleRect.isEmpty
            guard next != self.lastVisible else { return }
            self.lastVisible = next
            self.onChange?(next)
        }
    }

    func stopObserving() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
}
