import SwiftUI

/// A shared, animated selector for workbench filters, using the same accent as task controls.
struct WorkspaceSegmentedControl<Selection: Hashable>: View {
    let title: String
    @Binding var selection: Selection
    let options: [Selection]
    let optionSymbol: (Selection) -> String?
    let optionTitle: (Selection) -> String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @FocusState private var isFocused: Bool
    @State private var hoveredOption: Selection?

    init(title: String, selection: Binding<Selection>, options: [Selection],
         optionSymbol: @escaping (Selection) -> String? = { _ in nil },
         optionTitle: @escaping (Selection) -> String) {
        self.title = title
        _selection = selection
        self.options = options
        self.optionSymbol = optionSymbol
        self.optionTitle = optionTitle
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                Button {
                    isFocused = true
                    // Forward repeat clicks too: a custom-range segment can reopen its editor.
                    selection = option
                } label: {
                    HStack(spacing: 5) {
                        if let symbol = optionSymbol(option) { Image(systemName: symbol) }
                        Text(optionTitle(option))
                    }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(selection == option ? Color.white : Color.primary)
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background {
                            if selection != option && hoveredOption == option {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.primary.opacity(0.045))
                            }
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .onHover { inside in
                    hoveredOption = inside ? option : (hoveredOption == option ? nil : hoveredOption)
                }
                .accessibilityAddTraits(selection == option ? [.isSelected] : [])
                .anchorPreference(key: SegmentBoundsKey<Selection>.self, value: .bounds) { [option: $0] }
            }
        }
        .backgroundPreferenceValue(SegmentBoundsKey<Selection>.self) { bounds in
            GeometryReader { geometry in
                if let anchor = bounds[selection] {
                    let frame = geometry[anchor]
                    if reduceMotion {
                        selectionBackground
                            .frame(width: frame.width, height: frame.height)
                            .position(x: frame.midX, y: frame.midY)
                            .id(selection)
                            .transition(.opacity)
                    } else {
                        // One persistent shape slides between segments without
                        // an incoming highlight appearing at the destination first.
                        selectionBackground
                            .frame(width: frame.width, height: frame.height)
                            .position(x: frame.midX, y: frame.midY)
                    }
                }
            }
            .allowsHitTesting(false)
        }
        .padding(3)
        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
        .fixedSize(horizontal: true, vertical: false)
        .opacity(isEnabled ? 1 : 0.5)
        .focusable(isEnabled)
        .focused($isFocused)
        .modifier(SegmentedControlFocusAppearance())
        .onMoveCommand { direction in
            guard isEnabled, let index = options.firstIndex(of: selection) else { return }
            let next: Int
            switch direction {
            case .left: next = max(0, index - 1)
            case .right: next = min(options.count - 1, index + 1)
            default: return
            }
            if next != index { selection = options[next] }
        }
        .animation(reduceMotion ? WorkspaceMotion.sidebarSelectionFade : WorkspaceMotion.sidebarSelection,
                   value: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityValue(optionTitle(selection))
    }

    private var selectionBackground: some View {
        RoundedRectangle(cornerRadius: 6).fill(Color.accentColor)
    }
}

private struct SegmentBoundsKey<Selection: Hashable>: PreferenceKey {
    static var defaultValue: [Selection: Anchor<CGRect>] { [:] }

    static func reduce(value: inout [Selection: Anchor<CGRect>],
                       nextValue: () -> [Selection: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

private struct SegmentedControlFocusAppearance: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) { content.focusEffectDisabled() }
        else { content }
    }
}
