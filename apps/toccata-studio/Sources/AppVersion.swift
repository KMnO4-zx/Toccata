import Foundation

struct AppVersion: Decodable, Equatable {
    let version: String
    let build: String

    var displayVersion: String { "v\(version)" }
    var copyableDescription: String {
        "Toccata \(displayVersion) (Build \(build))\nmacOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
    }

    static let current: AppVersion = {
        if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
           let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
           Bundle.main.bundleIdentifier == "com.toccata.studio" {
            return AppVersion(version: version, build: build)
        }
        // SwiftPM launches do not have the app's Info.plist.
        guard let data = ResourceLoader.jsonData(named: "app-version", subdirectory: ""),
              let version = try? JSONDecoder().decode(AppVersion.self, from: data) else {
            preconditionFailure("Missing app-version.json; run scripts/sync-assets.sh")
        }
        return version
    }()
}

/// Stable releases use numeric major.minor.patch comparison, never lexicographic order.
struct ReleaseVersion: Equatable, Comparable {
    let major: Int
    let minor: Int
    let patch: Int

    init?(_ value: String) {
        let raw = value.hasPrefix("v") ? String(value.dropFirst()) : value
        let parts = raw.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ part in
            !part.isEmpty && part.utf8.allSatisfy { (48...57).contains($0) } &&
                (part.count == 1 || part.first != "0")
        }), let major = Int(parts[0]), let minor = Int(parts[1]), let patch = Int(parts[2]) else { return nil }
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}
