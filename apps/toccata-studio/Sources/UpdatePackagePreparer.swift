import AppKit
import CryptoKit
import Foundation
import Security

enum UpdateInstallFailure: Error {
    case location, integrity, package, incompatible, installer, save

    var message: String {
        switch self {
        case .location: return L10n.tr("请先将 Toccata 移到可写的应用程序文件夹，再使用应用内更新。")
        case .integrity: return L10n.tr("安装包校验未通过，原应用未改动。请重新下载。")
        case .package: return L10n.tr("安装包无效或不属于 Toccata，原应用未改动。")
        case .incompatible: return L10n.tr("此更新不兼容当前 Mac 或 macOS 版本。")
        case .installer: return L10n.tr("暂时无法安装更新，请稍后重试。")
        case .save: return L10n.tr("任务或键盘记录尚未保存，更新已暂停。请稍后重试安装。")
        }
    }
}

struct PreparedAppUpdate: Codable, Equatable {
    let target: URL
    let staged: URL
    let backup: URL
    let directory: URL
    let originalIdentity: String
    let version: String

    static func cleanUpSuccessfulInstallation(arguments: [String] = CommandLine.arguments, target: URL = Bundle.main.bundleURL) {
        guard let index = arguments.firstIndex(of: "--toccata-updated"), arguments.indices.contains(index + 1) else { return }
        let directory = URL(fileURLWithPath: arguments[index + 1]).standardizedFileURL
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        guard directory.deletingLastPathComponent().resolvingSymlinksInPath().path == temporary.path,
              directory.lastPathComponent.hasPrefix("ToccataUpdate-"),
              UUID(uuidString: String(directory.lastPathComponent.dropFirst("ToccataUpdate-".count))) != nil,
              (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false,
              let data = try? Data(contentsOf: directory.appendingPathComponent("plan.json")),
              let plan = try? JSONDecoder().decode(Self.self, from: data),
              plan.directory.standardizedFileURL.path == directory.path,
              plan.target.resolvingSymlinksInPath().path == target.resolvingSymlinksInPath().path,
              plan.backup.deletingLastPathComponent().path == plan.target.deletingLastPathComponent().path,
              plan.backup.lastPathComponent.hasPrefix(".Toccata-backup-"),
              UUID(uuidString: String(plan.backup.deletingPathExtension().lastPathComponent.dropFirst(".Toccata-backup-".count))) != nil,
              let info = try? UpdatePackagePreparer.appInfo(target),
              info["CFBundleShortVersionString"] as? String == plan.version,
              (try? UpdatePackagePreparer.appInfo(plan.backup)) != nil else { return }
        // Reached only after the replacement app has actually started.
        try? FileManager.default.removeItem(at: plan.backup)
        try? FileManager.default.removeItem(at: directory)
    }

    func discard() {
        try? FileManager.default.removeItem(at: staged)
        try? FileManager.default.removeItem(at: directory)
    }

    func startInstaller() async throws {
        let worker = Task.detached(priority: .userInitiated) {
            let script = directory.appendingPathComponent("install-update.sh")
            let ready = directory.appendingPathComponent("ready")
            try? FileManager.default.removeItem(at: ready)
            let log = directory.appendingPathComponent("install.log")
            FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
            let handle = try FileHandle(forWritingTo: log)
            defer { try? handle.close() }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [script.path, String(ProcessInfo.processInfo.processIdentifier),
                                 target.path, staged.path, backup.path, directory.path, originalIdentity, version]
            process.standardOutput = handle
            process.standardError = handle
            try process.run()
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline && process.isRunning {
                if FileManager.default.fileExists(atPath: ready.path) { return }
                try await Task.sleep(nanoseconds: 25_000_000)
            }
            if process.isRunning { process.terminate() }
            throw UpdateInstallFailure.installer
        }
        try await worker.value
    }
}

struct UpdatePackagePreparer {
    let target: URL
    init(target: URL = Bundle.main.bundleURL) { self.target = target }

