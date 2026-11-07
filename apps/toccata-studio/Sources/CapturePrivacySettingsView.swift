import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct CapturePrivacySettingsView: View {
    @ObservedObject private var language = LanguageSettings.shared
    @ObservedObject private var policy = CapturePolicySettings.shared

    var body: some View {
        let _ = language.language
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 20) {
                Text(policy.pauseStatusText ?? L10n.tr("正在记录键盘活动"))
                Spacer(minLength: 12)
                if policy.isPaused {
                    Button(L10n.tr("恢复记录")) { policy.resume() }
                        .accessibilityIdentifier("settings-capture-resume")
                } else {
                    pauseMenu
                }
            }
            note(L10n.tr("暂停期间不写入按键，活跃时长和喝水提醒也不会计入。"))
            if policy.isFileInvalid {
                errorText(L10n.tr("隐私设置文件无法读取，已暂停键盘记录。恢复记录会重建此文件。"))
            }
            Divider()
            HStack(spacing: 20) {
                Text(L10n.tr("应用规则"))
                Spacer(minLength: 12)
                addAppMenu
            }
            ForEach(policy.appRules, id: \.app) { rule in
                ruleRow(app: rule.app, mode: rule.mode)
            }
            note(L10n.tr("密码管理器默认不记录；系统安全输入期间也不记录。"))
            note(L10n.tr("脱敏只保留次数和时长，不保存具体按键；不记录则完全不写入。"))
            if let error = policy.errorMessage { errorText(error) }
        }
    }

    private var pauseMenu: some View {
        let title = L10n.tr("暂停记录")
        return SettingsPopoverButton(label: title) { dismiss in
            SettingsPopoverOptions(title: title, options: CapturePauseDuration.allCases, selection: nil,
                                   optionTitle: \.title) { duration in
                dismiss()
                policy.pause(duration)
            }
            .frame(width: language.language == .english ? 220 : 170)
        }
        .accessibilityIdentifier("settings-capture-pause")
    }

    private var addAppMenu: some View {
        let title = L10n.tr("添加应用")
        return SettingsPopoverButton(label: title) { dismiss in
            let choices = runningApps.map { AppChoice.running(name: $0.name, bundleID: $0.bundleID) } + [.other]
            let options = SettingsPopoverOptions(title: title, options: choices, selection: nil,
                                                 optionTitle: \.title) { choice in
                dismiss()
                switch choice {
                case .running(_, let bundleID): policy.setMode(.redact, for: bundleID)
                case .other: chooseApp()
                }
            }
            ViewThatFits(in: .vertical) {
                options
                ScrollView { options }
            }
            .frame(width: 240)
            .frame(maxHeight: 320)
        }
        .accessibilityIdentifier("settings-capture-add-app")
    }

    private enum AppChoice: Hashable {
        case running(name: String, bundleID: String)
        case other

        var title: String {
            switch self {
            case .running(let name, _): return name
            case .other: return L10n.tr("选择其他应用…")
            }
        }
    }

    private var runningApps: [(name: String, bundleID: String)] {
        let configured = Set(policy.document.apps.keys)
        let apps = NSWorkspace.shared.runningApplications.compactMap { app -> (name: String, bundleID: String)? in
            guard app.activationPolicy == .regular, let bundleID = app.bundleIdentifier,
                  bundleID != Bundle.main.bundleIdentifier, !configured.contains(bundleID) else { return nil }
            return (name: app.localizedName ?? bundleID, bundleID: bundleID)
        }
        return apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func ruleRow(app: String, mode: CaptureAppMode) -> some View {
        HStack(spacing: 12) {
            Text(displayName(app)).lineLimit(1).help(app)
            Spacer(minLength: 12)
            SettingsPopoverPicker(title: L10n.tr("记录方式"), options: CaptureAppMode.allCases,
                                  selection: Binding(get: { mode }, set: { policy.setMode($0, for: app) }),
                                  optionTitle: { $0.title },
                                  popoverWidth: language.language == .english ? 190 : 150)
            Button { policy.removeRule(for: app) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.tr("移除规则"))
            .accessibilityLabel(L10n.tr("移除规则"))
        }
    }

    private func displayName(_ bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path)
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.title = L10n.tr("选择应用")
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let bundleID = Bundle(url: url)?.bundleIdentifier else {
            policy.errorMessage = L10n.tr("所选文件不是可识别的应用。")
            return
        }
        policy.setMode(.redact, for: bundleID)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func errorText(_ error: String) -> some View {
        Text(error).font(.callout).foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
    }
}
