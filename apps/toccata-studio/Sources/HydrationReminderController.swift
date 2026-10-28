import AppKit
import Combine
import Foundation
import UserNotifications

enum HydrationNotificationAuthorization {
    case notDetermined, denied, authorized, unavailable
}

struct HydrationNotification: Equatable {
    let identifier: String
    let title: String
    let body: String
}

@MainActor
protocol HydrationNotificationServicing: AnyObject {
    func authorization() async -> HydrationNotificationAuthorization
    func requestAuthorization() async throws
    func send(_ notification: HydrationNotification) async throws
    func openSettings()
}

/// Tests inject a service rather than contacting macOS or requesting permissions.
@MainActor
final class SystemHydrationNotificationService: NSObject, HydrationNotificationServicing, UNUserNotificationCenterDelegate {
    private var center: UNUserNotificationCenter? {
        // Calling current() in an unbundled SwiftPM executable can raise an
        // Objective-C exception. The installed, signed app owns notification access.
        guard Bundle.main.bundleURL.pathExtension == "app", Bundle.main.bundleIdentifier != nil else { return nil }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        return center
    }

    func authorization() async -> HydrationNotificationAuthorization {
        guard let center else { return .unavailable }
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional: return .authorized
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        @unknown default: return .unavailable
        }
    }

    func requestAuthorization() async throws {
        guard let center else { throw HydrationNotificationError.unavailable }
        _ = try await center.requestAuthorization(options: [.alert, .sound])
    }

    func send(_ notification: HydrationNotification) async throws {
        guard let center else { throw HydrationNotificationError.unavailable }
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = .default
        try await center.add(UNNotificationRequest(identifier: notification.identifier, content: content, trigger: nil))
    }

    func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                           withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}

private enum HydrationNotificationError: LocalizedError {
    case unavailable
    var errorDescription: String? { L10n.tr("请从 Toccata.app 开启系统通知。") }
}

/// Lives with the app, independently of all windows. Only settings actions may
/// request permission; login launches and keyboard events only read authorization.
@MainActor
final class HydrationReminderController: ObservableObject {
    static let defaultInterval = 8_192
    static let intervals = [4_096, 8_192, 16_384, 32_768]
    static let enabledKey = "hydrationReminderEnabled"
    static let intervalKey = "hydrationReminderInterval"
    static let progressKey = "hydrationReminderProgress"
    private static let baselineKey = "hydrationReminderNeedsBaseline"

    @Published private(set) var isEnabled: Bool
    @Published private(set) var interval: Int
    @Published private(set) var authorization: HydrationNotificationAuthorization = .notDetermined
    @Published private(set) var isRequestingPermission = false
    @Published private(set) var errorMessage: String?

    private struct Progress: Codable, Equatable {
        var day: Date
        var handledCount: Int
    }

    private let defaults: UserDefaults
    private let service: HydrationNotificationServicing
    private let calendar: Calendar
    private let now: () -> Date
    private let databaseURL: URL
    private var progress: Progress?
    private var needsBaseline = false {
        didSet {
            if needsBaseline != oldValue { defaults.set(needsBaseline, forKey: Self.baselineKey) }
        }
    }
    private var revision = 0
    private var isEvaluating = false
    private weak var refresher: LiveRefresher?
    private var subscription: AnyCancellable?
    private var countTask: Task<Void, Never>?
    private var refreshPending = false

    init(defaults: UserDefaults = .standard, service: HydrationNotificationServicing? = nil,
         calendar: Calendar = .autoupdatingCurrent, now: @escaping () -> Date = Date.init,
         databaseURL: URL = Database.defaultURL) {
        self.defaults = defaults
        self.service = service ?? SystemHydrationNotificationService()
        self.calendar = calendar
        self.now = now
        self.databaseURL = databaseURL
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        needsBaseline = defaults.bool(forKey: Self.baselineKey)
        let savedInterval = defaults.integer(forKey: Self.intervalKey)
        interval = Self.intervals.contains(savedInterval) ? savedInterval : Self.defaultInterval
        if let data = defaults.data(forKey: Self.progressKey) {
            progress = try? JSONDecoder().decode(Progress.self, from: data)
        }
    }

    var statusText: String {
        guard isEnabled else { return L10n.tr("开启后，按今日累计按键次数提醒喝水。") }
        switch authorization {
        case .notDetermined: return L10n.tr("需要允许 Toccata 发送通知。")
        case .denied: return L10n.tr("通知已被系统关闭，请在系统设置中允许。")
        case .authorized: return L10n.tr("已允许通知；专注模式和系统通知设置可能影响提醒显示。")
        case .unavailable: return L10n.tr("请从 Toccata.app 开启系统通知。")
        }
    }

    static func intervalTitle(_ count: Int) -> String {
        L10n.tr("每 \(count.formatted(.number.locale(L10n.locale))) 次按键")
    }

    func start(refresher: LiveRefresher) {
        guard subscription == nil else { return }
        self.refresher = refresher
        subscription = refresher.$generation
            .throttle(for: .seconds(1), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in
            self?.refreshCount()
        }
        Task { await refreshAuthorization() }
    }

