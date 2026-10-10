import SwiftUI

struct RGB {
    var r: Double
    var g: Double
    var b: Double
    var a: Double

    init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    /// 支持 "#RRGGBB" 与 "#RRGGBBAA"。
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard let value = UInt64(s, radix: 16) else { return nil }
        switch s.count {
        case 6:
            r = Double((value >> 16) & 0xFF) / 255
            g = Double((value >> 8) & 0xFF) / 255
            b = Double(value & 0xFF) / 255
            a = 1
        case 8:
            r = Double((value >> 24) & 0xFF) / 255
            g = Double((value >> 16) & 0xFF) / 255
            b = Double((value >> 8) & 0xFF) / 255
            a = Double(value & 0xFF) / 255
        default:
            return nil
        }
    }

    func lerp(to other: RGB, t: Double) -> RGB {
        let t = min(max(t, 0), 1)
        return RGB(
            r: r + (other.r - r) * t,
            g: g + (other.g - g) * t,
            b: b + (other.b - b) * t,
            a: a + (other.a - a) * t
        )
    }
}

extension Color {
    init(rgb: RGB) {
        self.init(.sRGB, red: rgb.r, green: rgb.g, blue: rgb.b, opacity: rgb.a)
    }

    init?(hex: String) {
        guard let rgb = RGB(hex: hex) else { return nil }
        self.init(rgb: rgb)
    }
}

struct ThemePalette {
    var heatLow: RGB
    var heatHigh: RGB

    func heatColor(t: Double) -> Color {
        Color(rgb: heatLow.lerp(to: heatHigh, t: t))
    }
}

/// 从主题 JSON 加载热力图配色；加载失败使用代码内置默认色（与随包主题一致）。
final class ThemeStore {
    static let shared = ThemeStore()

    let light: ThemePalette
    let dark: ThemePalette

    private init() {
        light = ThemeStore.load(name: "light")
            ?? ThemePalette(heatLow: RGB(hex: "#FFE5D9")!, heatHigh: RGB(hex: "#D0342C")!)
        dark = ThemeStore.load(name: "dark")
            ?? ThemePalette(heatLow: RGB(hex: "#3D1D18")!, heatHigh: RGB(hex: "#FF6B5E")!)
    }

    private static func load(name: String) -> ThemePalette? {
        guard let data = ResourceLoader.jsonData(named: name, subdirectory: "Themes"),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let lowHex = object["heatLow"] as? String,
              let highHex = object["heatHigh"] as? String,
              let low = RGB(hex: lowHex),
              let high = RGB(hex: highHex) else { return nil }
        return ThemePalette(heatLow: low, heatHigh: high)
    }

    func palette(for colorScheme: ColorScheme) -> ThemePalette {
        colorScheme == .dark ? dark : light
    }
}
