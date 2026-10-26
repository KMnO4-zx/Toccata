import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct ActivitySharePopover: View {
    let range: ActivityRange
    let referenceDate: Date
    let onClose: () -> Void
    @State private var report: ActivityShareSnapshot?
    @State private var rendered: ActivityShareImage?
    @State private var errorMessage: String?
    @State private var feedback: String?
    @State private var isLoading = false
    @State private var isSaving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("分享键盘足迹").font(.system(size: 17, weight: .semibold))
                    Text(report?.dateLabel ?? "正在准备所选时段…")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark").frame(width: 22, height: 22) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("关闭分享预览")
                    .accessibilityLabel("关闭分享预览").disabled(isSaving)
            }
            Group {
                if let rendered {
                    ScrollView {
                        Image(nsImage: rendered.image).resizable().interpolation(.high).scaledToFit()
                            .accessibilityLabel("所选时段的概览、键盘热力图、活跃时间线和常用应用分享图片")
                    }
                } else if isLoading {
                    VStack(spacing: 12) {
                        ProgressView().controlSize(.small)
                        Text("正在生成图片…").font(.callout).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "photo.badge.exclamationmark").font(.title).foregroundStyle(.secondary)
                        Text(errorMessage ?? "暂时无法生成图片").font(.callout).multilineTextAlignment(.center)
                        Button("重试") { Task { await generate() } }
                    }
                    .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(height: 410)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.07)))

            if rendered != nil, let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Text(feedback ?? "PNG 图片 · 已保存记录 · 仅在本机生成")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button {
                    do {
                        try rendered?.copy()
                        errorMessage = nil
                        feedback = "已复制图片"
                    } catch { errorMessage = error.localizedDescription }
                } label: { Label("复制", systemImage: "doc.on.doc") }
                .accessibilityIdentifier("activity-share-copy")
                Button(action: download) { Label("下载", systemImage: "arrow.down.to.line") }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("activity-share-download")
            }
            .disabled(rendered == nil || isSaving)
        }
        .padding(18).frame(width: 540)
        .background(Color(nsColor: .windowBackgroundColor))
        .interactiveDismissDisabled(isSaving)
        .task { await generate() }
    }

    private func generate() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        feedback = nil
        defer { isLoading = false }
        do {
            let selected = range
            let now = referenceDate
            let result = try await Task.detached(priority: .userInitiated) {
                try ActivityShareSnapshot.load(range: selected, now: now)
            }.value
            try Task.checkCancellation()
            let identities = Dictionary(uniqueKeysWithValues: result.apps.map {
                ($0.app, ApplicationIdentityCache.shared.identity(for: $0.app))
            })
            let picture = try ActivityShareImage.render(report: result, identities: identities)
            report = result
            rendered = picture
        } catch is CancellationError {
            // Dismissing the popover must not publish a late preview.
        } catch { errorMessage = error.localizedDescription }
    }

    private func download() {
        guard let rendered, let report, !isSaving else { return }
        let panel = NSSavePanel()
        panel.title = "保存键盘足迹"
        panel.prompt = "保存"
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = report.filename
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        isSaving = true
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            isSaving = false
            guard response == .OK, let url = panel.url else { return }
            do {
                try rendered.save(to: url)
                errorMessage = nil
                feedback = "图片已保存"
            } catch { errorMessage = "保存失败：\(error.localizedDescription)" }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: completion) }
        else { panel.begin(completionHandler: completion) }
    }
}
