import Foundation
import Darwin

/// Receives live keys and committed-data notifications. A small polling fallback
/// also refreshes after reconnects and when an older daemon is running.
final class LiveRefresher: ObservableObject {
    @Published private(set) var generation = 0
    @Published private(set) var liveEvents: [ActivityKeyEvent] = []
    @Published private(set) var isConnected = false

    private let lock = NSLock()
    private var stopFlag = false
    private var currentFD: Int32 = -1
    private var thread: Thread?
    private var pollTimer: Timer?
    private var pendingRefresh: DispatchWorkItem?
    private var liveBuffer = LiveEventBuffer()

    func start() {
        guard thread == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.generation += 1
        }
        let worker = Thread { [weak self] in self?.runLoop() }
        worker.qualityOfService = .utility
        worker.name = "toccata-studio.live-refresher"
        thread = worker
        worker.start()
    }

    func stop() {
        pollTimer?.invalidate()
        pendingRefresh?.cancel()
        lock.lock()
        stopFlag = true
        if currentFD >= 0 { shutdown(currentFD, SHUT_RDWR) }
        lock.unlock()
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopFlag
    }

    private func connectionChanged(_ connected: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isConnected = connected
            self.liveEvents.removeAll()
            self.liveBuffer.reset()
            self.generation += 1
        }
    }

    private func runLoop() {
        var backoff: TimeInterval = 0.5
        while !isStopped {
            let fd = openSocket()
            if fd >= 0 {
                backoff = 0.5
                connectionChanged(true)
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

    private func receive(_ data: Data) {
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = payload["type"] as? String else { return }
        if type == "updated" {
            DispatchQueue.main.async { [weak self] in self?.generation += 1 }
        } else if type == "key",
                  let timestamp = payload["ts"] as? NSNumber,
                  let keycode = payload["keycode"] as? NSNumber,
                  let kind = payload["kind"] as? String,
                  kind == "down" || kind == "up" {
            let event = ActivityKeyEvent(timestampMs: timestamp.int64Value,
                                         keycode: keycode.intValue, kind: kind == "down" ? 0 : 1)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.liveBuffer.append(event)
                self.liveEvents = self.liveBuffer.events
                // Throttle rather than debounce, so continuous typing still refreshes.
                guard self.pendingRefresh == nil else { return }
                let item = DispatchWorkItem { [weak self] in
                    self?.pendingRefresh = nil
                    self?.generation += 1
                }
                self.pendingRefresh = item
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
            }
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
        var event = rawEvent
        if event.kind == 0 {
            if downAt[event.keycode] == nil { downAt[event.keycode] = event.timestampMs }
        } else if let down = downAt.removeValue(forKey: event.keycode) {
            event.holdMs = max(0, event.timestampMs - down)
        }
        events.append(event)
        let cutoff = event.timestampMs - 5 * 60 * 1000
        guard let first = events.first, first.timestampMs < cutoff else { return }
        var held: [Int: Int] = [:]
        for (index, item) in events.enumerated() {
            if item.kind == 0 {
                if held[item.keycode] == nil { held[item.keycode] = index }
            } else {
                held.removeValue(forKey: item.keycode)
            }
        }
        let retainedDowns = Set(held.values)
        events = events.enumerated().compactMap { index, item in
            item.timestampMs >= cutoff || retainedDowns.contains(index) ? item : nil
        }
    }
}
