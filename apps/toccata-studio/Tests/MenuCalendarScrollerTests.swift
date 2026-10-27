import AppKit
import SwiftUI
import XCTest
@testable import toccata_studio

/// Rebuild the selected day's list in a hidden panel; each list must keep the
/// same native scrollbar as the workbench. All tasks use a temporary database.
@MainActor
final class MenuCalendarScrollerTests: XCTestCase {
    func testReplacingEmptyDayListKeepsWorkbenchScrollbar() async throws {
        _ = NSApplication.shared
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let otherDay = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: today))
        let createdAt = try XCTUnwrap(calendar.date(byAdding: .month, value: -2, to: today))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ToccataMenuScroller-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TaskStore(databaseURL: directory.appendingPathComponent("tasks.sqlite"),
                              now: { createdAt }, completionFeedback: {})
        let ids = try (0..<18).map { index in
            try XCTUnwrap(store.addTask(title: "Scrollbar task \(index)", plannedDate: today))
        }

        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 312, height: 440),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: MenuCalendarView()
            .environmentObject(store).environmentObject(MenuTaskPresentation()))
        let workbench = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 700, height: 500),
                                 styleMask: [.borderless], backing: .buffered, defer: false)
        workbench.isReleasedWhenClosed = false
        workbench.contentView = NSHostingView(rootView: TaskCalendarView().environmentObject(store))
        defer {
            panel.contentView = nil
            panel.close()
            workbench.contentView = nil
            workbench.close()
        }
        try await settle(workbench)
        try await settle(panel)
        let expected = try XCTUnwrap(scrollViews(in: workbench.contentView!).first?.verticalScroller)
        XCTAssertTrue(NSStringFromClass(type(of: expected)).contains("TaskScroller"))
        var previousScroll = try assertMatchingScroller(in: panel, expected: expected)

        for _ in 0..<2 {
            // Emptying the selected day removes its native ScrollView; restoring
            // its plans creates another, just like returning from an empty day.
            try movePlans(ids, to: otherDay, store: store)
            try await settle(panel)
            XCTAssertTrue(scrollViews(in: panel.contentView!).isEmpty)
            try movePlans(ids, to: today, store: store)
            try await settle(panel)
            let current = try assertMatchingScroller(in: panel, expected: expected)
            XCTAssertFalse(current === previousScroll, "The selected day's native ScrollView should be rebuilt")
            previousScroll = current
        }

        XCTAssertFalse(panel.isVisible)
        XCTAssertFalse(workbench.isVisible)
    }

    private func movePlans(_ ids: [String], to date: Date, store: TaskStore) throws {
        for id in ids {
            let task = try XCTUnwrap(store.task(id: id))
            XCTAssertTrue(store.updateTask(id: id, title: task.title, details: task.details, plannedDate: date))
        }
    }

    private func assertMatchingScroller(in panel: NSPanel, expected: NSScroller,
                                        file: StaticString = #filePath, line: UInt = #line) throws -> NSScrollView {
        let scroll = try XCTUnwrap(scrollViews(in: panel.contentView!).first, file: file, line: line)
        let scroller = try XCTUnwrap(scroll.verticalScroller, file: file, line: line)
        XCTAssertGreaterThan(try XCTUnwrap(scroll.documentView).bounds.height, scroll.contentSize.height,
                             file: file, line: line)
        XCTAssertEqual(NSStringFromClass(type(of: scroller)), NSStringFromClass(type(of: expected)),
                       file: file, line: line)
        XCTAssertEqual(scroller.controlSize, expected.controlSize, file: file, line: line)
        XCTAssertEqual(scroll.scrollerStyle, .legacy, file: file, line: line)
        return scroll
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        if let scroll = view as? NSScrollView { return [scroll] }
        return view.subviews.flatMap { scrollViews(in: $0) }
    }

    private func settle(_ window: NSWindow) async throws {
        for _ in 0..<20 {
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
