import AppKit

struct Theme: Decodable {
    let name: String
    let windowBackground: String
    let keycap: String
    let keycapBorder: String
    let label: String
    let pressed: String
    let pressedLabel: String
    let heatLow: String
    let heatHigh: String
    let heatLabel: String
    let decor: String
}

extension Theme {
    var windowBackgroundColor: NSColor { NSColor(hex: windowBackground) ?? .clear }
    var keycapColor: NSColor { NSColor(hex: keycap) ?? .white }
    var keycapBorderColor: NSColor { NSColor(hex: keycapBorder) ?? .gray }
    var labelColor: NSColor { NSColor(hex: label) ?? .black }
    var pressedColor: NSColor { NSColor(hex: pressed) ?? .systemBlue }
    var pressedLabelColor: NSColor { NSColor(hex: pressedLabel) ?? .white }
    var heatLowColor: NSColor { NSColor(hex: heatLow) ?? .white }
    var heatHighColor: NSColor { NSColor(hex: heatHigh) ?? .systemRed }
    var heatLabelColor: NSColor { NSColor(hex: heatLabel) ?? .black }
    var decorColor: NSColor { NSColor(hex: decor) ?? .lightGray }

    static let fallback = Theme(
        name: "Light",
        windowBackground: "#F5F5F7D9", keycap: "#FFFFFF", keycapBorder: "#D1D1D6",
        label: "#1D1D1F", pressed: "#0A84FF", pressedLabel: "#FFFFFF",
        heatLow: "#FFE5D9", heatHigh: "#D0342C", heatLabel: "#1D1D1F", decor: "#E8E8ED"
    )

    static func decode(from url: URL) -> Theme? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Theme.self, from: data)
    }
}

struct ThemeEntry {
    let name: String
    let load: () -> Theme
}

enum ThemeCatalog {
    static let builtinFileNames = ["light", "dark"]

    static func availableThemes() -> [ThemeEntry] {
        var entries: [ThemeEntry] = []
        for fileName in builtinFileNames {
            let bundled = Bundle.module.url(forResource: fileName, withExtension: "json")
                .flatMap(Theme.decode)
            entries.append(ThemeEntry(name: bundled?.name ?? fileName.capitalized) {
                let overrideURL = ToccataPaths.themesDir.appendingPathComponent("\(fileName).json")
                if let theme = Theme.decode(from: overrideURL) { return theme }
                return bundled ?? .fallback
            })
        }
        if let files = try? FileManager.default.contentsOfDirectory(atPath: ToccataPaths.themesDir.path) {
            for file in files.sorted() where file.hasSuffix(".json") {
                let url = ToccataPaths.themesDir.appendingPathComponent(file)
                guard let theme = Theme.decode(from: url),
                      !entries.contains(where: { $0.name == theme.name }) else { continue }
                entries.append(ThemeEntry(name: theme.name) {
                    Theme.decode(from: url) ?? .fallback
                })
            }
        }
        return entries
    }
}
