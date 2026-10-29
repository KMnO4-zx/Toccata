import SwiftUI

struct MenuActivityTimeline: View {
    let buckets: [ActivityBucket]
    @State private var hoveredID: ActivityBucket.ID?

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                ForEach(["00:00", "06:00", "12:00", "18:00", "24:00"], id: \.self) { value in
                    Text(value).font(.system(size: 9)).foregroundStyle(TaskMenuStyle.secondary)
                    if value != "24:00" { Spacer(minLength: 0) }
                }
            }
            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    HStack(spacing: 0.6) {
                        ForEach(buckets) { bucket in
                            RoundedRectangle(cornerRadius: 1)
                                .fill(bucket.fraction > 0
                                      ? Color.accentColor.opacity(0.18 + bucket.fraction * 0.82)
                                      : Color.primary.opacity(0.045))
                                .overlay {
                                    if bucket.id == hoveredID {
                                        RoundedRectangle(cornerRadius: 1)
                                            .strokeBorder(Color.accentColor, lineWidth: 1)
                                    }
                                }
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .accessibilityLabel(description(bucket))
                        }
                    }
                    .frame(height: 54, alignment: .bottom)
                    if let index = buckets.firstIndex(where: { $0.id == hoveredID }) {
                        let bucket = buckets[index]
                        let step = geometry.size.width / CGFloat(buckets.count)
                        let x = (CGFloat(index) + 0.5) * step
                        let width = min(190, geometry.size.width)
                        tooltip(bucket)
                            .frame(width: width)
                            .position(x: min(max(x, width / 2), geometry.size.width - width / 2), y: -54)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .frame(width: geometry.size.width, height: 54)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point):
                        guard !buckets.isEmpty, geometry.size.width > 0,
                              point.x >= 0, point.x <= geometry.size.width,
                              point.y >= 0, point.y <= geometry.size.height else { hoveredID = nil; return }
                        let index = min(buckets.count - 1, max(0, Int(point.x / geometry.size.width * CGFloat(buckets.count))))
                        hoveredID = buckets[index].id
                    case .ended: hoveredID = nil
                    }
                }
                .onValueChange(of: geometry.frame(in: .global)) { hoveredID = nil }
            }
            .frame(height: 54)
        }
        .onDisappear { hoveredID = nil }
        .onChange(of: buckets.first?.id) { _ in hoveredID = nil }
    }

    private func tooltip(_ bucket: ActivityBucket) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(timeRange(bucket)).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            tooltipRow(L10n.tr("键盘活跃"), value: Formatters.duration(ms: bucket.activeMs))
            tooltipRow(L10n.tr("按键次数"), value: L10n.tr("\(bucket.keyCount.formatted(.number.locale(L10n.locale))) 次"))
            tooltipRow(L10n.tr("Fn 按住"), value: Formatters.duration(ms: bucket.fnMs))
        }
        .lineLimit(1).minimumScaleFactor(0.8)
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.14), radius: 8, y: 3)
    }

    private func tooltipRow(_ title: String, value: String) -> some View {
        HStack(spacing: 8) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(value).fontWeight(.medium)
        }
        .font(.system(size: 11)).monospacedDigit()
    }

    private func timeRange(_ bucket: ActivityBucket) -> String {
        let style = Date.FormatStyle.dateTime.hour().minute().locale(L10n.locale)
        let start = Date(timeIntervalSince1970: Double(bucket.startMs) / 1000).formatted(style)
        let end = Date(timeIntervalSince1970: Double(bucket.endMs) / 1000).formatted(style)
        return "\(start)–\(end)"
    }

    private func description(_ bucket: ActivityBucket) -> String {
        timeRange(bucket) + " · " + L10n.tr("活跃 \(Formatters.duration(ms: bucket.activeMs))，Fn 按住 \(Formatters.duration(ms: bucket.fnMs))，\(bucket.keyCount) 次按键")
    }
}
