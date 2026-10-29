#if TOCCATA_DEMO
import AppKit
import SwiftUI
import SQLite3
import ServiceManagement

/// Compiled only by scripts/render-demo.sh. The production lifecycle and the
/// keyboard collector are never started, and every run gets fresh sample data.
@main
enum ToccataDemoApplication {
    @MainActor
    static func main() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("toccata-demo-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            setenv("TOCCATA_DATA_DIR", directory.path, 1)
            UserDefaults.standard.setVolatileDomain([
                LanguageSettings.defaultsKey: CommandLine.arguments.contains("--english") ? "en" : "zh-Hans",
                AppearanceSettings.defaultsKey: CommandLine.arguments.contains("--dark") ? "dark" : "light",
                DockIconSettings.defaultsKey: false,
                HydrationReminderController.enabledKey: false,
                MenuBarSettings.defaultPageKey: MenuPanelPage.tasks.rawValue,
                "workspacePrimaryColumnFraction": 0.49
            ], forName: UserDefaults.argumentDomain)
            let application = NSApplication.shared
            application.setActivationPolicy(.accessory)
            application.appearance = NSAppearance(named: CommandLine.arguments.contains("--dark") ? .darkAqua : .aqua)
            let output = CommandLine.arguments.dropFirst().first ?? "images"
            let delegate = try DemoApplicationDelegate(directory: directory,
                output: URL(fileURLWithPath: output, isDirectory: true))
            application.delegate = delegate
            withExtendedLifetime(delegate) { application.run() }
        } catch {
            try? FileManager.default.removeItem(at: directory)
            fputs("Demo export failed: \(error)\n", stderr)
            exit(1)
        }
    }
}

@MainActor
private final class DemoApplicationDelegate: NSObject, NSApplicationDelegate {
    private let directory: URL
    private let output: URL
    private let store: TaskStore
    private let selectedTask: String
    private let appearance = AppearanceSettings()
    private let loginItems = LoginItemController(service: DemoLoginItemService())
    private let dockIcon = DockIconSettings(apply: { _ in true })
    private let reminders = HydrationReminderController(service: DemoNotificationService())
    // Deliberately not started: no socket connection, polling or input capture.
    private let refresher = LiveRefresher()
    private let presentation = MenuTaskPresentation()
    private var window: NSWindow?
    private var menuController: TaskMenuController?

