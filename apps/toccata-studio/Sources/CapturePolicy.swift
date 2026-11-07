import Combine
import Foundation

enum CaptureAppMode: String, Codable, CaseIterable, Identifiable {
    case record
    case redact
    case ignore

    var id: String { rawValue }
    var title: String {
        switch self {
        case .record: return L10n.tr("完整记录")
        case .redact: return L10n.tr("脱敏")
        case .ignore: return L10n.tr("不记录")
        }
    }
}

enum CapturePauseDuration: String, CaseIterable, Identifiable {
    case fifteenMinutes
    case oneHour
    case untilResumed

    var id: String { rawValue }
    var title: String {
        switch self {
        case .fifteenMinutes: return L10n.tr("暂停 15 分钟")
        case .oneHour: return L10n.tr("暂停 1 小时")
        case .untilResumed: return L10n.tr("暂停到手动恢复")
        }
    }

    func deadlineMs(from now: Date) -> Int64 {
        switch self {
        case .fifteenMinutes: return ActivityCalculator.milliseconds(now.addingTimeInterval(15 * 60))
        case .oneHour: return ActivityCalculator.milliseconds(now.addingTimeInterval(60 * 60))
        case .untilResumed: return Int64.max
        }
    }
}

/// Shared with toccata-core, which owns the password-manager defaults and reads
/// this file. See shared/protocol.md.
struct CapturePolicyDocument: Codable, Equatable {
    static let currentVersion = 1
    static let redactedKeycode = -1

    var version = currentVersion
    var pausedUntilMs: Int64?
    var apps: [String: CaptureAppMode] = [:]

    enum CodingKeys: String, CodingKey {
        case version
        case pausedUntilMs = "paused_until_ms"
        case apps
    }
}

@MainActor
final class CapturePolicySettings: ObservableObject {
    static let shared = CapturePolicySettings()

    @Published private(set) var document = CapturePolicyDocument()
    @Published private(set) var isFileInvalid = false
    @Published var errorMessage: String?
    var onChange: (() -> Void)?

    private let url: URL
    private let now: () -> Date
    private var expiryTimer: Timer?

    init(url: URL = AppPaths.supportDirectory.appendingPathComponent("capture-policy.json"),
         now: @escaping () -> Date = Date.init) {
        self.url = url
        self.now = now
        load()
        scheduleExpiry()
    }

    var isPaused: Bool {
        guard !isFileInvalid else { return true }
        guard let until = document.pausedUntilMs else { return false }
        return ActivityCalculator.milliseconds(now()) < until
    }

    var pauseStatusText: String? {
        guard isPaused else { return nil }
        guard !isFileInvalid, let until = document.pausedUntilMs, until != Int64.max else {
            return L10n.tr("已暂停，手动恢复前不记录")
        }
        let date = Date(timeIntervalSince1970: TimeInterval(until) / 1000)
        let time = date.formatted(.dateTime.hour().minute().locale(L10n.locale))
        return L10n.tr("已暂停，\(time) 恢复记录")
    }

    var appRules: [(app: String, mode: CaptureAppMode)] {
        document.apps.sorted { $0.key < $1.key }.map { (app: $0.key, mode: $0.value) }
    }

    func pause(_ duration: CapturePauseDuration) {
        var next = document
        next.pausedUntilMs = duration.deadlineMs(from: now())
        save(next)
    }

    func resume() {
        var next = document
        next.pausedUntilMs = nil
        save(next)
    }

    func setMode(_ mode: CaptureAppMode, for app: String) {
        var next = document
        next.apps[app] = mode
        save(next)
    }

    func removeRule(for app: String) {
        var next = document
        next.apps.removeValue(forKey: app)
        save(next)
    }

    /// An unreadable file pauses the service too, so show the same state here.
    private func load() {
        guard let data = try? Data(contentsOf: url) else {
            isFileInvalid = FileManager.default.fileExists(atPath: url.path)
            return
        }
        guard let saved = try? JSONDecoder().decode(CapturePolicyDocument.self, from: data),
              saved.version == CapturePolicyDocument.currentVersion else {
            isFileInvalid = true
            return
        }
        document = saved
    }

    private func save(_ next: CapturePolicyDocument) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(next)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            errorMessage = L10n.tr("无法保存隐私设置，请重试。")
            return
        }
        document = next
        isFileInvalid = false
        errorMessage = nil
        scheduleExpiry()
        onChange?()
    }

    /// The service compares each event with the deadline; this only refreshes the UI.
    private func scheduleExpiry() {
        expiryTimer?.invalidate()
        expiryTimer = nil
        guard let until = document.pausedUntilMs, until != Int64.max else { return }
        let date = Date(timeIntervalSince1970: TimeInterval(until) / 1000)
        let interval = date.timeIntervalSince(now())
        guard interval > 0 else { return }
        expiryTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.objectWillChange.send() }
        }
    }
}
