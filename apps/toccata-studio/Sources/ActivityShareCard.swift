import AppKit
import SwiftUI

/// A narrow, compact poster: text remains readable when fitted to a phone screen.
@MainActor
struct ActivityShareCard: View {
    @ObservedObject private var interfaceLanguage = LanguageSettings.shared
    static let width: CGFloat = 720
    let report: ActivityShareSnapshot
    let identities: [String: ApplicationIdentityCache.Identity]
    private let ink = Color(red: 0.16, green: 0.19, blue: 0.25)
    private let muted = Color(red: 0.43, green: 0.47, blue: 0.53)
    private let blue = Color(red: 0.16, green: 0.37, blue: 0.83)

    var body: some View {
        let _ = interfaceLanguage.language
        VStack(alignment: .leading, spacing: 12) {
            header
            metrics
            keyboard
            timeline
            applications
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .bottom) {
                    Text(L10n.tr("本机已保存记录 · 活跃时长为估算"))
                        .font(.system(size: 16)).foregroundStyle(muted)
                    Spacer()
                    Text(L10n.tr("看见投入")).font(.system(size: 17)).foregroundStyle(muted)
                }
                Label(ToccataReleaseSource.repositoryAddress, systemImage: "link")
                    .font(.system(size: 18)).foregroundStyle(blue)
            }
            .padding(.horizontal, 2)
        }
        .padding(18)
        .frame(width: Self.width)
        .foregroundStyle(ink)
        .background(Color(red: 0.965, green: 0.972, blue: 0.984))
        .environment(\.colorScheme, .light)
        .environment(\.locale, L10n.locale)
        .environment(\.calendar, report.calendar)
        .environment(\.timeZone, report.calendar.timeZone)
        .tint(blue)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L10n.tr("我的键盘足迹")).font(.system(size: 32))
                Spacer()
                Label("Toccata", systemImage: "square.3.layers.3d")
                    .font(.system(size: 21, weight: .medium)).foregroundStyle(blue)
            }
            Text(report.dateLabel).font(.system(size: 19))
                .monospacedDigit().foregroundStyle(muted)
        }
        .padding(.horizontal, 2).padding(.bottom, 2)
    }

    private var metrics: some View {
        VStack(spacing: 8) {
            HStack(alignment: .center) {
                Text(L10n.tr("键盘活跃时间")).font(.system(size: 21)).foregroundStyle(muted)
                Spacer(minLength: 8)
                Text(Formatters.duration(ms: report.activity.activeMs))
                    .font(.system(size: 35)).monospacedDigit().foregroundStyle(blue)
                    .lineLimit(1).minimumScaleFactor(0.75)
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
            .background(blue.opacity(0.065), in: RoundedRectangle(cornerRadius: 13))
            HStack(spacing: 8) {
                metric(L10n.tr("按键次数"), value: report.activity.keyCount.formatted())
                metric(L10n.tr("语音输出估算 · Fn"), value: Formatters.duration(ms: report.activity.fnMs))
            }
        }
    }

    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 18)).foregroundStyle(muted)
                .fixedSize(horizontal: true, vertical: false)
            Text(value).font(.system(size: 27)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.vertical, 10)
        .background(.white, in: RoundedRectangle(cornerRadius: 13))
    }

    private var keyboard: some View {
        VStack(alignment: .leading, spacing: 10) {
            heading(L10n.tr("键盘热力图"), detail: L10n.tr("越深，按得越多"))
            KeyboardHeatmapView(counts: report.activity.keyCounts, fnMs: report.activity.fnMs,
                                periodDescription: L10n.tr("所选时段"), labelScale: 1.4)
                .frame(width: 656, height: 656 / KeyboardLayout.magicKeyboard.aspectRatio)
                .allowsHitTesting(false)
            let keys = KeyboardUsageRanking.topFive(counts: report.activity.keyCounts)
            if keys.isEmpty {
                Text(L10n.tr("暂无按键记录")).font(.system(size: 19)).foregroundStyle(muted)
            } else {
                Rectangle().fill(ink.opacity(0.07)).frame(height: 1)
                HStack(spacing: 6) {
                    ForEach(keys) { key in
                        VStack(spacing: 4) {
                            keyBadge(shortName(key))
                            Text(L10n.tr("\(key.count.formatted()) 次"))
                                .font(.system(size: 19)).monospacedDigit().foregroundStyle(muted)
                                .lineLimit(1).minimumScaleFactor(0.75)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 4)
                    }
                }
            }
        }
        .padding(14).background(.white, in: RoundedRectangle(cornerRadius: 16))
    }

    private func keyBadge(_ name: String) -> some View {
        Text(name)
            .font(.system(size: 21, weight: .regular, design: .monospaced))
            .lineLimit(1)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .frame(minWidth: 34)
            .background {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color(red: 0.96, green: 0.965, blue: 0.975))
                    .shadow(color: .black.opacity(0.08), radius: 1.2, x: 0, y: 1.5)
                    .overlay {
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(ink.opacity(0.1), lineWidth: 0.6)
                    }
            }
    }

    private func shortName(_ key: KeyboardUsageRanking.Entry) -> String {
        switch key.keycode {
        case 55: return L10n.tr("左 ⌘")
        case 54: return L10n.tr("右 ⌘")
        case 56: return L10n.tr("左 ⇧")
        case 60: return L10n.tr("右 ⇧")
        case 58: return L10n.tr("左 ⌥")
        case 61: return L10n.tr("右 ⌥")
        case 59: return L10n.tr("左 ⌃")
        case 62: return L10n.tr("右 ⌃")
        case 63: return "Fn"
        default: return key.name
        }
    }

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 10) {
            heading(L10n.tr("活跃时间线"), detail: L10n.tr("每格 15 分钟"))
            HStack {
                Text("00:00"); Spacer(); Text("06:00"); Spacer(); Text("12:00")
                Spacer(); Text("18:00"); Spacer(); Text("24:00")
            }
            .font(.system(size: 17)).foregroundStyle(muted)
            VStack(spacing: 12) {
                ForEach(report.activity.days) { day in
                    VStack(spacing: 5) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(day.date, format: .dateTime.month(.twoDigits).day(.twoDigits))
                                .font(.system(size: 19))
                            Spacer()
                            Text(Formatters.duration(ms: day.activeMs)).font(.system(size: 19))
                            Text("· " + L10n.tr("\(day.keyCount.formatted()) 次按键"))
                                .font(.system(size: 17)).foregroundStyle(muted)
                            Text("· Fn \(Formatters.duration(ms: day.fnMs))")
                                .font(.system(size: 17)).foregroundStyle(muted)
                        }
                        .monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
                        Canvas { context, size in
                            guard !day.buckets.isEmpty else { return }
                            let pitch = size.width / CGFloat(day.buckets.count)
                            for (index, bucket) in day.buckets.enumerated() {
                                let rect = CGRect(x: CGFloat(index) * pitch, y: 0,
                                                  width: max(0.5, pitch - 1.5), height: size.height)
                                let color = bucket.fraction > 0 ? blue.opacity(0.2 + 0.8 * bucket.fraction) : blue.opacity(0.055)
                                context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(color))
                            }
                        }
                        .frame(height: report.activity.days.count == 1 ? 35 : 22)
                    }
                }
            }
        }
        .padding(14).background(.white, in: RoundedRectangle(cornerRadius: 16))
    }

    private var applications: some View {
        VStack(alignment: .leading, spacing: 10) {
            heading(L10n.tr("常用应用"), detail: L10n.tr("活跃时长前 6 名"), weight: .light)
            if report.apps.isEmpty {
                Text(L10n.tr("暂无应用记录")).font(.system(size: 19)).foregroundStyle(muted)
            } else {
                // Eager stacks ensure all rows are present in the exported image.
                VStack(spacing: 8) {
                    ForEach(0..<((report.apps.count + 1) / 2), id: \.self) { row in
                        if row > 0 {
                            Rectangle().fill(ink.opacity(0.07)).frame(height: 1)
                        }
                        HStack(spacing: 8) {
                            appCell(report.apps[row * 2])
                            if row * 2 + 1 < report.apps.count { appCell(report.apps[row * 2 + 1]) }
                            else { Color.clear.frame(maxWidth: .infinity) }
                        }
                    }
                }
            }
        }
        .padding(14).background(.white, in: RoundedRectangle(cornerRadius: 16))
    }

    private func appCell(_ app: AppRank) -> some View {
        let identity = identities[app.app]
        return HStack(alignment: .top, spacing: 10) {
            Group {
                if let icon = identity?.icon { Image(nsImage: icon).resizable() }
                else { Image(systemName: "app.dashed").resizable().foregroundStyle(muted).padding(5) }
            }
            .scaledToFit().frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 3) {
                Text(identity?.name ?? app.shortName).font(.system(size: 21, weight: .light)).lineLimit(1)
                Text(Formatters.duration(ms: app.usageMs)).font(.system(size: 20, weight: .light))
                Text(L10n.tr("\(app.keyCount.formatted()) 次按键"))
                    .font(.system(size: 18, weight: .light)).foregroundStyle(muted)
            }
            .foregroundStyle(Color(red: 0.30, green: 0.33, blue: 0.39))
            .monospacedDigit().lineLimit(1).minimumScaleFactor(0.85)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
    }

    private func heading(_ title: String, detail: String, weight: Font.Weight = .regular) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 23, weight: weight))
            Spacer()
            Text(detail).font(.system(size: 17)).foregroundStyle(muted)
        }
    }
}

