import Darwin
import Foundation

final class DaemonClient {
    var onKeyEvent: ((_ keycode: UInt16, _ isDown: Bool) -> Void)?

    private let queue = DispatchQueue(label: "toccata.overlay.daemon-client", qos: .utility)
    private let lock = NSLock()
    private var _stopped = false
    private var stopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _stopped
    }

    func start() {
        queue.async { self.reconnectLoop() }
    }

    func stop() {
        lock.lock()
        _stopped = true
        lock.unlock()
    }

    private func reconnectLoop() {
        var backoff: UInt32 = 1
        while !stopped {
            let hadConnection = runSession()
            if stopped { break }
            if hadConnection { backoff = 1 }
            sleep(backoff)
            backoff = min(backoff * 2, 15)
        }
    }

    /// Returns true if a connection was established (and later dropped), false if connect failed.
    private func runSession() -> Bool {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }

        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_un()
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.stride)
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathCapacity = MemoryLayout.size(ofValue: addr.sun_path)
        let pathOK = ToccataPaths.socketPath.withCString { cstr in
            _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: pathCapacity) { dest in
                    strncpy(dest, cstr, pathCapacity - 1)
                }
            }
            return strlen(cstr) < pathCapacity
        }
        guard pathOK else { return false }

        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.stride))
            }
        }
        guard rc == 0 else { return false }

        guard sendSubscribe(fd: fd) else { return true }

        var buffer = [UInt8](repeating: 0, count: 8192)
        var pending = Data()
        let newline = UInt8(ascii: "\n")
        while !stopped {
            let n = Darwin.read(fd, &buffer, buffer.count)
            if n <= 0 { return true }
            pending.append(contentsOf: buffer[0..<n])
            while let nl = pending.firstIndex(of: newline) {
                let line = pending[pending.startIndex..<nl]
                if !line.isEmpty { handleLine(Data(line)) }
                pending.removeSubrange(pending.startIndex...nl)
            }
        }
        return true
    }

    private func sendSubscribe(fd: Int32) -> Bool {
        let bytes = Array(#"{"cmd":"subscribe"}"#.utf8) + [UInt8(ascii: "\n")]
        var sent = 0
        while sent < bytes.count {
            let n = bytes.withUnsafeBufferPointer { buf in
                Darwin.send(fd, buf.baseAddress! + sent, bytes.count - sent, 0)
            }
            if n <= 0 { return false }
            sent += n
        }
        return true
    }

    private func handleLine(_ data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any],
              let type = dict["type"] as? String else { return }
        guard type == "key",
              let code = (dict["keycode"] as? NSNumber)?.uint16Value,
              let kind = dict["kind"] as? String else { return }
        onKeyEvent?(code, kind == "down")
    }
}
