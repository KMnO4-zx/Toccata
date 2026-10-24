import Foundation

enum ResourceLoader {
    /// .process("Resources") 正常会保留 Layout/、Themes/ 子目录；
    /// 若目录结构被扁平化则退回 bundle 根目录查找。
    static func jsonData(named name: String, subdirectory: String) -> Data? {
        if let url = AppResources.bundle.url(forResource: name, withExtension: "json", subdirectory: subdirectory) {
            return try? Data(contentsOf: url)
        }
        if let url = AppResources.bundle.url(forResource: name, withExtension: "json") {
            return try? Data(contentsOf: url)
        }
        return nil
    }
}

/// 解析布局 JSON 提供 keycode → 键名映射；加载失败时回退为 "Key<code>"。
final class KeyLabels {
    static let shared = KeyLabels()

    private var map: [Int: String] = [:]

    private init() {
        guard let data = ResourceLoader.jsonData(named: "macbook-air-ansi", subdirectory: "Layout"),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["rows"] as? [[Any]] else { return }
        for row in rows {
            for item in row {
                guard let key = item as? [String: Any],
                      let code = key["code"] as? NSNumber,
                      let label = key["label"] as? String else { continue }
                map[code.intValue] = label
            }
        }
    }

    func label(for keycode: Int) -> String {
        guard let label = map[keycode] else { return "Key\(keycode)" }
        return label.isEmpty ? "Space" : label
    }
}
