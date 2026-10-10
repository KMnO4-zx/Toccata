import AppKit

struct KeySpec: Decodable {
    let code: UInt16?
    let label: String
    let w: Double
    let h: Double
    let x: Double
    let y: Double
    let decor: Bool

    enum CodingKeys: String, CodingKey { case code, label, w, h, x, y, decor }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        code = try c.decodeIfPresent(UInt16.self, forKey: .code)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        w = try c.decodeIfPresent(Double.self, forKey: .w) ?? 1
        h = try c.decodeIfPresent(Double.self, forKey: .h) ?? 1
        x = try c.decodeIfPresent(Double.self, forKey: .x) ?? 0
        y = try c.decodeIfPresent(Double.self, forKey: .y) ?? 0
        decor = try c.decodeIfPresent(Bool.self, forKey: .decor) ?? false
    }
}

struct PlacedKey {
    let code: UInt16?
    let label: String
    let decor: Bool
    let rect: CGRect // unit coordinates
}

struct KeyboardLayout: Decodable {
    let id: String
    let name: String
    let unit: Double
    let keyGap: Double
    let rows: [[KeySpec]]

    let placedKeys: [PlacedKey]
    let widthU: Double
    let heightU: Double

    var contentWidthPoints: Double { widthU * unit }
    var contentHeightPoints: Double { heightU * unit }

    enum CodingKeys: String, CodingKey { case id, name, unit, keyGap, rows }

    init(id: String, name: String, unit: Double, keyGap: Double, rows: [[KeySpec]]) {
        self.id = id
        self.name = name
        self.unit = unit
        self.keyGap = keyGap
        self.rows = rows
        (placedKeys, widthU, heightU) = KeyboardLayout.place(rows: rows)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        unit = try c.decode(Double.self, forKey: .unit)
        keyGap = try c.decode(Double.self, forKey: .keyGap)
        rows = try c.decode([[KeySpec]].self, forKey: .rows)
        (placedKeys, widthU, heightU) = KeyboardLayout.place(rows: rows)
    }

    private static func place(rows: [[KeySpec]]) -> ([PlacedKey], Double, Double) {
        var placed: [PlacedKey] = []
        var widthU = 0.0
        var maxY = 0.0
        for (rowIndex, row) in rows.enumerated() {
            var cursor = 0.0
            let rowY = Double(rowIndex)
            for key in row {
                cursor += key.x
                let rect = CGRect(x: cursor, y: rowY + key.y, width: key.w, height: key.h)
                placed.append(PlacedKey(code: key.code, label: key.label, decor: key.decor, rect: rect))
                maxY = max(maxY, Double(rect.maxY))
                cursor += key.w
            }
            widthU = max(widthU, cursor)
        }
        return (placed, widthU, max(maxY, Double(rows.count)))
    }
}

extension KeyboardLayout {
    static let layoutFileName = "macbook-air-ansi.json"

    static func decode(from url: URL) -> KeyboardLayout? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(KeyboardLayout.self, from: data)
    }

    static func load() -> KeyboardLayout {
        let overrideURL = ToccataPaths.layoutsDir.appendingPathComponent(layoutFileName)
        if let layout = decode(from: overrideURL) { return layout }
        if let url = Bundle.module.url(forResource: "macbook-air-ansi", withExtension: "json"),
           let layout = decode(from: url) {
            return layout
        }
        return KeyboardLayout(id: "empty", name: "Empty", unit: 54, keyGap: 6, rows: [])
    }
}
