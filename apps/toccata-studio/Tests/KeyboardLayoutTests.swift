import Foundation
import XCTest
@testable import toccata_studio

final class KeyboardLayoutTests: XCTestCase {
    private func key(_ code: Int, in layout: KeyboardLayout = .magicKeyboard,
                     file: StaticString = #filePath, line: UInt = #line) throws -> KeyboardLayout.Key {
        try XCTUnwrap(layout.keys.first { $0.code == code }, "缺少 keycode \(code)", file: file, line: line)
    }

    func testMagicKeyboardResourceLoadsAndRowsShareWidth() throws {
        let layout = KeyboardLayout.magicKeyboard
        XCTAssertTrue(layout.isValid, layout.loadError ?? "布局无效")
        XCTAssertNil(layout.loadError)
        XCTAssertEqual(layout.id, "magic-keyboard-ansi")
        XCTAssertEqual(layout.keys.count, 78)
        XCTAssertEqual(layout.widthUnits, 14.5, accuracy: 0.000_001)
        XCTAssertEqual(layout.heightUnits, 6, accuracy: 0.000_001)

        let rows = Dictionary(grouping: layout.keys, by: \.row)
        XCTAssertEqual(rows.count, 6)
        for (row, keys) in rows {
            let width = keys.map { $0.x + $0.w }.max() ?? 0
            XCTAssertEqual(width, layout.widthUnits, accuracy: 0.000_001, "第 \(row) 行宽度不一致")
        }
        XCTAssertEqual(try key(63).label, "🌐 fn")
        XCTAssertEqual(try key(127).label, "lock")
    }

    func testRealKeycodesAndIdentitiesAreUnique() {
        let layout = KeyboardLayout.magicKeyboard
        let codes = layout.keys.compactMap(\.code)
        XCTAssertEqual(codes.count, layout.keys.count)
        XCTAssertEqual(Set(codes).count, codes.count)
        XCTAssertEqual(Set(layout.keys.map(\.id)).count, layout.keys.count)
        for code in codes {
            XCTAssertEqual(layout.keys.first { $0.code == code }?.id, "keycode-\(code)")
        }
    }

    func testLeftAndRightModifiersHaveDifferentIdentities() throws {
        for (leftCode, rightCode) in [(56, 60), (55, 54), (58, 61)] {
            let left = try key(leftCode)
            let right = try key(rightCode)
            XCTAssertNotEqual(left.code, right.code)
            XCTAssertNotEqual(left.id, right.id)
            XCTAssertEqual(left.label, right.label)
        }
    }

    func testArrowKeysAreHalfHeightWithInvertedTOffsets() throws {
        let left = try key(123)
        let up = try key(126)
        let down = try key(125)
        let right = try key(124)

        for arrow in [left, up, down, right] {
            XCTAssertEqual(arrow.h, 0.5, accuracy: 0.000_001)
        }
        XCTAssertEqual(up.y, 5, accuracy: 0.000_001)
        XCTAssertEqual(left.y, 5.5, accuracy: 0.000_001)
        XCTAssertEqual(down.y, 5.5, accuracy: 0.000_001)
        XCTAssertEqual(right.y, 5.5, accuracy: 0.000_001)
        XCTAssertEqual(up.x, down.x, accuracy: 0.000_001)
        XCTAssertEqual(left.x + 1, up.x, accuracy: 0.000_001)
        XCTAssertEqual(down.x + 1, right.x, accuracy: 0.000_001)
    }

