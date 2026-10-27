import AppKit
import Combine
import SwiftUI

@MainActor
final class AboutWindowController {
    private var panel: NSPanel?
    private var languageSubscription: AnyCancellable?

    init() {
        languageSubscription = LanguageSettings.shared.$language.dropFirst()
            .receive(on: RunLoop.main).sink { [weak self] _ in
                guard let panel = self?.panel else { return }
                panel.title = L10n.tr("关于 Toccata")
                if let content = panel.contentView {
                    content.layoutSubtreeIfNeeded()
                    panel.setContentSize(content.fittingSize)
                }
            }
    }

    func show() {
        if panel == nil {
            let window = AboutPanel(contentRect: .zero,
                styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
            window.title = L10n.tr("关于 Toccata")
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.hidesOnDeactivate = false
            window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            let content = NSHostingView(rootView: AboutView())
            window.contentView = content
            window.setContentSize(content.fittingSize)
            window.center()
            panel = window
        }
        // Showing About must not bring a background workbench to the foreground.
        panel?.makeKeyAndOrderFront(nil)
    }
}

private final class AboutPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
struct AboutView: View {
    @ObservedObject private var interfaceLanguage = LanguageSettings.shared
    let version: AppVersion
    @StateObject private var checker: UpdateChecker
    @State private var copied = false

    init(version: AppVersion = .current, checker: UpdateChecker? = nil) {
        self.version = version
        _checker = StateObject(wrappedValue: checker ?? UpdateChecker(current: version))
    }

    var body: some View {
        let _ = interfaceLanguage.language
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                if let url = AppResources.bundle.url(forResource: "AppIcon", withExtension: "icns"),
                   let icon = NSImage(contentsOf: url) {
                    Image(nsImage: icon).resizable().frame(width: 80, height: 80)
                        .accessibilityHidden(true)
                }
                Text("Toccata").font(.system(size: 26, weight: .bold))
                Text(L10n.tr("记下想法，看见投入")).foregroundStyle(.secondary)
                Text(version.displayVersion).font(.callout.weight(.medium))
                    .monospacedDigit().padding(.top, 4)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(version.copyableDescription, forType: .string)
                    copied = true
                } label: {
                    Label(copied ? L10n.tr("已复制版本信息") : L10n.tr("复制版本信息"), systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.plain).font(.caption).foregroundStyle(Color.accentColor)
            }

            Link(destination: ToccataReleaseSource.repositoryURL) {
                HStack(spacing: 12) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .font(.system(size: 18, weight: .medium))
                        .frame(width: 32, height: 32)
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.tr("项目仓库 · GitHub")).font(.caption).foregroundStyle(.secondary)
                        Text(ToccataReleaseSource.repositoryAddress)
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(.primary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.right").font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
                .contentShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .help(L10n.tr("打开 GitHub 仓库：\(ToccataReleaseSource.repository)"))

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(L10n.tr("软件更新"), systemImage: "arrow.triangle.2.circlepath").font(.headline)
                    Spacer()
                    if checker.state == .checking {
                        ProgressView().controlSize(.small).accessibilityLabel(L10n.tr("正在检查更新"))
                    }
                }
                updateStatus
                    .frame(maxWidth: .infinity, minHeight: 58, alignment: .topLeading)
                HStack {
                    Button(checker.state == .checking ? L10n.tr("正在检查…") : L10n.tr("检查更新")) {
                        Task { await checker.check() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(checker.state == .checking)
                    Spacer()
                    if case let .available(update) = checker.state {
                        Link(L10n.tr("查看新版 ↗"), destination: update.pageURL)
                    } else {
                        Link(L10n.tr("发布页面 ↗"), destination: ToccataReleaseSource.releasesURL)
                    }
                }
                .controlSize(.regular)
            }
            .padding(16)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
            Text(L10n.tr("手动检查 GitHub Releases，不会自动下载安装。"))
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(28)
        .frame(width: 390)
        .fixedSize(horizontal: false, vertical: true)
        .languageChangeTransition()
    }

    @ViewBuilder private var updateStatus: some View {
        VStack(alignment: .leading, spacing: 5) {
            switch checker.state {
            case .idle:
                Text(L10n.tr("查看是否有新版本")).fontWeight(.medium)
                Text(L10n.tr("点击检查，获取最新的正式发布版本。"))
                    .font(.callout).foregroundStyle(.secondary)
            case .checking:
                Text(L10n.tr("正在连接 GitHub…")).fontWeight(.medium)
            case .upToDate:
                Label(L10n.tr("当前已是最新版本"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).fontWeight(.medium)
                Text(L10n.tr("当前版本 \(version.displayVersion)")).font(.callout).foregroundStyle(.secondary)
            case let .available(update):
                Text(L10n.tr("发现新版本 v\(update.version)")).fontWeight(.semibold).foregroundStyle(Color.accentColor)
                Text(L10n.tr("查看更新说明并下载，安装由你确认。"))
                    .font(.callout).foregroundStyle(.secondary)
            case let .failed(error):
                Text(error.title).fontWeight(.medium)
                Text(error.detail).font(.callout).foregroundStyle(.secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }
}
