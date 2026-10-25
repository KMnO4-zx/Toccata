import XCTest
@testable import toccata_studio

@MainActor
final class CoreProcessControllerTests: XCTestCase {
    func testReachableSocketDoesNotProbePermissionsOrStopExternalCore() async throws {
        let directory = try fixture()
        let helper = try makeHelper(in: directory)
        let external = Process()
        external.executableURL = helper
        external.environment = ProcessInfo.processInfo.environment.merging(
            ["TOCCATA_DATA_DIR": directory.path], uniquingKeysWith: { _, value in value }
        )
        external.standardOutput = FileHandle.nullDevice
        external.standardError = FileHandle.nullDevice
        try external.run()
        addTeardownBlock {
            if external.isRunning { external.terminate() }
            for _ in 0..<100 where external.isRunning {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        try await waitForFile(markerURL(in: directory))
        let controller = makeController(helper: helper, directory: directory, socketReachable: true,
            preflight: { XCTFail("An existing service must skip permission checks"); return false })

        XCTAssertFalse(controller.start())
        let stopped = await controller.stop(timeout: 0.1)
        XCTAssertTrue(stopped)
        XCTAssertTrue(external.isRunning, "Reusing a socket does not grant ownership of that process")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("stopped").path))
        XCTAssertEqual(try String(contentsOf: markerURL(in: directory)), "x")
    }

