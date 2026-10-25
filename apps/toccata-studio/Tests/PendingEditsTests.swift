import Foundation
import XCTest
@testable import toccata_studio

@MainActor
final class PendingEditsTests: XCTestCase {
    private final class Editor: PendingMarkdownFlushing {
        var calls = 0
        let operation: () async -> Bool
        init(_ operation: @escaping () async -> Bool = { true }) { self.operation = operation }
        func flushPendingMarkdown() async -> Bool {
            calls += 1
            return await operation()
        }
    }

    private final class Buffer: PendingDraftSaving {
        var calls = 0
        var succeeds = true
        var operation: (() -> Void)?
        func savePendingDrafts() -> Bool {
            calls += 1
            operation?()
            return succeeds
        }
    }

    func testReadsFinalEditorContentBeforeSavingVisibleAndRetainedDrafts() async {
        var draft = "old"
        var events: [String] = []
        let registry = PendingEdits(saveVisibleDrafts: {
            events.append("save:\(draft)")
            return true
        })
        let editor = Editor {
            events.append("flush")
            await Task.yield()
            draft = "final"
            return true
        }
        let buffer = Buffer()
        buffer.operation = { events.append("retained:\(draft)") }
        registry.registerEditor(editor)
        registry.registerDraftBuffer(buffer)
        let saved = await registry.flushAll()
        XCTAssertTrue(saved)
        XCTAssertEqual(events, ["flush", "save:final", "retained:final"])
    }

    func testFailedEditorReadDoesNotReportSavingStaleNativeState() async {
        var saves = 0
        let registry = PendingEdits(saveVisibleDrafts: { saves += 1; return true })
        let editor = Editor { false }
        registry.registerEditor(editor)
        let saved = await registry.flushAll()
        XCTAssertFalse(saved)
        XCTAssertEqual(saves, 0)
    }

    func testRetainedFailedDraftBlocksQuitAndCanBeRetriedWithoutVisibleEditor() async {
        let registry = PendingEdits(saveVisibleDrafts: { true })
        let buffer = Buffer()
        buffer.succeeds = false
        registry.registerDraftBuffer(buffer)
        let failed = await registry.flushAll()
        XCTAssertFalse(failed)
        buffer.succeeds = true
        let retried = await registry.flushAll()
        XCTAssertTrue(retried)
        XCTAssertEqual(buffer.calls, 2)
    }

    func testVisibleFailureStillAttemptsEveryRetainedBuffer() async {
        let registry = PendingEdits(saveVisibleDrafts: { false })
        let first = Buffer()
        first.succeeds = false
        let second = Buffer()
        registry.registerDraftBuffer(first)
        registry.registerDraftBuffer(second)
        let saved = await registry.flushAll()
        XCTAssertFalse(saved)
        XCTAssertEqual(first.calls, 1)
        XCTAssertEqual(second.calls, 1)
    }

    func testBufferCreatedByVisibleSaveParticipatesInSameFlush() async {
        let buffer = Buffer()
        var registry: PendingEdits!
        registry = PendingEdits(saveVisibleDrafts: {
            registry.registerDraftBuffer(buffer)
            return true
        })
        let saved = await registry.flushAll()
        XCTAssertTrue(saved)
        XCTAssertEqual(buffer.calls, 1)
    }

    func testRegistryDoesNotRetainEditorsOrBuffersAndUnregisterPreventsRead() async {
        let registry = PendingEdits(saveVisibleDrafts: { true })
        weak var weakEditor: Editor?
        weak var weakBuffer: Buffer?
        do {
            let editor = Editor()
            let buffer = Buffer()
            weakEditor = editor
            weakBuffer = buffer
            registry.registerEditor(editor)
            registry.registerDraftBuffer(buffer)
        }
        XCTAssertNil(weakEditor)
        XCTAssertNil(weakBuffer)
        let editor = Editor()
        registry.registerEditor(editor)
        registry.unregisterEditor(editor)
        let saved = await registry.flushAll()
        XCTAssertTrue(saved)
        XCTAssertEqual(editor.calls, 0)
    }

    func testRepeatedRegistrationAndConcurrentCloseQuitShareOneFlush() async {
        var saves = 0
        let registry = PendingEdits(saveVisibleDrafts: { saves += 1; return true })
        let editor = Editor {
            try? await Task.sleep(nanoseconds: 20_000_000)
            return true
        }
        registry.registerEditor(editor)
        registry.registerEditor(editor)
        async let first = registry.flushAll()
        async let second = registry.flushAll()
        let results = await [first, second]
        XCTAssertEqual(results, [true, true])
        XCTAssertEqual(editor.calls, 1)
        XCTAssertEqual(saves, 1)
    }

    func testCallbackTimeoutCancelsSaveAndLateCompletionCannotChangeOutcome() async {
        var completion: PendingEditCompletion?
        let saved = await withCheckedContinuation { continuation in
            completion = PendingEditCompletion(continuation, timeout: 0.01)
        }
        XCTAssertFalse(saved)
        XCTAssertTrue(completion?.finished == true)
        completion?.finish(true)
        XCTAssertTrue(completion?.finished == true)
    }

    func testCallbackCanSucceedBeforeTimeoutAndOnlyResumesOnce() async {
        let saved = await withCheckedContinuation { continuation in
            let completion = PendingEditCompletion(continuation, timeout: 0.01)
            completion.finish(true)
            completion.finish(false)
        }
        XCTAssertTrue(saved)
    }
}
