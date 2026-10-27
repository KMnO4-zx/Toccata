import SwiftUI

struct SidebarFooterView: View {
    @ObservedObject private var interfaceLanguage = LanguageSettings.shared
    var openAbout: () -> Void
    @EnvironmentObject private var appearance: AppearanceSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsAppearancePicker = false
    @State private var showsLanguagePicker = false
    @State private var isAboutHovered = false

    var body: some View {
        let _ = interfaceLanguage.language
        VStack(alignment: .leading, spacing: 7) {
            aboutButton
            appearanceButton
            languageButton
                .padding(.bottom, 7)
            CaptureStatusView()
                .font(.system(size: 12))
                .labelStyle(SidebarFooterLabelStyle())
                .padding(.horizontal, 10)
            Text(L10n.tr("任务随时可用 · 数据保存在本机"))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    private var languageButton: some View {
        Button {
            showsAppearancePicker = false
            showsLanguagePicker.toggle()
        } label: {
            HStack(spacing: 0) {
                Label {
                    Text(interfaceLanguage.language.nativeName)
                } icon: {
                    Image(systemName: "globe")
                        .foregroundStyle(Color.accentColor)
                }
                    .labelStyle(SidebarFooterLabelStyle())
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 12))
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showsLanguagePicker, arrowEdge: .top) {
            languagePicker
        }
        .accessibilityIdentifier("sidebar-language-picker")
        .accessibilityLabel(L10n.tr("界面语言"))
        .accessibilityValue(interfaceLanguage.language.nativeName)
        .help(L10n.tr("切换中英文，任务内容保持原文。"))
    }

    private var languagePicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.tr("语言"))
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.bottom, 4)
            ForEach(AppLanguage.allCases) { language in
                Button {
                    showsLanguagePicker = false
                    interfaceLanguage.select(language, reduceMotion: reduceMotion)
                } label: {
                    HStack {
                        Text(language.nativeName)
                        Spacer(minLength: 20)
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                            .opacity(interfaceLanguage.language == language ? 1 : 0)
                    }
                    .font(.system(size: 12))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(interfaceLanguage.language == language ? Color.accentColor.opacity(0.08) : .clear,
                                in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(interfaceLanguage.language == language ? [.isSelected] : [])
            }
        }
        .padding(10)
        .frame(width: interfaceLanguage.language == .english ? 220 : 170)
    }

    private var aboutButton: some View {
        Button {
            showsAppearancePicker = false
            showsLanguagePicker = false
            openAbout()
        } label: {
            HStack(spacing: 0) {
                Label(L10n.tr("关于 Toccata"), systemImage: "info.circle")
                    .labelStyle(SidebarFooterLabelStyle())
                    .foregroundStyle(.primary)
                Spacer(minLength: 4)
                Text(AppVersion.current.displayVersion)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 12))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(Color.primary.opacity(isAboutHovered ? 0.055 : 0),
                        in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { isAboutHovered = $0 }
        .accessibilityIdentifier("sidebar-about-toccata")
        .accessibilityLabel(L10n.tr("关于 Toccata"))
        .accessibilityValue(AppVersion.current.displayVersion)
        .help(L10n.tr("查看版本信息与检查更新"))
    }

    private var appearanceButton: some View {
        Button {
            showsLanguagePicker = false
            showsAppearancePicker.toggle()
        } label: {
            HStack(spacing: 0) {
                Label {
                    Text(appearance.mode.title)
                } icon: {
                    Image(systemName: "circle.lefthalf.filled")
                        .foregroundStyle(Color.accentColor)
                }
                    .labelStyle(SidebarFooterLabelStyle())
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 12))
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showsAppearancePicker, arrowEdge: .top) {
            appearancePicker
        }
        .accessibilityLabel(L10n.tr("外观模式"))
        .accessibilityValue(appearance.mode.title)
        .help(L10n.tr("切换月之亮面、月之暗面或跟随系统"))
    }

    private var appearancePicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.tr("外观"))
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.bottom, 4)
            ForEach(AppearanceMode.allCases) { mode in
                Button {
                    appearance.mode = mode
                    showsAppearancePicker = false
                } label: {
                    HStack {
                        Text(mode.title)
                        Spacer(minLength: 20)
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                            .opacity(appearance.mode == mode ? 1 : 0)
                    }
                    .font(.system(size: 12))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(appearance.mode == mode ? Color.accentColor.opacity(0.08) : .clear,
                                in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(appearance.mode == mode ? [.isSelected] : [])
            }
        }
        .padding(10)
        .frame(width: interfaceLanguage.language == .english ? 220 : 170)
    }
}

private struct SidebarFooterLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon.frame(width: 16, alignment: .leading)
            configuration.title
        }
    }
}
