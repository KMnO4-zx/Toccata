import AppKit
import SwiftUI

@MainActor
struct HydrationReminderSettingsView: View {
    @ObservedObject private var language = LanguageSettings.shared
    @ObservedObject var reminders: HydrationReminderController
    var showsTitle = true

    var body: some View {
        let _ = language.language
        VStack(alignment: .leading, spacing: 12) {
            if showsTitle { Text(L10n.tr("喝水提醒")).font(.headline) }
            Toggle(isOn: Binding(
                get: { reminders.isEnabled },
                set: { value in Task { await reminders.setEnabled(value) } }
            )) {
                Text(L10n.tr("开启喝水提醒"))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityIdentifier("settings-hydration-enabled")
            HStack {
                Text(L10n.tr("提醒间隔"))
                Spacer(minLength: 12)
                SettingsPopoverPicker(title: L10n.tr("提醒间隔"), options: HydrationReminderController.intervals,
                                      selection: Binding(
                    get: { reminders.interval }, set: { reminders.setInterval($0) }
                ), optionTitle: HydrationReminderController.intervalTitle,
                                      popoverWidth: language.language == .english ? 250 : 200)
                .frame(width: 220, alignment: .trailing)
                .accessibilityIdentifier("settings-hydration-interval")
            }
            Text(L10n.tr("每天重新计数，每个节点只提醒一次。开启提醒或调整间隔后，从下一个节点开始。"))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(reminders.statusText)
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                if reminders.isEnabled && reminders.authorization == .notDetermined {
                    Button(L10n.tr("允许通知")) { Task { await reminders.requestPermission() } }
                }
                if reminders.authorization == .denied {
                    Button(L10n.tr("前往通知设置")) { reminders.openNotificationSettings() }
                }
                Button(L10n.tr("发送测试通知")) { Task { await reminders.sendTestNotification() } }
                    .disabled(!reminders.isEnabled || reminders.authorization == .unavailable)
            }
            .disabled(reminders.isRequestingPermission)
            if let error = reminders.errorMessage {
                Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
        .task { await reminders.refreshAuthorization() }
    }
}

@MainActor
final class HydrationReminderWindowController {
    private var window: NSWindow?

    func show(reminders: HydrationReminderController) {
        if window == nil {
            let content = HydrationReminderSettingsView(reminders: reminders)
                .padding(24).frame(width: 420).languageChangeTransition()
            let window = NSWindow(contentViewController: NSHostingController(rootView: content))
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        window?.title = L10n.tr("喝水提醒")
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
