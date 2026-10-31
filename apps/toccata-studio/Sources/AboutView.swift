import AppKit
import Combine
import SwiftUI

@MainActor
final class AboutWindowController {
    private var panel: NSPanel?
    private var languageSubscription: AnyCancellable?
    private let updater: AppUpdateController

    init(install: @escaping AppUpdateController.Install) {
        updater = AppUpdateController(install: install)
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
            let content = NSHostingView(rootView: AboutView(updater: updater))
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
    @StateObject private var updater: AppUpdateController
    @State private var copied = false

    init(version: AppVersion = .current, checker: UpdateChecker? = nil, updater: AppUpdateController) {
        self.version = version
        _checker = StateObject(wrappedValue: checker ?? UpdateChecker(current: version))
        _updater = StateObject(wrappedValue: updater)
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
                HStack(spacing: 8) {
                    Text(version.displayVersion)
                        .font(.callout.weight(.medium)).monospacedDigit()
                    Text("·").foregroundStyle(.tertiary)
                    Text("Commit \(version.displayCommit)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .textSelection(.enabled)
                .padding(.top, 4)
                .accessibilityIdentifier("about-version-info")
                if version.hasLocalChanges {
                    Text(L10n.tr("含未提交修改"))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(version.copyableDescription, forType: .string)
                    copied = true
                } label: {
                    Label(copied ? L10n.tr("已复制版本信息") : L10n.tr("复制版本信息"), systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.plain).font(.caption).foregroundStyle(Color.accentColor)
            }

            HStack(spacing: 10) {
                Link(destination: ToccataReleaseSource.repositoryURL) {
                    HStack(spacing: 10) {
                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                            .font(.system(size: 18, weight: .medium))
                            .frame(width: 24, height: 32)
                            .foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.tr("项目仓库 · GitHub")).font(.caption).foregroundStyle(.secondary)
                            Text(ToccataReleaseSource.repositoryAddress)
                                .font(.system(size: 11, weight: .medium)).foregroundStyle(.primary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L10n.tr("打开 GitHub 仓库：\(ToccataReleaseSource.repository)"))

                Link(L10n.tr("去点 Star 🌟"), destination: ToccataReleaseSource.repositoryURL)
                    .font(.system(size: 11, weight: .medium))
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .fixedSize()
                    .help(L10n.tr("在 GitHub 上为 Toccata 点 Star"))
                    .accessibilityIdentifier("about-star-github")
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(L10n.tr("软件更新"), systemImage: "arrow.triangle.2.circlepath").font(.headline)
                    Spacer()
                    if checker.state == .checking || updater.state == .verifying || updater.state == .installing {
                        ProgressView().controlSize(.small).accessibilityLabel(progressLabel)
                    }
                }
                Group {
                    if updater.state == .idle { updateStatus }
                    else { downloadStatus }
                }
                .frame(maxWidth: .infinity, minHeight: 78, alignment: .topLeading)
                HStack {
                    updateAction
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
            Text(L10n.tr("从 GitHub 下载并校验更新，点击“安装并重启”完成更新。"))
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
                Text(update.package == nil
                     ? L10n.tr("此版本暂无可自动安装的兼容安装包，请查看发布页面。")
                     : L10n.tr("可在这里下载更新，完成后安装并重启。"))
                    .font(.callout).foregroundStyle(.secondary)
            case let .failed(error):
                Text(error.title).fontWeight(.medium)
                Text(error.detail).font(.callout).foregroundStyle(.secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var updateAction: some View {
        if isDownloading || updater.state == .verifying {
            Button(L10n.tr("取消下载")) { updater.cancel() }.buttonStyle(.bordered)
        } else if updater.prepared != nil {
            Button(updater.state == .installing ? L10n.tr("正在准备重启…") : L10n.tr("安装并重启")) { updater.install() }
                .buttonStyle(.borderedProminent).disabled(updater.state == .installing)
        } else if case let .available(update) = checker.state, update.package != nil {
            Button(L10n.tr("下载更新")) { updater.download(update) }
                .buttonStyle(.borderedProminent).disabled(updater.state.isBusy)
        } else {
            Button(checker.state == .checking ? L10n.tr("正在检查…") : L10n.tr("检查更新")) {
                updater.cancel()
                Task { await checker.check() }
            }
            .buttonStyle(.borderedProminent).disabled(checker.state == .checking)
        }
    }

    private var isDownloading: Bool {
        if case .downloading = updater.state { return true }
        return false
    }

    private var progressLabel: String {
        switch updater.state {
        case .verifying: return L10n.tr("正在校验并准备安装…")
        case .installing: return L10n.tr("正在保存任务和键盘记录…")
        default: return L10n.tr("正在检查更新")
        }
    }

    @ViewBuilder private var downloadStatus: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch updater.state {
            case .idle: EmptyView()
            case let .downloading(progress):
                HStack {
                    Text(L10n.tr("正在下载更新…")).fontWeight(.medium)
                    Spacer()
                    Text(progress, format: .percent.precision(.fractionLength(0))).monospacedDigit()
                }
                ProgressView(value: progress)
            case .verifying:
                Text(L10n.tr("正在校验并准备安装…")).fontWeight(.medium)
                Text(L10n.tr("安装包下载完成，正在检查完整性与兼容性。"))
                    .font(.callout).foregroundStyle(.secondary)
            case .ready:
                Label(L10n.tr("更新已准备好"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Text(L10n.tr("点击下方按钮，保存当前任务后安装并重新打开 Toccata。"))
                    .font(.callout).foregroundStyle(.secondary)
            case .installing:
                Text(L10n.tr("正在保存任务和键盘记录…")).fontWeight(.medium)
                Text(L10n.tr("完成后会自动安装并重新打开 Toccata。"))
                    .font(.callout).foregroundStyle(.secondary)
            case let .failed(message):
                Text(L10n.tr("更新未完成")).fontWeight(.medium)
                Text(message).font(.callout).foregroundStyle(.secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
