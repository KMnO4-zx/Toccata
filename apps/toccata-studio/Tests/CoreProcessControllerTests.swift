import XCTest
@testable import toccata_studio

@MainActor
final class CoreProcessControllerTests: XCTestCase {
    func testReachableSocketDoesNotLaunchAnotherCore() throws {
        let directory = try fixture()
        let helper = try makeHelper(in: directory)
        let controller = CoreProcessController(
            helperURL: helper, dataDirectory: directory, socketPath: directory.path,
            socketIsReachable: { _ in true }
        )

        XCTAssertFalse(controller.start())
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL(in: directory).path))
    }

    func testUnavailableSocketStartsHelperOnceWithMatchingDataDirectory() async throws {
        let directory = try fixture()
        let helper = try makeHelper(in: directory)
        let controller = CoreProcessController(
            helperURL: helper, dataDirectory: directory, socketPath: directory.path,
            socketIsReachable: { _ in false }
        )

        XCTAssertTrue(controller.start())
        XCTAssertFalse(controller.start())
        try await waitForFile(markerURL(in: directory))
        XCTAssertEqual(try String(contentsOf: markerURL(in: directory), encoding: .utf8), "x")
        XCTAssertEqual(try String(contentsOf: environmentURL(in: directory), encoding: .utf8), directory.path)
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("core.log"), encoding: .utf8), "helper-ready\n")
        try await Task.sleep(nanoseconds: 1_100_000_000)
    }

    func testMissingHelperDoesNotStartAProcess() throws {
        let directory = try fixture()
        let controller = CoreProcessController(
            helperURL: directory.appendingPathComponent("missing-core"),
            dataDirectory: directory, socketPath: directory.path,
            socketIsReachable: { _ in false }
        )

        XCTAssertFalse(controller.start())
    }

    private func fixture() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ToccataCoreProcessTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func makeHelper(in directory: URL) throws -> URL {
        let helper = directory.appendingPathComponent("helper.sh")
        let script = """
        #!/bin/sh
        echo helper-ready
        printf x >> '\(markerURL(in: directory).path)'
        printf '%s' "$TOCCATA_DATA_DIR" > '\(environmentURL(in: directory).path)'
        sleep 1
        """
        try script.write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        return helper
    }

    private func markerURL(in directory: URL) -> URL {
        directory.appendingPathComponent("started")
    }

    private func environmentURL(in directory: URL) -> URL {
        directory.appendingPathComponent("environment")
    }

    private func waitForFile(_ url: URL) async throws {
        for _ in 0..<50 {
            if FileManager.default.fileExists(atPath: url.path) { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Helper did not create \(url.lastPathComponent)")
    }
}
