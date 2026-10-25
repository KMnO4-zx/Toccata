import AppKit

/// Resolve installed applications once, keeping icon lookup out of each row render.
@MainActor
final class ApplicationIdentityCache {
    struct Identity {
        let name: String
        let icon: NSImage?
    }

    static let shared = ApplicationIdentityCache()
    private var identities: [String: Identity] = [:]

    func identity(for bundleIdentifier: String) -> Identity {
        if let cached = identities[bundleIdentifier] { return cached }

        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first
        let url = running?.bundleURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        let bundle = url.flatMap(Bundle.init(url:))
        let name = running?.localizedName
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? url.map { $0.deletingPathExtension().lastPathComponent }
            ?? bundleIdentifier.split(separator: ".").last.map(String.init)
            ?? bundleIdentifier
        let icon = running?.icon ?? url.map { NSWorkspace.shared.icon(forFile: $0.path) }
        let identity = Identity(name: name, icon: icon)
        // A missing app may be launched or installed later in this session.
        if icon != nil { identities[bundleIdentifier] = identity }
        return identity
    }
}
