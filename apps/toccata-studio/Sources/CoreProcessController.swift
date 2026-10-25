import Combine
import CoreGraphics
import Darwin
import Foundation

@MainActor
final class CoreProcessController: ObservableObject {
    private let helperURL: URL?
    private let dataDirectory: URL
    private let socketPath: String
    private let socketIsReachable: (String) -> Bool
    private let preflightAccess: () -> Bool
    private let requestAccess: () -> Bool
    private let permitsPermissionPrompt: Bool
    private var process: Process?
    private var stopRequests = 0

    convenience init() {
        self.init(
            helperURL: Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/toccata-core"),
            dataDirectory: AppPaths.supportDirectory,
            socketPath: AppPaths.socketPath,
            socketIsReachable: Self.probeSocket
        )
    }

    init(helperURL: URL?, dataDirectory: URL, socketPath: String,
         socketIsReachable: @escaping (String) -> Bool,
         preflightAccess: @escaping () -> Bool = { CGPreflightListenEventAccess() },
         requestAccess: @escaping () -> Bool = { CGRequestListenEventAccess() },
         permitsPermissionPrompt: Bool = Bundle.main.bundleURL.pathExtension == "app") {
        self.helperURL = helperURL
        self.dataDirectory = dataDirectory
        self.socketPath = socketPath
        self.socketIsReachable = socketIsReachable
        self.preflightAccess = preflightAccess
        self.requestAccess = requestAccess
        self.permitsPermissionPrompt = permitsPermissionPrompt
    }

    @discardableResult
    func start(requestPermission: Bool = true) -> Bool {
        // Health checks are cheap and silent while a helper is already available.
        guard stopRequests == 0 else { return false }
        if let process, process.isRunning { return false }
        process = nil
        guard !socketIsReachable(socketPath) else { return false }
        guard let helperURL, FileManager.default.isExecutableFile(atPath: helperURL.path) else { return false }

        let allowed = preflightAccess()
        NSLog("Input monitoring preflight (studio): \(allowed)")
        try? FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        try? "studio preflight: \(allowed)\n".write(
            to: dataDirectory.appendingPathComponent("studio-preflight.log"),
            atomically: true,
            encoding: .utf8
        )
        if requestPermission && !allowed && permitsPermissionPrompt {
            NSLog("Input monitoring request (studio): \(requestAccess())")
        }

        let process = Process()
        process.executableURL = helperURL
        var environment = ProcessInfo.processInfo.environment
        environment["TOCCATA_DATA_DIR"] = dataDirectory.path
        environment["TOCCATA_REQUEST_INPUT_PERMISSION"] = requestPermission ? "1" : "0"
        process.environment = environment
        var log: FileHandle?
        do {
            try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
            let logURL = dataDirectory.appendingPathComponent("core.log")
            if !FileManager.default.fileExists(atPath: logURL.path) { try Data().write(to: logURL) }
            let handle = try FileHandle(forWritingTo: logURL)
            log = handle
            try handle.seekToEnd()
            process.standardOutput = handle
            process.standardError = handle
            process.terminationHandler = { _ in try? handle.close() }
            try process.run()
            self.process = process
            return true
        } catch {
            try? log?.close()
            NSLog("Unable to launch toccata-core: \(error.localizedDescription)")
            return false
        }
    }

    /// Call only after a user opens the workbench. A helper started silently at
    /// login may already be running, so this cannot depend on start()'s guards.
    @discardableResult
    func requestInputMonitoringPermission() -> Bool {
        if preflightAccess() { return true }
        guard permitsPermissionPrompt else { return false }
        let allowed = requestAccess()
        NSLog("Input monitoring request (studio): \(allowed)")
        return allowed
    }

    /// Only this controller's child receives SIGTERM. A reused external service is
    /// never signalled. Returning false keeps ownership so quitting can be retried
    /// without leaving an untracked helper or starting a second one.
    @discardableResult
    func stop(timeout: TimeInterval = 6) async -> Bool {
        guard let ownedProcess = process else { return true }
        guard ownedProcess.isRunning else {
            process = nil
            return true
        }

        stopRequests += 1
        defer { stopRequests -= 1 }
        // Concurrent quit requests share the same shutdown signal, but each may
        // wait with its own timeout. start() stays disabled until they all finish.
        if stopRequests == 1 { ownedProcess.terminate() }
        let duration = timeout.isFinite ? max(0, timeout) : 6
        let deadline = ProcessInfo.processInfo.systemUptime + duration
        while ownedProcess.isRunning {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return false }
            do {
                let nanoseconds = UInt64(max(1, min(0.05, remaining) * 1_000_000_000))
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                // Cancellation must not turn this wait into a main-thread spin.
                if ownedProcess.isRunning { return false }
            }
        }
        if process === ownedProcess { process = nil }
        return true
    }

    private static func probeSocket(_ path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = path.utf8CString.map { UInt8(bitPattern: $0) }
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return false }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
    }
}
