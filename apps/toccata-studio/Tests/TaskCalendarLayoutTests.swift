import AppKit
import SwiftUI
import XCTest
@testable import toccata_studio

@MainActor
final class TaskCalendarLayoutTests: XCTestCase {
    func testCalendarHeaderStaysStillWhenDayTasksStartAndStopScrolling() async throws {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let otherMonth = try XCTUnwrap(calendar.date(byAdding: .month, value: 2, to: today))
        let createdAt = try XCTUnwrap(calendar.date(byAdding: .month, value: -2, to: today))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ToccataCalendarLayout-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TaskStore(databaseURL: directory.appendingPathComponent("tasks.sqlite"),
                              now: { createdAt }, completionFeedback: {})
        let ids = try (0..<16).map { index in
            try XCTUnwrap(store.addTask(title: "Calendar layout task \(index)", plannedDate: otherMonth))
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 1100),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = NSHostingView(rootView: TaskCalendarView().environmentObject(store))
        defer {
            window.contentView = nil
            window.close()
        }
        for _ in 0..<15 { try await layout(window) }
        let originalHeader = try headerPixels(in: window)
        let scroll = try XCTUnwrap(findScrollView(in: window.contentView!))
        XCTAssertLessThanOrEqual(try XCTUnwrap(scroll.documentView).bounds.height, scroll.contentSize.height)

        // Moving plans into/out of the selected day changes the list height just
        // like switching between a busy day and an empty day. The month header
        // and its navigation controls must keep the same horizontal geometry.
        for plannedDate in [today, otherMonth, today] {
            for id in ids {
                let task = try XCTUnwrap(store.task(id: id))
                XCTAssertTrue(store.updateTask(id: id, title: task.title, details: task.details,
                                               plannedDate: plannedDate))
            }
            var maximumDifferentBytes = 0
            for _ in 0..<15 {
                try await layout(window)
                let header = try headerPixels(in: window)
                XCTAssertEqual(header.count, originalHeader.count)
                maximumDifferentBytes = max(maximumDifferentBytes,
                    zip(header, originalHeader).filter { $0 != $1 }.count)
            }
            XCTAssertEqual(maximumDifferentBytes, 0,
                           "The month header must not resize while the scrollbar appears or disappears")
            let documentHeight = try XCTUnwrap(scroll.documentView).bounds.height
            if plannedDate == today {
                XCTAssertGreaterThan(documentHeight, scroll.contentSize.height)
            } else {
                XCTAssertLessThanOrEqual(documentHeight, scroll.contentSize.height)
            }
        }
        XCTAssertFalse(window.isVisible)
    }

    private func layout(_ window: NSWindow) async throws {
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 20_000_000)
    }

    private func headerPixels(in window: NSWindow) throws -> Data {
        let view = try XCTUnwrap(window.contentView)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let bytes = try XCTUnwrap(bitmap.bitmapData)
        // Exclude the scrollbar itself: its visibility is allowed to change.
        let pixelWidth = bitmap.pixelsWide - Int(22 * CGFloat(bitmap.pixelsWide) / view.bounds.width)
        let pixelBytesPerRow = (pixelWidth * bitmap.bitsPerPixel + 7) / 8
        // The top 140 points include the month navigation but none of the date
        // cells whose event dots legitimately change as the plans move.
        let rows = min(bitmap.pixelsHigh, Int(140 * CGFloat(bitmap.pixelsHigh) / view.bounds.height))
        var result = Data(capacity: rows * pixelBytesPerRow)
        for y in 0..<rows {
            result.append(bytes.advanced(by: y * bitmap.bytesPerRow), count: pixelBytesPerRow)
        }
        return result
    }

    private func findScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap { self.findScrollView(in: $0) }.first
    }
}
