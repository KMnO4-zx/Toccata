import SwiftUI

@MainActor
struct GeneralSettingsView: View {
    @ObservedObject private var language = LanguageSettings.shared
    @ObservedObject private var menuSettings = MenuBarSettings.shared
    @EnvironmentObject private var appearance: AppearanceSettings
    @EnvironmentObject private var loginItems: LoginItemController
    @EnvironmentObject private var dockIcon: DockIconSettings
    @EnvironmentObject private var reminders: HydrationReminderController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var openAbout: () -> Void

    var body: some View {
        let _ = language.language
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(L10n.tr("通用配置"))
                        .font(.system(size: 28, weight: .bold))
                    Text(L10n.tr("调整外观、提醒与启动方式。"))
                        .font(.callout).foregroundStyle(.secondary)
                }

                settingsCard(L10n.tr("外观与语言"), symbol: "paintpalette") {
                    settingsRow(L10n.tr("外观")) {
                        SettingsPopoverPicker(title: L10n.tr("外观"), options: AppearanceMode.allCases,
                                              selection: $appearance.mode, optionTitle: { $0.title },
                                              popoverWidth: language.language == .english ? 220 : 170)
                        .frame(width: 220, alignment: .trailing)
                        .accessibilityIdentifier("settings-appearance")
                    }
                    Divider()
                    settingsRow(L10n.tr("界面语言")) {
                        SettingsPopoverPicker(title: L10n.tr("语言"), options: AppLanguage.allCases,
                                              selection: Binding(
                            get: { language.language },
                            set: { language.select($0, reduceMotion: reduceMotion) }
                        ), optionTitle: { $0.nativeName },
                                              popoverWidth: language.language == .english ? 220 : 170)
                        .frame(width: 220, alignment: .trailing)
                        .accessibilityIdentifier("settings-language")
                    }
                }

                settingsCard(L10n.tr("状态栏"), symbol: "menubar.rectangle") {
                    settingsRow(L10n.tr("状态栏默认页面")) {
                        SettingsPopoverPicker(title: L10n.tr("状态栏默认页面"), options: MenuPanelPage.allCases,
                                              selection: $menuSettings.defaultPage, optionTitle: { $0.title },
                                              popoverWidth: language.language == .english ? 230 : 190)
                            .accessibilityIdentifier("settings-menu-default-page")
                    }
                    Text(L10n.tr("点击状态栏图标时，默认打开所选页面。"))
                        .font(.caption).foregroundStyle(.secondary)
                }

                settingsCard(L10n.tr("启动与后台运行"), symbol: "power") {
                    Toggle(isOn: Binding(get: { loginItems.enabled }, set: { loginItems.setEnabled($0) })) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(L10n.tr("登录时启动"))
                            Text(loginItems.statusText)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .accessibilityIdentifier("settings-launch-at-login")
                    if loginItems.requiresApproval {
                        HStack {
                            Button(L10n.tr("前往系统设置允许启动")) { loginItems.openSystemSettings() }
                            Button(L10n.tr("取消登录启动申请")) { loginItems.setEnabled(false) }
                        }
                    }
                    if let error = loginItems.errorMessage { errorText(error) }
                    Divider()
                    Toggle(isOn: Binding(get: { dockIcon.isHidden }, set: { dockIcon.setHidden($0) })) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(L10n.tr("隐藏 Dock 栏图标"))
                            Text(L10n.tr("隐藏后，仍可从菜单栏打开工作台。"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .accessibilityIdentifier("settings-hide-dock-icon")
                    if let error = dockIcon.errorMessage { errorText(error) }
                    Text(L10n.tr("关闭工作台后继续在后台运行；选择“退出 Toccata”可停止运行。"))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                settingsCard(L10n.tr("喝水提醒"), symbol: "drop") {
                    HydrationReminderSettingsView(reminders: reminders, showsTitle: false)
                }

                settingsCard(L10n.tr("关于"), symbol: "info.circle") {
                    Button(action: openAbout) {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(L10n.tr("关于 Toccata"))
                                Text(AppVersion.current.displayVersion)
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(L10n.tr("版本信息与检查更新"))
                                .font(.callout).foregroundStyle(.secondary)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("settings-about")
                }
            }
            .padding(28)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .toggleStyle(.switch)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { loginItems.refresh() }
    }

    private func settingsCard<Content: View>(_ title: String, symbol: String,
                                             @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(title, systemImage: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.07)))
    }

    private func settingsRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 20) {
            Text(title)
            Spacer(minLength: 12)
            content()
        }
    }

    private func errorText(_ error: String) -> some View {
        Text(error).font(.callout).foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
    }
}
