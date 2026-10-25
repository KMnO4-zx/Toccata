import AppKit
import SwiftUI
import XCTest
@testable import toccata_studio

@MainActor
final class MarkdownAppearanceTests: XCTestCase {
    func testExplicitSchemeResolvesDynamicTextIndependentlyOfAmbientAppearance() async throws {
        let lightColor = NSColor(srgbRed: 0.12, green: 0.24, blue: 0.36, alpha: 1)
        let darkColor = NSColor(srgbRed: 0.91, green: 0.82, blue: 0.73, alpha: 0.85)
        let dynamicColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? darkColor : lightColor
        }
        let aqua = try XCTUnwrap(NSAppearance(named: .aqua))
        let darkAqua = try XCTUnwrap(NSAppearance(named: .darkAqua))
        var darkUnderLight: MarkdownEditorStyle?
        var lightUnderDark: MarkdownEditorStyle?
        aqua.performAsCurrentDrawingAppearance {
            darkUnderLight = MarkdownEditorStyle(fontSize: 13, textColor: dynamicColor, colorScheme: .dark)
        }
        darkAqua.performAsCurrentDrawingAppearance {
            lightUnderDark = MarkdownEditorStyle(fontSize: 13, textColor: dynamicColor, colorScheme: .light)
        }
        let expectedDark = MarkdownEditorStyle(fontSize: 13, textColor: darkColor, colorScheme: .dark)
        let expectedLight = MarkdownEditorStyle(fontSize: 13, textColor: lightColor, colorScheme: .light)
        XCTAssertEqual(darkUnderLight?.variables["--editor-text"], expectedDark.variables["--editor-text"])
        XCTAssertEqual(lightUnderDark?.variables["--editor-text"], expectedLight.variables["--editor-text"])
        XCTAssertNotEqual(darkUnderLight?.variables["--editor-text"], lightUnderDark?.variables["--editor-text"])
    }

    func testFixedCustomTextColorIsPreservedAcrossAppearanceChanges() async {
        let textColor = NSColor(srgbRed: 0.25, green: 0.45, blue: 0.7, alpha: 0.8)
        let light = MarkdownEditorStyle(fontSize: 15, textColor: textColor, colorScheme: .light)
        let dark = MarkdownEditorStyle(fontSize: 15, textColor: textColor, colorScheme: .dark)
        XCTAssertEqual(light.variables["--editor-text"], dark.variables["--editor-text"])
        XCTAssertEqual(light.fontSize, 15)
        XCTAssertEqual(dark.fontSize, 15)
        XCTAssertEqual(light.colorSchemeName, "light")
        XCTAssertEqual(dark.colorSchemeName, "dark")
        XCTAssertNotEqual(light, dark)
    }

    func testSupportingColorsTrackAppearanceAlongsideBodyText() async throws {
        let light = MarkdownEditorStyle(fontSize: 12, textColor: .labelColor, colorScheme: .light)
        let dark = MarkdownEditorStyle(fontSize: 12, textColor: .labelColor, colorScheme: .dark)
        for key in ["--editor-text", "--editor-placeholder", "--editor-code-background", "--editor-quote-text", "--editor-border", "--editor-scrollbar"] {
            let lightValue = try XCTUnwrap(light.variables[key], key)
            let darkValue = try XCTUnwrap(dark.variables[key], key)
            XCTAssertNotEqual(lightValue, darkValue, "\(key) must adapt to the selected appearance")
        }
        for key in ["--editor-link", "--editor-code-text", "--editor-scrollbar-hover", "--editor-selection", "--editor-selection-text"] {
            XCTAssertNotNil(light.variables[key], key)
            XCTAssertNotNil(dark.variables[key], key)
        }
    }
}
