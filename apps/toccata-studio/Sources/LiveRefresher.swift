import Foundation
import Darwin
import Combine

/// Receives live keys and committed-data notifications. A small polling fallback
/// also refreshes after reconnects and when an older daemon is running.
final class LiveRefresher: ObservableObject {
    // Transient feedback bypasses the 300 ms statistics batch. Only the visible
    // keyboard subscribes; key events do not invalidate the workspace here.
    let keyboardUpdates = PassthroughSubject<LiveKeyboardUpdate, Never>()
    @Published private(set) var generation = 0
    @Published private(set) var liveEvents: [ActivityKeyEvent] = []
    @Published private(set) var isConnected = false
    @Published private(set) var captureEnabled = false
    @Published private(set) var permissionRequired = false

    private let lock = NSLock()
    private var stopFlag = false
    private var currentFD: Int32 = -1
    private var thread: Thread?
    private var pollTimer: Timer?
    private var pendingRefresh: DispatchWorkItem?
    private var pendingUpdates: [PendingLiveUpdate] = []
    private var liveBuffer = LiveEventBuffer()
    private let refreshInterval: TimeInterval

    init(refreshInterval: TimeInterval = 0.3) {
        self.refreshInterval = refreshInterval
    }

    private enum PendingLiveUpdate {
        case connection(connected: Bool, enabled: Bool, permissionRequired: Bool)
        case capture(enabled: Bool, permissionRequired: Bool)
        case key(ActivityKeyEvent)
        case persistedData
    }

