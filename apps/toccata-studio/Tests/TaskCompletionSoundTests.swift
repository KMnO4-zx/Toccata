import AppKit
import XCTest
@testable import toccata_studio

@MainActor
final class TaskCompletionSoundTests: XCTestCase {
    func testBundledCompletionSoundCanBeDecodedWithoutPlayback() async throws {
        let url = try XCTUnwrap(AppResources.bundle.url(forResource: "task-completed", withExtension: "wav"),
                                "The completion sound must ship in the SwiftPM resource bundle")
        let sound = try XCTUnwrap(NSSound(contentsOf: url, byReference: false))
        XCTAssertGreaterThan(sound.duration, 0.8, "The chime needs time to ring out naturally")
        XCTAssertLessThan(sound.duration, 1.6, "Completion feedback should finish without a lingering notification loop")
        XCTAssertFalse(sound.isPlaying)
    }
}
