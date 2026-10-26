import XCTest
@testable import toccata_studio

final class ReleaseVersionTests: XCTestCase {
    func testNumericComparisonAcrossVersionBoundaries() throws {
        XCTAssertEqual(ReleaseVersion("v0.1.0"), ReleaseVersion("0.1.0"))
        XCTAssertLessThan(try XCTUnwrap(ReleaseVersion("0.9.9")), try XCTUnwrap(ReleaseVersion("0.10.0")))
        XCTAssertLessThan(try XCTUnwrap(ReleaseVersion("0.1.9")), try XCTUnwrap(ReleaseVersion("0.1.10")))
        XCTAssertLessThan(try XCTUnwrap(ReleaseVersion("0.99.99")), try XCTUnwrap(ReleaseVersion("1.0.0")))
    }

    func testOnlyStableVersionTagsAreAccepted() {
        for tag in ["", "v", "1.0", "01.0.0", "1.00.0", "1.0.0.0", "-1.0.0", "1.0.0-beta.1",
                    "1.0.0+1", " 1.0.0", "1.0.0/path", "１.0.0", "999999999999999999999999.0.0"] {
            XCTAssertNil(ReleaseVersion(tag), tag)
        }
    }

    func testBundledVersionMatchesSourceAndRustManifest() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try JSONDecoder().decode(AppVersion.self, from: Data(contentsOf: root.appendingPathComponent("shared/app-version.json")))
        XCTAssertEqual(AppVersion.current, source)
        XCTAssertNotNil(ReleaseVersion(source.version))
        XCTAssertGreaterThan(Int(source.build) ?? 0, 0)
        let manifest = try String(contentsOf: root.appendingPathComponent("core/toccata-core/Cargo.toml"))
        XCTAssertTrue(manifest.contains("version = \"\(source.version)\""))
        XCTAssertTrue(source.copyableDescription.contains("Toccata v\(source.version) (Build \(source.build))"))
    }
}

@MainActor
final class ReleaseUpdateTests: XCTestCase {
    private let current = AppVersion(version: "0.0.1", build: "4")

    func testManualCheckFindsNewVersionAndUsesTrustedReleasePage() async {
        var requests = 0
        let service = ReleaseUpdateService { request in
            requests += 1
            XCTAssertEqual(request.url, ToccataReleaseSource.latestAPIURL)
            XCTAssertNil(request.httpBody)
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
            return self.response(tag: "v0.1.0", extra: ",\"html_url\":\"https://untrusted.example\"")
        }
        let checker = UpdateChecker(service: service, current: current)
        XCTAssertEqual(checker.state, .idle)
        XCTAssertEqual(requests, 0, "Opening About must not send a request")
        await checker.check()
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(checker.state, .available(AvailableUpdate(version: "0.1.0",
            pageURL: URL(string: "https://github.com/KMnO4-zx/Toccata/releases/tag/v0.1.0")!)))
    }

    func testEqualOrOlderReleaseDoesNotOfferDowngrade() async {
        for tag in ["v0.0.1", "v0.0.0"] {
            let checker = makeChecker { _ in self.response(tag: tag) }
            await checker.check()
            XCTAssertEqual(checker.state, .upToDate)
        }
    }

    func testPrivateRepoOrNoReleaseDoesNotClaimUpToDate() async {
        let checker = makeChecker { _ in self.response(status: 404) }
        await checker.check()
        XCTAssertEqual(checker.state, .failed(.noAccessibleRelease))
    }

    func testRateLimitAndServiceFailureHaveRecoverableStates() async {
        for status in [403, 429, 500] {
            let checker = makeChecker { _ in self.response(status: status) }
            await checker.check()
            XCTAssertEqual(checker.state, .failed(status == 500 ? .connectionFailed : .rateLimited))
        }
    }

    func testInvalidOrPreviewReleaseIsNotOffered() async {
        for (tag, extra) in [("v0.2.0-beta.1", ""), ("v0.2.0", ",\"draft\":true"),
                             ("v0.2.0", ",\"prerelease\":true"), ("v0.2.0/unsafe", "")] {
            // Build the response with explicit flags rather than duplicate JSON keys.
            let draft = extra.contains("draft")
            let preview = extra.contains("prerelease")
            let checker = makeChecker { _ in self.response(tag: tag, draft: draft, preview: preview) }
            await checker.check()
            XCTAssertEqual(checker.state, .failed(.invalidResponse))
        }
        let checker = makeChecker { _ in (Data("not json".utf8), self.response().1) }
        await checker.check()
        XCTAssertEqual(checker.state, .failed(.invalidResponse))
    }

    func testNetworkFailureCanBeRetriedSuccessfully() async {
        var attempts = 0
        let checker = makeChecker { _ in
            attempts += 1
            if attempts == 1 { throw URLError(.timedOut) }
            return self.response()
        }
        await checker.check()
        XCTAssertEqual(checker.state, .failed(.connectionFailed))
        await checker.check()
        XCTAssertEqual(checker.state, .upToDate)
    }

    func testConcurrentClicksOnlySendOneRequest() async {
        var requests = 0
        var pending: CheckedContinuation<(Data, URLResponse), Error>?
        let checker = makeChecker { _ in
            requests += 1
            return try await withCheckedThrowingContinuation { pending = $0 }
        }
        let first = Task { await checker.check() }
        while pending == nil { await Task.yield() }
        XCTAssertEqual(checker.state, .checking)
        await checker.check()
        XCTAssertEqual(requests, 1)
        pending?.resume(returning: response())
        await first.value
        XCTAssertEqual(checker.state, .upToDate)
    }

    private func makeChecker(transport: @escaping ReleaseUpdateService.Transport) -> UpdateChecker {
        UpdateChecker(service: ReleaseUpdateService(transport: transport), current: current)
    }

    private func response(status: Int = 200, tag: String = "v0.0.1", draft: Bool = false,
                          preview: Bool = false, extra: String = "") -> (Data, URLResponse) {
        let data = Data("{\"tag_name\":\"\(tag)\",\"draft\":\(draft),\"prerelease\":\(preview)\(extra)}".utf8)
        return (data, HTTPURLResponse(url: ToccataReleaseSource.latestAPIURL, statusCode: status,
                                      httpVersion: nil, headerFields: nil)!)
    }
}
