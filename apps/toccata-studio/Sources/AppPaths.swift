import Foundation

/// Shared location for the workspace, with optional daemon path overrides.
enum AppPaths {
    static let supportDirectory: URL = {
        if let path = ProcessInfo.processInfo.environment["TOCCATA_DATA_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Toccata", isDirectory: true)
    }()

    private static var configuration: [String: Any] {
        guard let data = try? Data(contentsOf: supportDirectory.appendingPathComponent("config.json")),
              let values = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return values
    }

    static var databaseURL: URL {
        if let path = configuration["db_path"] as? String, !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return supportDirectory.appendingPathComponent("toccata.db")
    }

    static var socketPath: String {
        if let path = configuration["socket_path"] as? String, !path.isEmpty { return path }
        return supportDirectory.appendingPathComponent("toccata.sock").path
    }
}
