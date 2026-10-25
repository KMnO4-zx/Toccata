import Combine
import Darwin
import Foundation

@MainActor
final class CoreProcessController: ObservableObject {
    private let helperURL: URL?
    private let dataDirectory: URL
    private let socketPath: String
    private let socketIsReachable: (String) -> Bool
    private var process: Process?

    convenience init() {
        self.init(
            helperURL: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/toccata-core"),
            dataDirectory: AppPaths.supportDirectory,
            socketPath: AppPaths.socketPath,
            socketIsReachable: Self.probeSocket
        )
    }

    init(helperURL: URL?, dataDirectory: URL, socketPath: String,
         socketIsReachable: @escaping (String) -> Bool) {
        self.helperURL = helperURL
        self.dataDirectory = dataDirectory
        self.socketPath = socketPath
        self.socketIsReachable = socketIsReachable
    }

    @discardableResult
    func start() -> Bool {
        if let process, process.isRunning { return false }
        process = nil
        guard !socketIsReachable(socketPath) else { return false }
        guard let helperURL, FileManager.default.isExecutableFile(atPath: helperURL.path) else { return false }

        let process = Process()
        process.executableURL = helperURL
        var environment = ProcessInfo.processInfo.environment
        environment["TOCCATA_DATA_DIR"] = dataDirectory.path
        process.environment = environment
        do {
            try process.run()
            self.process = process
            return true
        } catch {
            NSLog("Unable to launch toccata-core: \(error.localizedDescription)")
            return false
        }
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
