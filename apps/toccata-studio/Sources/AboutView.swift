import AppKit
import SwiftUI

@MainActor
final class AboutWindowController {
    private var panel: NSPanel?

    func show() {
        if panel == nil {
            let window = AboutPanel(contentRect: .zero,
                styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
            window.title = "关于 Toccata"
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
    let version: AppVersion
    @StateObject private var checker: UpdateChecker
    @State private var copied = false

    init(version: AppVersion = .current, checker: UpdateChecker? = nil) {
        self.version = version
        _checker = StateObject(wrappedValue: checker ?? UpdateChecker(current: version))
    }

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                if let url = AppResources.bundle.url(forResource: "AppIcon", withExtension: "icns"),
                   let icon = NSImage(contentsOf: url) {
                    Image(nsImage: icon).resizable().frame(width: 80, height: 80)
                        .accessibilityHidden(true)
                }
                Text("Toccata").font(.system(size: 26, weight: .bold))
                Text("记下想法，看见投入").foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Text(version.displayVersion).fontWeight(.medium)
                    Text("·").foregroundStyle(.tertiary)
                    Text("构建 \(version.build)").foregroundStyle(.secondary)
                }
                .font(.callout).monospacedDigit().padding(.top, 4)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(version.copyableDescription, forType: .string)
                    copied = true
                } label: {
                    Label(copied ? "已复制版本信息" : "复制版本信息", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.plain).font(.caption).foregroundStyle(Color.accentColor)
            }

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("软件更新", systemImage: "arrow.triangle.2.circlepath").font(.headline)
                    Spacer()
                    if checker.state == .checking {
                        ProgressView().controlSize(.small).accessibilityLabel("正在检查更新")
                    }
                }
                updateStatus
                    .frame(maxWidth: .infinity, minHeight: 58, alignment: .topLeading)
                HStack {
                    Button(checker.state == .checking ? "正在检查…" : "检查更新") {
                        Task { await checker.check() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(checker.state == .checking)
                    Spacer()
                    if case let .available(update) = checker.state {
                        Link("查看新版 ↗", destination: update.pageURL)
                    } else {
                        Link("发布页面 ↗", destination: ToccataReleaseSource.releasesURL)
                    }
                }
                .controlSize(.regular)
            }
            .padding(16)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
            Text("手动检查 GitHub Releases，不会自动下载安装。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(28)
        .frame(width: 390)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var updateStatus: some View {
        VStack(alignment: .leading, spacing: 5) {
            switch checker.state {
            case .idle:
                Text("查看是否有新版本").fontWeight(.medium)
                Text("点击检查，获取最新的正式发布版本。")
                    .font(.callout).foregroundStyle(.secondary)
            case .checking:
                Text("正在连接 GitHub…").fontWeight(.medium)
            case .upToDate:
                Label("当前已是最新版本", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).fontWeight(.medium)
                Text("当前版本 \(version.displayVersion)").font(.callout).foregroundStyle(.secondary)
            case let .available(update):
                Text("发现新版本 v\(update.version)").fontWeight(.semibold).foregroundStyle(Color.accentColor)
                Text("查看更新说明并下载，安装由你确认。")
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
