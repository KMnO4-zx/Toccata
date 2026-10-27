import SwiftUI

/// Show where editing is available without moving the text or changing focus.
private struct EditableSurface: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false
    let isFocused: Bool
    let cornerRadius: CGFloat
    let accent: Color
    let fill: Color
    let idleBorderOpacity: Double

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        content
            .background {
                shape.fill(fill)
                shape.fill(accent.opacity(isFocused ? 0.055 : (isHovered ? 0.025 : 0)))
            }
            .overlay {
                shape.strokeBorder(accent.opacity(isFocused ? 0.55 : (isHovered ? 0.25 : idleBorderOpacity)),
                                   lineWidth: isFocused ? 1.5 : 1)
                    .shadow(color: accent.opacity(isFocused ? 0.12 : 0), radius: 3)
                    .allowsHitTesting(false)
            }
            .onHover { isHovered = $0 }
            .animation(reduceMotion ? nil : WorkspaceMotion.editFocus, value: isFocused)
            .animation(reduceMotion ? nil : WorkspaceMotion.editFocus, value: isHovered)
    }
}

extension View {
    func editableSurface(isFocused: Bool, cornerRadius: CGFloat = 8,
                         accent: Color = .accentColor, fill: Color = .clear,
                         idleBorderOpacity: Double = 0) -> some View {
        modifier(EditableSurface(isFocused: isFocused, cornerRadius: cornerRadius,
                                 accent: accent, fill: fill, idleBorderOpacity: idleBorderOpacity))
    }
}

struct EditActionButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.45)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.9 : 1)
            .animation(reduceMotion ? nil : WorkspaceMotion.editPress, value: configuration.isPressed)
            .animation(reduceMotion ? nil : WorkspaceMotion.editFocus, value: isEnabled)
    }
}