    func start() {
        guard thread == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.enqueue(.persistedData)
        }
        let worker = Thread { [weak self] in self?.runLoop() }
        worker.qualityOfService = .utility
        worker.name = "toccata-studio.live-refresher"
        thread = worker
        worker.start()
    }

    func stop() {
        pollTimer?.invalidate()
        lock.lock()
        stopFlag = true
        pendingRefresh?.cancel()
        pendingRefresh = nil
        pendingUpdates.removeAll()
        if currentFD >= 0 { shutdown(currentFD, SHUT_RDWR) }
        lock.unlock()
        keyboardUpdates.send(.reset)
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopFlag
    }

    private func connectionChanged(_ connected: Bool) {
        enqueue(.connection(connected: connected, enabled: false, permissionRequired: false))
    }

    // Ingestion happens on the socket thread. One queued main-thread job owns
    // each batch, instead of publishing every key-down and key-up separately.
    private func enqueue(_ update: PendingLiveUpdate) {
        lock.lock()
        guard !stopFlag else { lock.unlock(); return }
        pendingUpdates.append(update)
        let item: DispatchWorkItem?
        if pendingRefresh == nil {
            item = DispatchWorkItem { [weak self] in self?.publishPendingUpdates() }
            pendingRefresh = item
        } else {
            item = nil
        }
        lock.unlock()
        switch update {
        case .key(let event): keyboardUpdates.send(.key(event))
        case .connection, .capture(enabled: false, permissionRequired: _): keyboardUpdates.send(.reset)
        default: break
        }
        if let item {
            DispatchQueue.main.asyncAfter(deadline: .now() + refreshInterval, execute: item)
        }
    }

    private func publishPendingUpdates() {
        lock.lock()
        guard !stopFlag, !pendingUpdates.isEmpty else { lock.unlock(); return }
        let updates = pendingUpdates
        pendingUpdates.removeAll(keepingCapacity: true)
        pendingRefresh = nil
        lock.unlock()

        var connected = isConnected
        var enabled = captureEnabled
        var required = permissionRequired
        var keys: [ActivityKeyEvent] = []
        var eventsChanged = false
        var shouldRefresh = false
        for update in updates {
            switch update {
            case let .connection(nextConnected, nextEnabled, nextRequired):
                if connected != nextConnected {
                    liveBuffer.reset()
                    keys.removeAll(keepingCapacity: true)
                    eventsChanged = !liveEvents.isEmpty
                    shouldRefresh = true
                }
                shouldRefresh = shouldRefresh || enabled != nextEnabled || required != nextRequired
                connected = nextConnected
                enabled = nextEnabled
                required = nextRequired
            case let .capture(nextEnabled, nextRequired):
                shouldRefresh = shouldRefresh || enabled != nextEnabled || required != nextRequired
                enabled = nextEnabled
                required = nextRequired
            case let .key(event):
                keys.append(event)
                enabled = true
                required = false
                shouldRefresh = true
            case .persistedData:
                shouldRefresh = true
            }
        }
        if !keys.isEmpty {
            liveBuffer.append(contentsOf: keys)
            eventsChanged = true
        }
        if isConnected != connected { isConnected = connected }
        if captureEnabled != enabled { captureEnabled = enabled }
        if permissionRequired != required { permissionRequired = required }
        if eventsChanged { liveEvents = liveBuffer.events }
        if shouldRefresh { generation += 1 }
    }

    private func runLoop() {
        var backoff: TimeInterval = 0.5
        while !isStopped {
            let fd = openSocket()
            if fd >= 0 {
                backoff = 0.5
                readLoop(fd: fd)
                lock.lock()
                currentFD = -1
                close(fd)
                lock.unlock()
                connectionChanged(false)
            }
            guard !isStopped else { break }
            Thread.sleep(forTimeInterval: backoff)
            backoff = min(backoff * 2, 15)
        }
    }

    private func openSocket() -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = AppPaths.socketPath.utf8CString.map { UInt8(bitPattern: $0) }
        guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            return -1
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { close(fd); return -1 }
        let subscribe = Array("{\"cmd\":\"subscribe\"}\n".utf8)
        var sent = 0
        while sent < subscribe.count {
            let count = subscribe.withUnsafeBufferPointer {
                Darwin.send(fd, $0.baseAddress! + sent, subscribe.count - sent, 0)
            }
            guard count > 0 else { close(fd); return -1 }
            sent += count
        }
        lock.lock()
        if stopFlag {
            close(fd)
            lock.unlock()
            return -1
        }
        currentFD = fd
        lock.unlock()
        return fd
    }

    private func readLoop(fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 8192)
        var pending = Data()
        while !isStopped {
            let count = recv(fd, &buffer, buffer.count, 0)
            if count <= 0 { return }
            pending.append(contentsOf: buffer.prefix(count))
            while let newline = pending.firstIndex(of: 10) {
                let line = Data(pending[..<newline])
                pending.removeSubrange(...newline)
                receive(line)
            }
        }
    }

    /// Shared parser for the socket stream; publication is batched independently
    /// of how many protocol lines arrive in one read.
    func receive(_ data: Data) {
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = payload["type"] as? String else { return }
        if type == "hello" {
            enqueue(.connection(connected: true,
                                enabled: payload["capture_enabled"] as? Bool ?? false,
                                permissionRequired: payload["permission_required"] as? Bool ?? false))
        } else if type == "capture", let enabled = payload["enabled"] as? Bool {
            enqueue(.capture(enabled: enabled,
                             permissionRequired: payload["permission_required"] as? Bool ?? false))
        } else if type == "updated" {
            enqueue(.persistedData)
        } else if type == "key",
                  let timestamp = payload["ts"] as? NSNumber,
                  let keycode = payload["keycode"] as? NSNumber,
                  let kind = payload["kind"] as? String,
                  kind == "down" || kind == "up" {
            enqueue(.key(ActivityKeyEvent(timestampMs: timestamp.int64Value,
                                          keycode: keycode.intValue, kind: kind == "down" ? 0 : 1)))
        }
    }

}

/// Retain a bounded live history while preserving holds that exceed that history.
/// Completed holds carry their duration before the matching down is discarded.
struct LiveEventBuffer {
    private(set) var events: [ActivityKeyEvent] = []
    private var downAt: [Int: Int64] = [:]

    mutating func reset() {
        events.removeAll()
        downAt.removeAll()
    }

    mutating func append(_ rawEvent: ActivityKeyEvent) {
        append(contentsOf: [rawEvent])
    }

    /// Publish and trim once per batch; copying a five-minute history on every
    /// physical key event made typing invalidate the full SwiftUI view tree.
    mutating func append(contentsOf rawEvents: [ActivityKeyEvent]) {
        guard !rawEvents.isEmpty else { return }
        for rawEvent in rawEvents {
            var event = rawEvent
            if event.kind == 0 {
                if downAt[event.keycode] == nil { downAt[event.keycode] = event.timestampMs }
            } else if let down = downAt.removeValue(forKey: event.keycode) {
                event.holdMs = max(0, event.timestampMs - down)
            }
            events.append(event)
        }
        guard let latest = rawEvents.last?.timestampMs else { return }
        let cutoff = latest - 5 * 60 * 1000
        guard let first = events.first, first.timestampMs < cutoff else { return }
        events = events.filter { event in
            event.timestampMs >= cutoff || (event.kind == 0 && downAt[event.keycode] == event.timestampMs)
        }
    }
}
