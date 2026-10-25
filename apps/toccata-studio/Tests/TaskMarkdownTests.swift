import Foundation
import XCTest
@testable import toccata_studio

final class TaskMarkdownTests: XCTestCase {
    func testHeadingListsAndQuoteAreBlocks() {
        let blocks = TaskMarkdownParser.blocks(from: """
        # 本周目标
        **完成设计**
        - 整理任务
        2. 验证交互
        > 保留原文
        ---
        """)
        XCTAssertEqual(blocks.map(\.kind), [
            .heading(level: 1, text: "本周目标"),
            .paragraph("**完成设计**"),
            .unorderedItem("整理任务"),
            .orderedItem(number: 2, text: "验证交互"),
            .quote("保留原文"),
            .divider
        ])
    }

    func testInlineStrongAndLinkUseNativeMarkdownParsing() {
        let text = TaskMarkdownInline.attributedString("**重点** [链接](https://example.com)")
        XCTAssertEqual(String(text.characters), "重点 链接")
        XCTAssertTrue(text.runs.contains { $0.link?.absoluteString == "https://example.com" })
    }

    func testCodeFenceKeepsMarkdownLiteral() {
        let blocks = TaskMarkdownParser.blocks(from: """
        ```swift
        let title = "**不解析**"
        let command = "SELECT ';'"
        ```
        """)
        XCTAssertEqual(blocks.map(\.kind), [
            .code(language: "swift", text: "let title = \"**不解析**\"\nlet command = \"SELECT ';'\"")
        ])
    }

    func testUnclosedFenceDoesNotDropContent() {
        let blocks = TaskMarkdownParser.blocks(from: "~~~\n第一行\n**第二行**")
        XCTAssertEqual(blocks.map(\.kind), [.code(language: nil, text: "第一行\n**第二行**")])
    }

    func testInvalidMarkersRemainPlainParagraph() {
        let blocks = TaskMarkdownParser.blocks(from: "#notHeading\n1.notList\n普通内容")
        XCTAssertEqual(blocks.map(\.kind), [.paragraph("#notHeading 1.notList 普通内容")])
        XCTAssertEqual(String(TaskMarkdownInline.attributedString("Hello, 任务。").characters), "Hello, 任务。")
    }
}
