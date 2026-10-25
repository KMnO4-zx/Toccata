import AppKit
import SwiftUI

/// Keep the compact menu's white-and-blue palette in light mode while resolving
/// every surface against the hosting window's effective appearance.
enum TaskMenuStyle {
    static let background = Color(nsColor: gray("background", light: 1, dark: 0.115))
    static let primary = Color(nsColor: gray("primary", light: 0.20, dark: 0.94))
    static let textColor = gray("text", light: 0.33, dark: 0.84)
    static let text = Color(nsColor: textColor)
    static let secondary = Color(nsColor: gray("secondary", light: 0.42, dark: 0.65))
    static let muted = Color(nsColor: gray("muted", light: 0.44, dark: 0.61))
    static let input = Color(nsColor: gray("input", light: 0.969, dark: 0.17))
    static let hover = Color(nsColor: gray("hover", light: 0.961, dark: 0.20))
    static let accent = Color(nsColor: adaptive("accent",
        light: NSColor(srgbRed: 0.278, green: 0.447, blue: 0.980, alpha: 1),
        dark: NSColor(srgbRed: 0.46, green: 0.62, blue: 1, alpha: 1)))
    static let divider = Color(nsColor: adaptive("divider",
        light: NSColor.black.withAlphaComponent(0.055), dark: NSColor.white.withAlphaComponent(0.09)))
    static let pendingCheckbox = Color(nsColor: gray("checkbox.pending", light: 0.50, dark: 0.63))
    static let completedCheckbox = Color(nsColor: gray("checkbox.completed", light: 0.54, dark: 0.48))
    static let cornerRadius: CGFloat = 12

    private static func gray(_ name: String, light: CGFloat, dark: CGFloat) -> NSColor {
        adaptive(name, light: NSColor(srgbRed: light, green: light, blue: light, alpha: 1),
                 dark: NSColor(srgbRed: dark, green: dark, blue: dark, alpha: 1))
    }

    private static func adaptive(_ name: String, light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: "Toccata.Menu.\(name)") { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }
}

struct TaskMenuCheckbox: View {
    let isCompleted: Bool
    var size: CGFloat = 12
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isCompleted ? "checkmark.circle.fill" : "circle")
                .font(.system(size: size + 2, weight: .regular))
                .foregroundStyle(isCompleted ? TaskMenuStyle.completedCheckbox : TaskMenuStyle.pendingCheckbox)
                .frame(width: size, height: max(22, size))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