    func prepare(_ update: AvailableUpdate, progress: @escaping @Sendable (Double?) -> Void) async throws -> PreparedAppUpdate {
        guard let package = update.package else { throw UpdateInstallFailure.package }
        try Self.checkLocation(target)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ToccataUpdate-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var complete = false
        defer { if !complete { try? FileManager.default.removeItem(at: directory) } }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 600
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: package.url)
        request.setValue("Toccata/\(AppVersion.current.version)", forHTTPHeaderField: "User-Agent")
        guard UpdateDownloadDelegate.permits(package.url) else { throw UpdateInstallFailure.package }
        let delegate = UpdateDownloadDelegate(size: package.size, progress: progress)
        let (temporary, response) = try await session.download(for: request, delegate: delegate)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let finalURL = http.url, UpdateDownloadDelegate.permits(finalURL) else { throw UpdateInstallFailure.integrity }
        try Task.checkCancellation()
        let archive = directory.appendingPathComponent("update.dmg")
        try FileManager.default.moveItem(at: temporary, to: archive)
        progress(nil)
        let worker = Task.detached(priority: .userInitiated) {
            try Self.stage(archive: archive, package: package, update: update, target: target, directory: directory)
        }
        let prepared = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
        if Task.isCancelled { prepared.discard(); throw CancellationError() }
        complete = true
        return prepared
    }

