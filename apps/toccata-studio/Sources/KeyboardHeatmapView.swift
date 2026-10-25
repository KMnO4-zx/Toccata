import SwiftUI

struct KeyboardHeatmapView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let layout: KeyboardLayout
    private let counts: [Int: Int]
    private let fnMs: Int64
    private let periodDescription: String
    @State private var hoveredKeyID: String?

    init(layout: KeyboardLayout = .magicKeyboard, counts: [Int: Int] = [:], fnMs: Int64 = 0,
         periodDescription: String = "今天") {
        self.layout = layout
        self.counts = counts
        self.fnMs = fnMs
        self.periodDescription = periodDescription
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
                        activity: activityDescription(for: item.key),
                        intensity: intensity,
                        size: item.frame.size,
                        hovering: hoveredKeyID == item.id
                    )
                    .frame(width: item.frame.width, height: item.frame.height)
                    .position(x: item.frame.midX, y: item.frame.midY)
                }

                if let item = scaled.keys.first(where: { $0.id == hoveredKeyID }) {
                    let width = min(item.key.code == 63 ? 240 : 180, scaled.size.width)
                    let height: CGFloat = 66
                    let halfWidth = width / 2
                    let halfHeight = height / 2
                    let x = min(max(item.frame.midX, halfWidth), scaled.size.width - halfWidth)
                    let above = item.frame.minY - halfHeight - 10
                    let y = above >= halfHeight ? above : item.frame.maxY + halfHeight + 10

                    KeyboardKeyTooltip(
                        name: keyName(for: item.key),
                        activity: activityDescription(for: item.key)
                    )
                    .frame(width: width, height: height)
                    .position(x: x, y: min(max(y, halfHeight), max(halfHeight, scaled.size.height - halfHeight)))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .transition(.opacity)
                    .zIndex(1)
                }
            }
            .frame(width: scaled.size.width, height: scaled.size.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    hoveredKeyID = scaled.keys.first { $0.frame.contains(location) }?.id
                case .ended:
                    hoveredKeyID = nil
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: hoveredKeyID != nil)
        }
        .aspectRatio(layout.aspectRatio, contentMode: .fit)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("\(periodDescription)逐键键盘热度"))
        .onDisappear { hoveredKeyID = nil }
    }

    private func activityDescription(for key: KeyboardLayout.Key) -> String {
        if key.code == 63 {
            return "\(periodDescription)按住 \(Formatters.duration(ms: fnMs))"
        }
        let count = max(0, counts[key.code ?? Int.min] ?? 0)
        return "\(periodDescription)按下 \(count.formatted()) 次"
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
        case 63: return "Fn / 地球键"
        case 105: return "锁定"
        case 49: return "空格"
        case 53: return "Esc"
        case 48: return "Tab"
        case 51: return "退格"
        case 36: return "回车"
        case 57: return "大写锁定"
        case 123: return "左方向键"
        case 124: return "右方向键"
        case 125: return "下方向键"
        case 126: return "上方向键"
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

    fileprivate static func color(intensity: Double, scheme: ColorScheme) -> Color {
        let t = min(max(intensity, 0), 1)
        let base = scheme == .dark
            ? (red: 0.16, green: 0.17, blue: 0.20)
            : (red: 0.949, green: 0.957, blue: 0.969)
        let hot = scheme == .dark
            ? (red: 0.18, green: 0.32, blue: 0.75)
            : (red: 0.025, green: 0.220, blue: 0.720)
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
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let label: String
    let name: String
    let activity: String
    let intensity: Double
    let size: CGSize
    let hovering: Bool

    private var cornerRadius: CGFloat {
        min(7, min(size.width, size.height) * 0.18)
    }

    private var fontSize: CGFloat {
        max(7, min(16, size.height * 0.28))
    }

    private var highlights: [Color] {
        if colorScheme == .dark {
            return [.white.opacity(0.08), .white.opacity(0.015), .black.opacity(0.12)]
        }
        return [.white.opacity(0.62 - intensity * 0.46), .white.opacity(0.08),
                .black.opacity(0.035 + intensity * 0.025)]
    }

    private var edges: [Color] {
        colorScheme == .dark
            ? [.white.opacity(0.24), .white.opacity(0.07), .black.opacity(0.35)]
            : [.white.opacity(0.95), Color(white: 0.70), .white.opacity(0.82)]
    }

    private var labelColor: Color {
        if colorScheme == .dark { return Color(white: 0.96) }
        return KeyboardHeatmap.usesWhiteText(intensity: intensity) ? .white : Color(white: 0.17)
    }

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(KeyboardHeatmap.color(intensity: intensity, scheme: colorScheme))
            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.30 : 0.14), radius: 1.2, x: 0, y: 1)
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: highlights,
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: edges,
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: hovering ? 1.2 : 0.8
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: max(0, cornerRadius - 1), style: .continuous)
                    .stroke(Color.white.opacity(colorScheme == .dark ? 0.06 : 0.42), lineWidth: 0.5)
                    .padding(1)
            }
            .overlay {
                Text(label)
                    .font(.system(size: fontSize, weight: .medium, design: .rounded))
                    .foregroundColor(labelColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                    .padding(2)
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(name))
            .accessibilityValue(Text(activity))
    }
}

private struct KeyboardKeyTooltip: View {
    let name: String
    let activity: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(activity)
                .font(.system(size: 13, weight: .medium))
                .monospacedDigit()
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.14), radius: 8, x: 0, y: 3)
    }
}
