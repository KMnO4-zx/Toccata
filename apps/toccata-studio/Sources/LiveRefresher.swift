import Foundation
import Darwin

/// 后台线程连接 daemon 的 Unix socket，收到任何键盘事件后 1s 防抖在主线程通知 UI 刷新。
/// daemon 不在时静默重连，指数退避封顶 15s；App 功能不依赖它。
final class LiveRefresher: ObservableObject {
    @Published private(set) var generation = 0

    private let socketPath = NSHomeDirectory() + "/Library/Application Support/Toccata/toccata.sock"
    private let lock = NSLock()
    private var stopFlag = false
    private var currentFD: Int32 = -1
    private var thread: Thread?
    private var pendingRefresh: DispatchWorkItem?

    func start() {
        guard thread == nil else { return }
        let thread = Thread { [weak self] in self?.runLoop() }
        thread.qualityOfService = .utility
        thread.name = "toccata-studio.live-refresher"
        self.thread = thread
        thread.start()
    }

    func stop() {
        lock.lock()
        stopFlag = true
        let fd = currentFD
        lock.unlock()
        if fd >= 0 { shutdown(fd, SHUT_RDWR) }
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopFlag
    }

    private func setCurrentFD(_ fd: Int32) {
        lock.lock()
        currentFD = fd
        lock.unlock()
    }

    private func runLoop() {
        var backoff: TimeInterval = 0.5
        while !isStopped {
            let fd = openSocket()
            if fd >= 0 {
                backoff = 0.5
                readLoop(fd: fd)
                close(fd)
                setCurrentFD(-1)
            }
            guard !isStopped else { break }
            Thread.sleep(forTimeInterval: backoff)
            backoff = min(backoff * 2, 15)
        }
    }

    /// 连接并发送订阅命令；失败返回 -1。
    private func openSocket() -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let pathBytes = socketPath.utf8CString.map { UInt8(bitPattern: $0) }
        guard pathBytes.count <= 104 else {
            close(fd)
            return -1
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
            buffer.copyBytes(from: pathBytes)
        }
        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else {
            close(fd)
            return -1
        }

        setCurrentFD(fd)
        let subscribe = "{\"cmd\":\"subscribe\"}\n"
        _ = subscribe.withCString { Darwin.send(fd, $0, strlen($0), 0) }
        return fd
    }

    /// 阻塞读取；任何字节都视为键盘事件触发防抖刷新。断线/出错返回后由外层重连。
    private func readLoop(fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while !isStopped {
            let n = recv(fd, &buffer, buffer.count, 0)
            if n <= 0 { return }
            scheduleRefresh()
        }
    }

    private func scheduleRefresh() {
        DispatchQueue.main.async {
            self.pendingRefresh?.cancel()
            let item = DispatchWorkItem { [weak self] in
                self?.generation += 1
            }
            self.pendingRefresh = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: item)
        }
    }
}