    func testUnavailableSocketStartsHelperOnceWithMatchingDataDirectory() async throws {
        let directory = try fixture()
        let helper = try makeHelper(in: directory)
        var preflightCalls = 0
        let controller = makeController(helper: helper, directory: directory, preflight: {
            preflightCalls += 1
            return true
        })

        XCTAssertTrue(controller.start())
        XCTAssertFalse(controller.start())
        try await waitForFile(markerURL(in: directory))
        XCTAssertEqual(preflightCalls, 1, "A health check must not repeat preflight or logging")
        XCTAssertEqual(try String(contentsOf: markerURL(in: directory)), "x")
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("environment")), directory.path)
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("core.log")), "helper-ready\n")
        let stopped = await controller.stop(timeout: 2)
        XCTAssertTrue(stopped)
    }

    func testMissingHelperDoesNotProbePermissionsOrStartAProcess() throws {
        let directory = try fixture()
        let controller = makeController(helper: directory.appendingPathComponent("missing-core"),
            directory: directory,
            preflight: { XCTFail("A missing helper must not cause a permission prompt"); return false })

        XCTAssertFalse(controller.start())
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL(in: directory).path))
    }

    func testBackgroundStartSuppressesPermissionRequestAndExplicitStartCanRequestIt() async throws {
        let directory = try fixture()
        let helper = try makeHelper(in: directory)
        var requestCalls = 0
        let controller = makeController(helper: helper, directory: directory,
            preflight: { false }, request: { requestCalls += 1; return false })

        XCTAssertTrue(controller.start(requestPermission: false))
        try await waitForFile(markerURL(in: directory))
        XCTAssertEqual(requestCalls, 0)
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("permission-policy")), "0",
                       "The helper must also suppress its own permission prompt in the background")
        let firstStop = await controller.stop(timeout: 2)
        XCTAssertTrue(firstStop)

        XCTAssertTrue(controller.start(requestPermission: true))
        try await waitForContents(markerURL(in: directory), equalTo: "xx")
        XCTAssertEqual(requestCalls, 1, "Only an explicitly permitted foreground launch may request access")
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("permission-policy")), "1")
        let secondStop = await controller.stop(timeout: 2)
        XCTAssertTrue(secondStop)
    }

    func testForegroundPermissionRequestWorksWithRunningOrReusedHelper() async throws {
        for reusesSocket in [false, true] {
            let directory = try fixture()
            let helper = try makeHelper(in: directory)
            var requestCalls = 0
            let controller = makeController(helper: helper, directory: directory, socketReachable: reusesSocket,
                preflight: { false }, request: { requestCalls += 1; return true })

            XCTAssertEqual(controller.start(requestPermission: false), !reusesSocket)
            if !reusesSocket { try await waitForFile(markerURL(in: directory)) }
            XCTAssertEqual(requestCalls, 0)
            XCTAssertTrue(controller.requestInputMonitoringPermission())
            XCTAssertEqual(requestCalls, 1, "Opening the workbench may request access without restarting its helper")
            XCTAssertFalse(controller.start(requestPermission: false))
            XCTAssertEqual(requestCalls, 1, "A subsequent health check must remain silent")
            let stopped = await controller.stop(timeout: 2)
            XCTAssertTrue(stopped)
        }
    }

    func testForegroundPermissionRequestSkipsPromptWhenAlreadyAuthorized() throws {
        let directory = try fixture()
        let controller = makeController(helper: directory.appendingPathComponent("unused"), directory: directory)
        XCTAssertTrue(controller.requestInputMonitoringPermission())
    }

    func testStopWaitsForFlushAndRejectsRestartDuringShutdown() async throws {
        let directory = try fixture()
        let helper = try makeHelper(in: directory, shutdown: """
            printf x > "$TOCCATA_DATA_DIR/stopping"
            /bin/sleep 0.15
            printf flushed > "$TOCCATA_DATA_DIR/stopped"
            exit 0
            """)
        let controller = makeController(helper: helper, directory: directory)
        XCTAssertTrue(controller.start())
        try await waitForFile(markerURL(in: directory))

        let shutdown = Task { await controller.stop(timeout: 2) }
        try await waitForFile(directory.appendingPathComponent("stopping"))
        XCTAssertFalse(controller.start(requestPermission: false))
        let stopped = await shutdown.value
        XCTAssertTrue(stopped)
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("stopped")), "flushed")
        XCTAssertEqual(try String(contentsOf: markerURL(in: directory)), "x")
        let repeatedStop = await controller.stop(timeout: 0)
        XCTAssertTrue(repeatedStop, "Stopping an already exited helper is harmless")
    }

    func testStopTimeoutRetainsOwnershipAndDoesNotForceKill() async throws {
        let directory = try fixture()
        let helper = try makeHelper(in: directory, shutdown: "", run: """
            /bin/sleep 0.4
            printf natural-exit > "$TOCCATA_DATA_DIR/stopped"
            """)
        let controller = makeController(helper: helper, directory: directory)
        XCTAssertTrue(controller.start())
        try await waitForFile(markerURL(in: directory))

        let timedOut = await controller.stop(timeout: 0.03)
        XCTAssertFalse(timedOut)
        XCTAssertFalse(controller.start(requestPermission: false), "A timeout must retain the running helper")
        let finished = await controller.stop(timeout: 2)
        XCTAssertTrue(finished)
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("stopped")), "natural-exit",
                       "The helper must get to finish on its own instead of receiving SIGKILL")
    }

    func testUnexpectedHelperExitCanBeRestartedByHealthCheck() async throws {
        let directory = try fixture()
        let helper = try makeHelper(in: directory, run: "/bin/sleep 0.1\nexit 3")
        var preflightCalls = 0
        let controller = makeController(helper: helper, directory: directory, preflight: {
            preflightCalls += 1
            return true
        })
        XCTAssertTrue(controller.start())
        try await waitForFile(markerURL(in: directory))

        var restarted = false
        for _ in 0..<100 {
            if controller.start(requestPermission: false) {
                restarted = true
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(restarted)
        try await waitForContents(markerURL(in: directory), equalTo: "xx")
        XCTAssertEqual(preflightCalls, 2)
        let stopped = await controller.stop(timeout: 2)
        XCTAssertTrue(stopped)
    }

    private func makeController(helper: URL, directory: URL, socketReachable: Bool = false,
                                preflight: @escaping () -> Bool = { true },
                                request: @escaping () -> Bool = {
                                    XCTFail("This test must not request input monitoring access")
                                    return false
                                }) -> CoreProcessController {
        let controller = CoreProcessController(
            helperURL: helper, dataDirectory: directory, socketPath: directory.path,
            socketIsReachable: { _ in socketReachable }, preflightAccess: preflight,
            requestAccess: request, permitsPermissionPrompt: true
        )
        addTeardownBlock { _ = await controller.stop(timeout: 2) }
        return controller
    }

    private func fixture() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ToccataCoreProcessTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func makeHelper(in directory: URL,
                            shutdown: String = "printf stopped > \"$TOCCATA_DATA_DIR/stopped\"; exit 0",
                            run: String = "while :; do /bin/sleep 0.05; done") throws -> URL {
        let helper = directory.appendingPathComponent("helper.sh")
        let script = """
        #!/bin/sh
        set -eu
        trap '\(shutdown)' TERM
        echo helper-ready
        printf '%s' "$TOCCATA_DATA_DIR" > "$TOCCATA_DATA_DIR/environment"
        printf '%s' "${TOCCATA_REQUEST_INPUT_PERMISSION:-}" > "$TOCCATA_DATA_DIR/permission-policy"
        printf x >> "$TOCCATA_DATA_DIR/started"
        \(run)
        """
        try script.write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        return helper
    }

    private func markerURL(in directory: URL) -> URL {
        directory.appendingPathComponent("started")
    }

    private func waitForFile(_ url: URL) async throws {
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: url.path) { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Helper did not create \(url.lastPathComponent)")
    }

    private func waitForContents(_ url: URL, equalTo expected: String) async throws {
        for _ in 0..<100 {
            if (try? String(contentsOf: url)) == expected { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Helper did not write the expected contents to \(url.lastPathComponent)")
    }
}
