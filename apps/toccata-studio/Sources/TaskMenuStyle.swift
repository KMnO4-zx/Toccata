import SwiftUI

/// Menu-bar surfaces follow the supplied light TickTick reference, independently
/// of the workbench's appearance.
enum TaskMenuStyle {
    static let background = Color.white
    static let primary = Color(red: 0.20, green: 0.20, blue: 0.20)
    static let text = Color(red: 0.33, green: 0.33, blue: 0.33)
    static let secondary = Color(red: 0.65, green: 0.65, blue: 0.65)
    static let muted = Color(red: 0.82, green: 0.82, blue: 0.82)
    static let input = Color(red: 0.969, green: 0.969, blue: 0.969)
    static let hover = Color(red: 0.961, green: 0.961, blue: 0.961)
    static let accent = Color(red: 0.278, green: 0.447, blue: 0.980)
    static let divider = Color.black.opacity(0.055)
    static let cornerRadius: CGFloat = 12
}

struct TaskMenuCheckbox: View {
    let isCompleted: Bool
    var size: CGFloat = 12
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isCompleted ? "checkmark.circle.fill" : "circle")
                .font(.system(size: size + 2, weight: .regular))
                .foregroundStyle(isCompleted ? Color(white: 0.88) : Color(white: 0.62))
                .frame(width: size, height: max(22, size))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
