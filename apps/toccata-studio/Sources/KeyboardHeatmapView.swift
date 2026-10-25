import SwiftUI

struct KeyboardHeatmapView: View {
    private let layout: KeyboardLayout
    private let counts: [Int: Int]

    init(layout: KeyboardLayout = .magicKeyboard, counts: [Int: Int] = [:]) {
        self.layout = layout
        self.counts = counts
    }

    var body: some View {
        Group {
            if layout.isValid {
                keyboard
            } else {
                Text("键盘布局不可用")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            }
        }
    }

    private var maxCount: Int {
        counts.values.max() ?? 0
    }

    private var keyboard: some View {
        GeometryReader { proxy in
            let scaled = layout.scaled(toWidth: proxy.size.width)
            ZStack(alignment: .topLeading) {
                ForEach(scaled.keys) { item in
                    let count = max(0, counts[item.key.code ?? Int.min] ?? 0)
                    let intensity = KeyboardHeatmap.intensity(
                        count: count,
                        maxCount: maxCount
                    )
                    KeyboardKeyCap(
                        label: item.key.displayLabel,
                        name: keyName(for: item.key),
                        count: count,
                        intensity: intensity,
                        size: item.frame.size
                    )
                    .frame(width: item.frame.width, height: item.frame.height)
                    .position(x: item.frame.midX, y: item.frame.midY)
                }
            }
            .frame(width: scaled.size.width, height: scaled.size.height, alignment: .topLeading)
        }
        .aspectRatio(layout.aspectRatio, contentMode: .fit)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("今日逐键键盘热度"))
    }

    private func keyName(for key: KeyboardLayout.Key) -> String {
        switch key.code {
        case 56: return "左 Shift"
        case 60: return "右 Shift"
        case 59: return "左 Control"
        case 58: return "左 Option"
        case 61: return "右 Option"
        case 55: return "左 Command"
        case 54: return "右 Command"
        case 63: return "globe / Fn"
        case 105: return "锁定"
        default: return key.displayLabel
        }
    }
}

enum KeyboardHeatmap {
    static func intensity(count: Int, maxCount: Int) -> Double {
        guard count > 0, maxCount > 0 else { return 0 }
        let clampedCount = min(count, maxCount)
        return log1p(Double(clampedCount)) / log1p(Double(maxCount))
    }

    fileprivate static func color(intensity: Double) -> Color {
        let t = min(max(intensity, 0), 1)
        let base = (red: 0.949, green: 0.957, blue: 0.969)
        let hot = (red: 0.025, green: 0.220, blue: 0.720)
        return Color(
            .sRGB,
            red: base.red + (hot.red - base.red) * t,
            green: base.green + (hot.green - base.green) * t,
            blue: base.blue + (hot.blue - base.blue) * t,
            opacity: 1
        )
    }

    fileprivate static func usesWhiteText(intensity: Double) -> Bool {
        intensity >= 0.68
    }
}

private struct KeyboardKeyCap: View {
    let label: String
    let name: String
    let count: Int
    let intensity: Double
    let size: CGSize

    @State private var hovering = false

    private var cornerRadius: CGFloat {
        min(7, min(size.width, size.height) * 0.18)
    }

    private var fontSize: CGFloat {
        max(7, min(16, size.height * 0.28))
    }

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(KeyboardHeatmap.color(intensity: intensity))
            .shadow(color: Color.black.opacity(0.14), radius: 1.2, x: 0, y: 1)
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.62 - intensity * 0.46),
                                Color.white.opacity(0.08),
                                Color.black.opacity(0.035 + intensity * 0.025)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.95),
                                Color(white: 0.70),
                                Color.white.opacity(0.82)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: hovering ? 1.2 : 0.8
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: max(0, cornerRadius - 1), style: .continuous)
                    .stroke(Color.white.opacity(0.42), lineWidth: 0.5)
                    .padding(1)
            }
            .overlay {
                Text(label)
                    .font(.system(size: fontSize, weight: .medium, design: .rounded))
                    .foregroundColor(
                        KeyboardHeatmap.usesWhiteText(intensity: intensity)
                            ? .white
                            : Color(white: 0.17)
                    )
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                    .padding(2)
            }
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
            .help("\(name)：今天 \(count) 次")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("\(name)，今天 \(count) 次"))
    }
}
