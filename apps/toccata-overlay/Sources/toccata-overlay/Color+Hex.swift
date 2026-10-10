import AppKit

extension NSColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let value = UInt64(s, radix: 16) else { return nil }
        let r, g, b, a: CGFloat
        if s.count == 6 {
            r = CGFloat((value >> 16) & 0xFF) / 255
            g = CGFloat((value >> 8) & 0xFF) / 255
            b = CGFloat(value & 0xFF) / 255
            a = 1
        } else {
            r = CGFloat((value >> 24) & 0xFF) / 255
            g = CGFloat((value >> 16) & 0xFF) / 255
            b = CGFloat((value >> 8) & 0xFF) / 255
            a = CGFloat(value & 0xFF) / 255
        }
        self.init(srgbRed: r, green: g, blue: b, alpha: a)
    }

    func interpolated(to other: NSColor, t: CGFloat) -> NSColor {
        let c1 = usingColorSpace(.sRGB) ?? self
        let c2 = other.usingColorSpace(.sRGB) ?? other
        let k = max(0, min(1, t))
        return NSColor(
            srgbRed: c1.redComponent + (c2.redComponent - c1.redComponent) * k,
            green: c1.greenComponent + (c2.greenComponent - c1.greenComponent) * k,
            blue: c1.blueComponent + (c2.blueComponent - c1.blueComponent) * k,
            alpha: c1.alphaComponent + (c2.alphaComponent - c1.alphaComponent) * k
        )
    }
}
