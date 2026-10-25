#!/usr/bin/env swift
import AppKit
import Foundation

// Run from the project root with: swift scripts/generate-branding.swift
// Reuse the sidebar's native symbol instead of maintaining a separate logo drawing.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let branding = root.appendingPathComponent("shared/branding")
let resources = root.appendingPathComponent("apps/toccata-studio/Resources")
let iconset = root.appendingPathComponent(".build/branding/AppIcon.iconset")
let fileManager = FileManager.default
for directory in [branding, resources, iconset] {
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
}

let blue = NSColor(srgbRed: 0, green: 122 / 255, blue: 1, alpha: 1)
let configuration = NSImage.SymbolConfiguration(pointSize: 1024, weight: .regular)
    .applying(NSImage.SymbolConfiguration(paletteColors: [blue]))
guard let symbol = NSImage(systemSymbolName: "square.stack.3d.up.fill", accessibilityDescription: "Toccata")?
    .withSymbolConfiguration(configuration) else {
    fatalError("The Toccata symbol is unavailable on this macOS version.")
}

func png(size: Int, appIcon: Bool) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                 isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    context.cgContext.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    if appIcon {
        let plate = NSBezierPath(roundedRect: NSRect(x: 52, y: 52, width: 920, height: 920),
                                 xRadius: 208, yRadius: 208)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.16)
        shadow.shadowBlurRadius = 18
        shadow.shadowOffset = NSSize(width: 0, height: -8)
        shadow.set()
        NSColor.white.setFill()
        plate.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGradient(starting: .white, ending: NSColor(srgbRed: 0.95, green: 0.97, blue: 1, alpha: 1))!
            .draw(in: plate, angle: -90)
    }
    let height: CGFloat = appIcon ? 596 : 864
    let width = height * symbol.size.width / symbol.size.height
    symbol.draw(in: NSRect(x: (1024 - width) / 2, y: (1024 - height) / 2, width: width, height: height))
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}

try png(size: 1024, appIcon: false).write(to: branding.appendingPathComponent("toccata-mark.png"))
try png(size: 1024, appIcon: true).write(to: branding.appendingPathComponent("toccata-app-icon.png"))
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        try png(size: size * scale, appIcon: true)
            .write(to: iconset.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["--convert", "icns", iconset.path, "--output", resources.appendingPathComponent("AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Generated Toccata branding PNGs and AppIcon.icns from square.stack.3d.up.fill")
