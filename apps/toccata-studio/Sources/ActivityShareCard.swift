import AppKit
import SwiftUI

/// A narrow, compact poster: text remains readable when fitted to a phone screen.
@MainActor
struct ActivityShareCard: View {
    static let width: CGFloat = 720
    let report: ActivityShareSnapshot
    let identities: [String: ApplicationIdentityCache.Identity]
    private let ink = Color(red: 0.12, green: 0.17, blue: 0.25)
    private let muted = Color(red: 0.39, green: 0.44, blue: 0.52)
    private let blue = Color(red: 0.12, green: 0.35, blue: 0.90)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            metrics
            keyboard
            timeline
            applications
            HStack(alignment: .bottom) {
                Text("本机已保存记录 · 活跃时长为估算")
                    .font(.system(size: 16)).foregroundStyle(muted)
                Spacer()
                Text("看见投入").font(.system(size: 17, weight: .medium)).foregroundStyle(blue)
            }
            .padding(.horizontal, 2)
        }
        .padding(18)
        .frame(width: Self.width)
        .foregroundStyle(ink)
        .background(Color(red: 0.94, green: 0.96, blue: 1))
        .environment(\.colorScheme, .light)
        .environment(\.locale, Locale(identifier: "zh_CN"))
        .environment(\.calendar, report.calendar)
        .environment(\.timeZone, report.calendar.timeZone)
        .tint(blue)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("我的键盘足迹").font(.system(size: 32, weight: .bold))
                Spacer()
                Label("Toccata", systemImage: "square.3.layers.3d")
                    .font(.system(size: 21, weight: .semibold)).foregroundStyle(blue)
            }
            Text(report.dateLabel).font(.system(size: 19, weight: .medium, design: .rounded))
                .monospacedDigit().foregroundStyle(muted)
        }
        .padding(.horizontal, 2).padding(.bottom, 2)
    }

    private var metrics: some View {
        VStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("键盘活跃时间").font(.system(size: 21, weight: .medium))
                Spacer(minLength: 8)
                Text(Formatters.duration(ms: report.activity.activeMs))
                    .font(.system(size: 35, weight: .bold, design: .rounded)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.75)
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
            .foregroundStyle(.white).background(blue, in: RoundedRectangle(cornerRadius: 13))
            HStack(spacing: 8) {
                metric("按键次数", value: report.activity.keyCount.formatted())
                metric("语音输出估算 · Fn", value: Formatters.duration(ms: report.activity.fnMs))
            }
        }
    }

    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 18, weight: .medium)).foregroundStyle(muted)
                .fixedSize(horizontal: true, vertical: false)
            Text(value).font(.system(size: 27, weight: .bold, design: .rounded)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.vertical, 10)
        .background(.white, in: RoundedRectangle(cornerRadius: 13))
    }

    private var keyboard: some View {
        VStack(alignment: .leading, spacing: 10) {
            heading("键盘热力图", detail: "越深，按得越多")
            KeyboardHeatmapView(counts: report.activity.keyCounts, fnMs: report.activity.fnMs,
                                periodDescription: "所选时段", labelScale: 1.4)
                .frame(width: 656, height: 656 / KeyboardLayout.magicKeyboard.aspectRatio)
                .allowsHitTesting(false)
            let keys = KeyboardUsageRanking.topFive(counts: report.activity.keyCounts)
            if keys.isEmpty {
                Text("暂无按键记录").font(.system(size: 19)).foregroundStyle(muted)
            } else {
                HStack(spacing: 6) {
                    ForEach(keys) { key in
                        VStack(spacing: 4) {
                            Text(shortName(key)).font(.system(size: 21, weight: .semibold)).lineLimit(1)
                            Text("\(key.count.formatted()) 次")
                                .font(.system(size: 19)).monospacedDigit().foregroundStyle(muted)
                                .lineLimit(1).minimumScaleFactor(0.75)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                        .background(blue.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
        .padding(14).background(.white, in: RoundedRectangle(cornerRadius: 16))
    }

    private func shortName(_ key: KeyboardUsageRanking.Entry) -> String {
        switch key.keycode {
        case 55: return "左 ⌘"
        case 54: return "右 ⌘"
        case 56: return "左 ⇧"
        case 60: return "右 ⇧"
        case 58: return "左 ⌥"
        case 61: return "右 ⌥"
        case 59: return "左 ⌃"
        case 62: return "右 ⌃"
        case 63: return "Fn"
        default: return key.name
        }
    }

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 10) {
            heading("活跃时间线", detail: "每格 15 分钟")
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
                                .font(.system(size: 19, weight: .semibold, design: .rounded))
                            Spacer()
                            Text(Formatters.duration(ms: day.activeMs)).font(.system(size: 19, weight: .semibold))
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
            heading("常用应用", detail: "活跃时长前 6 名")
            if report.apps.isEmpty {
                Text("暂无应用记录").font(.system(size: 19)).foregroundStyle(muted)
            } else {
                // Eager stacks ensure all rows are present in the exported image.
                VStack(spacing: 8) {
                    ForEach(0..<((report.apps.count + 1) / 2), id: \.self) { row in
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
                Text(identity?.name ?? app.shortName).font(.system(size: 21, weight: .semibold)).lineLimit(1)
                Text(Formatters.duration(ms: app.usageMs)).font(.system(size: 20, weight: .medium)).foregroundStyle(blue)
                Text("\(app.keyCount.formatted()) 次按键").font(.system(size: 18)).foregroundStyle(muted)
            }
            .monospacedDigit().lineLimit(1).minimumScaleFactor(0.85)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
        .background(blue.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    private func heading(_ title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 23, weight: .bold))
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
