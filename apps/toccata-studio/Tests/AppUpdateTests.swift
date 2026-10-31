import AppKit
import CryptoKit
import XCTest
@testable import toccata_studio

@MainActor
final class UpdateAssetTests: XCTestCase {
    func testSelectsArchitectureAndConstructsTrustedDownloadURL() async throws {
        let service = service(assets: [asset("x86_64"), asset("universal"), asset("arm64")])
        let update = try await service.check(current: current, architecture: "arm64")
        XCTAssertEqual(update?.package?.url.absoluteString,
                       "https://github.com/KMnO4-zx/Toccata/releases/download/v0.2.0/Toccata-0.2.0-arm64.dmg")
        XCTAssertEqual(update?.package?.size, 123)
        XCTAssertEqual(update?.package?.sha256, String(repeating: "a", count: 64))
    }

    func testUniversalFallbackAndUnsupportedArchitecture() async throws {
        let universal = try await service(assets: [asset("universal")]).check(current: current, architecture: "arm64")
        XCTAssertTrue(universal?.package?.url.lastPathComponent.hasSuffix("universal.dmg") == true)
        let unsupported = try await service(assets: [asset("x86_64")]).check(current: current, architecture: "arm64")
        XCTAssertNotNil(unsupported)
        XCTAssertNil(unsupported?.package)
    }

    func testMissingInvalidOrAmbiguousDigestKeepsManualReleaseLink() async throws {
        var missing = asset("arm64"); missing.removeValue(forKey: "digest")
        var invalid = asset("arm64"); invalid["digest"] = "sha256:no"
        var tooLarge = asset("arm64"); tooLarge["size"] = 1_073_741_825
        var notUploaded = asset("arm64"); notUploaded["state"] = "new"
        var wrongName = asset("arm64"); wrongName["name"] = "../Toccata-0.2.0-arm64.dmg"
        for assets in [[missing], [invalid], [tooLarge], [notUploaded], [wrongName], [asset("arm64"), asset("arm64")]] {
            let update = try await service(assets: assets).check(current: current, architecture: "arm64")
            XCTAssertNotNil(update)
            XCTAssertNil(update?.package)
        }
    }

