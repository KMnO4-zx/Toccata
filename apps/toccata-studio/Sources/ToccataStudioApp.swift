import SwiftUI
import AppKit

@main
struct ToccataStudioApp: App {
    @StateObject private var refresher = LiveRefresher()

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        Window("Toccata Studio", id: "main") {
            ContentView()
                .environmentObject(refresher)
                .frame(minWidth: 780, minHeight: 560)
                .onAppear { refresher.start() }
        }
        .defaultSize(width: 960, height: 680)
    }
}

struct ContentView: View {
    private enum Tab: String, CaseIterable, Identifiable {
        case overview = "概览"
        case calendar = "日历"
        case ranking = "排行"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .overview

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .padding(.horizontal, 160)
            .padding(.vertical, 10)

            Divider()

            switch tab {
            case .overview:
                OverviewView()
            case .calendar:
                CalendarHeatmapView()
            case .ranking:
                RankingView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension View {
    /// macOS 13/14 兼容的 onChange（零参数闭包形式）。
    @ViewBuilder
    func onValueChange<V: Equatable>(of value: V, perform action: @escaping () -> Void) -> some View {
        if #available(macOS 14.0, *) {
            onChange(of: value, action)
        } else {
            onChange(of: value) { _ in action() }
        }
    }
}
