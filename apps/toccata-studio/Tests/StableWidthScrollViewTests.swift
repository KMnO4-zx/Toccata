import AppKit
import SwiftUI
import XCTest
@testable import toccata_studio

@MainActor
final class StableWidthScrollViewTests: XCTestCase {
    func testLoadingAndRemovingRowsDoesNotMoveCenteredContent() async throws {
        let state = ScrollFixtureState()
        let window = makeWindow(state: state)
        defer { close(window) }
        let marker = try await marker(in: window)
        let original = marker.convert(marker.bounds, to: nil)

        for rows in [30, 0, 30] {
            state.rows = rows
            // Sample the layout while the native scrollbar appears/disappears,
            // rather than only checking its eventual settled position.
            for _ in 0..<15 {
                window.contentView?.layoutSubtreeIfNeeded()
                try await Task.sleep(nanoseconds: 20_000_000)
                let frame = marker.convert(marker.bounds, to: nil)
                XCTAssertEqual(frame.minX, original.minX, accuracy: 0.5)
                XCTAssertEqual(frame.width, original.width, accuracy: 0.5)
            }
        }

        let scroll = try XCTUnwrap(find(NSScrollView.self, in: window.contentView!))
        XCTAssertGreaterThan(try XCTUnwrap(scroll.documentView).bounds.height, scroll.contentSize.height)
        XCTAssertFalse(window.isVisible)
    }

    func testCenteredContentStillRespondsToWindowResizing() async throws {
        let window = makeWindow(state: ScrollFixtureState())
        defer { close(window) }
        let marker = try await marker(in: window)
        let original = marker.convert(marker.bounds, to: nil)

        window.setContentSize(NSSize(width: 700, height: 500))
        for _ in 0..<15 {
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let resized = marker.convert(marker.bounds, to: nil)
        XCTAssertEqual(resized.midX, original.midX - 100, accuracy: 0.5)
        XCTAssertEqual(resized.width, original.width, accuracy: 0.5)
    }

    private func makeWindow(state: ScrollFixtureState) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 500),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ScrollFixture(state: state))
        return window
    }

    private func marker(in window: NSWindow) async throws -> ScrollFixtureMarkerView {
        for _ in 0..<15 {
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return try XCTUnwrap(find(ScrollFixtureMarkerView.self, in: window.contentView!))
    }

    private func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        return view.subviews.lazy.compactMap { self.find(type, in: $0) }.first
    }

    private func close(_ window: NSWindow) {
        window.contentView = nil
        window.close()
    }
}

private final class ScrollFixtureState: ObservableObject {
    @Published var rows = 0
}

private struct ScrollFixture: View {
    @ObservedObject var state: ScrollFixtureState

    var body: some View {
        StableWidthScrollView {
            VStack(spacing: 16) {
                Color.blue.frame(width: 240, height: 120)
                    .background(ScrollFixtureMarker())
                ForEach(0..<state.rows, id: \.self) { row in
                    Text("Application \(row)").frame(height: 40)
                }
            }
            .padding(28)
            .frame(maxWidth: 1120)
            .frame(maxWidth: .infinity)
        }
    }
}

private final class ScrollFixtureMarkerView: NSView {}

private struct ScrollFixtureMarker: NSViewRepresentable {
    func makeNSView(context: Context) -> ScrollFixtureMarkerView { ScrollFixtureMarkerView() }
    func updateNSView(_ view: ScrollFixtureMarkerView, context: Context) {}
}