    static func checkLocation(_ target: URL) throws {
        let values = try? target.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .volumeIsReadOnlyKey])
        guard target.pathExtension == "app", values?.isDirectory == true,
              values?.isSymbolicLink != true, values?.volumeIsReadOnly != true,
              !target.path.contains("/AppTranslocation/"),
              FileManager.default.isWritableFile(atPath: target.path),
              FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) else { throw UpdateInstallFailure.location }
    }

    static func verifyArchive(_ archive: URL, package: UpdatePackage) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: archive.path)
        guard (attributes[.size] as? NSNumber)?.int64Value == package.size else { throw UpdateInstallFailure.integrity }
        let handle = try FileHandle(forReadingFrom: archive)
        defer { try? handle.close() }
        var digest = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            try Task.checkCancellation()
            digest.update(data: chunk)
        }
        let hash = digest.finalize().map { String(format: "%02x", $0) }.joined()
        guard hash == package.sha256 else { throw UpdateInstallFailure.integrity }
    }

    private static func stage(archive: URL, package: UpdatePackage, update: AvailableUpdate,
                              target: URL, directory: URL) throws -> PreparedAppUpdate {
        try verifyArchive(archive, package: package)
        let currentInfo = try appInfo(target)
        guard let currentVersion = currentInfo["CFBundleShortVersionString"] as? String,
              let installed = ReleaseVersion(currentVersion), let latest = ReleaseVersion(update.version),
              latest > installed else { throw UpdateInstallFailure.package }
        let team = try signingTeam(target)
        let originalIdentity = try run("/usr/bin/stat", ["-f", "%d:%i", target.path], directory: directory)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let mount = directory.appendingPathComponent("volume", isDirectory: true)
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: false)
        _ = try run("/usr/bin/hdiutil", ["attach", "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", mount.path, archive.path], directory: directory)
        defer {
            do { _ = try run("/usr/bin/hdiutil", ["detach", mount.path], directory: directory) }
            catch { _ = try? run("/usr/bin/hdiutil", ["detach", "-force", mount.path], directory: directory) }
        }
        try Task.checkCancellation()
        let candidate = mount.appendingPathComponent("Toccata.app")
        try validate(candidate, version: update.version, requiredTeam: team, directory: directory)
        let parent = target.deletingLastPathComponent()
        let token = UUID().uuidString
        let staged = parent.appendingPathComponent(".Toccata-update-\(token).app")
        let backup = parent.appendingPathComponent(".Toccata-backup-\(token).app")
        var complete = false
        defer { if !complete { try? FileManager.default.removeItem(at: staged) } }
        _ = try run("/usr/bin/ditto", [candidate.path, staged.path], directory: directory)
        try validate(staged, version: update.version, requiredTeam: team, directory: directory)
        try Task.checkCancellation()
        guard let script = AppResources.bundle.url(forResource: "install-update", withExtension: "sh") else { throw UpdateInstallFailure.installer }
        try FileManager.default.copyItem(at: script, to: directory.appendingPathComponent("install-update.sh"))
        let plan = PreparedAppUpdate(target: target, staged: staged, backup: backup, directory: directory,
                                     originalIdentity: originalIdentity, version: update.version)
        try JSONEncoder().encode(plan).write(to: directory.appendingPathComponent("plan.json"), options: .atomic)
        complete = true
        return plan
    }

    static func appInfo(_ app: URL) throws -> [String: Any] {
        guard let values = try? app.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink != true,
              let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == "com.toccata.studio",
              info["CFBundleExecutable"] as? String == "Toccata" else { throw UpdateInstallFailure.package }
        return info
    }

    static func validate(_ app: URL, version: String, requiredTeam: String?, directory: URL) throws {
        let info = try appInfo(app)
        guard info["CFBundleShortVersionString"] as? String == version else { throw UpdateInstallFailure.package }
        guard let minimum = info["LSMinimumSystemVersion"] as? String else { throw UpdateInstallFailure.incompatible }
        let components = minimum.split(separator: ".", omittingEmptySubsequences: false)
        let parts = components.compactMap { Int($0) }
        guard !parts.isEmpty, parts.count <= 3, parts.count == components.count,
              components.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }),
              ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(
                majorVersion: parts[0], minorVersion: parts.count > 1 ? parts[1] : 0,
                patchVersion: parts.count > 2 ? parts[2] : 0)) else { throw UpdateInstallFailure.incompatible }
        // Framework links may stay inside the app, never escape the verified bundle.
        let root = app.resolvingSymlinksInPath().path + "/"
        guard let entries = FileManager.default.enumerator(at: app, includingPropertiesForKeys: [.isSymbolicLinkKey]) else { throw UpdateInstallFailure.package }
        for case let url as URL in entries {
            if try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true,
               !url.resolvingSymlinksInPath().path.hasPrefix(root) { throw UpdateInstallFailure.package }
        }
        let team = try signingTeam(app)
        if let requiredTeam, requiredTeam != team { throw UpdateInstallFailure.integrity }
        for name in ["Toccata", "toccata-core"] {
            let binary = app.appendingPathComponent("Contents/MacOS/\(name)")
            guard FileManager.default.isExecutableFile(atPath: binary.path) else { throw UpdateInstallFailure.package }
            _ = try run("/usr/bin/lipo", [binary.path, "-verify_arch", UpdatePackage.architecture], directory: directory)
        }
    }

    private static func signingTeam(_ app: URL) throws -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode), nil) == errSecSuccess else {
            throw UpdateInstallFailure.integrity
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess else { throw UpdateInstallFailure.integrity }
        return (information as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }

    private static func run(_ executable: String, _ arguments: [String], directory: URL) throws -> String {
        let output = directory.appendingPathComponent("command-\(UUID()).log")
        FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: output) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        let deadline = Date().addingTimeInterval(60)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.025) }
        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.1)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            throw UpdateInstallFailure.installer
        }
        guard process.terminationStatus == 0 else {
            NSLog("Update preparation command %@ failed (%d): %@", executable, process.terminationStatus,
                  (try? String(contentsOf: output)) ?? "")
            throw UpdateInstallFailure.package
        }
        return (try? String(contentsOf: output)) ?? ""
    }
}

final class UpdateDownloadDelegate: NSObject, URLSessionDownloadDelegate {
    private let size: Int64
    private let progress: @Sendable (Double?) -> Void
    init(size: Int64, progress: @escaping @Sendable (Double?) -> Void) {
        self.size = size
        self.progress = progress
    }

    static func permits(_ url: URL) -> Bool {
        url.scheme == "https" && url.user == nil && url.password == nil && (url.port == nil || url.port == 443) &&
            ["github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com", "github-releases.githubusercontent.com"].contains(url.host ?? "")
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url.map(Self.permits) == true ? request : nil)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesWritten <= size else { downloadTask.cancel(); return }
        progress(Double(totalBytesWritten) / Double(max(1, size)))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