    func stop() {
        subscription?.cancel()
        subscription = nil
        refresher = nil
        countTask?.cancel()
        refreshPending = false
    }

    func refreshAuthorization() async {
        let previous = authorization
        authorization = await service.authorization()
        if previous == .denied, authorization == .authorized { needsBaseline = true }
    }

    func setEnabled(_ requested: Bool) async {
        guard isEnabled != requested else { return }
        isEnabled = requested
        defaults.set(requested, forKey: Self.enabledKey)
        revision += 1
        needsBaseline = true
        errorMessage = nil
        if requested {
            await requestPermission()
            refreshCount()
        }
    }

    func setInterval(_ value: Int) {
        guard Self.intervals.contains(value), value != interval else { return }
        interval = value
        defaults.set(value, forKey: Self.intervalKey)
        revision += 1
        needsBaseline = true
        refreshCount()
    }

    func requestPermission() async {
        guard !isRequestingPermission, isEnabled else { return }
        isRequestingPermission = true
        defer { isRequestingPermission = false }
        errorMessage = nil
        await refreshAuthorization()
        guard isEnabled, authorization == .notDetermined else { return }
        do {
            try await service.requestAuthorization()
            await refreshAuthorization()
        } catch {
            errorMessage = L10n.tr("无法开启喝水通知：\(error.localizedDescription)")
        }
    }

    func openNotificationSettings() { service.openSettings() }

    /// One notification for the latest crossed milestone, even after reconnects
    /// or time spent away. Lower snapshots never rewind today's progress.
    func update(keyCount: Int, at date: Date) async {
        guard isEnabled, !isEvaluating, !Task.isCancelled else { return }
        isEvaluating = true
        defer { isEvaluating = false }
        let currentRevision = revision
        await refreshAuthorization()
        guard isEnabled, revision == currentRevision, !Task.isCancelled,
              calendar.isDate(date, inSameDayAs: now()) else { return }
        let day = calendar.startOfDay(for: date)
        let count = max(0, keyCount)
        if progress?.day != day { progress = Progress(day: day, handledCount: 0) }
        let previous = progress!
        if needsBaseline {
            saveProgress(Progress(day: day, handledCount: max(previous.handledCount, count)))
            needsBaseline = false
            return
        }
        if authorization != .authorized {
            if count / interval > previous.handledCount / interval {
                saveProgress(Progress(day: day, handledCount: count))
            }
            return
        }
        guard count / interval > previous.handledCount / interval else { return }
        let milestone = (count / interval) * interval
        let notification = HydrationNotification(
            identifier: "hydration.\(Int(day.timeIntervalSince1970)).\(interval).\(milestone)",
            title: L10n.tr("💧 记得喝水哦～"),
            body: L10n.tr("今天已经敲了 \(count.formatted(.number.locale(L10n.locale))) 次键盘，喝了几杯水了呢？起来倒杯水，顺便活动一下吧。")
        )
        // Reserve before the async handoff so a restart cannot replay this
        // milestone. A rejected submission restores it for a later retry.
        let reserved = Progress(day: day, handledCount: count)
        saveProgress(reserved)
        do {
            try await service.send(notification)
            errorMessage = nil
        } catch {
            if progress == reserved { saveProgress(previous) }
            errorMessage = L10n.tr("喝水通知发送失败：\(error.localizedDescription)")
        }
    }

    func sendTestNotification() async {
        guard isEnabled else { return }
        await requestPermission()
        guard isEnabled, authorization == .authorized else { return }
        do {
            try await service.send(HydrationNotification(identifier: "hydration.test.\(UUID().uuidString)",
                title: L10n.tr("💧 记得喝水哦～"),
                body: L10n.tr("这是一条喝水提醒测试通知。喝口水，活动一下吧～")))
            errorMessage = nil
        } catch {
            errorMessage = L10n.tr("喝水通知发送失败：\(error.localizedDescription)")
        }
    }

    private func saveProgress(_ value: Progress) {
        guard value != progress || defaults.data(forKey: Self.progressKey) == nil else { return }
        progress = value
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: Self.progressKey) }
    }

    private func refreshCount() {
        guard isEnabled, let refresher else { return }
        guard countTask == nil else { refreshPending = true; return }
        let date = now()
        let events = refresher.liveEvents
        let connected = refresher.isConnected
        let url = databaseURL
        let calendar = calendar
        let currentRevision = revision
        countTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                Result { try ActivityRepository(url: url, calendar: calendar)
                    .todayKeyCount(now: date, liveEvents: events, liveConnected: connected) }
            }.value
            guard let self else { return }
            if !Task.isCancelled, self.revision == currentRevision, case .success(let count) = result {
                await self.update(keyCount: count, at: date)
            } else if !Task.isCancelled, self.revision != currentRevision {
                self.refreshPending = true
            }
            self.countTask = nil
            if self.refreshPending {
                self.refreshPending = false
                self.refreshCount()
            }
        }
    }
}
