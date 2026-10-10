import Foundation

enum ToccataPaths {
    static let supportDir: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Toccata", isDirectory: true)
    }()

    static var themesDir: URL { supportDir.appendingPathComponent("themes", isDirectory: true) }
    static var layoutsDir: URL { supportDir.appendingPathComponent("layouts", isDirectory: true) }
    static var socketPath: String { supportDir.appendingPathComponent("toccata.sock").path }
    static var databasePath: String { supportDir.appendingPathComponent("toccata.db").path }
}
