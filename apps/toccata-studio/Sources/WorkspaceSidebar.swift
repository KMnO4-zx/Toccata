import SwiftUI

enum WorkspaceSection: String, CaseIterable, Identifiable {
    case tasks = "任务"
    case inbox = "收集箱"
    case taskCalendar = "任务日历"
    case review = "任务回顾"
    case activity = "键盘活跃"
    case ranking = "应用与趋势"
    case generalSettings = "通用配置"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .tasks: return "checklist"
        case .inbox: return "tray"
        case .taskCalendar: return "calendar"
        case .review: return "checkmark.circle"
        case .activity: return "waveform.path"
        case .ranking: return "chart.bar.xaxis"
        case .generalSettings: return "gearshape"
        }
    }
}

/// All destinations share one SwiftUI layout so the selection can travel
/// across groups without being clipped by native List row hosting views.
struct WorkspaceSidebar: View {
    @ObservedObject private var interfaceLanguage = LanguageSettings.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var controlActiveState
    @Binding var selection: WorkspaceSection?
    let openCount: Int
    @FocusState private var sidebarFocused: Bool
    @State private var hoveredSection: WorkspaceSection?

    var body: some View {
        let _ = interfaceLanguage.language
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    group(L10n.tr("任务"), items: [.tasks, .inbox, .taskCalendar, .review])
                    group(L10n.tr("时间与活动"), items: [.activity, .ranking])
                    group(L10n.tr("设置"), items: [.generalSettings])
                }
                .backgroundPreferenceValue(SidebarRowBoundsKey.self) { bounds in
                    GeometryReader { geometry in
                        if !reduceMotion, let anchor = bounds[selection ?? .tasks] {
                            let frame = geometry[anchor]
                            RoundedRectangle(cornerRadius: 7)
                                .fill(selectionColor)
                                .frame(width: frame.width, height: frame.height)
                                .position(x: frame.midX, y: frame.midY)
                        }
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
                .padding(.horizontal, 10)
                .padding(.top, 4)
                .padding(.bottom, 8)
                .animation(reduceMotion ? WorkspaceMotion.sidebarSelectionFade : WorkspaceMotion.sidebarSelection,
                           value: selection)
            }
            .focusable()
            .focused($sidebarFocused)
            .modifier(SidebarFocusAppearance())
            .onMoveCommand { direction in
                guard sidebarFocused, direction == .up || direction == .down else { return }
                let destinations = WorkspaceSection.allCases
                let current = destinations.firstIndex(of: selection ?? .tasks) ?? 0
                let next = min(max(current + (direction == .up ? -1 : 1), 0), destinations.count - 1)
                selection = destinations[next]
                proxy.scrollTo(destinations[next])
            }
        }
    }

    private func group(_ title: String, items: [WorkspaceSection]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                ForEach(items) { item in row(item) }
            }
        }
    }

    private func row(_ item: WorkspaceSection) -> some View {
        let isSelected = (selection ?? .tasks) == item
        let isEmphasized = isSelected && controlActiveState != .inactive
        return Button {
            sidebarFocused = true
            selection = item
        } label: {
            HStack(spacing: 9) {
                Image(systemName: item.symbol)
                    .font(.system(size: 14))
                    .frame(width: 16)
                Text(L10n.key(item.rawValue))
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if item == .inbox, openCount > 0 {
                    Text(openCount.formatted())
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(isEmphasized ? Color.white.opacity(0.8) : Color.secondary)
                }
            }
            .foregroundStyle(isEmphasized ? Color.white : Color.primary)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background {
                if isSelected && reduceMotion {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(selectionColor)
                        .transition(.opacity)
                } else if !isSelected && hoveredSection == item {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.primary.opacity(0.045))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .onHover { hoveredSection = $0 ? item : (hoveredSection == item ? nil : hoveredSection) }
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityIdentifier("workspace-sidebar-\(item.symbol)")
        .anchorPreference(key: SidebarRowBoundsKey.self, value: .bounds) { [item: $0] }
        .id(item)
    }

    private var selectionColor: Color {
        Color(nsColor: controlActiveState == .inactive
              ? .unemphasizedSelectedContentBackgroundColor : .selectedContentBackgroundColor)
    }
}

private struct SidebarRowBoundsKey: PreferenceKey {
    static var defaultValue: [WorkspaceSection: Anchor<CGRect>] = [:]

    static func reduce(value: inout [WorkspaceSection: Anchor<CGRect>],
                       nextValue: () -> [WorkspaceSection: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct SidebarFocusAppearance: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) { content.focusEffectDisabled() }
        else { content }
    }
}
