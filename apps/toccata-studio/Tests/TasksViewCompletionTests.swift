import AppKit
import SwiftUI
import XCTest
@testable import toccata_studio

/// Compare a live SwiftUI list with a freshly mounted list of the same records.
/// Model-only assertions cannot catch stale views when a task changes sections.
/// The windows stay hidden and all records live in a temporary database.
@MainActor
final class TasksViewCompletionTests: XCTestCase {
    func testInboxMainTaskCompletionAndReopeningRefreshRenderedRow() async throws {
        try await assertMainTaskCompletion(in: .inbox)
    }

    func testTasksMainTaskCompletionAndReopeningRefreshRenderedRow() async throws {
        try await assertMainTaskCompletion(in: .tasks)
    }

    func testReviewMainTaskCompletionAndReopeningRefreshRenderedRow() async throws {
        try await assertMainTaskCompletion(in: .review)
    }

    func testChildAndParentCompletionKeepRenderedStatesInSync() async throws {
        for mode in [TaskViewMode.inbox, .tasks, .review] {
            let store = makeStore()
            let parentID = try XCTUnwrap(store.addTask(title: "Parent completion regression"))
            let firstChild = try XCTUnwrap(store.addTask(title: "Completed child", parentID: parentID))
            let secondChild = try XCTUnwrap(store.addTask(title: "Pending child", parentID: parentID))
            let window = makeWindow(store: store, selection: parentID, mode: mode)
            defer { close(window) }
            try await assertMatchesFreshList(window, store: store, selection: parentID, mode: mode)

            XCTAssertTrue(store.setCompleted(id: firstChild, completed: true))
            XCTAssertFalse(try XCTUnwrap(store.task(id: parentID)).isCompleted)
            try await assertMatchesFreshList(window, store: store, selection: parentID, mode: mode)

            XCTAssertTrue(store.setCompleted(id: parentID, completed: true))
            XCTAssertTrue(try XCTUnwrap(store.task(id: secondChild)).isCompleted)
            try await assertMatchesFreshList(window, store: store, selection: parentID, mode: mode)

            XCTAssertTrue(store.setCompleted(id: parentID, completed: false))
            XCTAssertTrue(try XCTUnwrap(store.task(id: firstChild)).isCompleted)
            XCTAssertTrue(try XCTUnwrap(store.task(id: secondChild)).isCompleted)
            try await assertMatchesFreshList(window, store: store, selection: parentID, mode: mode)
            XCTAssertFalse(window.isVisible)
        }
    }

    private func assertMainTaskCompletion(in mode: TaskViewMode) async throws {
        let store = makeStore()
        let taskID = try XCTUnwrap(store.addTask(title: "Completion regression root"))
        let otherID = try XCTUnwrap(store.addTask(title: "Already completed"))
        XCTAssertTrue(store.setCompleted(id: otherID, completed: true))
        let window = makeWindow(store: store, selection: taskID, mode: mode)
        defer { close(window) }
        try await assertMatchesFreshList(window, store: store, selection: taskID, mode: mode)

        // This is the same shared-store update made by the detail pane. Repeated
        // moves also catch a stale row returning from the completed section.
        for completed in [true, false, true, false] {
            XCTAssertTrue(store.setCompleted(id: taskID, completed: completed))
            XCTAssertEqual(try XCTUnwrap(store.task(id: taskID)).isCompleted, completed)
            try await assertMatchesFreshList(window, store: store, selection: taskID, mode: mode)
        }
        XCTAssertFalse(window.isVisible)
    }

    private func makeStore() -> TaskStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ToccataCompletion-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return TaskStore(databaseURL: directory.appendingPathComponent("tasks.sqlite"),
                         completionFeedback: {})
    }

    private func makeWindow(store: TaskStore, selection: String, mode: TaskViewMode) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 800),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = NSHostingView(rootView:
            TasksView(mode: mode, selection: .constant(selection)).environmentObject(store))
        return window
    }

    private func close(_ window: NSWindow) {
        window.contentView = nil
        window.close()
    }

    private func assertMatchesFreshList(_ window: NSWindow, store: TaskStore,
                                        selection: String, mode: TaskViewMode,
                                        file: StaticString = #filePath, line: UInt = #line) async throws {
        let actual = try await bitmap(in: window)
        let fresh = makeWindow(store: store, selection: selection, mode: mode)
        defer { close(fresh) }
        let expected = try await bitmap(in: fresh)
        XCTAssertEqual(actual.pixelsWide, expected.pixelsWide, file: file, line: line)
        XCTAssertEqual(actual.pixelsHigh, expected.pixelsHigh, file: file, line: line)
        XCTAssertEqual(actual.bitsPerPixel, expected.bitsPerPixel, file: file, line: line)
        XCTAssertFalse(actual.isPlanar, file: file, line: line)
        XCTAssertFalse(expected.isPlanar, file: file, line: line)
        guard actual.pixelsWide == expected.pixelsWide,
              actual.pixelsHigh == expected.pixelsHigh,
              actual.bitsPerPixel == expected.bitsPerPixel else { return }

        // Ignore row padding, whose unused bytes need not be initialized equally.
        let pixelBytesPerRow = (actual.pixelsWide * actual.bitsPerPixel + 7) / 8
        let actualBytes = try XCTUnwrap(actual.bitmapData)
        let expectedBytes = try XCTUnwrap(expected.bitmapData)
        var differentBytes = 0
        for y in 0..<actual.pixelsHigh {
            for x in 0..<pixelBytesPerRow {
                if actualBytes[y * actual.bytesPerRow + x] != expectedBytes[y * expected.bytesPerRow + x] {
                    differentBytes += 1
                }
            }
        }
        XCTAssertEqual(differentBytes, 0,
                       "The live \(mode.rawValue) list must render the same completion state as a fresh list",
                       file: file, line: line)
    }

    private func bitmap(in window: NSWindow) async throws -> NSBitmapImageRep {
        for _ in 0..<15 {
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let view = try XCTUnwrap(window.contentView)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }
}
