import Foundation

/// Screen coordinates use AppKit's bottom-left origin; row coordinates use the
/// SwiftUI list's top-left origin. Opening an editor never changes the list frame.
enum MenuPanelLayout {
    static func listSize(in screen: CGRect) -> CGSize {
        CGSize(width: min(312, screen.width - 32), height: max(300, min(554, screen.height - 24)))
    }

    static func listFrame(anchor: CGRect, screen: CGRect) -> CGRect {
        let size = listSize(in: screen)
        let x = min(max(anchor.midX - size.width / 2, screen.minX + 8), screen.maxX - size.width - 8)
        let top = min(anchor.minY - 6, screen.maxY - 6)
        let y = max(screen.minY + 8, top - size.height)
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    static func editorFrame(list: CGRect, row: CGRect?, screen: CGRect) -> CGRect {
        let width = min(400, screen.width - 16)
        let height = min(300, screen.height - 16)
        let gap: CGFloat = 0
        let leftX = list.minX - gap - width
        let rightX = list.maxX + gap
        let x: CGFloat
        if leftX >= screen.minX + 8 {
            x = leftX
        } else if rightX + width <= screen.maxX - 8 {
            x = rightX
        } else {
            // Very narrow displays keep both windows on-screen as far as possible.
            x = screen.minX + 8
        }
        let rowTop = min(max(row?.minY ?? 0, 0), list.height - 40)
        let top = min(list.maxY - rowTop, screen.maxY - 8)
        let y = min(max(top - height, screen.minY + 8), screen.maxY - height - 8)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