    func testParserDefaultsAndStableDecorationIdentity() throws {
        let data = Data(#"""
        {
          "id": "defaults",
          "rows": [[
            { "code": 1, "label": "A" },
            { "code": 2, "label": "", "w": 2 },
            { "id": "status-light", "code": null, "decor": true, "label": "•" }
          ]]
        }
        """#.utf8)
        let layout = try KeyboardLayout.parse(data)
        XCTAssertEqual(layout.unit, 54, accuracy: 0.000_001)
        XCTAssertEqual(layout.keyGap, 6, accuracy: 0.000_001)

        let first = try key(1, in: layout)
        XCTAssertEqual(first.x, 0, accuracy: 0.000_001)
        XCTAssertEqual(first.y, 0, accuracy: 0.000_001)
        XCTAssertEqual(first.w, 1, accuracy: 0.000_001)
        XCTAssertEqual(first.h, 1, accuracy: 0.000_001)

        let space = try key(2, in: layout)
        XCTAssertEqual(space.x, 1, accuracy: 0.000_001)
        XCTAssertEqual(space.y, 0, accuracy: 0.000_001)
        XCTAssertEqual(space.h, 1, accuracy: 0.000_001)
        XCTAssertEqual(space.displayLabel, "Space")

        let decoration = try XCTUnwrap(layout.keys.first { $0.isDecoration })
        XCTAssertEqual(decoration.id, "decor-status-light")
        XCTAssertEqual(try KeyboardLayout.parse(data).keys.first { $0.isDecoration }?.id, decoration.id)
    }

    func testScalingUsesOneGlobalCoordinateSystem() throws {
        let layout = KeyboardLayout.magicKeyboard
        let original = layout.scaled(toWidth: 783)
        let doubled = layout.scaled(toWidth: 1_566)
        XCTAssertEqual(original.size, CGSize(width: 783, height: 324))
        XCTAssertEqual(doubled.size, CGSize(width: 1_566, height: 648))
        XCTAssertEqual(original.keys.count, doubled.keys.count)

        let escape = try XCTUnwrap(original.keys.first { $0.key.code == 53 })
        XCTAssertEqual(escape.frame, CGRect(x: 3, y: 3, width: 48, height: 48))
        for (first, second) in zip(original.keys, doubled.keys) {
            XCTAssertEqual(first.id, second.id)
            XCTAssertEqual(second.frame.minX, first.frame.minX * 2, accuracy: 0.000_001)
            XCTAssertEqual(second.frame.minY, first.frame.minY * 2, accuracy: 0.000_001)
            XCTAssertEqual(second.frame.width, first.frame.width * 2, accuracy: 0.000_001)
            XCTAssertEqual(second.frame.height, first.frame.height * 2, accuracy: 0.000_001)
        }
    }

    func testNarrowRowsAreNotIndependentlyStretched() throws {
        let data = Data(#"""
        {
          "unit": 10,
          "keyGap": 0,
          "rows": [
            [{ "code": 1, "label": "wide", "w": 2 }],
            [{ "code": 2, "label": "normal" }]
          ]
        }
        """#.utf8)
        let scaled = try KeyboardLayout.parse(data).scaled(toWidth: 200)
        XCTAssertEqual(scaled.size, CGSize(width: 200, height: 200))
        XCTAssertEqual(scaled.keys[0].frame.width, 200, accuracy: 0.000_001)
        XCTAssertEqual(scaled.keys[1].frame.width, 100, accuracy: 0.000_001)
        XCTAssertEqual(scaled.keys[1].frame.minY, 100, accuracy: 0.000_001)
    }

    func testDuplicateKeycodesAreRejected() {
        let data = Data(#"""
        { "rows": [[
          { "code": 7, "label": "first" },
          { "code": 7, "label": "duplicate" }
        ]] }
        """#.utf8)
        XCTAssertThrowsError(try KeyboardLayout.parse(data)) { error in
            XCTAssertEqual(error as? KeyboardLayoutError, .duplicateKeycode(7))
        }
    }

    func testHeatmapIntensityIsNormalizedAndMonotonic() {
        XCTAssertEqual(KeyboardHeatmap.intensity(count: -1, maxCount: 100), 0)
        XCTAssertEqual(KeyboardHeatmap.intensity(count: 0, maxCount: 100), 0)
        XCTAssertEqual(KeyboardHeatmap.intensity(count: 1, maxCount: 0), 0)
        XCTAssertEqual(KeyboardHeatmap.intensity(count: 100, maxCount: 100), 1)
        XCTAssertEqual(KeyboardHeatmap.intensity(count: 101, maxCount: 100), 1)
        XCTAssertEqual(
            KeyboardHeatmap.intensity(count: 10, maxCount: 100),
            log1p(10.0) / log1p(100.0),
            accuracy: 0.000_001
        )

        let values = (0...100).map { KeyboardHeatmap.intensity(count: $0, maxCount: 100) }
        for (lower, higher) in zip(values, values.dropFirst()) {
            XCTAssertGreaterThanOrEqual(higher, lower)
        }
    }
}