    private var current: AppVersion { AppVersion(version: "0.1.1", build: "18") }
    private func asset(_ architecture: String) -> [String: Any] {
        ["name": "Toccata-0.2.0-\(architecture).dmg", "state": "uploaded", "size": 123,
         "digest": "sha256:" + String(repeating: "a", count: 64), "browser_download_url": "https://untrusted.example/payload"]
    }
    private func service(assets: [[String: Any]]) -> ReleaseUpdateService {
        ReleaseUpdateService { _ in
            let data = try JSONSerialization.data(withJSONObject: ["tag_name": "v0.2.0", "draft": false, "prerelease": false, "assets": assets])
            return (data, HTTPURLResponse(url: ToccataReleaseSource.latestAPIURL, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }
}

final class UpdatePackageValidationTests: XCTestCase {
    func testArchiveHashAndLengthAreBothRequired() throws {
        let directory = try temporary()
        let archive = directory.appendingPathComponent("update.dmg")
        let data = Data("a verified package".utf8)
        try data.write(to: archive)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let url = URL(string: "https://github.com/KMnO4-zx/Toccata/releases/download/v0.2.0/example.dmg")!
        XCTAssertNoThrow(try UpdatePackagePreparer.verifyArchive(archive, package: UpdatePackage(url: url, size: Int64(data.count), sha256: hash)))
        XCTAssertThrowsError(try UpdatePackagePreparer.verifyArchive(archive, package: UpdatePackage(url: url, size: Int64(data.count + 1), sha256: hash)))
        XCTAssertThrowsError(try UpdatePackagePreparer.verifyArchive(archive, package: UpdatePackage(url: url, size: Int64(data.count), sha256: String(repeating: "0", count: 64))))
    }

    func testDownloadRedirectsCannotLeaveGitHubHTTPS() {
        for address in ["https://github.com/repo/file", "https://release-assets.githubusercontent.com/file?sig=1", "https://objects.githubusercontent.com/file"] {
            XCTAssertTrue(UpdateDownloadDelegate.permits(URL(string: address)!))
        }
        for address in ["http://github.com/file", "https://github.com.evil.example/file", "https://evil.example/file",
                        "file:///tmp/app", "https://user:password@github.com/file", "https://github.com:444/file"] {
            XCTAssertFalse(UpdateDownloadDelegate.permits(URL(string: address)!))
        }
    }

    func testWrongBundleAndSymlinkTargetsAreRejected() throws {
        let directory = try temporary()
        let app = directory.appendingPathComponent("Other.app")
        try writeApp(app, version: "0.2.0", identifier: "other.application")
        XCTAssertThrowsError(try UpdatePackagePreparer.appInfo(app))
        let link = directory.appendingPathComponent("Toccata.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: app)
        XCTAssertThrowsError(try UpdatePackagePreparer.checkLocation(link))
        XCTAssertThrowsError(try UpdatePackagePreparer.appInfo(link))
    }

    func testSuccessfulRelaunchRemovesOnlyMatchingBackup() throws {
        let directory = try temporary(name: "ToccataUpdate-\(UUID())")
        let apps = try temporary()
        let target = apps.appendingPathComponent("Toccata.app")
        let backup = apps.appendingPathComponent(".Toccata-backup-\(UUID()).app")
        try writeApp(target, version: "0.2.0")
        try writeApp(backup, version: "0.1.1")
        let plan = PreparedAppUpdate(target: target, staged: apps.appendingPathComponent(".Toccata-update-\(UUID()).app"),
                                     backup: backup, directory: directory, originalIdentity: "0:0", version: "0.2.0")
        try JSONEncoder().encode(plan).write(to: directory.appendingPathComponent("plan.json"))
        PreparedAppUpdate.cleanUpSuccessfulInstallation(arguments: ["app", "--toccata-updated", directory.path], target: target)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testRelaunchCleanupRefusesUnrelatedPathOrWrongVersion() throws {
        let directory = try temporary(name: "ToccataUpdate-\(UUID())")
        let apps = try temporary()
        let target = apps.appendingPathComponent("Toccata.app")
        let backup = apps.appendingPathComponent("Important.app")
        try writeApp(target, version: "0.1.1")
        try writeApp(backup, version: "0.1.0")
        let plan = PreparedAppUpdate(target: target, staged: apps.appendingPathComponent("staged.app"),
                                     backup: backup, directory: directory, originalIdentity: "0:0", version: "0.2.0")
        try JSONEncoder().encode(plan).write(to: directory.appendingPathComponent("plan.json"))
        PreparedAppUpdate.cleanUpSuccessfulInstallation(arguments: ["app", "--toccata-updated", directory.path], target: target)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
    }

    private func temporary(name: String = "UpdateTests-\(UUID())") throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func writeApp(_ app: URL, version: String, identifier: String = "com.toccata.studio") throws {
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": identifier,
            "CFBundleExecutable": "Toccata", "CFBundleShortVersionString": version], format: .xml, options: 0)
        try data.write(to: app.appendingPathComponent("Contents/Info.plist"))
    }
}

@MainActor
final class AppUpdateControllerTests: XCTestCase {
    private let update = AvailableUpdate(version: "0.2.0", pageURL: ToccataReleaseSource.releasesURL)

    func testRepeatedClicksDoNotStartConcurrentDownloads() async throws {
        var count = 0
        var pending: CheckedContinuation<PreparedAppUpdate, Error>?
        let controller = AppUpdateController { _, progress in
            count += 1
            progress(0.5)
            return try await withCheckedThrowingContinuation { pending = $0 }
        }
        XCTAssertEqual(count, 0)
        controller.download(update)
        while pending == nil { await Task.yield() }
        controller.download(update)
        XCTAssertEqual(count, 1)
        let plan = try fixture()
        pending?.resume(returning: plan)
        await settle(controller)
        XCTAssertEqual(controller.state, .ready)
        XCTAssertEqual(controller.prepared, plan)
        controller.cancel()
        XCTAssertFalse(FileManager.default.fileExists(atPath: plan.staged.path))
    }

    func testCancellationDiscardsLateResultAndCanRetry() async throws {
        var pending: CheckedContinuation<PreparedAppUpdate, Error>?
        let plan = try fixture()
        var count = 0
        let controller = AppUpdateController { _, _ in
            count += 1
            if count == 1 { return try await withCheckedThrowingContinuation { pending = $0 } }
            return try self.fixture()
        }
        controller.download(update)
        while pending == nil { await Task.yield() }
        controller.cancel()
        pending?.resume(returning: plan)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(controller.state, .idle)
        XCTAssertNil(controller.prepared)
        XCTAssertFalse(FileManager.default.fileExists(atPath: plan.staged.path))
        controller.download(update)
        await settle(controller)
        XCTAssertEqual(controller.state, .ready)
        controller.cancel()
    }

    func testVerificationFailureIsRetryable() async throws {
        var count = 0
        let controller = AppUpdateController { _, _ in
            count += 1
            if count == 1 { throw UpdateInstallFailure.integrity }
            return try self.fixture()
        }
        controller.download(update)
        await settle(controller)
        if case .failed = controller.state {} else { XCTFail("Expected verification failure") }
        controller.download(update)
        await settle(controller)
        XCTAssertEqual(controller.state, .ready)
        controller.cancel()
    }

    func testInstallUsesInjectedLifecycleAndIgnoresSystemDelegate() async throws {
        let application = NSApplication.shared
        let previousDelegate = application.delegate
        let proxy = UpdateTestApplicationDelegate()
        application.delegate = proxy
        defer { application.delegate = previousDelegate }
        let plan = try fixture()
        var received: [PreparedAppUpdate] = []
        let controller = AppUpdateController(install: { plan, _ in received.append(plan) },
                                             prepare: { _, _ in plan })
        controller.install()
        XCTAssertTrue(received.isEmpty, "Installation requires a verified package")
        controller.download(update)
        await settle(controller)
        controller.install()
        controller.install()
        XCTAssertEqual(received, [plan], "Repeated clicks must request only one installation")
        XCTAssertEqual(controller.state, .installing)
    }

    func testInstallationFailureKeepsPreparedPackageForRetry() async throws {
        let plan = try fixture()
        var count = 0
        var failure: ((Error) -> Void)?
        let controller = AppUpdateController(install: { _, failed in
            count += 1
            failure = failed
        }, prepare: { _, _ in plan })
        controller.download(update)
        await settle(controller)
        controller.install()
        failure?(UpdateInstallFailure.save)
        XCTAssertEqual(controller.state, .failed(UpdateInstallFailure.save.message))
        XCTAssertEqual(controller.prepared, plan)
        XCTAssertTrue(FileManager.default.fileExists(atPath: plan.staged.path))
        controller.install()
        XCTAssertEqual(count, 2)
        XCTAssertEqual(controller.state, .installing)
    }

    func testTerminationDoesNotDiscardPackageHandedToInstaller() async throws {
        let plan = try fixture()
        let controller = AppUpdateController(install: { _, _ in }, prepare: { _, _ in plan })
        controller.download(update)
        await settle(controller)
        controller.install()
        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
        controller.cancel()
        XCTAssertEqual(controller.state, .installing)
        XCTAssertEqual(controller.prepared, plan)
        XCTAssertTrue(FileManager.default.fileExists(atPath: plan.staged.path))
    }

    func testMissingInstallerReportsFailureWithoutClaimingInvalidLocation() async throws {
        let plan = try fixture()
        let controller = AppUpdateController(prepare: { _, _ in plan })
        controller.download(update)
        await settle(controller)
        controller.install()
        XCTAssertEqual(controller.state, .failed(UpdateInstallFailure.installer.message))
        controller.cancel()
        XCTAssertFalse(FileManager.default.fileExists(atPath: plan.staged.path))
    }

    private func settle(_ controller: AppUpdateController) async {
        for _ in 0..<500 {
            if !controller.state.isBusy { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Update operation did not settle")
    }

    private func fixture() throws -> PreparedAppUpdate {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("UpdateControllerTests-\(UUID())")
        let staged = directory.appendingPathComponent("staged.app")
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return PreparedAppUpdate(target: directory.appendingPathComponent("original.app"), staged: staged,
                                 backup: directory.appendingPathComponent("backup.app"), directory: directory,
                                 originalIdentity: "0:0", version: "0.2.0")
    }
}

private final class UpdateTestApplicationDelegate: NSObject, NSApplicationDelegate {}

final class UpdateDownloadSmokeTests: XCTestCase {
    func testPublishedPackageDownloadsVerifiesAndStagesWithoutInstalling() async throws {
        guard let path = ProcessInfo.processInfo.environment["TOCCATA_UPDATE_SMOKE_APP"] else {
            throw XCTSkip("Opt-in network/DMG smoke test; uses an isolated app copy only")
        }
        let target = URL(fileURLWithPath: path)
        guard target.path.contains("/.build/updater-smoke/"),
              (try UpdatePackagePreparer.appInfo(target))["CFBundleShortVersionString"] as? String == "0.0.0" else {
            XCTFail("Smoke target must be the isolated version 0.0.0 fixture")
            return
        }
        let service: ReleaseUpdateService
        if let responsePath = ProcessInfo.processInfo.environment["TOCCATA_UPDATE_SMOKE_RELEASE_JSON"] {
            let response = try Data(contentsOf: URL(fileURLWithPath: responsePath))
            service = ReleaseUpdateService { _ in
                (response, HTTPURLResponse(url: ToccataReleaseSource.latestAPIURL, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        } else {
            service = ReleaseUpdateService()
        }
        let update = try await service.check(current: AppVersion(version: "0.0.0", build: "1"))
        let available = try XCTUnwrap(update)
        let original = try Data(contentsOf: target.appendingPathComponent("Contents/Info.plist"))
        let prepared = try await UpdatePackagePreparer(target: target).prepare(available, progress: { _ in })
        defer { prepared.discard() }
        XCTAssertEqual(try UpdatePackagePreparer.appInfo(prepared.staged)["CFBundleShortVersionString"] as? String, available.version)
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("Contents/Info.plist")), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.backup.path))
    }
}
