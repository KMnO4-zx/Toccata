import CoreGraphics
import Foundation

struct KeyboardLayout {
    struct Key: Identifiable, Equatable {
        let id: String
        let code: Int?
        let label: String
        let row: Int
        let column: Int
        let isDecoration: Bool
        let x: Double
        let y: Double
        let w: Double
        let h: Double

        var displayLabel: String {
            label.isEmpty ? "Space" : label
        }

        /// Shared names for heatmap tooltips and the selected-range ranking.
        var readableLabel: String {
            switch code {
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
            default: return displayLabel
            }
        }
    }

    struct PositionedKey: Identifiable, Equatable {
        let key: Key
        let frame: CGRect

        var id: String { key.id }
    }

    struct ScaledLayout: Equatable {
        let size: CGSize
        let keys: [PositionedKey]
    }

    let id: String
    let name: String
    let unit: Double
    let keyGap: Double
    let widthUnits: Double
    let heightUnits: Double
    let keys: [Key]
    let loadError: String?

    static let magicKeyboard: KeyboardLayout = {
        guard let data = ResourceLoader.jsonData(named: "magic-keyboard-ansi", subdirectory: "Layout") else {
            return .unavailable("找不到妙控键盘布局资源")
        }
        do {
            return try parse(data)
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }()

    var isValid: Bool {
        guard loadError == nil, !keys.isEmpty,
              unit.isFinite, unit > 0,
              keyGap.isFinite, keyGap >= 0,
              widthUnits.isFinite, widthUnits > 0,
              heightUnits.isFinite, heightUnits > 0 else { return false }
        return keys.allSatisfy { key in
            key.x.isFinite && key.y.isFinite &&
            key.w.isFinite && key.h.isFinite &&
            key.w > 0 && key.h > 0 &&
            key.w * unit > keyGap && key.h * unit > keyGap
        }
    }

    var aspectRatio: CGFloat {
        guard widthUnits > 0, heightUnits > 0 else { return 1 }
        return CGFloat(widthUnits / heightUnits)
    }

    static func parse(_ data: Data) throws -> KeyboardLayout {
        let raw = try JSONDecoder().decode(RawLayout.self, from: data)
        let id = raw.id ?? "keyboard-layout"
        let unit = raw.unit ?? 54
        let keyGap = raw.keyGap ?? 6
        guard unit.isFinite, unit > 0, keyGap.isFinite, keyGap >= 0 else {
            throw KeyboardLayoutError.invalid("unit 和 keyGap 无效")
        }

        var keys: [Key] = []
        var keycodes = Set<Int>()
        var identifiers = Set<String>()
        var widthUnits = 0.0
        var rowY = 0.0

        for (rowIndex, row) in raw.rows.enumerated() {
            var cursorX = 0.0
            var rowWidth = 0.0
            var rowHeight = 1.0

            for (columnIndex, item) in row.enumerated() {
                let w = item.w ?? 1
                let h = item.h ?? 1
                let offsetX = item.x ?? 0
                let offsetY = item.y ?? 0
                guard w.isFinite, h.isFinite, w > 0, h > 0,
                      offsetX.isFinite, offsetY.isFinite,
                      w * unit > keyGap, h * unit > keyGap else {
                    throw KeyboardLayoutError.invalid("第 \(rowIndex + 1) 行第 \(columnIndex + 1) 项尺寸无效")
                }

                if let code = item.code {
                    guard code >= 0 else {
                        throw KeyboardLayoutError.invalid("keycode 不能为负数")
                    }
                    guard keycodes.insert(code).inserted else {
                        throw KeyboardLayoutError.duplicateKeycode(code)
                    }
                }

                let identifier: String
                if let code = item.code {
                    identifier = "keycode-\(code)"
                } else {
                    identifier = "decor-\(item.id ?? "\(rowIndex)-\(columnIndex)")"
                }
                guard identifiers.insert(identifier).inserted else {
                    throw KeyboardLayoutError.duplicateIdentifier(identifier)
                }

                cursorX += offsetX
                let x = cursorX
                let y = rowY + offsetY
                keys.append(Key(
                    id: identifier,
                    code: item.code,
                    label: item.label ?? "",
                    row: rowIndex,
                    column: columnIndex,
                    isDecoration: item.decor ?? (item.code == nil),
                    x: x,
                    y: y,
                    w: w,
                    h: h
                ))

                cursorX += w
                rowWidth = max(rowWidth, cursorX)
                rowHeight = max(rowHeight, offsetY + h)
            }

            widthUnits = max(widthUnits, rowWidth)
            rowY += rowHeight
        }

        let layout = KeyboardLayout(
            id: id,
            name: raw.name ?? id,
            unit: unit,
            keyGap: keyGap,
            widthUnits: widthUnits,
            heightUnits: rowY,
            keys: keys,
            loadError: nil
        )
        guard layout.isValid else {
            throw KeyboardLayoutError.invalid("布局为空或尺寸无效")
        }
        return layout
    }

    func scaled(toWidth width: CGFloat) -> ScaledLayout {
        guard isValid, width.isFinite, width > 0 else {
            return ScaledLayout(size: .zero, keys: [])
        }

        let scale = width / CGFloat(widthUnits * unit)
        let gap = CGFloat(keyGap) * scale
        let positionedKeys = keys.map { key in
            let frame = CGRect(
                x: CGFloat(key.x * unit) * scale + gap / 2,
                y: CGFloat(key.y * unit) * scale + gap / 2,
                width: CGFloat(key.w * unit) * scale - gap,
                height: CGFloat(key.h * unit) * scale - gap
            )
            return PositionedKey(key: key, frame: frame)
        }
        return ScaledLayout(
            size: CGSize(width: width, height: CGFloat(heightUnits * unit) * scale),
            keys: positionedKeys
        )
    }

    func frames(forWidth width: CGFloat) -> [PositionedKey] {
        scaled(toWidth: width).keys
    }

    private static func unavailable(_ message: String) -> KeyboardLayout {
        KeyboardLayout(
            id: "magic-keyboard-ansi",
            name: "Apple Magic Keyboard (ANSI)",
            unit: 54,
            keyGap: 6,
            widthUnits: 0,
            heightUnits: 0,
            keys: [],
            loadError: message
        )
    }

    private struct RawLayout: Decodable {
        let id: String?
        let name: String?
        let unit: Double?
        let keyGap: Double?
        let rows: [[RawKey]]
    }

    private struct RawKey: Decodable {
        let id: String?
        let code: Int?
        let label: String?
        let decor: Bool?
        let w: Double?
        let h: Double?
        let x: Double?
        let y: Double?
    }
}

enum KeyboardLayoutError: LocalizedError, Equatable {
    case invalid(String)
    case duplicateKeycode(Int)
    case duplicateIdentifier(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let message):
            return "键盘布局无效：\(message)"
        case .duplicateKeycode(let code):
            return "键盘布局包含重复 keycode：\(code)"
        case .duplicateIdentifier(let identifier):
            return "键盘布局包含重复 ID：\(identifier)"
        }
    }
}