@MainActor
struct ActivityShareImage {
    let png: Data
    let image: NSImage

    static func render(report: ActivityShareSnapshot,
                       identities: [String: ApplicationIdentityCache.Identity]) throws -> Self {
        let renderer = ImageRenderer(content: ActivityShareCard(report: report, identities: identities)
            .fixedSize(horizontal: false, vertical: true))
        renderer.proposedSize = ProposedViewSize(width: ActivityShareCard.width, height: nil)
        renderer.isOpaque = true
        var size = CGSize.zero
        renderer.render { measured, _ in size = measured }
        guard size.width > 0, size.height > 0, size.height.isFinite else { throw ActivityShareError.renderFailed }
        // Bound memory for very long custom ranges without cutting off any dates.
        let scale = min(2, 16_000 / size.height, sqrt(32_000_000 / (size.width * size.height)))
        guard scale >= 0.5 else { throw ActivityShareError.rangeTooLarge }
        renderer.scale = scale
        guard let cgImage = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) else {
            throw ActivityShareError.renderFailed
        }
        return Self(png: png, image: NSImage(cgImage: cgImage, size: size))
    }

    func copy(to pasteboard: NSPasteboard = .general) throws {
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else { throw ActivityShareError.copyFailed }
    }

    func save(to url: URL) throws { try png.write(to: url, options: .atomic) }
}
