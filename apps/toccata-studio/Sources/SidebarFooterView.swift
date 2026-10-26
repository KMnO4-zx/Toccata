import SwiftUI

struct SidebarFooterView: View {
    var openAbout: () -> Void
    @EnvironmentObject private var appearance: AppearanceSettings
    @State private var showsAppearancePicker = false
    @State private var isAboutHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            aboutButton
            appearanceButton
                .padding(.bottom, 7)
            CaptureStatusView()
                .font(.system(size: 12))
                .labelStyle(SidebarFooterLabelStyle())
                .padding(.horizontal, 10)
            Text("任务随时可用 · 数据保存在本机")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    private var aboutButton: some View {
        Button {
            showsAppearancePicker = false
            openAbout()
        } label: {
            HStack(spacing: 0) {
                Label("关于 Toccata", systemImage: "info.circle")
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
        .accessibilityLabel("关于 Toccata")
        .accessibilityValue(AppVersion.current.displayVersion)
        .help("查看版本信息与检查更新")
    }

    private var appearanceButton: some View {
        Button {
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
        .accessibilityLabel("外观模式")
        .accessibilityValue(appearance.mode.title)
        .help("切换月之亮面、月之暗面或跟随系统")
    }

    private var appearancePicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("外观")
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
        .frame(width: 170)
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
