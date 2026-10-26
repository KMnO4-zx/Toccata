import AppKit
import SwiftUI

/// Export-specific layout: no controls, hover state or scroll clipping.
@MainActor
struct ActivityShareCard: View {
    let report: ActivityShareSnapshot
    let identities: [String: ApplicationIdentityCache.Identity]
    private let ink = Color(red: 0.12, green: 0.17, blue: 0.25)
    private let muted = Color(red: 0.43, green: 0.48, blue: 0.56)
    private let blue = Color(red: 0.12, green: 0.35, blue: 0.90)

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            metrics
            keyboard
            timeline
            applications
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("记下想法，看见投入").font(.system(size: 13, weight: .medium))
                    Text("基于本机已保存的键盘活动 · 活跃时间与应用时长均为估算")
                        .font(.system(size: 10)).foregroundStyle(muted)
                }
                Spacer()
                Text("TOCCATA").font(.system(size: 11, weight: .bold, design: .rounded)).tracking(2)
                    .foregroundStyle(blue)
            }
            .padding(.horizontal, 4).padding(.top, 4)
        }
        .padding(32)
        .frame(width: 960)
        .foregroundStyle(ink)
        .background(LinearGradient(colors: [Color(red: 0.93, green: 0.96, blue: 1),
                                           Color(red: 0.97, green: 0.98, blue: 1)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing))
        .environment(\.colorScheme, .light)
        .environment(\.locale, Locale(identifier: "zh_CN"))
        .environment(\.calendar, report.calendar)
        .environment(\.timeZone, report.calendar.timeZone)
        .tint(blue)
    }

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                Label("Toccata", systemImage: "square.3.layers.3d")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(blue)
                Text("我的键盘足迹").font(.system(size: 32, weight: .bold))
            }
            Spacer()
            Text(report.dateLabel)
                .font(.system(size: 13, weight: .medium, design: .rounded)).monospacedDigit()
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(.white.opacity(0.8), in: Capsule())
        }
        .padding(.bottom, 4)
    }

    private var metrics: some View {
        HStack(spacing: 12) {
            metric("键盘活跃时间", value: Formatters.duration(ms: report.activity.activeMs),
                   subtitle: "短窗口合并，重叠只计算一次", prominent: true)
            metric("按键次数", value: report.activity.keyCount.formatted(),
                   subtitle: "包含修饰键 · 过滤长按重复")
            metric("语音输出估算 · Fn", value: Formatters.duration(ms: report.activity.fnMs),
                   subtitle: "Fn 累计按住时长")
        }
    }

    private func metric(_ title: String, value: String, subtitle: String, prominent: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 12, weight: .medium)).opacity(0.8)
            Text(value).font(.system(size: 26, weight: .bold, design: .rounded)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.55).frame(height: 34, alignment: .leading)
            Text(subtitle).font(.system(size: 10)).opacity(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(18)
        .foregroundStyle(prominent ? Color.white : ink)
        .background(prominent ? blue : .white, in: RoundedRectangle(cornerRadius: 16))
    }

    private var keyboard: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionHeading("键盘热力图", subtitle: "颜色越深，按键次数越多", number: "01")
            KeyboardHeatmapView(counts: report.activity.keyCounts, fnMs: report.activity.fnMs,
                                periodDescription: "所选时段")
                .frame(width: 792, height: 792 / KeyboardLayout.magicKeyboard.aspectRatio)
                .frame(maxWidth: .infinity).allowsHitTesting(false)
            let keys = KeyboardUsageRanking.topFive(counts: report.activity.keyCounts)
            if keys.isEmpty {
                Text("这段时间暂无按键记录").font(.system(size: 12)).foregroundStyle(muted)
            } else {
                HStack(spacing: 10) {
                    Text("常用按键").font(.system(size: 11)).foregroundStyle(muted)
                    ForEach(keys) { key in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(key.name).font(.system(size: 12, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7)
                            Text("\(key.count.formatted()) 次").font(.system(size: 11)).monospacedDigit().foregroundStyle(muted)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .background(blue.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
                    }
                }
            }
        }
        .padding(24).background(.white, in: RoundedRectangle(cornerRadius: 20))
    }

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeading("活跃时间线", subtitle: "每格 15 分钟 · 颜色越深，活跃时间越长", number: "02")
            HStack(spacing: 12) {
                Text("日期").frame(width: 64, alignment: .leading)
                HStack {
                    Text("00:00"); Spacer(); Text("06:00"); Spacer(); Text("12:00")
                    Spacer(); Text("18:00"); Spacer(); Text("24:00")
                }
                Text("活跃 / Fn").frame(width: 154, alignment: .trailing)
            }
            .font(.system(size: 10)).foregroundStyle(muted)
            VStack(spacing: 8) {
                ForEach(report.activity.days) { day in
                    HStack(spacing: 12) {
                        Text(day.date, format: .dateTime.month(.twoDigits).day(.twoDigits))
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .frame(width: 64, alignment: .leading)
                        // Canvas keeps long, custom ranges inexpensive to export.
                        Canvas { context, size in
                            guard !day.buckets.isEmpty else { return }
                            let pitch = size.width / CGFloat(day.buckets.count)
                            for (index, bucket) in day.buckets.enumerated() {
                                let rect = CGRect(x: CGFloat(index) * pitch, y: 0,
                                                  width: max(0.5, pitch - 1.5), height: size.height)
                                let color = bucket.fraction > 0 ? blue.opacity(0.2 + 0.8 * bucket.fraction) : blue.opacity(0.045)
                                context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(color))
                            }
                        }
                        .frame(height: report.activity.days.count == 1 ? 48 : 26)
                        VStack(alignment: .trailing, spacing: 3) {
                            Text(Formatters.duration(ms: day.activeMs)).font(.system(size: 11, weight: .semibold))
                            Text("Fn \(Formatters.duration(ms: day.fnMs))").font(.system(size: 10)).foregroundStyle(muted)
                        }
                        .monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                        .frame(width: 154, alignment: .trailing)
                    }
                }
            }
        }
        .padding(24).background(.white, in: RoundedRectangle(cornerRadius: 20))
    }

    private var applications: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeading("常用应用", subtitle: "按键盘活跃时长排序 · 最多 6 个", number: "03")
            if report.apps.isEmpty {
                Text("这段时间暂无应用使用记录").font(.system(size: 12)).foregroundStyle(muted).padding(.vertical, 14)
            } else {
                // Eager stacks are intentional: every row must appear in the PNG.
                VStack(spacing: 12) {
                    ForEach(0..<((report.apps.count + 1) / 2), id: \.self) { row in
                        HStack(spacing: 12) {
                            appCell(report.apps[row * 2])
                            if row * 2 + 1 < report.apps.count { appCell(report.apps[row * 2 + 1]) }
                            else { Color.clear.frame(maxWidth: .infinity) }
                        }
                    }
                }
            }
        }
        .padding(24).background(.white, in: RoundedRectangle(cornerRadius: 20))
    }

    private func appCell(_ app: AppRank) -> some View {
        let identity = identities[app.app]
        return HStack(spacing: 12) {
            Group {
                if let icon = identity?.icon { Image(nsImage: icon).resizable() }
                else { Image(systemName: "app.dashed").resizable().foregroundStyle(muted).padding(5) }
            }
            .scaledToFit().frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 7) {
                Text(identity?.name ?? app.shortName).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                HStack(spacing: 10) {
                    Text(Formatters.duration(ms: app.usageMs)).foregroundStyle(blue)
                    Text("\(app.keyCount.formatted()) 次按键").foregroundStyle(muted)
                }
                .font(.system(size: 11)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.75)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(14)
        .background(blue.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    }

    private func sectionHeading(_ title: String, subtitle: String, number: String) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 17, weight: .bold))
                Text(subtitle).font(.system(size: 11)).foregroundStyle(muted)
            }
            Spacer()
            Text(number).font(.system(size: 14, weight: .semibold, design: .rounded)).foregroundStyle(blue.opacity(0.45))
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
        renderer.proposedSize = ProposedViewSize(width: 960, height: nil)
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
