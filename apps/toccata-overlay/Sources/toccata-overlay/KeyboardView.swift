import AppKit

final class KeyboardView: NSView {
    enum Mode { case live, heat }

    var layout: KeyboardLayout { didSet { needsDisplay = true } }
    var theme: Theme { didSet { needsDisplay = true } }
    var mode: Mode = .live { didSet { needsDisplay = true } }
    var pressed: Set<UInt16> = [] { didSet { needsDisplay = true } }
    var heatCounts: [UInt16: Int] = [:]
    var heatMax: Int = 0
    var heatAvailable: Bool = false

    init(layout: KeyboardLayout, theme: Theme) {
        self.layout = layout
        self.theme = theme
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let backgroundPath = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 14, yRadius: 14)
        theme.windowBackgroundColor.setFill()
        backgroundPath.fill()

        let contentW = layout.contentWidthPoints
        let contentH = layout.contentHeightPoints
        guard contentW > 0, contentH > 0 else { return }

        let scale = min(Double(bounds.width) / contentW, Double(bounds.height) / contentH)
        let originX = (Double(bounds.width) - contentW * scale) / 2
        let originY = (Double(bounds.height) - contentH * scale) / 2
        let gap = layout.keyGap * scale
        let font = NSFont.systemFont(ofSize: layout.unit * scale * 0.28, weight: .medium)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byClipping

        for key in layout.placedKeys {
            let raw = NSRect(
                x: originX + Double(key.rect.minX) * layout.unit * scale,
                y: originY + Double(key.rect.minY) * layout.unit * scale,
                width: Double(key.rect.width) * layout.unit * scale,
                height: Double(key.rect.height) * layout.unit * scale
            )
            let keyRect = raw.insetBy(dx: gap / 2, dy: gap / 2)
            guard keyRect.width > 0.5, keyRect.height > 0.5 else { continue }

            let fill: NSColor
            let labelColor: NSColor
            if key.decor {
                fill = theme.decorColor
                labelColor = theme.labelColor
            } else {
                switch mode {
                case .live:
                    if let code = key.code, pressed.contains(code) {
                        fill = theme.pressedColor
                        labelColor = theme.pressedLabelColor
                    } else {
                        fill = theme.keycapColor
                        labelColor = theme.labelColor
                    }
                case .heat:
                    labelColor = theme.heatLabelColor
                    let n = key.code.flatMap { heatCounts[$0] } ?? 0
                    if !heatAvailable || heatMax <= 0 {
                        fill = theme.keycapColor
                    } else {
                        let t = log(1 + Double(n)) / log(1 + Double(heatMax))
                        fill = theme.heatLowColor.interpolated(to: theme.heatHighColor, t: CGFloat(t))
                    }
                }
            }

            let radius = keyRect.height * 0.12
            let path = NSBezierPath(roundedRect: keyRect, xRadius: radius, yRadius: radius)
            fill.setFill()
            path.fill()
            theme.keycapBorderColor.setStroke()
            path.lineWidth = 1
            path.stroke()

            guard !key.label.isEmpty else { continue }
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: labelColor,
                .paragraphStyle: paragraph,
            ]
            let textSize = (key.label as NSString).size(withAttributes: attributes)
            let textRect = NSRect(
                x: keyRect.minX,
                y: keyRect.midY - textSize.height / 2,
                width: keyRect.width,
                height: textSize.height
            )
            (key.label as NSString).draw(in: textRect, withAttributes: attributes)
        }
    }
}