    init(directory: URL, output: URL) throws {
        self.directory = directory
        self.output = output
        let now = Date()
        var taskTime = now.addingTimeInterval(-600)
        store = TaskStore(databaseURL: directory.appendingPathComponent("tasks.sqlite"),
                          now: { taskTime.addTimeInterval(1); return taskTime }, completionFeedback: {})
        selectedTask = try DemoFixtures.tasks(in: store, now: now)
        try DemoFixtures.keyboard(at: directory.appendingPathComponent("toccata.db"), now: now)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            do {
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                if CommandLine.arguments.contains("--menu-preview") {
                    showMenuPreview()
                    return
                } else if CommandLine.arguments.contains("--menu") {
                    try await renderMenu(tab: .keyboard, filename: "menu-keyboard.png")
                    try await renderMenu(tab: .apps, filename: "menu-apps.png")
                } else if CommandLine.arguments.contains("--about") {
                    try await renderAbout()
                } else if CommandLine.arguments.contains("--settings") {
                    try await render(.generalSettings, size: NSSize(width: 1320, height: 1160), filename: "general-settings.png")
                } else {
                    try await render(.tasks, size: NSSize(width: 1600, height: 960), filename: "todo-management.png")
                    try await render(.activity, size: NSSize(width: 1440, height: 1580), filename: "keyboard-activity.png")
                }
                try FileManager.default.removeItem(at: directory)
                print("Exported demo images: \(output.path)")
                NSApp.terminate(nil)
            } catch {
                fputs("Demo export failed: \(error)\n", stderr)
                try? FileManager.default.removeItem(at: directory)
                exit(1)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        try? FileManager.default.removeItem(at: directory)
    }

    private func showMenuPreview() {
        let controller = TaskMenuController()
        controller.configure(store: store, loginItems: loginItems, appearance: appearance,
                             refresher: refresher, openHydrationSettings: {}, openAbout: {}) { [weak self] in
            self?.showSettingsPreview()
        }
        menuController = controller
        controller.showMenu()
    }

    private func showSettingsPreview() {
        let content = GeneralSettingsView(openAbout: {})
            .environmentObject(appearance).environmentObject(loginItems)
            .environmentObject(dockIcon).environmentObject(reminders)
            .frame(width: 700, height: 740).languageChangeTransition()
        let window = NSWindow(contentViewController: NSHostingController(rootView: content))
        window.title = "Toccata Demo Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        self.window?.close()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func renderMenu(tab: MenuActivityTab, filename: String) async throws {
        let presentation = MenuTaskPresentation()
        presentation.prepareForOpening()
        presentation.page = .activity
        presentation.activityTab = tab
        let content = QuickCaptureView()
            .environmentObject(store).environmentObject(presentation).environmentObject(refresher)
            .environment(\.colorScheme, appearance.mode == .dark ? .dark : .light)
            .tint(TaskMenuStyle.accent)
        try await capture(content, size: presentation.panelSize, filename: filename)
        presentation.menuDidHide()
    }

    private func renderAbout() async throws {
        let service = ReleaseUpdateService { _ in
            let json: [String: Any] = ["tag_name": "v0.2.0", "draft": false, "prerelease": false,
                "assets": [["name": "Toccata-0.2.0-\(UpdatePackage.architecture).dmg", "state": "uploaded",
                            "size": 123, "digest": "sha256:" + String(repeating: "a", count: 64)]]]
            return (try JSONSerialization.data(withJSONObject: json),
                    HTTPURLResponse(url: ToccataReleaseSource.latestAPIURL, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let version = AppVersion(version: "0.1.1", build: "18")
        let checker = UpdateChecker(service: service, current: version)
        await checker.check()
        guard case let .available(update) = checker.state else { throw DemoError.message("Missing demo update") }
        let work = directory.appendingPathComponent("update-preview")
        let updater = AppUpdateController { _, progress in
            progress(0.42)
            try await Task.sleep(nanoseconds: 4_000_000_000)
            return PreparedAppUpdate(target: work.appendingPathComponent("original.app"),
                staged: work.appendingPathComponent("staged.app"), backup: work.appendingPathComponent("backup.app"),
                directory: work, originalIdentity: "0:0", version: "0.2.0")
        }
        let content = AboutView(version: version, checker: checker, updater: updater)
            .environment(\.colorScheme, appearance.mode == .dark ? .dark : .light)
            .background(Color(nsColor: .windowBackgroundColor))
        let size = NSHostingView(rootView: content).fittingSize
        try await capture(content, size: size, filename: "about-update-available.png")
        updater.download(update)
        try await capture(content, size: size, filename: "about-update-downloading.png")
        try await capture(content, size: size, filename: "about-update-ready.png")
        updater.cancel()
    }

    private func render(_ section: WorkspaceSection, size: NSSize, filename: String) async throws {
        let content = DemoCanvas(section: section, selectedTask: selectedTask, size: size)
            .environmentObject(store)
            .environmentObject(appearance)
            .environmentObject(refresher)
            .environmentObject(presentation)
            .environmentObject(loginItems)
            .environmentObject(dockIcon)
            .environmentObject(reminders)
            .environment(\.colorScheme, appearance.mode == .dark ? .dark : .light)
            .environment(\.locale, LanguageSettings.shared.language.locale)
        try await capture(content, size: size, filename: filename)
    }

    private func capture<Content: View>(_ content: Content, size: NSSize, filename: String) async throws {
        window?.close()
        let host = NSHostingView(rootView: content)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setContentSize(size)
        // Offscreen native layout and rendering, with no desktop capture API.
        window.setFrameOrigin(NSPoint(x: -size.width - 100, y: 0))
        window.orderFront(nil)
        self.window = window
        // Allow SwiftUI's asynchronous statistics query and WebKit editor to settle.
        try await Task.sleep(nanoseconds: 3_000_000_000)
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            throw DemoError.message("Could not allocate the image")
        }
        bitmap.size = size
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw DemoError.message("Could not encode the image")
        }
        try data.write(to: output.appendingPathComponent(filename), options: .atomic)
        window.close()
    }
}

private struct DemoCanvas: View {
    @Environment(\.colorScheme) private var colorScheme
    let section: WorkspaceSection
    let selectedTask: String
    let size: CGSize

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack(alignment: .firstTextBaseline) {
                HStack(spacing: 12) {
                    Image(systemName: "square.stack.3d.up.fill")
                        .foregroundStyle(.indigo)
                    Text("Toccata").fontWeight(.semibold)
                }
                .font(.system(size: 24))
                Text(L10n.key(section.rawValue))
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(L10n.tr("演示数据"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            if section == .tasks {
                HStack(alignment: .center, spacing: 32) {
                    workbench(width: 1176, height: 794)
                    VStack(alignment: .leading, spacing: 14) {
                        Label("菜单栏 · 随手记", systemImage: "menubar.rectangle")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                        QuickCaptureView()
                            .tint(TaskMenuStyle.accent)
                            .clipShape(RoundedRectangle(cornerRadius: TaskMenuStyle.cornerRadius))
                            .overlay(RoundedRectangle(cornerRadius: TaskMenuStyle.cornerRadius)
                                .strokeBorder(Color.black.opacity(0.08)))
                            .shadow(color: .black.opacity(0.10), radius: 22, y: 12)
                    }
                }
            } else if section == .generalSettings {
                workbench(width: 1240, height: 1010)
            } else {
                workbench(width: 1360, height: 1414)
            }
            Spacer(minLength: 0)
        }
        .padding(40)
        .frame(width: size.width, height: size.height)
        .background(LinearGradient(colors: colorScheme == .dark
                                   ? [Color(red: 0.12, green: 0.13, blue: 0.19),
                                      Color(red: 0.08, green: 0.09, blue: 0.14)]
                                   : [Color(red: 0.95, green: 0.96, blue: 0.99),
                                      Color(red: 0.89, green: 0.91, blue: 0.97)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing))
    }

    private func workbench(width: CGFloat, height: CGFloat) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach([Color(red: 1, green: 0.37, blue: 0.34),
                         Color(red: 1, green: 0.74, blue: 0.18),
                         Color(red: 0.16, green: 0.79, blue: 0.26)], id: \.self) { color in
                    Circle().fill(color).frame(width: 12, height: 12)
                }
                Spacer()
                Text("Toccata").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Color.clear.frame(width: 52, height: 1)
            }
            .padding(.horizontal, 16)
            .frame(height: 36)
            .background(Color(nsColor: .windowBackgroundColor))
            Divider()
            ContentView(initialSection: section, initialTaskID: section == .tasks ? selectedTask : nil,
                        initialActivityRange: .lastSevenDays, openAbout: {})
        }
        .frame(width: width, height: height)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.black.opacity(0.10)))
        .shadow(color: .indigo.opacity(0.12), radius: 25, y: 14)
    }
}

