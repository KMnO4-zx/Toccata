import Foundation

extension Notification.Name {
    static let toccataSavePendingEdits = Notification.Name("ToccataSavePendingEdits")
}

@MainActor
final class PendingEditSaveRequest {
    var failed = false
}

@MainActor
protocol PendingMarkdownFlushing: AnyObject {
    func flushPendingMarkdown() async -> Bool
}

@MainActor
protocol PendingDraftSaving: AnyObject {
    func savePendingDrafts() -> Bool
}

/// The registry does not own editors or buffers. A close/quit operation first
/// obtains current WebKit content, then saves visible drafts and retained drafts.
@MainActor
final class PendingEdits {
    static let shared = PendingEdits()

    private final class WeakEditor {
        weak var value: PendingMarkdownFlushing?
        init(_ value: PendingMarkdownFlushing) { self.value = value }
    }

    private final class WeakBuffer {
        weak var value: PendingDraftSaving?
        init(_ value: PendingDraftSaving) { self.value = value }
    }

    private var editors: [ObjectIdentifier: WeakEditor] = [:]
    private var buffers: [ObjectIdentifier: WeakBuffer] = [:]
    private var flushTask: Task<Bool, Never>?
    private let saveVisibleDrafts: () -> Bool

    init(saveVisibleDrafts: (() -> Bool)? = nil) {
        self.saveVisibleDrafts = saveVisibleDrafts ?? {
            let request = PendingEditSaveRequest()
            NotificationCenter.default.post(name: .toccataSavePendingEdits, object: request)
            return !request.failed
        }
    }

    func registerEditor(_ editor: PendingMarkdownFlushing) {
        editors[ObjectIdentifier(editor)] = WeakEditor(editor)
    }

    func unregisterEditor(_ editor: PendingMarkdownFlushing) {
        editors.removeValue(forKey: ObjectIdentifier(editor))
    }

    func registerDraftBuffer(_ buffer: PendingDraftSaving) {
        buffers[ObjectIdentifier(buffer)] = WeakBuffer(buffer)
    }

    func flushAll() async -> Bool {
        // Closing a window and quitting can arrive together. They must await the
        // same operation instead of saving competing snapshots of the editors.
        if let flushTask { return await flushTask.value }
        let task = Task { @MainActor in await self.performFlush() }
        flushTask = task
        let result = await task.value
        flushTask = nil
        return result
    }

    private func performFlush() async -> Bool {
        editors = editors.filter { $0.value.value != nil }
        let activeEditors = editors.values.compactMap(\.value)
        var editorSuccess = true
        for editor in activeEditors {
            if !(await editor.flushPendingMarkdown()) { editorSuccess = false }
        }
        // Never report a save of stale SwiftUI state as a successful editor flush.
        guard editorSuccess else { return false }
        await Task.yield()
        let visibleSuccess = saveVisibleDrafts()

        // A view can register its retained draft while handling the save request.
        buffers = buffers.filter { $0.value.value != nil }
        let retainedBuffers = buffers.values.compactMap(\.value)
        var retainedSuccess = true
        for buffer in retainedBuffers {
            if !buffer.savePendingDrafts() { retainedSuccess = false }
        }
        return visibleSuccess && retainedSuccess
    }
}

/// A callback may arrive after WebKit has stalled or the view has gone away.
/// Resolve once so a timed-out close/quit remains cancelled even if it arrives late.
@MainActor
final class PendingEditCompletion {
    private var continuation: CheckedContinuation<Bool, Never>?
    private(set) var finished = false

    init(_ continuation: CheckedContinuation<Bool, Never>, timeout: TimeInterval) {
        self.continuation = continuation
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, timeout)) { [self] in
            finish(false)
        }
    }

    func finish(_ success: Bool) {
        guard !finished else { return }
        finished = true
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(returning: success)
    }
}
