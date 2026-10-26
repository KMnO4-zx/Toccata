import Foundation

enum ResourceLoader {
    /// Look in the requested resource directory first, then support bundles
    /// whose resources were flattened by SwiftPM.
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