private enum DemoError: Error {
    case message(String)
}

/// Screenshot runs never register login items or contact notification services.
@MainActor
private final class DemoLoginItemService: LoginItemServicing {
    var status: SMAppService.Status { .notRegistered }
    func register() {}
    func unregister() {}
    func openSystemSettings() {}
}

@MainActor
private final class DemoNotificationService: HydrationNotificationServicing {
    func authorization() async -> HydrationNotificationAuthorization { .notDetermined }
    func requestAuthorization() async throws {}
    func send(_ notification: HydrationNotification) async throws {}
    func openSettings() {}
}

@MainActor
private enum DemoFixtures {
    static func tasks(in store: TaskStore, now: Date) throws -> String {
        func add(_ title: String, details: String = "", date: Date? = nil,
                 parent: String? = nil, priority: TaskPriority = .none, done: Bool = false) throws -> String {
            guard let id = store.addTask(title: title, details: details, plannedDate: date, parentID: parent),
                  store.setPriority(id: id, priority: priority) else {
                throw DemoError.message(store.errorMessage ?? "Could not create the sample task")
            }
            if done, !store.setCompleted(id: id, completed: true) {
                throw DemoError.message("Could not complete the sample task")
            }
            return id
        }
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: now)!
        _ = try add("整理本周阅读笔记", details: "把有用的观点留下来，写几句自己的理解。", done: true)
        _ = try add("给书桌留一点空白", details: "收好散落的线材和便签。", done: true)
        _ = try add("买一袋新的咖啡豆", details: "试试浅烘的花香调。")
        _ = try add("读完《设计心理学》这一章", details: "记录三个可以用在产品里的细节。")
        _ = try add("准备周五的产品分享", details: "用一个真实的小案例，把思路讲清楚。", date: tomorrow, priority: .medium)
        let featured = try add("打磨个人网站 2.0", details: "## 这次想做好什么\n\n让作品和想法更容易被看见。\n\n- 首页只留下最重要的三个项目\n- 为每个项目补一张清楚的截图\n- 检查手机上的阅读体验\n\n> 做完一小步，就记录一小步。", date: now, priority: .high)
        _ = try add("确定首页内容与结构", parent: featured, done: true)
        _ = try add("补齐项目介绍和配图", parent: featured)
        _ = try add("检查移动端排版", parent: featured)
        return featured
    }

    static func keyboard(at url: URL, now: Date) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            throw DemoError.message("Could not create the demo keyboard database")
        }
        defer { sqlite3_close(database) }
        let schema = """
        CREATE TABLE key_events(ts_ms INTEGER NOT NULL,keycode INTEGER NOT NULL,kind INTEGER NOT NULL,hold_ms INTEGER,app TEXT);
        CREATE INDEX idx_key_events_ts ON key_events(ts_ms);
        CREATE TABLE app_sessions(app TEXT NOT NULL,start_ms INTEGER NOT NULL,end_ms INTEGER NOT NULL,key_count INTEGER NOT NULL);
        BEGIN;
        """
        guard sqlite3_exec(database, schema, nil, nil, nil) == SQLITE_OK else {
            throw DemoError.message("Could not initialize the demo schema")
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "INSERT INTO key_events VALUES(?,?,?,?,?)", -1, &statement, nil) == SQLITE_OK,
              let statement else { throw DemoError.message("Could not prepare demo events") }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        func event(_ stamp: Int64, key: Int32, kind: Int32, hold: Int64?, app: String) throws {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            sqlite3_bind_int64(statement, 1, stamp)
            sqlite3_bind_int(statement, 2, key)
            sqlite3_bind_int(statement, 3, kind)
            if let hold { sqlite3_bind_int64(statement, 4, hold) }
            sqlite3_bind_text(statement, 5, app, -1, transient)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw DemoError.message("Could not insert demo event") }
        }
        var random: UInt64 = 0x746f6363617461
        func next(_ limit: Int) -> Int {
            random = random &* 6364136223846793005 &+ 1442695040888963407
            return Int((random >> 32) % UInt64(limit))
        }
        let keys: [Int32] = [49,49,49,49,49,49,14,14,14,14,0,0,0,1,1,1,2,2,2,3,4,5,6,7,8,9,11,
                            12,13,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32,33,34,35,
                            36,36,37,38,39,40,41,42,43,44,45,46,47,48,51,51,53,55,55,55,56,58,59,123,124,125,126]
        let applications = ["com.microsoft.VSCode", "com.apple.Safari", "com.apple.Notes", "com.apple.Terminal"]
        let calendar = Calendar.current
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        for offset in -6...0 {
            let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now))!
            let midnight = Int64(day.timeIntervalSince1970 * 1000)
            let weekend = calendar.isDateInWeekend(day)
            let slots = weekend ? Array(40...46) + Array(60...65) : Array(36...47) + Array(54...69) + Array(79...84)
            for slot in slots {
                if next(9) == 0 { continue }
                let start = midnight + Int64(slot * 900 + next(170)) * 1000
                let length = Int64(180 + next(610)) * 1000
                let end = min(start + length, nowMs - 60_000)
                let application = applications[next(applications.count)]
                var stamp = start
                while stamp + 200 < end {
                    let key = keys[next(keys.count)]
                    let hold = Int64(55 + next(130))
                    try event(stamp, key: key, kind: 0, hold: nil, app: application)
                    try event(stamp + hold, key: key, kind: 1, hold: hold, app: application)
                    stamp += Int64(350 + next(2100))
                    if next(32) == 0 { stamp += Int64(8 + next(25)) * 1000 }
                }
            }
            for minute in [626, 878, 1023] {
                let start = midnight + Int64(minute * 60) * 1000
                let hold = Int64(45 + next(160)) * 1000
                if start + hold >= nowMs { continue }
                try event(start, key: 63, kind: 0, hold: nil, app: "com.apple.Notes")
                try event(start + hold, key: 63, kind: 1, hold: hold, app: "com.apple.Notes")
            }
        }
        guard sqlite3_exec(database, "COMMIT;", nil, nil, nil) == SQLITE_OK else {
            throw DemoError.message("Could not save demo keyboard events")
        }
    }
}
#endif
