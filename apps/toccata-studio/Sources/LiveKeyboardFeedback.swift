import Combine
import Foundation

enum LiveKeyboardUpdate {
    case key(ActivityKeyEvent)
    case reset
}

/// Presentation only: never writes counts or activity duration. Use a monotonic
/// clock for animation so wall-clock corrections cannot strand a held key.
struct LiveKeyboardState: Equatable {
    static let bubbleLifetime: TimeInterval = 0.5
    static let holdThreshold: TimeInterval = 0.35
    static let minimumPressDuration: TimeInterval = 0.12
    static let bubblesPerKey = 4

    struct Press: Equatable {
        let startedAt: TimeInterval
        let timestampMs: Int64
        let bubbleID: UInt64
    }

    struct Bubble: Identifiable, Equatable {
        let id: UInt64
        let keycode: Int
        let startedAt: TimeInterval
        var pushFrom: Double = 0
        var pushTo: Double = 0
        var pushedAt: TimeInterval

        func displacement(at now: TimeInterval) -> Double {
            let elapsed = max(0, now - pushedAt)
            // A small damped spring nudges older bubbles out of the new one's way.
            let progress = 1 - exp(-elapsed * 24) * cos(elapsed * 22)
            return pushFrom + (pushTo - pushFrom) * progress
        }
    }

    private(set) var presses: [Int: Press] = [:]
    private(set) var pulseUntil: [Int: TimeInterval] = [:]
    private(set) var bubbles: [Bubble] = []
    private var nextID: UInt64 = 0

    var pressedKeys: Set<Int> { Set(presses.keys).union(pulseUntil.keys) }
    var hasEffects: Bool { !presses.isEmpty || !pulseUntil.isEmpty || !bubbles.isEmpty }
    var nextExpiration: TimeInterval? {
        (Array(pulseUntil.values) + bubbles.map { $0.startedAt + Self.bubbleLifetime }).min()
    }

    mutating func receive(_ event: ActivityKeyEvent, at now: TimeInterval) {
        guard (0...127).contains(event.keycode), event.kind == 0 || event.kind == 1 else { return }
        advance(to: now)
        if event.kind == 0 {
            guard presses[event.keycode] == nil else { return } // Never count autorepeat visually.
            let id = addBubble(keycode: event.keycode, at: now)
            presses[event.keycode] = Press(startedAt: now, timestampMs: event.timestampMs, bubbleID: id)
            pulseUntil[event.keycode] = now + Self.minimumPressDuration
        } else if let press = presses[event.keycode], event.timestampMs >= press.timestampMs {
            presses.removeValue(forKey: event.keycode)
            let duration = Double(event.timestampMs - press.timestampMs) / 1_000
            if duration >= Self.holdThreshold || now - press.startedAt >= Self.holdThreshold {
                bubbles.removeAll { $0.id == press.bubbleID }
                _ = addBubble(keycode: event.keycode, at: now)
            }
        }
    }

    mutating func advance(to now: TimeInterval) {
        pulseUntil = pulseUntil.filter { $0.value > now }
        bubbles.removeAll { now - $0.startedAt >= Self.bubbleLifetime }
    }

    func visibleBubbles(at now: TimeInterval) -> [Bubble] {
        bubbles.filter { bubble in
            guard now - bubble.startedAt < Self.bubbleLifetime else { return false }
            guard let press = presses[bubble.keycode], press.bubbleID == bubble.id else { return true }
            return now - press.startedAt < Self.holdThreshold
        }
    }

    @discardableResult
    private mutating func addBubble(keycode: Int, at now: TimeInterval) -> UInt64 {
        for index in bubbles.indices where bubbles[index].keycode == keycode {
            bubbles[index].pushFrom = bubbles[index].displacement(at: now)
            bubbles[index].pushTo += 18
            bubbles[index].pushedAt = now
        }
        let olderIDs = bubbles.filter { $0.keycode == keycode }.map(\.id)
        let removeIDs = Set(olderIDs.prefix(max(0, olderIDs.count - Self.bubblesPerKey + 1)))
        bubbles.removeAll { removeIDs.contains($0.id) }
        nextID &+= 1
        bubbles.append(Bubble(id: nextID, keycode: keycode, startedAt: now, pushedAt: now))
        return nextID
    }
}

@MainActor
final class LiveKeyboardFeedback: ObservableObject {
    @Published private(set) var state = LiveKeyboardState()
    private var subscription: AnyCancellable?
    private var expiry: DispatchWorkItem?

    func connect(to updates: AnyPublisher<LiveKeyboardUpdate, Never>) {
        guard subscription == nil else { return }
        subscription = updates.receive(on: DispatchQueue.main).sink { [weak self] update in
            guard let self else { return }
            switch update {
            case .key(let event):
                var next = self.state
                next.receive(event, at: ProcessInfo.processInfo.systemUptime)
                if next != self.state { self.state = next }
                self.scheduleExpiration()
            case .reset: self.clear()
            }
        }
    }

    func disconnect() {
        subscription?.cancel()
        subscription = nil
        clear()
    }

    private func clear() {
        expiry?.cancel()
        expiry = nil
        if state.hasEffects { state = LiveKeyboardState() }
    }

    private func scheduleExpiration() {
        expiry?.cancel()
        expiry = nil
        guard let deadline = state.nextExpiration else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            var next = self.state
            next.advance(to: ProcessInfo.processInfo.systemUptime)
            if next != self.state { self.state = next }
            self.scheduleExpiration()
        }
        expiry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.001, deadline - ProcessInfo.processInfo.systemUptime), execute: work)
    }
}
