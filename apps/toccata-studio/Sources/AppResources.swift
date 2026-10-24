import Foundation

enum AppResources {
    /// SwiftPM executables and packaged macOS applications resolve resources
    /// differently. Prefer the standard app Resources folder when packaged.
    static let bundle: Bundle = {
        if let resources = Bundle.main.resourceURL,
           let bundle = Bundle(url: resources.appendingPathComponent("toccata-studio_toccata-studio.bundle")) {
            return bundle
        }
        return Bundle.module
    }()
}
